# Hiveton H5000M (MT7987A) — Debian 13 启动脚本源文件
#
# 用途：编译为 boot.scr 后放置于启动分区（vfat，LABEL=H5000MBOOT）。
#       兼容 ImmortalWrt / OpenWrt Filogic 系列 U-Boot（boot.scr 自动加载流程），
#       无需修改 U-Boot 本身。
#
# 启动顺序：eMMC (mmc 0) -> USB (usb 0 / usb 1)
# 每个设备使用 GPT 分区 1（boot，vfat），加载 Image + DTB 后 booti 启动。
# 根文件系统由内核参数 root=PARTLABEL=rootfs 定位（分区 2，ext4）。
#
# 编译：mkimage -A arm64 -O linux -T script -C none -n "H5000M Debian" -d boot.cmd boot.scr
# 参考：build/make-boot.sh

setenv kernel_addr_r 0x46000000
setenv fdt_addr_r 0x45000000
setenv ramdisk_addr_r 0x44000000

setenv bootargs 'root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8'

echo '### H5000M Debian boot: trying eMMC (mmc 0:1) ###'
setenv devtype mmc
setenv devnum 0
load ${devtype} ${devnum}:1 ${kernel_addr_r} Image && load ${devtype} ${devnum}:1 ${fdt_addr_r} mt7987a-hiveton-h5000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### H5000M Debian boot: trying USB (usb 0:1) ###'
usb start
setenv devtype usb
setenv devnum 0
load ${devtype} ${devnum}:1 ${kernel_addr_r} Image && load ${devtype} ${devnum}:1 ${fdt_addr_r} mt7987a-hiveton-h5000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### H5000M Debian boot: trying USB (usb 1:1) ###'
setenv devnum 1
load ${devtype} ${devnum}:1 ${kernel_addr_r} Image && load ${devtype} ${devnum}:1 ${fdt_addr_r} mt7987a-hiveton-h5000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### H5000M Debian boot: no boot device found, dropping to shell ###'
