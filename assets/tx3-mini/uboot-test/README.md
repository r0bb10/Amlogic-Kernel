# Experimental USB-only chainloader

Not installed by the image builder. Do not replace the working eMMC loader
until hardware testing succeeds.

Source: U-Boot v2026.04, commit
`88dc2788777babfd6322fa655df549a019aa1e69`, https://github.com/u-boot/u-boot.
Base configuration: `libretech-cc_defconfig`, following the GXL chainload
approach documented in hexdump0815/u-boot-misc at
`ac94f69894744fce995f812b6560607abc9f13a9` (`readme.gxl`).

The build retains upstream serial/HDMI support and enables USB keyboard.
Unlike the public HDMI-only patch, it does not import MMC environments or
change board LEDs. Environment storage is RAM-only. Its boot command loads
only USB `0:1`'s `tx3-test.scr`; no eMMC fallback is configured. No new BL31,
SPL, FIP or DRAM initialization firmware is used for this chainload test.

`defconfig` records the build configuration. Build in a checkout of the
pinned U-Boot source with an AArch64 cross-compiler:

```
cp /path/to/this/defconfig .config
make CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j4 CROSS_COMPILE=aarch64-linux-gnu- u-boot.bin
```

`chainload.cmd` is the legacy-loader entry (load/jump at `0x01000000`).
`linux.cmd` becomes `tx3-test.scr`, loading the existing USB Linux payload
and adding `tx3_uboot_test=2026.04` to `/proc/cmdline` for verification.
The kernel and its legacy offset are unchanged in this first test.

Test deployment backs up the USB boot scripts, replaces `boot.ini` and
`s905_autoscript` with the chainload entry, and makes `aml_autoscript` a
non-persistent test entry too. The original `u-boot.usb`/`u-boot.sd` remain.
No `saveenv`, raw flashing, eMMC writes, or image regeneration are needed.
If it hangs, remove USB and power-cycle to boot unchanged eMMC Debian.

U-Boot is GPL-2.0+; see the pinned source's `Licenses/` directory for full
licensing information and individual source-file notices.

The current build has no custom version suffix and disables automatic
local-version suffixes. Its preboot hook prints exactly `U-Boot 2026.04`
after console initialization, so the version is visible on HDMI as well
as serial. Upstream's full banner still includes its normal build date.
Boot-script messages are limited to normal startup and failure messages.
The USB-only defaults and command-line verification marker remain until
eMMC boot has been separately validated.

Current payload SHA256:
`4e5d6a03f792bee9f3b96cc4ab2bdf2c46a3818c4304ab239fe3ada1b81946f2`.
The hashes in the historical test notes below identify the earlier build.

## Initial test, 2026-11-09

Build and ELF entry-address checks passed. Binary SHA256:
`aa85244b672b3504142b3e0e87bc64f873261f8c9c21bb1c915755a697ef8741`.
EFI capsule host-tool generation was disabled (not needed for this payload).

Deployed to the existing USB Debian at `10.0.0.194` and rebooted. No SSH
response at `.194`, `.186`, or `.187` within 120 seconds. Candidate boot is
**not verified**; display/serial evidence is needed before further changes.
Do not promote this binary to eMMC or the default image assets.

HDMI subsequently showed the candidate reached the USB Linux script but
failed loading the DTB. The initial script incorrectly selected
`0x10000000`, inside Meson's secure-monitor reserved range
(`0x10000000`–`0x10200000`). Corrected the script to use `0x08008000`.
After deploying that correction from eMMC Debian, reboot successfully
started USB Debian at `10.0.0.187`. `/proc/cmdline` contains
`tx3_uboot_test=2026.04`; root and BOOT are `/dev/sda2` and `/dev/sda1`.
System state is running, with zero failed services. Both eMMC partitions
are unmounted. The first 117 MiB and both hardware boot-area SHA256 hashes
match the pre-test values. Kernel alignment warning remains, as expected
with the unchanged legacy-offset kernel. This verifies the USB chainload
and Linux boot path, not yet an eMMC loader replacement or aligned kernel.

## Zero-offset USB test, 2026-11-09

Backed up USB `zImage` to `/boot/uboot-test-backup/zImage-legacy-offset`
and the off-device backup directory. Replaced only bytes 8–15 (the ARM64
Image `text_offset` field) with zero; all other bytes are unchanged. No
kernel rebuild, module changes, or eMMC payload changes were made.

Reboot through the same candidate succeeded at `10.0.0.187` with USB root
and BOOT and the expected test marker. Kernel physical start changed from
`0x11080000` to `0x11000000` (2 MiB aligned). The alignment warning is
absent, and there are zero failed services. Expected USB dummy-regulator
and staging-video warnings remain. eMMC prefix and hardware boot-area
hashes still match the pre-test values.

Zero-offset test Image SHA256:
`57f94b99681cb34fe9afd4ca43faef46dad91cee5046df94daab4204bcae0e2a`.
Full verification is in the off-device backup directory's
`zero-offset-verification.txt`. The repository's legacy kernel patch is
unchanged; removing it from production builds requires coordinating the
new loader with the supported boot paths.

Original USB entry scripts remain in `/boot/uboot-test-backup/`. To restore
the previous USB boot flow, copy its `boot.ini`, `aml_autoscript`, and
`s905_autoscript` back to the USB BOOT partition root. Test payload files can
remain unused. A separate off-device backup and preflight hashes are kept
at `/home/r88t/tx3-uboot-usb-backup-2026-11-09/` on the build host.
