#!/bin/bash
set -euo pipefail

r=$1
[[ -d "$r/etc/runit/runsvdir/default" && -d "$r/usr" ]]

services="$r/etc/runit/runsvdir/default"

enable() {
    [[ -d "$r/etc/sv/$1" ]] || {
        echo "Missing service $1"
        exit 1
    }
    ln -sfn "/etc/sv/$1" "$services/$1"
}

disable() {
    rm -f "$services/$1"
}

printf '%s\n' "$BUILD_HOSTNAME" > "$r/etc/hostname"

[[ -f "$r/usr/share/zoneinfo/$TIMEZONE" ]]
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$r/etc/localtime"

if [[ $NETWORK_MANAGER == true ]]; then
    disable dhcpcd
    disable wpa_supplicant
    disable iwd
    enable dbus
    enable NetworkManager
else
    disable NetworkManager
    enable dhcpcd
fi

if [[ $BLUETOOTH == true ]]; then
    enable dbus
    enable bluetoothd
else
    disable bluetoothd
fi

if [[ $SSH == true ]]; then
    enable sshd
else
    disable sshd
fi

sed -i -E '/^[[:space:]#]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication)[[:space:]]/d' "$r/etc/ssh/sshd_config"

printf '\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> "$r/etc/ssh/sshd_config"

rm -f "$r"/etc/ssh/ssh_host_*

chroot "$r" useradd -m -s /bin/bash admin

printf 'admin:voidlinux\nroot:voidlinux\n' | chroot "$r" chpasswd

chroot "$r" chage -d 0 admin
chroot "$r" chage -d 0 root

if [[ $SUDO == true ]]; then
    chroot "$r" usermod -aG wheel admin
    mkdir -p "$r/etc/sudoers.d"
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$r/etc/sudoers.d/90-rpi5"
    chmod 440 "$r/etc/sudoers.d/90-rpi5"
fi

case "$DESKTOP" in
    minimal)
        ;;
    kde|lxqt)
        enable dbus
        enable sddm
        ;;
    gnome)
        enable dbus
        enable gdm
        ;;
    xfce|mate|cinnamon)
        enable dbus
        enable lightdm
        ;;
    cosmic)
        enable dbus
        enable cosmic-greeter
        ;;
esac

find "$r/boot" -name 'bcm2712-rpi-5-b.dtb' -print -quit | grep -q . || {
    echo 'Pi 5 device tree missing from platform firmware'
    exit 1
}

[[ -s "$r/boot/config.txt" && -s "$r/boot/cmdline.txt" ]]

xbps-query -r "$r" -l > /build/output/packages-installed.txt
