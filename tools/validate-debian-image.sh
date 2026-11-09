#!/usr/bin/env bash
# Read-only inspection of the completed image; never accepts a block device.
set -euo pipefail
trap 'printf "Image validation failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
[[ $# -ge 2 && $# -le 3 ]] || { echo "Usage: $0 IMAGE KERNEL_RELEASE [BOARD]" >&2; exit 1; }
image=$(realpath "$1")
release=$2
[[ $(id -u) -eq 0 && -f $image && ! -b $image ]] || { echo 'Root and a regular image file are required' >&2; exit 1; }
[[ $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-(sm1|gxl)$ ]] || exit 1
family=${BASH_REMATCH[1]}
case "$family" in
    sm1) board=x96-max-plus; dtb=meson-sm1-x96-max-plus.dtb; overload=u-boot-x96maxplus.bin ;;
    gxl) board=tx3-mini; dtb=meson-gxl-s905w-tx3-mini.dtb; overload=u-boot.bin ;;
esac
[[ ${3:-$board} == "$board" ]] || { echo 'Board does not match kernel family' >&2; exit 1; }
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
python3 - "$image" "$board" <<'PY'
import os, struct, sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
    if sys.argv[2] == 'tx3-mini':
        # parted writes standard MBR boot code and a disk signature in sector 0.
        # Only the following gap must be empty: TX3 has no raw Amlogic loader.
        assert not any(f.read(4*1024*1024 - 512)), 'unexpected data before BOOT on TX3 image'
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
grep -Fxq "FDT=/dtb/amlogic/$dtb" "$boot/uEnv.txt"
grep -Eq '^APPEND=.* console=ttyAML0,115200n8( |$)' "$boot/uEnv.txt"
if grep -Eq '^APPEND=.* console=tty[0-9]+(,| |$)' "$boot/uEnv.txt"; then
    echo 'HDMI terminals must not receive kernel console output' >&2
    exit 1
fi
files=(zImage uInitrd "dtb/amlogic/$dtb" "$overload" \
    boot.scr boot.cmd boot.ini u-boot.usb u-boot.sd \
    s905_autoscript s905_autoscript.cmd aml_autoscript aml_autoscript.cmd)
if [[ $board == x96-max-plus ]]; then
    files+=(u-boot.ext boot-emmc.scr boot-emmc.cmd boot-emmc.ini emmc_autoscript)
else
    files+=(u-boot.defconfig COPYING SHA256SUMS)
fi
for file in "${files[@]}"; do
    test -s "$boot/$file"
done
if [[ $board == x96-max-plus ]]; then
    cmp "$boot/u-boot.ext" "$boot/$overload"
else
    assets=$(realpath "$(dirname "$0")/../assets/tx3-mini")
    cmp "$boot/SHA256SUMS" "$assets/SHA256SUMS"
    (cd "$boot" && sha256sum -c SHA256SUMS)
    test ! -e "$boot/u-boot.ext"
    test ! -e "$boot/u-boot-s905x-s912.bin"
fi
cmp "$boot/zImage" "$root/usr/lib/linux-image-$family/$release/zImage"
cmp "$boot/dtb/amlogic/$dtb" "$root/usr/lib/linux-image-$family/$release/$dtb"
test -s "$root/usr/lib/modules/$release/modules.dep"
if [[ $board == x96-max-plus ]]; then
    test -x "$root/root/install-to-emmc"
    test -x "$root/usr/local/sbin/ampart"
    test -s "$root/usr/lib/firmware/ath10k/QCA6174/hw3.0/board-2.bin"
    test -s "$root/usr/lib/firmware/ath10k/QCA6174/hw3.0/firmware-sdio-6.bin"
else
    test -s "$root/usr/lib/modules/$release/kernel/drivers/net/wireless/ssv6051/ssv6051.ko"
    grep -Fq 'alias sdio:c*v3030d3030* ssv6051' "$root/usr/lib/modules/$release/modules.alias"
    test -s "$root/usr/lib/firmware/ssv6051-sw.bin"
    test -s "$root/usr/lib/firmware/ssv6051-wifi.cfg"
    test -d "$root/var/lib/ssv6051"
    grep -Fxq 'mac_output_path = /var/lib/ssv6051/mac' "$root/usr/lib/firmware/ssv6051-wifi.cfg"
    test ! -e "$root/root/install-to-emmc"
    test ! -e "$root/usr/local/sbin/ampart"
    test -s "$root/root/README-tx3-mini.md"
    test ! -e "$boot/u-boot-x96maxplus.bin"
    test ! -e "$boot/emmc_autoscript"
fi
test -L "$root/sbin/init"
test "$(cat "$root/etc/default/locale")" = 'LANG=C.UTF-8'
test "$(stat -c %a "$root/etc/default/locale")" = 644
[[ $(chroot "$root" /usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 /usr/bin/locale charmap) == UTF-8 ]]
test -e "$root/usr/lib/systemd/system/serial-getty@.service"
test -e "$root/usr/lib/systemd/system/getty@.service"
test -L "$root/etc/systemd/system/getty.target.wants/getty@tty1.service"
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
metadata="$root/etc/amlogic-image-release"
if [[ -f $metadata ]]; then
    grep -Fxq "BOARD=$board" "$metadata"
elif [[ $board == x96-max-plus ]]; then
    metadata="$root/etc/x96-image-release"
fi
suite=$(sed -n 's/^DEBIAN_SUITE=//p' "$metadata")
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
chroot "$root" dpkg-query -W -f='${Status} ${Version}\n' "linux-image-$family" | grep -qx "install ok installed $release"
packages=(wpasupplicant systemd-sysv openssh-server)
if [[ $board == x96-max-plus ]]; then packages+=(firmware-atheros); fi
for package in "${packages[@]}"; do
    # shellcheck disable=SC2016
    status=$(chroot "$root" dpkg-query -W -f='${Status}' "$package")
    [[ $status == 'install ok installed' ]]
done
# Run this inspection on the host: the image's /dev is intentionally empty
# until devtmpfs is mounted at boot, and Perl requires /dev/null at startup.
# shellcheck disable=SC2016 # These are Perl variables, not shell variables.
perl -e 'open my $f, "<", $ARGV[0] or die $!; while (<$f>) { if (/^root:([^:]+):/) { exit(crypt("root", $1) eq $1 ? 0 : 1); } } exit 1;' "$root/etc/shadow"

# Verify raw ARM64/DTB headers and the legacy U-Boot ramdisk CRCs.
python3 - "$boot" "$work/initrd" "$dtb" "$board" <<'PY'
from pathlib import Path
import struct, sys, zlib
b = Path(sys.argv[1])
kernel = (b/'zImage').read_bytes()
assert kernel[56:60] == b'ARM\x64', 'not a raw ARM64 Image'
if sys.argv[4] == 'tx3-mini':
    assert struct.unpack_from('<Q', kernel, 8)[0] == 0, 'GXL requires a zero-offset kernel; rebuild the kernel package'
    assert b'U-Boot 2026.04 (' in (b/'u-boot.bin').read_bytes(), 'unexpected chainloader version'
    assert (b/'boot.ini').read_bytes() == b'ODROIDN2-UBOOT-CONFIG\n' + (b/'s905_autoscript.cmd').read_bytes(), 'stale legacy chainload entry'
    for script, arch in [('boot.scr', 22), ('s905_autoscript', 2), ('aml_autoscript', 2)]:
        source = 'boot.cmd' if script == 'boot.scr' else script + '.cmd'
        script_data = (b/script).read_bytes()
        script_header = bytearray(script_data[:64])
        magic, hcrc, _, size, _, _, dcrc = struct.unpack('>7I', script_header[:28])
        assert magic == 0x27051956 and script_header[30] == 6 and script_header[29] == arch, f'invalid {script} header'
        script_header[4:8] = b'\0'*4
        assert zlib.crc32(script_header) == hcrc, f'invalid {script} header CRC'
        script_payload = script_data[64:]
        assert len(script_payload) == size and zlib.crc32(script_payload) == dcrc, f'invalid {script} payload CRC'
        source_data = (b/source).read_bytes()
        assert struct.unpack('>2I', script_payload[:8]) == (len(source_data), 0), f'invalid {script} source size'
        assert script_payload[8:] == source_data, f'stale compiled {script}'
    for source in ['boot.cmd', 's905_autoscript.cmd', 'uEnv.txt']:
        text = (b/source).read_text()
        assert 'tx3_uboot_' not in text and '-test' not in text, f'temporary boot configuration in {source}'
        assert 'saveenv' not in text, f'persistent environment write in {source}'
assert (b/'dtb/amlogic'/sys.argv[3]).read_bytes()[:4] == b'\xd0\x0d\xfe\xed'
data = (b/'uInitrd').read_bytes()
header = bytearray(data[:64])
magic, hcrc, _, size, _, _, dcrc = struct.unpack('>7I', header[:28])
assert magic == 0x27051956 and header[30] == 3, 'not a U-Boot ramdisk'
if sys.argv[4] == 'tx3-mini':
    assert header[29] == 22, 'TX3 legacy boot requires an AArch64 ramdisk header; rebuild the GXL package'
header[4:8] = b'\0'*4
assert zlib.crc32(header) == hcrc, 'invalid ramdisk header CRC'
payload = data[64:]
assert len(payload) == size and zlib.crc32(payload) == dcrc, 'invalid ramdisk data CRC'
Path(sys.argv[2]).write_bytes(payload)
PY
lsinitramfs "$work/initrd" > "$work/initrd-files"
grep -Eq '(^|/)init$' "$work/initrd-files"
grep -Fq "lib/modules/$release/" "$work/initrd-files"
grep -qx "KERNEL_RELEASE=$release" "$metadata"
printf 'Validated image: %s (%s)\n' "$image" "$release"
