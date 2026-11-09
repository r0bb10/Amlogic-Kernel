echo "Booting Debian from USB"
setenv kernel_addr_r 0x11000000
setenv ramdisk_addr_r 0x15000000
setenv fdt_addr_r 0x08008000
setenv bootenv_addr_r 0x10400000
if load usb 0:1 ${bootenv_addr_r} uEnv.txt; then
    env import -t ${bootenv_addr_r} ${filesize}
    setenv bootargs ${APPEND} tx3_uboot_test=2026.04
    if load usb 0:1 ${kernel_addr_r} ${LINUX}; then
        if load usb 0:1 ${ramdisk_addr_r} ${INITRD}; then
            if load usb 0:1 ${fdt_addr_r} ${FDT}; then
                fdt addr ${fdt_addr_r}
                booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
            fi
        fi
    fi
fi
echo "USB boot failed"
while true; do sleep 10; done
