/*
 * Arm the ATBM/Z7682 master_wdt so it reboots BOTH chips (master-power state
 * machine: master_power_off -> "reboot two devices" -> HI_SDIO_Host_Reboot).
 * msg_id 0x14 = SET-PERIOD+START (payload w0 = seconds). Nothing in thingino
 * feeds it (0x15), so once armed it fires at the period. 0x12 = STOP first.
 *   usage: mcu_wdt_arm [seconds]   (default 20)
 */
#include <stdio.h>
#include <stdlib.h>

int rtos_cmd_init(void);
int rtos_cmd_send(int cmd_id, void *in_data, int in_len,
		  void *out_data, int *out_len, int timeout_ms);

int main(int argc, char **argv)
{
	unsigned int period = 20;
	int ret;

	if (argc > 1)
		period = (unsigned int)atoi(argv[1]);

	rtos_cmd_init();

	printf("master_wdt STOP (0x12)...\n");
	rtos_cmd_send(0x12, NULL, 0, NULL, NULL, 5000);

	printf("master_wdt SET-PERIOD+START (0x14) period=%u s ...\n", period);
	ret = rtos_cmd_send(0x14, &period, sizeof(period), NULL, NULL, 5000);

	printf("arm ret=%d -- unfed master_wdt should reboot the board in ~%u s\n",
	       ret, period);
	return 0;
}
