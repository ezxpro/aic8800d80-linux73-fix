#!/bin/sh
# Called by DKMS: dkms-make.sh <kernel version> <kernel source dir>
# Builds with clang (LLVM=1) when the target kernel was built with clang,
# as CachyOS kernels are; building such a kernel's modules with gcc fails.
set -e
kver="$1"
ksrc="$2"
extra=""
if grep -q '^CONFIG_CC_IS_CLANG=y' "$ksrc/.config" 2>/dev/null; then
    extra="LLVM=1"
fi
exec make KVER="$kver" KDIR="$ksrc" $extra
