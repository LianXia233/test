# Hiveton H5000M (MT7987A) — Debian 13 备用引导脚本源文件
#
# 【主引导路径】无需本脚本：
#   现有 U-Boot 从 eMMC p4 (kernel 分区) 读取 H5000M-debian13-kernel.bin 并 bootm，
#   分区布局 / 启动链完全不变（BootROM → BL2 → FIP → U-Boot → p4 FIT → Kernel
#   → root=PARTLABEL=rootfs → p5 Debian）。
#
# 【本脚本用途】备用/兜底引导（boot.scr）：
#   当 U-Boot 支持 distro boot（bootflow scan）时，会扫描文件系统分区。
#   本脚本编译为 /boot/boot.scr 后放在 p5 rootfs 的 /boot 下，
#   从 p5（ext4）加载备用 Image + DTB 并 booti 启动。
#   即使 p4 FIT 引导失败，也可从 U-Boot 控制台手动：
#     load mmc 0:5 ${scriptaddr} /boot/boot.scr; source ${scriptaddr}
#
# 编译：mkimage -A arm64 -O linux -T script -C none -n "H5000M Debian" -d boot.cmd boot.scr
# 参考：build/make-boot.sh

# kernel_addr_r 是 FIT 的暂存地址，必须与 FIT 内部 load/entry（0x46000000，见
# build/make-sd-image.sh）错开：bootm 解压目标 = FIT 内 load 地址，若暂存与 load
# 重合会触发解压自重叠（BOOTM_ERR_OVERLAP / LZMA 解码损坏）。0x60000000 与
# U-Boot 主引导路径实测一致，且远离解压窗口（0x46000000~0x4A000000）。
setenv kernel_addr_r 0x60000000
setenv fdt_addr_r 0x45000000
setenv ramdisk_addr_r 0x44000000

# bootargs 与官方 OpenWrt 一致（实测 H5000M sysupgrade.bin chosen/bootargs）
setenv bootargs 'earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=rootfs rootwait pci=pcie_bus_perf console=ttyS0,115200n8'

echo '### H5000M Debian boot (fallback): trying eMMC p5 (/boot, ext4) ###'
setenv devtype mmc
setenv devnum 0
load ${devtype} ${devnum}:5 ${kernel_addr_r} /boot/Image && load ${devtype} ${devnum}:5 ${fdt_addr_r} /boot/mt7987a-hiveton-h5000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### H5000M Debian boot (fallback): trying USB (usb 0:1) ###'
usb start
setenv devtype usb
setenv devnum 0
load ${devtype} ${devnum}:1 ${kernel_addr_r} /boot/Image && load ${devtype} ${devnum}:1 ${fdt_addr_r} /boot/mt7987a-hiveton-h5000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### H5000M Debian boot: no boot device found, dropping to shell ###'
