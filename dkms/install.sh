#!/bin/sh
# Install the driver through DKMS so it is rebuilt automatically on kernel updates.
# Usage: sudo dkms/install.sh
# After changing the driver source, bump PACKAGE_VERSION in dkms/dkms.conf
# (or just re-run this script, it removes the old copy first).
set -e

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
command -v dkms >/dev/null || { echo "dkms is not installed (sudo pacman -S dkms)."; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
NAME="aic8800d80-pcie"
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$HERE/dkms.conf")
DEST="/usr/src/$NAME-$VER"

echo "==> Removing any previous DKMS copy of $NAME $VER"
dkms remove -m "$NAME" -v "$VER" --all >/dev/null 2>&1 || true
rm -rf "$DEST"

echo "==> Copying sources to $DEST"
mkdir -p "$DEST"
(cd "$REPO/source/aic8800_fdrv" && tar \
    --exclude='*.o' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' \
    --exclude='*.cmd' --exclude='modules.order' --exclude='Module.symvers' \
    -cf - .) | tar -xf - -C "$DEST"
cp "$HERE/dkms.conf" "$HERE/dkms-make.sh" "$DEST/"
chmod +x "$DEST/dkms-make.sh"

echo "==> Registering and building for the running kernel ($(uname -r))"
dkms add -m "$NAME" -v "$VER"
dkms install -m "$NAME" -v "$VER"

echo "==> Done:"
dkms status
