# Tanix TX3 Mini (S905W / GXL)

## Boot chain

The stock firmware starts external media through `s905_autoscript` or the
vendor `u-boot.usb` / `u-boot.sd` loader and `boot.ini`. Both entries load
`u-boot.bin` at `0x01000000` and jump to it. U-Boot 2026.04 then scans USB
followed by MMC for partition 1's `boot.scr`, which reads `uEnv.txt` and
loads the kernel, initramfs and upstream TX3 Mini DTB from that device.
The DTB scratch address is `0x08008000`, outside secure-monitor memory.
`boot.ini`, `s905_autoscript`, and `boot.scr` are generated from the `.cmd`
sources. There is no `u-boot.ext` alias or raw bootloader in the image.

GXL kernels now retain upstream's zero ARM64 Image offset. Do not pair a
new GXL package with the old direct-boot scripts. Update the chainloader
and scripts together, or use a newly generated recovery image. The package
continues to wrap its initramfs with an AArch64 (`mkimage -A arm64`) header.

USB and standalone eMMC boot with U-Boot 2026.04 and the zero-offset
kernel were verified on the 2 GB / 16 GB TX3 Mini: kernel placement was
2 MiB aligned, with no alignment warning or failed services. The cleaned
shared USB/MMC scanning configuration still needs a fresh image boot check.
SD and other hardware revisions have not been verified.

The image is external-media recovery only: no TX3 eMMC installer is
included. Do not use the X96 installer or replace raw bootloader sectors.
Existing eMMC installations can reuse this payload as `u-boot.emmc` only
with matching `boot.scr`, `uEnv.txt`, and a zero-offset kernel, preserving
their original vendor handoff and partition layout. Keep a recovery USB
and off-device backups before changing an installed system.

`aml_autoscript` is the original multiboot provisioning script; it writes
the stock firmware's environment and reboots when first enabling multiboot.
The new chainloader and normal boot scripts do not save an environment.
`starting USB...` initializes controllers/keyboard; the subsequent
`Booting from usb/mmc N:1` message identifies the Linux boot source.

## Source and rebuild

`u-boot.bin` is built from upstream U-Boot **v2026.04**, commit
`88dc2788777babfd6322fa655df549a019aa1e69`, using `u-boot.defconfig`.
It is based on `libretech-cc_defconfig`; the GXL chainload approach is from
[hexdump0815/u-boot-misc](https://github.com/hexdump0815/u-boot-misc/blob/ac94f69894744fce995f812b6560607abc9f13a9/readme.gxl).
Serial, HDMI and USB keyboard are enabled. The banner has no custom suffix,
and the environment is RAM-only with `saveenv` disabled. No new SPL, BL31,
FIP or DRAM initialization firmware is built or installed.

To rebuild the payload and boot scripts on Debian, install `git`, `build-essential`,
`gcc-aarch64-linux-gnu`, `bison`, `flex`, `libssl-dev`, `python3` and
`u-boot-tools`, then run:

```
tools/build-tx3-uboot.sh
```

Build intermediates stay under `out/.work/tx3-uboot/`. U-Boot is GPL-2.0+
(see `COPYING`);
the exact source and its `Licenses/` directory are available at the pinned
[upstream revision](https://github.com/u-boot/u-boot/tree/88dc2788777babfd6322fa655df549a019aa1e69).
The rebuild uses a fixed source timestamp; the compiler version can still
affect binary hashes. `SHA256SUMS` records the checked-in boot assets.

## Vendor files

`aml_autoscript` and its source are unchanged from
[ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian/tree/ef311078d2857f1c02c6085063c200589108d48e/build-armbian/armbian-files/platform-files/amlogic/bootfs),
revision `ef311078d2857f1c02c6085063c200589108d48e` (GPL-2.0 repository).

The unchanged 2015.01 `u-boot.usb` and `u-boot.sd` come from:

```
https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.11/Armbian_26.11.0_amlogic_s905w_trixie_6.18.59_server_2026.11.02.img.gz
SHA256: e6323cc41e15cb92310f41907f992b2906d22a37b21cabcb84ac8f1a30dc1fb2
```

Keep these vendor external-media loaders: they are a different stage from
the new mainline chainloader. No precompiled Linux DTB is stored here.
GXL includes SSV6051 driver/firmware; see `assets/firmware/README.md`.
Association with the custom kernel remains unverified, and other TX3 Mini
revisions may use different RAM or Wi-Fi hardware.
