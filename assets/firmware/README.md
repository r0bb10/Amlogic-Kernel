# Wi-Fi firmware and board data

## X96 Max Plus

`qca6174-hw3.0-board-2.bin` was copied unchanged from the original local
`out/qca6174-hw3.0-board-2.bin`. The original download source/license was not
recorded here; verify redistribution rights before distributing this file.

The image builder installs Debian's `firmware-atheros` package, then places
this board data at `/usr/lib/firmware/ath10k/QCA6174/hw3.0/board-2.bin`.
The SDIO firmware (`firmware-sdio-6.bin`) comes from the Debian package.
Board variants with a different Wi-Fi chipset require different firmware.

## Tanix TX3 Mini (SSV6051)

`ssv6051-sw.bin` and `ssv6051-wifi.cfg` come from
[`ophub/firmware`](https://github.com/ophub/firmware/tree/a9d0e8337cc8aa2ca4b482acd7b19c74ce05860f/firmware),
revision `a9d0e8337cc8aa2ca4b482acd7b19c74ce05860f`.
Upstream's repository is GPL-2.0; a separate license for this firmware binary
is not recorded alongside it, so verify redistribution terms separately.

The binary is unchanged. The config retains the upstream 24 MHz crystal,
LDO regulator and e-fuse MAC settings; only the descriptive heading and
fallback MAC storage path were adapted for Debian. The latter is
`/var/lib/ssv6051/mac` instead of Android's `/data/wifimac`.
There are no baked-in MAC addresses or network credentials.

The TX3 image installs both files into `/usr/lib/firmware` before generating
the initramfs. `patches/ssv6051.patch` adds the matching driver from
[`unifreq/linux-6.18.y`](https://github.com/unifreq/linux-6.18.y/tree/bcd0ea0431fc71155aa417ac3893199081a58d58/drivers/net/wireless/ssv6051),
revision `bcd0ea0431fc71155aa417ac3893199081a58d58`, and enables it only in GXL.
Its source contains mixed ISC/GPL license notices, preserved in the patch;
review those terms before redistribution. The patch uses current `strscpy`
calls and declares exact firmware filenames for initramfs inclusion.
SDIO device `3030:3030` autoloads `ssv6051`; no forced module-load service is
needed. Wi-Fi credentials still come from `/boot/wpa_supplicant.conf` or
`/etc/wpa_supplicant/wpa_supplicant.conf`.
