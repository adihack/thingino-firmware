#!/bin/bash
set -e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
cd /home/adrian
VER=2.38
TAR=binutils-$VER.tar.xz
echo "[*] $(date) downloading binutils $VER"
[ -f "$TAR" ] || curl -sL -o "$TAR" "https://ftp.gnu.org/gnu/binutils/$TAR"
ls -la "$TAR"
echo "[*] extracting"
rm -rf binutils-$VER
tar xf "$TAR"
echo "[*] check nds32 is a known target"
cd binutils-$VER
if ! ./config.sub nds32le-elf >/dev/null 2>&1; then echo "!! nds32le-elf not recognised by config.sub"; ./config.sub nds32-elf || true; fi
mkdir -p build && cd build
echo "[*] configure for nds32le-elf (objdump+gas only)"
../configure --target=nds32le-elf --disable-nls --disable-werror \
   --disable-gdb --disable-sim --disable-ld --disable-gold \
   >/home/adrian/nds32_cfg.log 2>&1 || { echo "CONFIGURE FAILED"; tail -30 /home/adrian/nds32_cfg.log; exit 1; }
echo "[*] $(date) building all-binutils all-gas (this is the slow part)"
make -j$(nproc) all-binutils all-gas >/home/adrian/nds32_make.log 2>&1 || { echo "MAKE FAILED"; tail -40 /home/adrian/nds32_make.log; exit 1; }
echo "[*] done. objdump:"
ls -la binutils/objdump
./binutils/objdump --version | head -1
echo "[*] target list check:"
./binutils/objdump -i 2>/dev/null | grep -i nds32 | head
