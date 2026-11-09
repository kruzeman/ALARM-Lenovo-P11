#!/usr/bin/env python3
"""fdt-set-props.py — правка свойств в DTB без decompile/recompile.

Зачем: dtc round-trip на этом дереве не байт-стабилен (decompile+recompile
даёт другой размер), а по правилам порта DTB правится только так, чтобы
разница была ровно в нужных свойствах. Этот инструмент работает с самим
flattened device tree: разбирает struct block, меняет свойства у выбранного
узла и собирает blob заново, не трогая остальное.

    ./fdt-set-props.py in.dtb out.dtb --node compatible=usb-c-connector \\
        --del pd-disable \\
        --set sink-pdos=u32:0x40192c,0x2d0c8 \\
        --set op-sink-microwatt=u32:18000000

Значения: u32:a,b,c — массив ячеек; str:текст — строка (с завершающим нулём);
empty: — пустое свойство (флаг).
"""
import argparse
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def align4(n):
    return (n + 3) & ~3


class Node:
    __slots__ = ("name", "props", "children")

    def __init__(self, name):
        self.name = name
        self.props = []          # [(name, bytes)]
        self.children = []

    def prop(self, name):
        for n, v in self.props:
            if n == name:
                return v
        return None


def parse_struct(blob, off, size):
    strings_off = struct.unpack_from(">I", blob, 12)[0]
    pos = off
    end = off + size
    root = None
    stack = []
    pend = None

    while pos < end:
        (tok,) = struct.unpack_from(">I", blob, pos)
        pos += 4
        if tok == FDT_BEGIN_NODE:
            nul = blob.index(b"\0", pos)
            name = blob[pos:nul].decode()
            pos = align4(nul + 1)
            node = Node(name)
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            stack.append(node)
        elif tok == FDT_END_NODE:
            stack.pop()
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", blob, pos)
            pos += 8
            data = blob[pos:pos + length]
            pos = align4(pos + length)
            nul = blob.index(b"\0", strings_off + nameoff)
            pname = blob[strings_off + nameoff:nul].decode()
            stack[-1].props.append((pname, data))
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise SystemExit(f"неизвестный токен FDT {tok} по смещению {pos - 4}")
    return root


def walk(node, path=""):
    yield path + "/" + node.name, node
    for c in node.children:
        yield from walk(c, path + "/" + node.name)


def find_node(root, spec):
    key, _, val = spec.partition("=")
    for path, node in walk(root):
        if key == "name" and node.name == val:
            return path, node
        if key == "path" and path == val:
            return path, node
        if key == "compatible":
            c = node.prop("compatible")
            if c and val.encode() in c.split(b"\0"):
                return path, node
    raise SystemExit(f"узел не найден: {spec}")


def encode_value(text):
    kind, _, rest = text.partition(":")
    if kind == "empty":
        return b""
    if kind == "str":
        return rest.encode() + b"\0"
    if kind == "bytes":
        return bytes(int(x, 0) & 0xFF for x in rest.split(",") if x.strip())
    if kind == "u32":
        cells = [int(x, 0) for x in rest.split(",") if x.strip()]
        return b"".join(struct.pack(">I", c & 0xFFFFFFFF) for c in cells)
    raise SystemExit(f"непонятное значение: {text}")


def serialize(node, strings, out):
    out.append(struct.pack(">I", FDT_BEGIN_NODE))
    name = node.name.encode() + b"\0"
    out.append(name + b"\0" * (align4(len(name)) - len(name)))
    for pname, data in node.props:
        if pname not in strings:
            strings[pname] = None          # назначим смещения позже
        out.append(struct.pack(">III", FDT_PROP, len(data), 0))  # nameoff заполним позже
        pad = align4(len(data)) - len(data)
        out.append(data + b"\0" * pad)
    for c in node.children:
        serialize(c, strings, out)
    out.append(struct.pack(">I", FDT_END_NODE))


def build(root):
    strings = {}
    out = []
    serialize(root, strings, out)
    out.append(struct.pack(">I", FDT_END))
    struct_block = b"".join(out)

    # пересобрать struct с реальными nameoff
    strtab = b""
    offsets = {}
    for name in strings:
        offsets[name] = len(strtab)
        strtab += name.encode() + b"\0"

    out2 = []
    def emit(node):
        out2.append(struct.pack(">I", FDT_BEGIN_NODE))
        nm = node.name.encode() + b"\0"
        out2.append(nm + b"\0" * (align4(len(nm)) - len(nm)))
        for pname, data in node.props:
            out2.append(struct.pack(">III", FDT_PROP, len(data), offsets[pname]))
            pad = align4(len(data)) - len(data)
            out2.append(data + b"\0" * pad)
        for c in node.children:
            emit(c)
        out2.append(struct.pack(">I", FDT_END_NODE))
    emit(root)
    out2.append(struct.pack(">I", FDT_END))
    return b"".join(out2), strtab


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--node", required=True, help='name=connector | compatible=usb-c-connector | path=/x/y')
    ap.add_argument("--del", dest="delete", action="append", default=[])
    ap.add_argument("--set", action="append", default=[])
    a = ap.parse_args()

    blob = open(a.src, "rb").read()
    magic, totalsize, off_struct, off_strings, off_rsv, ver, lastver, cpu, strsize, structsize = \
        struct.unpack_from(">10I", blob, 0)
    if magic != FDT_MAGIC:
        raise SystemExit("не FDT")

    root = parse_struct(blob, off_struct, structsize)
    path, node = find_node(root, a.node)
    print(f"узел: {path}")

    for name in a.delete:
        before = len(node.props)
        node.props = [(n, v) for n, v in node.props if n != name]
        print(("  удалено " if len(node.props) < before else "  не было ") + name)

    for item in a.set:
        name, _, value = item.partition("=")
        data = encode_value(value)
        node.props = [(n, v) for n, v in node.props if n != name]
        node.props.append((name, data))
        print(f"  задано {name} = {data.hex()} ({len(data)} байт)")

    struct_block, strtab = build(root)
    rsv = blob[off_rsv:off_rsv + 16]   # одна пустая запись mem-rsvmap
    off_rsv_new = 40
    off_struct_new = align4(off_rsv_new + len(rsv))
    off_strings_new = off_struct_new + len(struct_block)
    total = off_strings_new + len(strtab)

    hdr = struct.pack(">10I", FDT_MAGIC, total, off_struct_new, off_strings_new,
                      off_rsv_new, ver, lastver, cpu, len(strtab), len(struct_block))
    out = bytearray(total)
    out[0:40] = hdr
    out[off_rsv_new:off_rsv_new + len(rsv)] = rsv
    out[off_struct_new:off_struct_new + len(struct_block)] = struct_block
    out[off_strings_new:off_strings_new + len(strtab)] = strtab
    open(a.dst, "wb").write(bytes(out))
    print(f"{a.dst}: {len(blob)} -> {total} байт")


if __name__ == "__main__":
    main()
