#!/usr/bin/env bash
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
ASSETS="$ROOT/assets/tx3-mini"
WORK="$ROOT/out/.work/tx3-uboot"
REVISION=88dc2788777babfd6322fa655df549a019aa1e69
SOURCE="$WORK/source"
BUILD="$WORK/build"
CROSS_COMPILE=${CROSS_COMPILE-aarch64-linux-gnu-}
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=amlogic TZ=UTC LC_ALL=C

for command in git make cc "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}readelf" bison flex python3 mkimage sha256sum flock; do
    command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 1; }
done
mkdir -p "$WORK"
exec 9>"$WORK/build.lock"
flock -n 9 || { echo 'Another TX3 U-Boot build is running' >&2; exit 1; }
if [[ ! -d $SOURCE/.git ]]; then
    git clone --depth 1 --branch v2026.04 https://github.com/u-boot/u-boot.git "$SOURCE"
fi
[[ $(git -C "$SOURCE" rev-parse HEAD) == "$REVISION" ]] || { echo 'Unexpected U-Boot source revision' >&2; exit 1; }
[[ -z $(git -C "$SOURCE" status --porcelain --untracked-files=all) ]] || { echo 'U-Boot source tree is not clean' >&2; exit 1; }
SOURCE_DATE_EPOCH=$(git -C "$SOURCE" show -s --format=%ct "$REVISION")
export SOURCE_DATE_EPOCH
mkdir -p "$BUILD"
cp "$ASSETS/u-boot.defconfig" "$BUILD/.config"
make -C "$SOURCE" O="$BUILD" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$SOURCE" O="$BUILD" CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)" u-boot.bin
"${CROSS_COMPILE}readelf" -h "$BUILD/u-boot" | grep -Eq 'Entry point address: +0x1000000$'
grep -qx 'CONFIG_ENV_IS_NOWHERE=y' "$BUILD/.config"
grep -qx '# CONFIG_CMD_SAVEENV is not set' "$BUILD/.config"
python3 - "$BUILD/u-boot.bin" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
assert b'U-Boot 2026.04 (' in data, 'unexpected U-Boot version'
assert b'-dirty' not in data and b'tx3-test' not in data, 'unexpected version or boot-path suffix'
PY
cp "$BUILD/u-boot.bin" "$ASSETS/u-boot.bin"
cp "$SOURCE/COPYING" "$ASSETS/COPYING"
mkimage -A arm64 -O linux -T script -C none -n 'Boot' \
    -d "$ASSETS/boot.cmd" "$ASSETS/boot.scr"
mkimage -A arm -O linux -T script -C none -n 'U-Boot' \
    -d "$ASSETS/s905_autoscript.cmd" "$ASSETS/s905_autoscript"
{ printf 'ODROIDN2-UBOOT-CONFIG\n'; cat "$ASSETS/s905_autoscript.cmd"; } > "$ASSETS/boot.ini"
(
    cd "$ASSETS"
    sha256sum u-boot.bin u-boot.defconfig COPYING boot.cmd boot.scr boot.ini \
        s905_autoscript.cmd s905_autoscript aml_autoscript.cmd aml_autoscript \
        u-boot.usb u-boot.sd > SHA256SUMS
)
printf 'Built TX3 Mini U-Boot 2026.04 and boot scripts in %s\n' "$ASSETS"
