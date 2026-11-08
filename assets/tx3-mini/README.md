# Tanix TX3 Mini (S905W / GXL)

Boot scripts and their sources are copied unchanged from
[`ophub/amlogic-s9xxx-armbian`](https://github.com/ophub/amlogic-s9xxx-armbian/tree/ef311078d2857f1c02c6085063c200589108d48e/build-armbian/armbian-files/platform-files/amlogic/bootfs),
revision `ef311078d2857f1c02c6085063c200589108d48e` (GPL-2.0 repository).

`u-boot-s905x-s912.bin` is copied unchanged from
[`ophub/u-boot`](https://github.com/ophub/u-boot/blob/5bf7380c25a22e889b78b4b670928272421cd6a9/u-boot/amlogic/overload/u-boot-s905x-s912.bin),
revision `5bf7380c25a22e889b78b4b670928272421cd6a9`.
Upstream distributes this binary without recording its precise build inputs
or a per-file license alongside it; verify redistribution terms separately.

Ophub's model database entry 111 selects this overload and
`meson-gxl-s905w-tx3-mini.dtb`. Our kernel builds the DTB from upstream Linux;
no precompiled DTB is stored here.

`u-boot.usb`, `u-boot.sd`, and `boot.ini` are copied unchanged from the
known-working external-media image:

```
https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.11/Armbian_26.11.0_amlogic_s905w_trixie_6.18.59_server_2026.11.02.img.gz
SHA256: e6323cc41e15cb92310f41907f992b2906d22a37b21cabcb84ac8f1a30dc1fb2
```

Keep these external-media boot files: `u-boot.usb` and `u-boot.sd` are the
2015.01 bootloaders supplied by Ophub, with `boot.ini` as their boot entry.
They are distinct from the 2020.07 `u-boot-s905x-s912.bin` overload. Omitting
them does not reproduce the known-working USB image's boot setup.

`patches/gxl.patch` restores the legacy Amlogic ARM64 Image load offset
(`0x01080000`) used by the working Ophub S905W kernel. A plain upstream
zero-offset Image is not interchangeable with it on the stock bootloader.
The GXL package must also create `uInitrd` with `mkimage -A arm64`:
legacy U-Boot rejects a ramdisk labelled as 32-bit ARM on this boot path.

The overload is kept under its original filename, as in Ophub's S905W image.
Do not create `/boot/u-boot.ext`: its presence makes `s905_autoscript` jump
into another U-Boot instead of directly loading Linux through the existing
bootloader. No raw bootloader is written into the image.
Boot from SD/USB using the stock bootloader's recovery/multiboot mechanism;
`aml_autoscript` enables multiboot by changing its environment.

USB boot was reported working on the inspected 2 GB / 16 GB unit after these
fixes. Do not use the X96 bootloader or eMMC installer on it. RAM and Wi-Fi
vary between revisions;
SSV6051 Wi-Fi is confirmed on the inspected 2 GB / 16 GB unit. GXL builds
include the extra SSV6051 driver and both firmware/config files by default;
see `assets/firmware/README.md` for their sources and adaptations. Driver
compilation is checked locally, but association with this custom kernel still
needs hardware verification. Other revisions may use a different Wi-Fi module.
