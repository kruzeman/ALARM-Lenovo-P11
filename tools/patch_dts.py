import re

src = open('base_fixed.dts').read().split('\n')

PINCTRL = ['\t\t\tpogo_tp_irq_default: pogo-tp-irq-default-state {',
           '\t\t\t\tpins = "gpio93";',
           '\t\t\t\tfunction = "gpio";',
           '\t\t\t\tdrive-strength = <0x02>;',
           '\t\t\t\tbias-disable;',
           '\t\t\t\tinput-enable;',
           '\t\t\t};',
           '\t\t\tpogo_kbd_irq_default: pogo-kbd-irq-default-state {',
           '\t\t\t\tpins = "gpio96";',
           '\t\t\t\tfunction = "gpio";',
           '\t\t\t\tdrive-strength = <0x02>;',
           '\t\t\t\tbias-disable;',
           '\t\t\t\tinput-enable;',
           '\t\t\t};']

HID_TP = ['\t\t\t\ttouchpad@60 {',
          '\t\t\t\t\tcompatible = "hid-over-i2c";',
          '\t\t\t\t\treg = <0x60>;',
          '\t\t\t\t\thid-descr-addr = <0x01>;',
          '\t\t\t\t\tpost-power-on-delay-ms = <0x64>;',
          '\t\t\t\t\tinterrupt-parent = <&tlmm>;',
          '\t\t\t\t\tinterrupts-extended = <&tlmm 0x5d 0x08>;',
          '\t\t\t\t\tpinctrl-names = "default";',
          '\t\t\t\t\tpinctrl-0 = <&pogo_tp_irq_default>;',
          '\t\t\t\t};']

HID_KBD = ['\t\t\t\tkeyboard@61 {',
           '\t\t\t\t\tcompatible = "hid-over-i2c";',
           '\t\t\t\t\treg = <0x61>;',
           '\t\t\t\t\thid-descr-addr = <0x01>;',
           '\t\t\t\t\tpost-power-on-delay-ms = <0x64>;',
           '\t\t\t\t\tinterrupt-parent = <&tlmm>;',
           '\t\t\t\t\tinterrupts-extended = <&tlmm 0x60 0x08>;',
           '\t\t\t\t\tpinctrl-names = "default";',
           '\t\t\t\t\tpinctrl-0 = <&pogo_kbd_irq_default>;',
           '\t\t\t\t};']

def node_end(lines, start):
    """index of the line holding the closing brace of the node opened at `start`"""
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count('{') - lines[i].count('}')
        if i > start and depth == 0:
            return i
    raise ValueError('unbalanced')

# work from the bottom up so indices stay valid
targets = [
    ('\t\tpinctrl@500000 {', PINCTRL, '\t\ttlmm: pinctrl@500000 {'),
    ('\t\t\ti2c@4a80000 {', HID_TP, None),
    ('\t\t\ti2c@4a84000 {', HID_KBD, None),
]
edits = []
for pat, block, relabel in targets:
    idx = [i for i, l in enumerate(src) if l == pat]
    assert len(idx) == 1, (pat, idx)
    start = idx[0]
    edits.append((start, node_end(src, start), block, relabel))
edits.sort(reverse=True)

lines = list(src)
for start, end, block, relabel in edits:
    if relabel:
        lines[start] = relabel
    lines[end:end] = block   # insert just before the closing brace

open('patched.dts', 'w').write('\n'.join(lines))
print('ok, lines:', len(lines))
