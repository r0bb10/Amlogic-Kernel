#!/usr/bin/env bash
# Read-only inspection of the completed image; never accepts a block device.
set -euo pipefail
trap 'printf "Image validation failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
[[ $# -eq 2 ]] || { echo "Usage: $0 IMAGE KERNEL_RELEASE" >&2; exit 1; }
image=$(realpath "$1")
release=$2
[[ $(id -u) -eq 0 && -f $image && ! -b $image ]] || { echo 'Root and a regular image file are required' >&2; exit 1; }
[[ $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-sm1$ ]] || exit 1
work=$(mktemp -d)
loop=""
cleanup() {
    local failed=0 dir
    for dir in "$work/boot" "$work/root"; do
        if mountpoint -q "$dir"; then umount "$dir" || failed=1; fi
    done
    ((failed == 0)) || return 1
    [[ -z $loop ]] || losetup -d "$loop" || return 1
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Check MBR boundaries before attaching the file.
python3 - "$image" <<'PY'
import os, struct, sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
assert mbr[510:] == b'\x55\xaa', 'missing MBR signature'
parts = [struct.unpack('<B3sB3sII', mbr[446+i*16:462+i*16]) for i in range(4)]
assert parts[0][2] in (0x0b, 0x0c) and parts[1][2] == 0x83, 'wrong partition types'
assert parts[0][4] == 4*2048 and parts[0][5] == 512*2048, 'wrong boot partition'
assert parts[1][4] == 516*2048, 'wrong root partition start'
assert parts[1][4] + parts[1][5] <= os.path.getsize(sys.argv[1])//512
assert parts[1][5] > 0 and parts[2][2] == parts[3][2] == 0, 'expected exactly two partitions'
PY
loop=$(losetup --read-only -Pf --show "$image")
for _ in {1..10}; do
    [[ -b ${loop}p1 && -b ${loop}p2 ]] && break
    partprobe "$loop"
    sleep 1
done
fsck.vfat -n "${loop}p1"
e2fsck -fn "${loop}p2"
mkdir "$work/boot" "$work/root"
mount -o ro "${loop}p1" "$work/boot"
mount -o ro,noload "${loop}p2" "$work/root"
boot="$work/boot"
root="$work/root"
uuid=$(blkid -s UUID -o value "${loop}p2")
[[ $(blkid -s LABEL -o value "${loop}p1") == BOOT ]]
grep -qx "UUID=$uuid / ext4 defaults,noatime 0 1" "$root/etc/fstab"
grep -qx 'LABEL=BOOT /boot vfat defaults 0 2' "$root/etc/fstab"
grep -q "root=UUID=$uuid " "$boot/uEnv.txt"
grep -qx 'LINUX=/zImage' "$boot/uEnv.txt"
grep -qx 'INITRD=/uInitrd' "$boot/uEnv.txt"
grep -qx 'FDT=/dtb/amlogic/meson-sm1-x96-max-plus.dtb' "$boot/uEnv.txt"
for file in zImage uInitrd dtb/amlogic/meson-sm1-x96-max-plus.dtb \
    u-boot.ext u-boot.sd u-boot.usb u-boot-x96maxplus.bin boot.scr boot.cmd \
    boot-emmc.scr boot-emmc.cmd boot.ini boot-emmc.ini \
    s905_autoscript aml_autoscript emmc_autoscript; do
    test -s "$boot/$file"
done
cmp "$boot/u-boot.ext" "$boot/u-boot-x96maxplus.bin"
cmp "$boot/zImage" "$root/usr/lib/linux-image-sm1/$release/zImage"
cmp "$boot/dtb/amlogic/meson-sm1-x96-max-plus.dtb" \
    "$root/usr/lib/linux-image-sm1/$release/meson-sm1-x96-max-plus.dtb"
test -s "$root/usr/lib/modules/$release/modules.dep"
test -x "$root/root/install-to-emmc"
test -x "$root/usr/local/sbin/ampart"
test -s "$root/usr/lib/firmware/ath10k/QCA6174/hw3.0/board-2.bin"
test -s "$root/usr/lib/firmware/ath10k/QCA6174/hw3.0/firmware-sdio-6.bin"
test -L "$root/sbin/init"
test -e "$root/usr/lib/systemd/system/serial-getty@.service"
test -L "$root/etc/systemd/system/getty.target.wants/serial-getty@ttyAML0.service"
test -e "$root/usr/lib/systemd/system/sshd-keygen.service"
test -L "$root/etc/systemd/system/ssh.service.wants/sshd-keygen.service"
test -L "$root/etc/systemd/system/multi-user.target.wants/ssh.service"
grep -qx 'allow-hotplug eth0' "$root/etc/network/interfaces"
grep -qx 'allow-hotplug wlan0' "$root/etc/network/interfaces"
grep -qx 'iface eth0 inet dhcp' "$root/etc/network/interfaces"
grep -qx 'iface wlan0 inet dhcp' "$root/etc/network/interfaces"
grep -qx '    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf' "$root/etc/network/interfaces"
test "$(stat -c %a "$root/etc/wpa_supplicant/wpa_supplicant.conf")" = 600
test -L "$root/etc/systemd/system/multi-user.target.wants/wifi-import.service"
grep -qx 'ConditionPathExists=/boot/wpa_supplicant.conf' "$root/etc/systemd/system/wifi-import.service"
grep -qx 'uninitialized' "$root/etc/machine-id"
suite=$(sed -n 's/^DEBIAN_SUITE=//p' "$root/etc/x96-image-release")
[[ $suite =~ ^[a-z0-9][a-z0-9-]*$ ]]
grep -Fxq "Suites: $suite $suite-updates" "$root/etc/apt/sources.list.d/debian.sources"
grep -Fxq "Suites: $suite-security" "$root/etc/apt/sources.list.d/debian.sources"
grep -qx 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$root/etc/apt/sources.list.d/debian.sources"
grep -qx 'PermitRootLogin yes' "$root/etc/ssh/sshd_config.d/00-root-login.conf"
grep -qx 'PasswordAuthentication yes' "$root/etc/ssh/sshd_config.d/00-root-login.conf"
test ! -e "$root/usr/sbin/policy-rc.d"
if find "$root/etc/ssh" -name 'ssh_host_*' | grep -q .; then
    echo 'Image contains shared SSH host keys' >&2
    exit 1
fi
# shellcheck disable=SC2016 # dpkg-query expands its own fields.
chroot "$root" dpkg-query -W -f='${Status} ${Version}\n' linux-image-sm1 | grep -qx "install ok installed $release"
for package in firmware-atheros wpasupplicant systemd-sysv openssh-server; do
    # shellcheck disable=SC2016
    status=$(chroot "$root" dpkg-query -W -f='${Status}' "$package")
    [[ $status == 'install ok installed' ]]
done
# Run this inspection on the host: the image's /dev is intentionally empty
# until devtmpfs is mounted at boot, and Perl requires /dev/null at startup.
# shellcheck disable=SC2016 # These are Perl variables, not shell variables.
perl -e 'open my $f, "<", $ARGV[0] or die $!; while (<$f>) { if (/^root:([^:]+):/) { exit(crypt("root", $1) eq $1 ? 0 : 1); } } exit 1;' "$root/etc/shadow"

# Verify raw ARM64/DTB headers and the legacy U-Boot ramdisk CRCs.
python3 - "$boot" "$work/initrd" <<'PY'
from pathlib import Path
import struct, sys, zlib
b = Path(sys.argv[1])
assert (b/'zImage').read_bytes()[56:60] == b'ARM\x64', 'not a raw ARM64 Image'
assert (b/'dtb/amlogic/meson-sm1-x96-max-plus.dtb').read_bytes()[:4] == b'\xd0\x0d\xfe\xed'
data = (b/'uInitrd').read_bytes()
header = bytearray(data[:64])
magic, hcrc, _, size, _, _, dcrc = struct.unpack('>7I', header[:28])
assert magic == 0x27051956 and header[30] == 3, 'not a U-Boot ramdisk'
header[4:8] = b'\0'*4
assert zlib.crc32(header) == hcrc, 'invalid ramdisk header CRC'
payload = data[64:]
assert len(payload) == size and zlib.crc32(payload) == dcrc, 'invalid ramdisk data CRC'
Path(sys.argv[2]).write_bytes(payload)
PY
lsinitramfs "$work/initrd" > "$work/initrd-files"
grep -Eq '(^|/)init$' "$work/initrd-files"
grep -Fq "lib/modules/$release/" "$work/initrd-files"
grep -qx "KERNEL_RELEASE=$release" "$root/etc/x96-image-release"
printf 'Validated image: %s (%s)\n' "$image" "$release"
