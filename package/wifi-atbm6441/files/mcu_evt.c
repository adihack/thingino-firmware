/* mcu_evt - listen for Cinnado S2 Z7682 MCU sensor/button events (KEY0 + PIR)
 * forwarded by the atbm6441 driver on /dev/atbm_ioctl (status_async type==6).
 * word0 bitmask: 0x01 KEY0 press, 0x02 KEY0 release, 0x08 PIR, 0x4000 tamper. */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>

static int fd = -1;

static void on_sigio(int s)
{
	unsigned char buf[256];
	int n;
	uint32_t code;
	(void)s;
	/* Drain the driver's customer-event ring: each read() pops one type=6
	 * event; a non-type-6 result means the ring is empty -> stop. */
	for (;;) {
		n = read(fd, buf, sizeof(buf));
		if (n < 8)
			break;
		if (buf[1] != 6)          /* status_async.type: 6 = MCU customer event */
			break;
		code = (uint32_t)buf[4] | ((uint32_t)buf[5] << 8) |
		       ((uint32_t)buf[6] << 16) | ((uint32_t)buf[7] << 24);
		printf("MCU event 0x%04x:", code);
		if (code & 0x0001) printf(" KEY0_PRESS");
		if (code & 0x0002) printf(" KEY0_RELEASE");
		if (code & 0x0008) printf(" PIR");
		if (code & 0x4000) printf(" TAMPER");
		if (!(code & 0x400b)) printf(" (unknown)");
		printf("\n");
		fflush(stdout);
	}
}

int main(void)
{
	int flags;
	fd = open("/dev/atbm_ioctl", O_RDWR);
	if (fd < 0) { perror("open /dev/atbm_ioctl"); return 1; }
	signal(SIGIO, on_sigio);
	if (fcntl(fd, F_SETOWN, getpid()) < 0) { perror("F_SETOWN"); return 1; }
	flags = fcntl(fd, F_GETFL);
	if (fcntl(fd, F_SETFL, flags | FASYNC) < 0) { perror("F_SETFL FASYNC"); return 1; }
	printf("mcu_evt: listening for KEY0/PIR on /dev/atbm_ioctl (run 'mcu_test --pir_enable' for PIR)\n");
	fflush(stdout);
	for (;;) pause();
	return 0;
}