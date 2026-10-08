# Airpi AP3000M (MT7981B) — Debian 13 备用引导脚本源文件
#
# 【主引导路径】无需本脚本：
#   现有 U-Boot 从 eMMC p4 (kernel 分区) 读取 AP3000M-debian13-kernel.bin 并 bootm，
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
# 编译：mkimage -A arm64 -O linux -T script -C none -n "AP3000M Debian" -d boot.cmd boot.scr
# 参考：build/make-boot.sh --board ap3000m
#
# 【多板说明】本文件是 AP3000M 的板级 boot.cmd，位于 boot/<board>/boot.cmd。
# 各板 DTB 文件名 / 串口基址 / bootargs 不同，故 boot.cmd 按板独立维护；
# make-boot.sh --board <id> 读取 boot/<id>/boot.cmd 编译为 out/boot/boot.scr。
#
# 【与 H5000M 的差异】
#   1. DTB 文件名：mt7981b-airpi-ap3000m.dtb
#   2. bootargs 串口基址：earlycon=uart8250,mmio32,0x11002000（MT7981B，不是 0x11000000）
#   3. 不带 pci=pcie_bus_perf（MT7981B 无 PCIe 控制器）
#   4. kernel_addr_r 取 0x44000000（见下方说明，避让 FIT 解压窗口）

# 【地址规划】FIT 内 load/entry = 0x46000000~0x4A000000（见 boards/ap3000m.board 的
# BOARD_FIT_LOAD_ADDR 与 build/make-sd-image.sh）。备用引导走 booti 加载裸 Image，
# Image 本身是位置无关的，但 DTB 必须落在内核解压/保留区之外。
# MT7981B DDR 起始 0x40000000；U-Boot 自身通常位于 0x41e00000 之上（BL2 布局），
# 故暂存区避开 [0x41e00000, 0x42000000) 与 FIT 窗口 [0x46000000, 0x4A000000)：
#   kernel_addr_r = 0x44000000（Image 暂存，位于 FIT 窗口之前，两者不重叠）
#   fdt_addr_r    = 0x43f00000（DTB，紧邻 kernel 之下）
#   ramdisk_addr_r= 0x43e00000
# 【实机注意】若 AP3000M 的 U-Boot 把自身重定位到 0x44000000 附近，需按实际
# `bdinfo` 输出的 relocaddr / ram_top 调整这三个地址（仅影响备用引导，主路径
# p4 FIT 不受影响）。
setenv kernel_addr_r 0x44000000
setenv fdt_addr_r 0x43f00000
setenv ramdisk_addr_r 0x43e00000

# bootargs：与 build/make-sd-image.sh 中 BOARD_BOOTARGS 生成的 cmdline 保持一致
#（fdtput 会覆写 DTB /chosen/bootargs，此处保证备用引导路径的 cmdline 自身正确）。
# 补 rw 的原因同 H5000M：厂商 U-Boot env 默认 bootargs 无 rw，p5 会 ro 挂载导致
# 引导层 /sbin/init 的 overlay 组装失败（引导层 init 内已另加 remount,rw 兜底）。
setenv bootargs 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x11002000 root=PARTLABEL=rootfs rootwait rw'

echo '### AP3000M Debian boot (fallback): trying eMMC p5 (/boot, ext4) ###'
setenv devtype mmc
setenv devnum 0
load ${devtype} ${devnum}:5 ${kernel_addr_r} /boot/Image && load ${devtype} ${devnum}:5 ${fdt_addr_r} /boot/mt7981b-airpi-ap3000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### AP3000M Debian boot (fallback): trying USB (usb 0:1) ###'
usb start
setenv devtype usb
setenv devnum 0
load ${devtype} ${devnum}:1 ${kernel_addr_r} /boot/Image && load ${devtype} ${devnum}:1 ${fdt_addr_r} /boot/mt7981b-airpi-ap3000m.dtb && booti ${kernel_addr_r} - ${fdt_addr_r}

echo '### AP3000M Debian boot: no boot device found, dropping to shell ###'
