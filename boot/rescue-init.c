/*
 * rescue-init — минимальный init для ремонта rootfs без загрузки системы.
 * Монтирует /dev/sda15, возвращает прежний модуль тачскрина из .bak,
 * пишет лог в /root/rescue.log и перезагружается.
 *
 * Собирается без libc: только системные вызовы aarch64.
 *   clang --target=aarch64-linux-gnu -nostdlib -static -ffreestanding -O2 -o init rescue-init.c
 */

#define AT_FDCWD (-100)
#define O_WRONLY 1
#define O_CREAT 64
#define O_TRUNC 512
#define SYS_openat 56
#define SYS_close 57
#define SYS_write 64
#define SYS_exit 93
#define SYS_reboot 142
#define SYS_mount 40
#define SYS_umount2 39
#define SYS_mkdirat 34
#define SYS_renameat 38
#define SYS_sync 81
#define SYS_nanosleep 101
#define SYS_mknodat 33

static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
			 : "memory");
	return x0;
}

#define sys4(n, a, b, c, d)        sys6(n, (long)(a), (long)(b), (long)(c), (long)(d), 0, 0)
#define sys3(n, a, b, c)           sys6(n, (long)(a), (long)(b), (long)(c), 0, 0, 0)
#define sys2(n, a, b)              sys6(n, (long)(a), (long)(b), 0, 0, 0, 0)
#define sys1(n, a)                 sys6(n, (long)(a), 0, 0, 0, 0, 0)

static long slen(const char *s)
{
	long n = 0;
	while (s[n])
		n++;
	return n;
}

static void puts_fd(long fd, const char *s)
{
	sys3(SYS_write, fd, s, slen(s));
}

static long open_w(const char *path)
{
	return sys4(SYS_openat, AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}

static void sleep_ms(long ms)
{
	long ts[2];
	ts[0] = ms / 1000;
	ts[1] = (ms % 1000) * 1000000L;
	sys2(SYS_nanosleep, ts, 0);
}

#define SYS_read 63
#define O_RDONLY 0

/* Скопировать файл из initramfs в целевой rootfs (для подмены модуля без загрузки системы). */
static int copy_file(const char *src, const char *dst)
{
	long in, out;
	char buf[4096];
	long n;

	in = sys6(SYS_openat, AT_FDCWD, (long)src, O_RDONLY, 0, 0, 0);
	if (in < 0)
		return -1;
	out = sys4(SYS_openat, AT_FDCWD, dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (out < 0) {
		sys1(SYS_close, in);
		return -1;
	}
	while ((n = sys3(SYS_read, in, buf, sizeof(buf))) > 0)
		sys3(SYS_write, out, buf, n);
	sys1(SYS_close, in);
	sys1(SYS_close, out);
	return 0;
}

static const char *ROOT = "/newroot";
static const char *HIMAX_DIR =
	"/newroot/usr/lib/modules/7.2.3-sm61x5-hermes/kernel/drivers/input/touchscreen/himax_hx83102e";
static const char *HIMAX = "himax_hx83102e.ko.zst";
static const char *HIMAX_BAK = "himax_hx83102e.ko.zst.bak";

static char logbuf[4096];
static int loglen;

static void log_add(const char *s)
{
	while (*s && loglen < (int)sizeof(logbuf) - 1)
		logbuf[loglen++] = *s++;
	logbuf[loglen] = 0;
}

static void log_put(const char *s)
{
	log_add(s);
	puts_fd(1, s);
}

/* собрать путь в статический буфер */
static char path_buf[512];
static const char *join(const char *dir, const char *name)
{
	int i = 0;
	while (dir[i] && i < (int)sizeof(path_buf) - 2) {
		path_buf[i] = dir[i];
		i++;
	}
	path_buf[i++] = '/';
	while (*name && i < (int)sizeof(path_buf) - 1)
		path_buf[i++] = *name++;
	path_buf[i] = 0;
	return path_buf;
}

void _start(void)
{
	long r;
	long fd;

	log_put("rescue-init: start\n");

	sys3(SYS_mkdirat, AT_FDCWD, ROOT, 0755);
	sleep_ms(1500); /* дать UFS/разделам появиться */

	r = sys4(SYS_mount, "/dev/sda15", ROOT, "ext4", 0);
	if (r) {
		/* попробуем ещё раз — диск иногда поднимается позже */
		sleep_ms(3000);
		r = sys4(SYS_mount, "/dev/sda15", ROOT, "ext4", 0);
	}
	if (r) {
		log_put("rescue-init: mount /dev/sda15 FAILED\n");
		goto out;
	}
	log_put("rescue-init: /dev/sda15 mounted rw\n");

	fd = open_w("/newroot/root/rescue.log");
	if (fd >= 0) {
		sys3(SYS_write, fd, "rescue: mounted\n", 16);
		sys1(SYS_close, fd);
	}

	r = sys4(SYS_renameat, AT_FDCWD, join(HIMAX_DIR, HIMAX_BAK),
		 AT_FDCWD, join(HIMAX_DIR, HIMAX));
	if (r) {
		log_put("rescue-init: restore himax module FAILED\n");
		/* если .bak уже переименован раньше — ничего страшного */
	} else {
		log_put("rescue-init: old himax module restored\n");
	}

	/* Подмена модуля кодека: в initramfs лежит рабочий snd-soc-es7210.ko.zst,
	 * кладём его в rootfs, чтобы система загрузилась с проверенной версией.
	 */
	if (copy_file("/es7210.ko.zst",
		      "/newroot/usr/lib/modules/7.2.3-sm61x5-hermes/kernel/sound/soc/codecs/snd-soc-es7210.ko.zst") == 0)
		log_put("rescue-init: es7210 module replaced\n");
	else
		log_put("rescue-init: es7210 module copy FAILED\n");

	/* страховка: убрать drop-in, который мог задержать/сломать upower */
	sys4(SYS_renameat, AT_FDCWD,
	     "/newroot/etc/systemd/system/upower.service.d/10-j606f-timeout.conf",
	     AT_FDCWD,
	     "/newroot/etc/systemd/system/upower.service.d/10-j606f-timeout.conf.disabled");

	sys1(SYS_sync, 0);

	fd = open_w("/newroot/root/rescue.log");
	if (fd >= 0) {
		sys3(SYS_write, fd, logbuf, loglen);
		sys1(SYS_close, fd);
	}
	sys1(SYS_sync, 0);

	sys2(SYS_umount2, ROOT, 0);
	log_put("rescue-init: done, restarting to bootloader\n");
	sys1(SYS_sync, 0);
out:
	sleep_ms(500);
	/* RB_RESTART2 с командой "bootloader" — устройство уходит в fastboot,
	 * чтобы сразу вернуть активный слот B без ручных кнопок.
	 */
	sys4(SYS_reboot, 0xfee1dead, 672274793, 0xa1b2c3d4, "bootloader");
	sleep_ms(1000);
	/* запасной вариант: выключиться */
	sys4(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0);
	for (;;)
		sleep_ms(1000);
}
