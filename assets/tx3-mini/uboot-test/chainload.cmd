echo "Starting USB bootloader"
usb start
if fatload usb 0:1 0x01000000 u-boot-test.bin; then
    go 0x01000000
fi
echo "Unable to start USB bootloader"
while true; do sleep 10; done
