/*
 * librtos - local RTOS command library for the ATBM6441/6461 on-package MCU.
 *
 * Talks to the MCU over the WiFi driver's /dev/atbm_ioctl general-command
 * bridge (WSM). Source reconstruction (from DWARF: atbm6441/rtos_cmdset_atbm6441.c)
 * of the vendor librtos.so, so it can be built from source instead of shipping a
 * binary blob. Only the functional entry points are kept; CRT/.init/.fini glue is
 * left to the toolchain.
 *
 * Consumers: z7682_disable_wdt (rtos_cmd_init + rtos_cmd_send with cmd 0x13).
 */

#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define ATBM_DEV_PATH			"/dev/atbm_ioctl"
#define ATBM_OPEN_RETRY_FLAGS		0x102
#define ATBM_OPEN_RDWR_FLAGS		2

#define ATBM_GENERAL_CMD		0x80047946UL
#define ATBM_PS_SET			0x80017900UL
#define ATBM_PRIV_IOCTL_7926		0x20007926UL
#define ATBM_PRIV_IOCTL_791F		0x2000791FUL
#define ATBM_MCU_FW_UPDATE		0x8004791AUL

#define WSM_MAGIC			0xacaccacaU
#define WSM_DATA_SIZE			512
#define UPDATE_DATA_SIZE		1024

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

enum {
	PS_TYPE_NO_SLEEP = 0,
	PS_TYPE_MODEM_SLEEP = 1,
	PS_TYPE_LIGHT_SLEEP = 2,
	PS_TYPE_DEEP_SLEEP = 3,
	PS_TYPE_MAX = 4,
};

struct powersave_mode {
	u32 status;
	u32 Flags;
	u8 powersave_mode;
	u8 powerave_level;
	u16 fastsleep_time;
};

struct update_info {
	u32 status;
	u32 len;
	u8 data[UPDATE_DATA_SIZE];
	u8 start;
	u8 end;
	u8 restart;
	u8 reserved[1];
};

typedef struct _spi_cmd {
	int maigc;
	int cmd_id;
	u32 crc;
	int payload_len;
	char data[];
} SPI_Cmd_t;

typedef struct _spi_resp {
	int maigc;
	int cmd_id;
	u32 crc;
	int retcode;
	int payload_len;
	char data[];
} SPI_Resp_t;

struct wsm_general_cmd {
	int maigc;
	int cmd_id;
	u32 crc;
	int retcode;
	int data_len;
	char data[WSM_DATA_SIZE];
};

static int g_6441_ready;
int g_6441_driver_ready = 1;
pthread_mutex_t g_rtos_cmd_mutex = PTHREAD_MUTEX_INITIALIZER;
static u32 crc_table[256];

static u32 crc32_compute(u32 crc, const char *buffer, u32 size)
{
	u32 i;

	for (i = 0; i < size; ++i) {
		crc = crc_table[((u8)buffer[i] ^ (u8)crc) & 0xff] ^
		      (crc >> 8);
	}

	return crc;
}

static void crc32_table_init(void)
{
	u32 i;

	for (i = 0; i != 256; ++i) {
		u32 c = i;
		int j;

		for (j = 8; j != 0; --j) {
			if (c & 1)
				c = (c >> 1) ^ 0xedb88320U;
			else
				c >>= 1;
		}

		crc_table[i] = c;
	}
}

int rtos_cmd_is_ready(void)
{
	if (g_6441_ready == 0) {
		int timeout = 500;

		for (;;) {
			if (access(ATBM_DEV_PATH, 0) == 0) {
				g_6441_ready = 1;
				break;
			}

			--timeout;
			usleep(10000);

			if (timeout == 0)
				return g_6441_ready;
		}
	}

	return 1;
}

int rtos_cmd_send_retry(void *in_data, int in_len, void *out_data,
			int *out_len, int timeout_ms)
{
	struct wsm_general_cmd general_cmd;
	int rtos_fd;

	(void)timeout_ms;

	memset(&general_cmd, 0, sizeof(general_cmd));

	rtos_fd = open(ATBM_DEV_PATH, ATBM_OPEN_RETRY_FLAGS);
	if (rtos_fd < 0) {
		printf("open %s failed\n", ATBM_DEV_PATH);
	} else {
		memcpy(&general_cmd, in_data, (size_t)in_len);

		if (ioctl(rtos_fd, ATBM_GENERAL_CMD, &general_cmd) < 0) {
			puts("ioctl ATBM_GENERAL_CMD error");
		} else {
			memcpy(out_data, &general_cmd,
			       (size_t)general_cmd.data_len + 20);
			*out_len = general_cmd.data_len;
		}

		if (rtos_fd == 0)
			return 0;
	}

	close(rtos_fd);
	return 0;
}

void rtos_cmd_dump_data(char *data, int len)
{
	int i;

	for (i = 0; i < len; ++i) {
		if (i > 0 && (i & 0xf) == 0)
			putchar('\n');
		printf("%02x ", (unsigned char)data[i]);
	}

	putchar('\n');
}

int rtos_cmd_send(int cmd_id, void *in_data, int in_len,
		  void *out_data, int *out_len, int timeout_ms)
{
	char rx_buf[sizeof(struct wsm_general_cmd)];
	char tx_buf[sizeof(struct wsm_general_cmd)];
	SPI_Cmd_t *cmd = (SPI_Cmd_t *)tx_buf;
	SPI_Resp_t *resp = (SPI_Resp_t *)rx_buf;
	int rx_len;
	int ret;

	memset(rx_buf, 0, sizeof(rx_buf));
	memset(tx_buf, 0, sizeof(tx_buf));

	if (rtos_cmd_is_ready() == 0)
		return -1;

	pthread_mutex_lock(&g_rtos_cmd_mutex);

	cmd->maigc = (int)WSM_MAGIC;
	cmd->cmd_id = cmd_id;

	if (in_data != NULL && in_len != 0) {
		cmd->payload_len = in_len;
		memcpy(cmd->data, in_data, (size_t)in_len);
	}

	cmd->crc = crc32_compute(0xffffffffU, cmd->data,
				 (u32)cmd->payload_len);

	ret = rtos_cmd_send_retry(cmd, in_len + 16, resp, &rx_len, timeout_ms);
	if (ret < 0) {
		printf("%s,%d ret=%d\n", "rtos_cmd_send", 172, ret);
		pthread_mutex_unlock(&g_rtos_cmd_mutex);
		printf("%s,%d spicmd:%d run error.\n",
		       "rtos_cmd_send", 214, cmd_id);
		return -1;
	}

	if (resp->retcode != 0) {
		printf("%s,%d cmd:%d resp->retcode=%d\n",
		       "rtos_cmd_send", 177, cmd_id, resp->retcode);
	} else if (resp->payload_len > 0) {
		u32 crc = crc32_compute(0xffffffffU, resp->data,
					(u32)resp->payload_len);

		if (resp->crc == crc) {
			if (out_data != NULL)
				memcpy(out_data, resp->data,
				       (size_t)resp->payload_len);
			if (out_len != NULL)
				*out_len = resp->payload_len;
		}
	}

	pthread_mutex_unlock(&g_rtos_cmd_mutex);
	return 0;
}

int rtos_cmd_master_poweroff(void)
{
	struct powersave_mode ps;
	int rtos_fd;
	int ret;

	memset(&ps, 0, sizeof(ps));

	if (g_6441_driver_ready == 0)
		return 0;

	puts("apollo sdio1.0: master poweroff.\n");

	pthread_mutex_lock(&g_rtos_cmd_mutex);

	rtos_fd = open(ATBM_DEV_PATH, ATBM_OPEN_RDWR_FLAGS);
	if (rtos_fd < 0) {
		printf("open %s failed\n", ATBM_DEV_PATH);
		ret = -1;
		close(rtos_fd);
		goto poweroff_done;
	}

	ps.powersave_mode = 2;
	ps.powerave_level = 1;

	ret = ioctl(rtos_fd, ATBM_PS_SET, &ps);
	if (ret < 0) {
		puts("ioctl ATBM_PS_SET error");
	} else {
		ioctl(rtos_fd, ATBM_PRIV_IOCTL_7926, 0);
		ioctl(rtos_fd, ATBM_PRIV_IOCTL_791F, 0);
	}

	if (rtos_fd != 0)
		close(rtos_fd);

poweroff_done:
	system("ifconfig wlan0 down");
	system("rmmod atbm6041_wifi_sdio");
	g_6441_driver_ready = 0;
	sleep(1);
	pthread_mutex_unlock(&g_rtos_cmd_mutex);
	return ret;
}

int rtos_cmd_mcu_upgrade(char *file_name)
{
	struct update_info update;
	FILE *file = NULL;
	int fd;
	int len;
	int read_len;
	int ret_size;
	int first_write;
	int ret;

	if (g_6441_driver_ready == 0)
		return 0;

	pthread_mutex_lock(&g_rtos_cmd_mutex);

	memset(&update, 0, sizeof(update));

	fd = open(ATBM_DEV_PATH, ATBM_OPEN_RDWR_FLAGS);
	if (fd < 0) {
		printf("open %s failed\n", ATBM_DEV_PATH);
		close(fd);
		goto err_unlock;
	}

	file = fopen(file_name, "rb");
	if (file == NULL) {
		printf("Line:%d invalid fw path %s\n", 305, file_name);
		if (fd != 0)
			close(fd);
		goto err_unlock;
	}

	fseek(file, 0, SEEK_END);
	len = (int)ftell(file);
	fseek(file, 0, SEEK_SET);

	printf("file:%s  size:%d bytes\n", file_name, len);

	if (len < 513) {
		printf("Line:%d The file length is invalid\n", 316);
		goto err_close;
	}

	if (ioctl(fd, ATBM_MCU_FW_UPDATE, &update) != 0) {
		printf("Line:%d start update err\n", 323);
		goto err_close;
	}

	update.start = 1;
	first_write = 1;

	for (;;) {
		read_len = 512;
		if (len < 512)
			read_len = len;

		if (feof(file) != 0 || len <= 0)
			break;

		if (first_write != 0) {
			ret_size = 512;
			read_len = 512;
		} else {
			ret_size = read_len;
		}

		if ((size_t)ret_size != fread(update.data, 1,
					      (size_t)read_len, file)) {
			printf("Line:%d returned bytes not match\n", 352);
			goto err_close;
		}

		update.len = (u32)read_len;

		if (ioctl(fd, ATBM_MCU_FW_UPDATE, &update) != 0) {
			printf("Line:%d write update err\n", 362);
			goto err_close;
		}

		len -= ret_size;
		first_write = 0;
	}

	fclose(file);
	update.start = 0;
	update.end = 1;

	ret = ioctl(fd, ATBM_MCU_FW_UPDATE, &update);
	if (ret == 0) {
		close(fd);
		pthread_mutex_unlock(&g_rtos_cmd_mutex);
		return 0;
	}

	printf("Line:%d end update err:%d\n", 374, ret);

err_close:
	if (fd != 0)
		close(fd);
	if (file != NULL)
		fclose(file);

err_unlock:
	pthread_mutex_unlock(&g_rtos_cmd_mutex);
	return -1;
}

int rtos_cmd_init(void)
{
	crc32_table_init();
	return 0;
}
