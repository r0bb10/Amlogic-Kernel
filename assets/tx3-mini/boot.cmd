echo "Booting from ${devtype} ${devnum}:1"
setenv kernel_addr_r 0x11000000
setenv ramdisk_addr_r 0x15000000
setenv fdt_addr_r 0x08008000
setenv bootenv_addr_r 0x10400000
if load ${devtype} ${devnum}:1 ${bootenv_addr_r} uEnv.txt && env import -t ${bootenv_addr_r} ${filesize}; then
    setenv bootargs ${APPEND}
    if printenv mac; then
        setenv bootargs ${bootargs} mac=${mac}
    elif printenv eth_mac; then
        setenv bootargs ${bootargs} mac=${eth_mac}
    elif printenv ethaddr; then
        setenv bootargs ${bootargs} mac=${ethaddr}
    fi
    if load ${devtype} ${devnum}:1 ${kernel_addr_r} ${LINUX}; then
        if load ${devtype} ${devnum}:1 ${ramdisk_addr_r} ${INITRD}; then
            if load ${devtype} ${devnum}:1 ${fdt_addr_r} ${FDT}; then
                fdt addr ${fdt_addr_r}
                booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
            fi
        fi
    fi
fi
echo "Boot failed on ${devtype} ${devnum}:1"
