#!/bin/bash
set -euo pipefail
[[ $(uname -m) == aarch64 ]]

case "$LIBC" in
 glibc) arch=aarch64;;
 musl) arch=aarch64-musl;;
 *) exit 2;;
esac

case "$FILESYSTEM" in
 ext4|btrfs);;
 *) exit 2;;
esac

case "$IMAGE_SIZE" in
 4GiB|6GiB|8GiB|12GiB|16GiB);;
 *) exit 2;;
esac

[[ "$PI_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ && "$PI_HOSTNAME" != *- ]]
[[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ && "$TIMEZONE" != *..* ]]

for v in NETWORK_MANAGER BLUETOOTH SSH SUDO EXPAND; do
 [[ ${!v} == true || ${!v} == false ]]
done

pkgs=(openssh tzdata)

[[ $NETWORK_MANAGER == false ]] || pkgs+=(NetworkManager dbus)
[[ $BLUETOOTH == false ]] || pkgs+=(bluez dbus)
[[ $SUDO == false ]] || pkgs+=(sudo)
[[ $FILESYSTEM != btrfs ]] || pkgs+=(btrfs-progs)

case "$DESKTOP" in
 minimal);;
 kde) pkgs+=(kde5 sddm dbus elogind xorg);;
 gnome) pkgs+=(gnome gdm dbus elogind);;
 xfce) pkgs+=(xfce4 lightdm lightdm-gtk3-greeter xorg dbus elogind);;
 lxqt) pkgs+=(lxqt sddm xorg dbus elogind);;
 mate) pkgs+=(mate lightdm lightdm-gtk3-greeter xorg dbus elogind);;
 cinnamon) pkgs+=(cinnamon lightdm-gtk3-greeter lightdm xorg dbus elogind);;
 cosmic) pkgs+=(cosmic cosmic-greeter dbus elogind);;
 *) exit 2;;
esac

[[ $DESKTOP == minimal || $IMAGE_SIZE != 4GiB ]] || {
 echo 'Choose at least 6GiB for desktop builds'
 exit 2
}

read -ra extra <<< "$EXTRA_PACKAGES"

for p in "${extra[@]}"; do
 [[ $p =~ ^[a-zA-Z0-9][a-zA-Z0-9+_.-]*$ ]] || exit 2
 pkgs+=("$p")
done

xbps-install -Suy xbps
xbps-install -Suy

xbps-install -Sy \
 bash make git curl coreutils findutils \
 util-linux parted e2fsprogs dosfstools \
 btrfs-progs xz tar gzip gawk sed rsync python3

make

repo=https://repo-default.voidlinux.org/current
repos=(-r "$repo" -r "$repo/musl" -r "$repo/aarch64")

mkdir -p output

platform="rpi-$arch"
root="void-$arch-ROOTFS.tar.xz"
plat="void-$platform-PLATFORMFS.tar.xz"

export BUILD_HOSTNAME="$PI_HOSTNAME"

bash ./mkrootfs.sh \
 "${repos[@]}" \
 -x 2 \
 -o "$root" \
 "$arch"

bash ./mkplatformfs.sh \
 "${repos[@]}" \
 -x 2 \
 -o "$plat" \
 -p "${pkgs[*]}" \
 -k 'bash ci/rpi5/configure.sh' \
 "$platform" "$root"

rm -f "$root"
rm -rf xbps-cachedir-*

python3 - <<'PY'
from pathlib import Path
import os

p = Path('mkimage.sh')
s = p.read_text()

s = s.replace(
    "'s|^#\\(PermitRootLogin\\) .*|\\1 yes|g'",
    "'s|^#\\(PermitRootLogin\\) .*|\\1 no|g'"
)

if os.environ['EXPAND'] == 'false':
    s = s.replace(
        'sed -i "${ROOTFS}/etc/default/growpart" -e \'s/#ENABLE/ENABLE/\'',
        ': # expansion disabled'
    )

assert 's/#ENABLE/ENABLE/' in s if os.environ['EXPAND'] == 'true' else 's/#ENABLE/ENABLE/' not in s

s = s.replace(
    '_args="-I -F16"',
    '_args="-I -F32"'
).replace(
    '2048,${BOOT_FSSIZE},b,*',
    '2048,${BOOT_FSSIZE},c,*'
)

s = s.replace(
    '[ "$ROOT_FSTYPE" = "f2fs" ]',
    '[ "$ROOT_FSTYPE" = "f2fs" ] || [ "$ROOT_FSTYPE" = "btrfs" ]'
)

p.write_text(s)
PY

name="void-rpi5-aarch64-$LIBC-$DESKTOP-$FILESYSTEM.img"

bash ./mkimage.sh \
 -B 512MiB \
 -b vfat \
 -r "$FILESYSTEM" \
 -s "$IMAGE_SIZE" \
 -x 2 \
 -o "output/$name" \
 "$plat"

rm -f "$plat"

printf "libc=%s\ndesktop=%s\nfilesystem=%s\nimage_size=%s\n" \
 "$LIBC" "$DESKTOP" "$FILESYSTEM" "$IMAGE_SIZE" \
 > output/build-info.txt

cd output
xz -t "$name.xz"
sha256sum "$name.xz" > SHA256SUMS
chmod a+r *
