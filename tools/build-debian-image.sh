#!/usr/bin/env bash
set -euo pipefail

# Build Debian for the Gigabit X96 Max+ using this repository's published kernel.
# No kernel compilation, Armbian image download, or physical disk writes.

ROOT=$(realpath "$(dirname "$0")/..")
ASSETS="$ROOT/assets/x96-max-plus"
OUTPUT=${OUTPUT:-"$ROOT/out/dist/debian-x96-max-plus.img"}
ROOT_GIB=${ROOT_GIB:-2}
ROOT_RESERVE_GIB=${ROOT_RESERVE_GIB:-1}
ROOT_ALIGN_MIB=${ROOT_ALIGN_MIB:-256}
DEBIAN_SUITE=${DEBIAN_SUITE:-trixie}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}
KERNEL_REPOSITORY=${KERNEL_REPOSITORY:-r0bb10/Amlogic-Kernel}
KERNEL_VERSION=${KERNEL_VERSION:-}
KERNEL_DEB=${KERNEL_DEB:-}
BOARD_FILE="$ROOT/assets/firmware/qca6174-hw3.0-board-2.bin"
WORK="$ROOT/out/.work/debian-image-build"
ROOTFS="$WORK/rootfs"
STATE="$WORK/.state"
LOOP=""
stage=all
reset=0

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
    printf 'Usage: %s [--stage bootstrap|configure|assemble|all|clean] [--reset]\n' "$0"
}
while (($#)); do
    case "$1" in
        --stage) (($# >= 2)) || die "--stage needs a value"; stage=$2; shift 2 ;;
        --reset) reset=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$stage" in
    bootstrap|configure|assemble|all|clean) ;;
    *) die "unknown stage: $stage" ;;
esac

cleanup() {
    local directory failed=0
    for directory in "$WORK/rootfs/proc" "$WORK/rootfs/sys" "$WORK/rootfs/dev" "$WORK/boot-mount" "$WORK/root-mount"; do
        if mountpoint -q "$directory"; then
            umount -R "$directory" || failed=1
        fi
    done
    if ((failed)); then
        printf 'Cleanup could not unmount all filesystems; retained %s and %s\n' "$WORK" "$LOOP" >&2
        return 1
    fi
    [[ -z $LOOP ]] || losetup -d "$LOOP" || return 1
    LOOP=""
    # Retain the unmounted rootfs and stage markers for resumable builds.
}

clean() {
    cleanup
    rm -rf -- "$WORK"
}

complete() { [[ -f $STATE/$1 ]]; }
mark() { touch "$STATE/$1"; }

mount_chroot() {
    local directory
    mkdir -p "$ROOTFS"/{proc,sys,dev}
    for directory in proc sys dev; do
        if ! mountpoint -q "$ROOTFS/$directory"; then
            mount --rbind "/$directory" "$ROOTFS/$directory"
            mount --make-rslave "$ROOTFS/$directory"
        fi
    done
}

validate_build_state() {
    local digest file
    digest=$({
        printf '%s\0' "$DEBIAN_SUITE" "$DEBIAN_MIRROR" "$KERNEL_REPOSITORY" \
            "$KERNEL_VERSION" "$ROOT_GIB" "$ROOT_RESERVE_GIB" "$ROOT_ALIGN_MIB"
        sha256sum "$WORK/kernel.deb" "$ROOT/tools/build-debian-image.sh" \
            "$ROOT/tools/install-to-emmc.sh" "$ROOT/tools/validate-debian-image.sh" \
            "$ROOT/configs/systemd/wifi-import.service" "$BOARD_FILE" | cut -d' ' -f1
        for file in "${boot_assets[@]}"; do
            sha256sum "$ASSETS/$file" | cut -d' ' -f1
        done
    } | sha256sum | cut -d' ' -f1)
    mkdir -p "$STATE"
    if [[ -f $STATE/config.sha256 ]]; then
        [[ $(<"$STATE/config.sha256") == "$digest" ]] \
            || die "build configuration or kernel changed; rerun with --reset"
    else
        [[ ! -d $ROOTFS && ! -f $STATE/bootstrap && ! -f $STATE/configure ]] \
            || die "staging data has no configuration record; rerun with --reset"
        printf '%s\n' "$digest" > "$STATE/config.sha256"
    fi
}

wait_for_partitions() {
    for _ in {1..10}; do
        [[ -b "${LOOP}p1" && -b "${LOOP}p2" ]] && return
        partprobe "$LOOP"
        sleep 1
    done
    die "image partitions did not appear"
}

# ---------------------------------------------------------------- prerequisites

[[ $(id -u) -eq 0 ]] || die "run as root"
for command in mountpoint umount losetup flock; do
    command -v "$command" >/dev/null || die "missing command: $command"
done
mkdir -p "$ROOT/out/.work"
# Lock outside the resettable directory so --reset cannot break the lock.
exec 9>"$WORK.lock"
flock -n 9 || die "another image build is using this staging directory"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ $stage == clean ]]; then
    clean
    exit 0
fi
[[ $ROOT_GIB =~ ^(0|[1-9][0-9]*)$ ]] || die "ROOT_GIB must be a non-negative integer (minimum root size)"
[[ $ROOT_RESERVE_GIB =~ ^(0|[1-9][0-9]*)$ ]] || die "ROOT_RESERVE_GIB must be a non-negative integer"
[[ $ROOT_ALIGN_MIB =~ ^[1-9][0-9]*$ ]] || die "ROOT_ALIGN_MIB must be a positive integer"
if [[ $(dpkg --print-architecture) != arm64 && ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    die "an arm64 host or registered qemu-aarch64 binfmt handler is required"
fi
for command in curl debootstrap dpkg dpkg-deb jq losetup mkfs.ext4 mkfs.vfat mount mountpoint umount parted partprobe rsync tar chroot dd truncate sha256sum python3 perl stat install fsck.vfat e2fsck blkid lsinitramfs zstd du; do
    command -v "$command" >/dev/null || die "missing command: $command"
done
[[ -d $ASSETS ]] || die "missing X96 Max+ boot assets"
[[ -s $BOARD_FILE ]] || die "missing QCA6174 board firmware"
[[ $KERNEL_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid KERNEL_REPOSITORY"
[[ -z $KERNEL_VERSION || $KERNEL_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid KERNEL_VERSION"
boot_assets=(ampart x96maxplus-u-boot.bin.sd.bin u-boot-x96maxplus.bin \
    s905_autoscript s905_autoscript.cmd aml_autoscript aml_autoscript.cmd \
    emmc_autoscript emmc_autoscript.cmd boot.scr boot.cmd boot-emmc.scr \
    boot-emmc.cmd boot.ini boot-emmc.ini u-boot.usb u-boot.sd)
for file in "${boot_assets[@]}"; do
    [[ -s $ASSETS/$file ]] || die "missing boot asset: $file"
done
# Raw bootloader writes must stay entirely before the first partition (4 MiB).
[[ $(stat -c %s "$ASSETS/x96maxplus-u-boot.bin.sd.bin") -lt $((4 * 1024 * 1024)) ]] \
    || die "bootloader overlaps the boot partition"

# ---------------------------------------------------------------- kernel package

if ((reset)); then clean; fi
mkdir -p "$WORK" "$(dirname "$OUTPUT")"
case "$stage" in
    configure) complete bootstrap || die "run the bootstrap stage first" ;;
    assemble) complete configure || die "run the configure stage first" ;;
esac
if [[ -n $KERNEL_DEB ]]; then
    cp "$KERNEL_DEB" "$WORK/kernel.deb.new"
    mv -f "$WORK/kernel.deb.new" "$WORK/kernel.deb"
elif [[ $stage != all && $stage != bootstrap && -z $KERNEL_VERSION && -s $WORK/kernel.deb ]]; then
    # Explicit configure/assemble stages resume the kernel already bootstrapped.
    :
else
    endpoint=latest
    [[ -z $KERNEL_VERSION ]] || endpoint="tags/$KERNEL_VERSION"
    api_headers=(-H 'Accept: application/vnd.github+json')
    if [[ -n ${GH_TOKEN:-} ]]; then
        api_headers+=(-H "Authorization: Bearer $GH_TOKEN")
    fi
    curl -fsSL --retry 3 "${api_headers[@]}" \
        "https://api.github.com/repos/$KERNEL_REPOSITORY/releases/$endpoint" > "$WORK/release.json"
    release_tag=$(jq -er '.tag_name' "$WORK/release.json")
    [[ $release_tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "latest release is not a kernel version"
    [[ -z $KERNEL_VERSION || $KERNEL_VERSION == "$release_tag" ]] || die "release tag does not match requested version"
    KERNEL_VERSION=$release_tag
    package_url=$(jq -er --arg name "linux-image-$KERNEL_VERSION-sm1.deb" \
        '[.assets[] | select(.name == $name)] | if length == 1 then .[0].browser_download_url else error("missing or ambiguous kernel asset") end' "$WORK/release.json")
    digest=$(jq -r --arg name "linux-image-$KERNEL_VERSION-sm1.deb" \
        '.assets[] | select(.name == $name) | .digest // empty' "$WORK/release.json")
    if [[ -n $digest ]]; then
        [[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || die "unexpected release asset digest"
    fi
    if [[ -z $digest || ! -s $WORK/kernel.deb ]] || \
        [[ $(sha256sum "$WORK/kernel.deb" | cut -d' ' -f1) != "${digest#sha256:}" ]]; then
        curl -fL --retry 3 -o "$WORK/kernel.deb.new" "$package_url"
        if [[ -n $digest ]]; then
            printf '%s  %s\n' "${digest#sha256:}" "$WORK/kernel.deb.new" | sha256sum -c -
        fi
        mv -f "$WORK/kernel.deb.new" "$WORK/kernel.deb"
    fi
fi
[[ $(dpkg-deb -f "$WORK/kernel.deb" Package) == linux-image-sm1 ]] || die "unexpected kernel package"
[[ $(dpkg-deb -f "$WORK/kernel.deb" Architecture) == arm64 ]] || die "kernel is not ARM64"
package_version=$(dpkg-deb -f "$WORK/kernel.deb" Version)
[[ $package_version =~ ^([0-9]+\.[0-9]+\.[0-9]+)-sm1$ ]] || die "unexpected kernel version"
resolved_version=${BASH_REMATCH[1]}
[[ -z $KERNEL_VERSION || $KERNEL_VERSION == "$resolved_version" ]] || die "kernel version does not match requested release"
KERNEL_VERSION=$resolved_version
shopt -s nullglob
validate_build_state

# ---------------------------------------------------------------- Debian root

bootstrap() {
    if complete bootstrap; then
        echo 'Reusing completed bootstrap stage.'
        return
    fi
    if ! complete debootstrap; then
        # A failed debootstrap is not a valid base; recreate only our staged root.
        cleanup
        rm -rf -- "$ROOTFS"
        debootstrap --arch=arm64 --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"
        mark debootstrap
    fi
    mount_chroot

    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
    printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
    chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"
    mkdir -p "$ROOTFS/etc/apt/sources.list.d"
    rm -f "$ROOTFS/etc/apt/sources.list"
    cat > "$ROOTFS/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $DEBIAN_SUITE-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    chroot "$ROOTFS" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        systemd-sysv ca-certificates dosfstools e2fsprogs ifupdown initramfs-tools isc-dhcp-client kmod openssh-server parted psmisc u-boot-tools firmware-atheros wpasupplicant wireless-regdb
    # Install firmware before the kernel's postinst generates the initramfs.
    install -D -m 0644 "$BOARD_FILE" "$ROOTFS/usr/lib/firmware/ath10k/QCA6174/hw3.0/board-2.bin"
    cp "$WORK/kernel.deb" "$ROOTFS/tmp/kernel.deb"
    # Avoid host-specific MODULES=dep when generating an image for another board.
    printf 'MODULES=most\nCOMPRESS=zstd\n' > "$ROOTFS/etc/initramfs-tools/conf.d/x96-image"
    chroot "$ROOTFS" dpkg -i /tmp/kernel.deb
    rm -f "$ROOTFS/tmp/"*.deb
    mark bootstrap
}

configure() {
    if complete configure; then
        echo 'Reusing completed configure stage.'
        return
    fi
    complete bootstrap || die "run the bootstrap stage first"
    mount_chroot

    FLASHER="$ROOTFS/root"
    mkdir -p "$FLASHER"
    cp "$ROOT/tools/install-to-emmc.sh" "$FLASHER/install-to-emmc"
    install -D -m 0755 "$ASSETS/ampart" "$ROOTFS/usr/local/sbin/ampart"
    cp "$ASSETS/x96maxplus-u-boot.bin.sd.bin" "$ASSETS/u-boot-x96maxplus.bin" "$FLASHER/"
    chmod 0755 "$FLASHER/install-to-emmc"

    MODULES=("$ROOTFS"/usr/lib/modules/*)
    [[ ${#MODULES[@]} -eq 1 && -d ${MODULES[0]} ]] || die "kernel modules were not installed"
    KERNEL_RELEASE=$(basename "${MODULES[0]}")
    [[ $KERNEL_RELEASE == "$KERNEL_VERSION-sm1" ]] || die "unexpected installed kernel release"
    DTB=meson-sm1-x96-max-plus.dtb
    [[ -s "$ROOTFS/boot/zImage" ]] || die "kernel package did not install zImage"
    [[ -s "$ROOTFS/boot/uInitrd" ]] || die "kernel package did not install uInitrd"
    [[ -s "$ROOTFS/boot/dtb/amlogic/$DTB" ]] || die "kernel package did not install $DTB"

    # ---------------------------------------------------------------- Debian config

    [[ -s $STATE/root-uuid ]] || cat /proc/sys/kernel/random/uuid > "$STATE/root-uuid"
    ROOT_UUID=$(<"$STATE/root-uuid")
    printf 'debian\n' > "$ROOTFS/etc/hostname"
    cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
127.0.1.1 debian
EOF
    cat > "$ROOTFS/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime 0 1
LABEL=BOOT /boot vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
    mkdir -p "$ROOTFS/etc/network" "$ROOTFS/etc/ssh/sshd_config.d"
    cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
    install -d -m 0755 "$ROOTFS/etc/wpa_supplicant"
    cat > "$ROOTFS/etc/wpa_supplicant/wpa_supplicant.conf" <<'EOF'
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
# Add a network={} block with your SSID and credentials before using wlan0.
EOF
    chmod 0600 "$ROOTFS/etc/wpa_supplicant/wpa_supplicant.conf"
    install -D -m 0644 "$ROOT/configs/systemd/wifi-import.service" \
        "$ROOTFS/etc/systemd/system/wifi-import.service"
    mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sfn ../wifi-import.service \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/wifi-import.service"
    chroot "$ROOTFS" systemd-analyze --man=no verify wifi-import.service
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$ROOTFS/etc/ssh/sshd_config.d/00-root-login.conf"
    printf 'root:root\n' | chroot "$ROOTFS" chpasswd
    printf 'WARNING: image enables root SSH with password root. Change it immediately.\n' >&2
    mkdir -p "$ROOTFS/run/sshd"
    chroot "$ROOTFS" ssh-keygen -A
    chroot "$ROOTFS" /usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 > "$WORK/sshd-config"
    grep -qx 'permitrootlogin yes' "$WORK/sshd-config" || die "root SSH login is disabled"
    grep -qx 'passwordauthentication yes' "$WORK/sshd-config" || die "SSH password authentication is disabled"
    # Each flashed system must generate its own host identity at first boot.
    rm -f "$ROOTFS/etc/ssh/ssh_host_"*
    mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
    ln -sfn /lib/systemd/system/serial-getty@.service "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyAML0.service"
    printf 'uninitialized\n' > "$ROOTFS/etc/machine-id"
    rm -f "$ROOTFS/var/lib/dbus/machine-id"
    ln -s /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"
    rm -f "$ROOTFS/usr/sbin/policy-rc.d"
    chroot "$ROOTFS" apt-get clean
    rm -rf "$ROOTFS/var/lib/apt/lists/"*
    cat > "$ROOTFS/etc/x96-image-release" <<EOF
DEBIAN_SUITE=$DEBIAN_SUITE
KERNEL_RELEASE=$KERNEL_RELEASE
KERNEL_REPOSITORY=$KERNEL_REPOSITORY
EOF

    # ---------------------------------------------------------------- boot payload

    BOOT="$WORK/boot"
    mkdir -p "$BOOT/dtb/amlogic"
    cp "$ROOTFS/boot/zImage" "$ROOTFS/boot/uInitrd" "$BOOT/"
    cp "$ROOTFS/boot/dtb/amlogic/$DTB" "$BOOT/dtb/amlogic/$DTB"
    cp "$ASSETS"/s905_autoscript "$ASSETS"/s905_autoscript.cmd \
        "$ASSETS"/aml_autoscript "$ASSETS"/aml_autoscript.cmd \
        "$ASSETS"/emmc_autoscript "$ASSETS"/emmc_autoscript.cmd \
        "$ASSETS"/boot.scr "$ASSETS"/boot.cmd \
        "$ASSETS"/boot-emmc.scr "$ASSETS"/boot-emmc.cmd \
        "$ASSETS"/boot.ini "$ASSETS"/boot-emmc.ini \
        "$ASSETS"/u-boot.usb "$ASSETS"/u-boot.sd \
        "$ASSETS"/u-boot-x96maxplus.bin "$BOOT/"
    cp "$ASSETS/u-boot-x96maxplus.bin" "$BOOT/u-boot.ext"
    cp "$ROOTFS/boot/config-$KERNEL_RELEASE" "$BOOT/"
    cat > "$BOOT/uEnv.txt" <<EOF
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/$DTB
APPEND=root=UUID=$ROOT_UUID rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 fsck.repair=yes net.ifnames=0
EOF
    mark configure
}

# ---------------------------------------------------------------- disk image

assemble() {
    complete configure || die "run the configure stage first"
    cleanup
    KERNEL_RELEASE="$KERNEL_VERSION-sm1"
    ROOT_UUID=$(<"$STATE/root-uuid")
    BOOT="$WORK/boot"
    IMAGE="$WORK/image.img"
    root_bytes=$(du -sx --apparent-size --block-size=1 "$ROOTFS" | cut -f1)
    root_bytes=$((root_bytes + ROOT_RESERVE_GIB * 1024 * 1024 * 1024))
    root_min_bytes=$((ROOT_GIB * 1024 * 1024 * 1024))
    ((root_bytes >= root_min_bytes)) || root_bytes=$root_min_bytes
    root_align_bytes=$((ROOT_ALIGN_MIB * 1024 * 1024))
    root_bytes=$(((root_bytes + root_align_bytes - 1) / root_align_bytes * root_align_bytes))
    printf 'Root partition: %s MiB (payload plus reserve, minimum %s GiB).\n' "$((root_bytes / 1024 / 1024))" "$ROOT_GIB"
    # Reassembly must start with a fresh filesystem, not truncate an existing image.
    rm -f "$IMAGE"
    truncate -s $((516 * 1024 * 1024 + root_bytes)) "$IMAGE"
    parted -s "$IMAGE" mklabel msdos \
        mkpart primary fat32 4MiB 516MiB set 1 lba on \
        mkpart primary ext4 516MiB 100%
    dd if="$ASSETS/x96maxplus-u-boot.bin.sd.bin" of="$IMAGE" conv=fsync,notrunc bs=1 count=444 status=none
    dd if="$ASSETS/x96maxplus-u-boot.bin.sd.bin" of="$IMAGE" conv=fsync,notrunc bs=512 skip=1 seek=1 status=none

    LOOP=$(losetup -Pf --show "$IMAGE")
    wait_for_partitions
    mkdir -p "$WORK/boot-mount" "$WORK/root-mount"
    mkfs.vfat -F 32 -n BOOT "${LOOP}p1"
    mkfs.ext4 -F -q -U "$ROOT_UUID" -L rootfs "${LOOP}p2"
    mount "${LOOP}p1" "$WORK/boot-mount"
    # FAT cannot preserve Unix ownership and permissions.
    cp -r "$BOOT/." "$WORK/boot-mount/"
    umount "$WORK/boot-mount"
    mount "${LOOP}p2" "$WORK/root-mount"
    rsync -aHAX --numeric-ids --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/tmp/*' "$ROOTFS/" "$WORK/root-mount/"
    mkdir -p "$WORK/root-mount"/{dev,proc,sys,tmp}
    chmod 1777 "$WORK/root-mount/tmp"
    umount "$WORK/root-mount"
    losetup -d "$LOOP"
    LOOP=""

    # Inspect the final on-disk filesystems, not merely the staging tree.
    "$ROOT/tools/validate-debian-image.sh" "$IMAGE" "$KERNEL_RELEASE"
    mv "$IMAGE" "$OUTPUT"
    (cd "$(dirname "$OUTPUT")" && sha256sum "$(basename "$OUTPUT")") > "$OUTPUT.sha256"
    mark assemble
    printf 'Built %s with kernel %s\n' "$OUTPUT" "$KERNEL_RELEASE"
}

case "$stage" in
    bootstrap) bootstrap ;;
    configure) configure ;;
    assemble) assemble ;;
    all) bootstrap; configure; assemble ;;
esac
