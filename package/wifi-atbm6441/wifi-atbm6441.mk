################################################################################
#
# wifi-atbm6441
#
# AltoBeam ATBM6441 (Hera) SDIO WiFi + Z7682 MCU combo, built FROM SOURCE.
#
# Unlike wifi-atbm6461 (which ships a recovery-extracted .ko blob shared by the
# B6/A1 cameras), this package compiles the gtxaspec/atbm6441 driver from git
# and applies the Cinnado S2 / T23ZN CMD53-survivability fix as a reviewable
# source patch (package/all-patches/wifi-atbm6441/). The physical chip on the
# Cinnado S2 is an ATBM6441, so this is its first-class driver.
#
# Nothing binary is shipped: the MCU comms lib (files/librtos.c, a source
# reconstruction of the vendor librtos.so) and the z7682 watchdog-disable tool
# are both compiled here from source.
#
# The vendor driver has its own top-level Makefile orchestration (reads its own
# .config, then recurses into the kernel Kbuild with M=<srcdir>), so this uses
# the generic-package infra with custom BUILD_CMDS rather than kernel-module.
#
################################################################################

WIFI_ATBM6441_VERSION = 8cf360686bb4e6e41b5206adaa86c3161d7e1515
WIFI_ATBM6441_SITE = https://github.com/gtxaspec/atbm6441
WIFI_ATBM6441_SITE_METHOD = git
WIFI_ATBM6441_LICENSE = GPL-2.0

# The kernel must be built first: the driver recurses into $(LINUX_DIR) and
# links against its Module.symvers, and we read CONFIG_LOCALVERSION from the
# final merged kernel .config to place the module in the right modules dir.
WIFI_ATBM6441_DEPENDENCIES = linux

# Module filename the init (S09mmc) and wifi.mk driver registration expect.
# Set in files/driver.config as CONFIG_ATBM_MODULE_NAME="atbm6441_wifi_sdio".
WIFI_ATBM6441_KO_NAME = atbm6441_wifi_sdio

# Consumed by package/wifi/wifi.mk (via the ATBM6441_ prefix) to know what to
# modprobe in S36wireless and with which options. Must match KO_NAME above.
ATBM6441_MODULE_NAME = atbm6441_wifi_sdio
ATBM6441_MODULE_OPTS = atbm_printk_mask=0

# Read CONFIG_LOCALVERSION from the merged kernel .config (e.g. "-Archon").
# Package-specific var name to avoid clobbering other wifi packages' vars.
WIFI_ATBM6441_KERN_LOCALVER = $(call qstrip,$(shell \
	awk -F= '/^CONFIG_LOCALVERSION=/ {v=$$2} END {print v}' \
		$(LINUX_DIR)/.config 2>/dev/null))

# Kernel options the driver + its SDIO host need. Mirrors wifi-atbm6461, but
# pins MMC1 to 24 MHz: the CMD53-response margin on this board is thin at
# 48 MHz (see the jzmmc + atbm CMD53 patches). The runtime jzmmc clamp is the
# belt; this is the suspenders.
define WIFI_ATBM6441_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_ENABLE_OPT,CONFIG_JZMMC_V12_MMC1)
	$(call KCONFIG_ENABLE_OPT,CONFIG_JZMMC_V12_MMC1_PB_4BIT)
	$(call KCONFIG_SET_OPT,CONFIG_MMC1_MAX_FREQ,24000000)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WLAN)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WIRELESS_EXT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_CORE)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PROC)
	$(call KCONFIG_ENABLE_OPT,CONFIG_WEXT_PRIV)
	$(call KCONFIG_SET_OPT,CONFIG_CFG80211,y)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211,y)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_MINSTREL_HT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MAC80211_RC_DEFAULT_MINSTREL)
	$(call KCONFIG_SET_OPT,CONFIG_MAC80211_RC_DEFAULT,"minstrel_ht")
	$(call KCONFIG_DISABLE_OPT,CONFIG_TRIM_UNUSED_KSYMS)
endef

# Build the driver from source via its own Makefile 'modules' target (which
# recurses: make -C $(KSRC) M=<srcdir> modules), plus the z7682 watchdog tool.
#
# .config sourced into the environment: the vendor Makefile pulls all its
# CONFIG_ATBM_* switches via "-include $(src)/.config", but under kbuild's M=
# recursion $(src) is empty when that line is parsed, so the config is never
# read and e.g. SDIO_BUS is left unset ("BUS error. must select SDIO or SPI").
# Exporting the (LF-normalised) config into the env makes make import every
# CONFIG_* as a variable, which the Makefile's "?=" assignments then honour.
#
# ATBM_WIFI__EXT_CCFLAGS: the vendor hal_apollo/Makefile adds the os/linux
# header dir as "-I$(PWD)/os/linux". Under kbuild's M= recursion $(PWD) is the
# KERNEL dir, not the driver, so atbm_os.h is not found for an out-of-tree
# build. We inject the correct absolute include here (and preserve the
# platform define the Makefile normally sets); gcc ignores the stale -I.
# DRIVER_PATH is also forced so any $(DRIVER_PATH)-based paths resolve.
define WIFI_ATBM6441_BUILD_CMDS
	cp $(WIFI_ATBM6441_PKGDIR)/files/driver.config $(@D)/.config
	sed -i 's/\r$$//' $(@D)/.config
	set -a; . $(@D)/.config; set +a; \
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) modules \
		ARCH=mips \
		CROSS_COMPILE=$(TARGET_CROSS) \
		KSRC=$(LINUX_DIR) \
		DRIVER_PATH=$(@D) \
		ATBM_WIFI__EXT_CCFLAGS="-DATBM_WIFI_PLATFORM=22 -I$(@D)/os/linux"
	$(TARGET_CC) $(TARGET_CFLAGS) -fPIC -shared \
		-o $(@D)/librtos.so \
		$(WIFI_ATBM6441_PKGDIR)/files/librtos.c \
		-lpthread $(TARGET_LDFLAGS)
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(@D)/z7682_disable_wdt \
		$(WIFI_ATBM6441_PKGDIR)/files/z7682_disable_wdt.c \
		-L$(@D) -lrtos \
		$(TARGET_LDFLAGS)
	# mcu_wdt_arm is STATIC (librtos.c compiled in, no shared libs) so it keeps
	# working after sysupgrade erases the rootfs - stage2 copies it into /tmp and
	# go_reboot arms the master_wdt from there. See thingino-sysupgrade.
	$(TARGET_CC) $(TARGET_CFLAGS) -static -o $(@D)/mcu_wdt_arm \
		$(WIFI_ATBM6441_PKGDIR)/files/mcu_wdt_arm.c \
		$(WIFI_ATBM6441_PKGDIR)/files/librtos.c \
		-lpthread \
		$(TARGET_LDFLAGS)
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(@D)/mcu_evt \
		$(WIFI_ATBM6441_PKGDIR)/files/mcu_evt.c \
		$(TARGET_LDFLAGS)
endef

# Install the source-built module + source-built librtos.so + z7682 tool + mcu_evt.
define WIFI_ATBM6441_INSTALL_TARGET_CMDS
	$(INSTALL) -m 0755 -d \
		$(TARGET_DIR)/usr/lib/modules/3.10.14$(WIFI_ATBM6441_KERN_LOCALVER)/extra
	$(INSTALL) -D -m 0644 \
		$(@D)/hal_apollo/$(WIFI_ATBM6441_KO_NAME).ko \
		$(TARGET_DIR)/usr/lib/modules/3.10.14$(WIFI_ATBM6441_KERN_LOCALVER)/extra/$(WIFI_ATBM6441_KO_NAME).ko
	$(INSTALL) -D -m 0755 $(@D)/librtos.so \
		$(TARGET_DIR)/usr/lib/librtos.so
	$(INSTALL) -D -m 0755 $(@D)/z7682_disable_wdt \
		$(TARGET_DIR)/usr/bin/z7682_disable_wdt
	$(INSTALL) -D -m 0755 $(@D)/mcu_wdt_arm \
		$(TARGET_DIR)/usr/bin/mcu_wdt_arm
	$(INSTALL) -D -m 0755 $(@D)/mcu_evt \
		$(TARGET_DIR)/usr/bin/mcu_evt
endef

# The gtxaspec source ships MIXED CRLF/LF line endings (e.g. atbm_ioctl_ext.h is
# CRLF). Our all-patches/ patch is LF, so normalise every source file to LF right
# after extract (before the patch step) so all hunks apply cleanly.
define WIFI_ATBM6441_NORMALIZE_EOL
	find $(@D) -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile*' -o -name '.config' \) \
		-exec sed -i 's/\r$$//' {} +
endef
WIFI_ATBM6441_POST_EXTRACT_HOOKS += WIFI_ATBM6441_NORMALIZE_EOL

$(eval $(generic-package))
