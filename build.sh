#!/usr/bin/env bash
# Build and package a versioned upstream Linux kernel for the X96 Max Plus.

set -euo pipefail

readonly KERNEL_VERSION="7.2.8"
readonly KERNEL_TAG="v${KERNEL_VERSION}"
readonly PACKAGE_NAME="linux-image-sm1"
readonly PACKAGE_VERSION="${KERNEL_VERSION}-sm1"
readonly ARCH="arm64"
readonly CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
# Suppress Git's fallback "+" suffix after committing the local DTS patch.
export LOCALVERSION=""
readonly ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly SOURCE_DIR="${ROOT_DIR}/source"
readonly OUTPUT_DIR="${ROOT_DIR}/build"
readonly PACKAGE_DIR="${ROOT_DIR}/out"
readonly PATCH_DIR="${ROOT_DIR}/patches"
readonly CONFIG_BASELINE="${ROOT_DIR}/configs/ophub-7.2.8-meson.config"
readonly KERNEL_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"

require_command() {
    command -v "$1" >/dev/null || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

check_prerequisites() {
    local command

    for command in git make "${CROSS_COMPILE}gcc" bc bison flex openssl perl python3 dpkg-deb; do
        require_command "${command}"
    done
}

checkout_source() {
    if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
        git clone --depth 1 --branch "${KERNEL_TAG}" "${KERNEL_URL}" "${SOURCE_DIR}"
    fi

    git -C "${SOURCE_DIR}" fetch --depth 1 origin "${KERNEL_TAG}"
    git -C "${SOURCE_DIR}" checkout --detach FETCH_HEAD
    git -C "${SOURCE_DIR}" reset --hard
    git -C "${SOURCE_DIR}" clean -fdx
}

apply_board_patch() {
    git -C "${SOURCE_DIR}" apply --check "${PATCH_DIR}/x96maxplus.patch"
    # Commit the local patch so the kernel release is reproducible and does
    # not acquire Linux's automatic "-dirty" suffix.
    git -C "${SOURCE_DIR}" apply --index "${PATCH_DIR}/x96maxplus.patch"
    git -C "${SOURCE_DIR}" -c user.name="Local X96 Kernel Build" \
        -c user.email="noreply@example.invalid" commit --no-gpg-sign -m "arm64: dts: add X96 Max Plus"
}

configure_kernel() {
    rm -rf "${OUTPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"

    # The baseline was normalized from the OPhub configuration with Linux
    # v7.2.8. Keep it whole until hardware validation permits safe pruning.
    install -m 0644 "${CONFIG_BASELINE}" "${OUTPUT_DIR}/.config"
    "${SOURCE_DIR}/scripts/config" --file "${OUTPUT_DIR}/.config" \
        --disable ARCH_SUNXI --disable ARCH_ROCKCHIP --enable ARCH_MESON \
        --set-str LOCALVERSION "-sm1" --disable LOCALVERSION_AUTO
    make -C "${SOURCE_DIR}" O="${OUTPUT_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig
}

build_kernel() {
    make -C "${SOURCE_DIR}" O="${OUTPUT_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
        -j"$(nproc)" Image modules amlogic/meson-sm1-x96-max-plus.dtb
}

package_kernel() {
    local stage_dir="${OUTPUT_DIR}/package-root"
    local control_dir="${stage_dir}/DEBIAN"
    local kernel_release
    local image_dir
    local image_source="${OUTPUT_DIR}/arch/arm64/boot/Image"
    local dtb_source="${OUTPUT_DIR}/arch/arm64/boot/dts/amlogic/meson-sm1-x96-max-plus.dtb"

    kernel_release="$(make -s -C "${SOURCE_DIR}" O="${OUTPUT_DIR}" ARCH="${ARCH}" kernelrelease)"
    image_dir="${stage_dir}/usr/lib/${PACKAGE_NAME}/${kernel_release}"

    rm -rf "${stage_dir}"
    mkdir -p "${control_dir}" "${image_dir}" "${stage_dir}/boot"

    make -C "${SOURCE_DIR}" O="${OUTPUT_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
        INSTALL_MOD_PATH="${stage_dir}" INSTALL_MOD_STRIP=1 modules_install
    rm -f "${stage_dir}/lib/modules/${kernel_release}/build" \
        "${stage_dir}/lib/modules/${kernel_release}/source"
    install -m 0644 "${image_source}" "${image_dir}/zImage"
    install -m 0644 "${dtb_source}" "${image_dir}/meson-sm1-x96-max-plus.dtb"
    install -m 0644 "${OUTPUT_DIR}/.config" "${image_dir}/config-${kernel_release}"
    install -m 0644 "${OUTPUT_DIR}/System.map" "${image_dir}/System.map-${kernel_release}"

    cat >"${control_dir}/control" <<EOF
Package: ${PACKAGE_NAME}
Version: ${PACKAGE_VERSION}
Architecture: arm64
Depends: initramfs-tools, u-boot-tools
Maintainer: Local X96 Kernel Build <noreply@example.invalid>
Description: Upstream Linux ${KERNEL_VERSION} for the AMedia X96 Max Plus
EOF

    cat >"${control_dir}/postinst" <<EOF
#!/bin/sh
set -eu

release='${kernel_release}'
staging_dir="/var/lib/${PACKAGE_NAME}/\${release}"
image_dir="/usr/lib/${PACKAGE_NAME}/\${release}"
initrd="\${staging_dir}/initrd.img-\${release}"

depmod -a "\${release}"
install -d -m 0755 /boot/dtb/amlogic
install -m 0644 "\${image_dir}/zImage" /boot/zImage
install -m 0644 "\${image_dir}/meson-sm1-x96-max-plus.dtb" /boot/dtb/amlogic/meson-sm1-x96-max-plus.dtb
install -m 0644 "\${image_dir}/config-\${release}" "/boot/config-\${release}"
install -d -m 0755 "\${staging_dir}"
rm -f "\${initrd}"
update-initramfs -c -k "\${release}" -b "\${staging_dir}"
mkimage -A arm -O linux -T ramdisk -C none -d "\${initrd}" /boot/uInitrd
EOF
    chmod 0755 "${control_dir}/postinst"

    cat >"${control_dir}/postrm" <<EOF
#!/bin/sh
set -eu

release='${kernel_release}'
staging_dir="/var/lib/${PACKAGE_NAME}/\${release}"
rm -f "\${staging_dir}/initrd.img-\${release}" \
    "\${staging_dir}/initrd.img-\${release}.bak"
rmdir "\${staging_dir}" 2>/dev/null || true
EOF
    chmod 0755 "${control_dir}/postrm"

    mkdir -p "${PACKAGE_DIR}"
    dpkg-deb --root-owner-group --build "${stage_dir}" "${PACKAGE_DIR}/linux-image-${kernel_release}.deb"
}

main() {
    check_prerequisites
    checkout_source
    apply_board_patch
    configure_kernel
    build_kernel
    package_kernel
    printf 'Built package: %s\n' "${PACKAGE_DIR}/linux-image-${KERNEL_VERSION}-sm1.deb"
}

main "$@"
