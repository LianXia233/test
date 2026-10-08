#!/bin/sh
# <board> Debian: let NetworkManager exclusively acquire DHCP for the MT5700M link.
# The USB Ethernet device is eth2 on this board; the interface can appear after
# at-webserver starts. A saved WAN-5G profile autoconnects when the device arrives.

IFACE=eth2
DEVICE_PATH="$(readlink -f "/sys/class/net/$IFACE/device" 2>/dev/null || true)"
case "$DEVICE_PATH" in
    *usb*) ;;
    *) exit 0 ;;
esac

command -v nmcli >/dev/null 2>&1 || exit 0
# Request activation without waiting in the modem event path. Never launch a
# second DHCP client: NetworkManager owns this connection and its lease files.
nmcli --wait 0 connection up id WAN-5G ifname "$IFACE" >/dev/null 2>&1 || true
exit 0
