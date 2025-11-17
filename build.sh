#!/bin/bash
set -e

# Get the path this script is located in
SCRIPT_DIR="$(realpath "$(dirname "$0")")"
cd "$SCRIPT_DIR" || exit 1
echo $SCRIPT_DIR

NEEDED_TOOLS=""
DEF_CONFIG="$SCRIPT_DIR/configs/gtvhacker/defconfig"
ROOTFS_BASE="$SCRIPT_DIR/rootfs"
ROOTFS_PATH="devices.cpio:busybox:terminfo:iptables:base"
LOGO_PATH="$SCRIPT_DIR/logo/nest-logo-320x320.png"
BUILD_TEMP="$SCRIPT_DIR/build-temp"
BUILD_KMOD="$BUILD_TEMP/modules"
NEW_ROOTFS="$SCRIPT_DIR/initramfs_data.cpio"

if [[ -d "$BUILD_TEMP" ]]; then
  rm -rf "$BUILD_TEMP"
fi

mkdir -p "$BUILD_TEMP" "$BUILD_KMOD"

if [[ -f "$1" ]]; then
  DEF_CONFIG="$1"
fi

if [[ -n "$2" ]]; then
  ROOTFS_PATH="$2"
fi

if [[ -f "$3" ]]; then
  LOGO_PATH="$3"
fi

DEF_CONFIG="$(realpath "$DEF_CONFIG")"
LOGO_PATH="$(realpath "$LOGO_PATH")"

# Check for depmod
if ! which depmod > /dev/null; then
  NEEDED_TOOLS="$NEEDED_TOOLS kmod"
fi

# Check for fakeroot
if ! which fakeroot > /dev/null; then
  NEEDED_TOOLS="$NEEDED_TOOLS fakeroot"
fi

# Check for cpio
if ! which cpio > /dev/null; then
  NEEDED_TOOLS="$NEEDED_TOOLS cpio"
fi

# Check for mkimage
if ! which mkimage > /dev/null; then
  NEEDED_TOOLS="$NEEDED_TOOLS u-boot-tools"
fi

# Check for pngtopnm
if ! which pngtopnm > /dev/null; then
  NEEDED_TOOLS="$NEEDED_TOOLS netpbm"
fi

if [[ ! -z "$NEEDED_TOOLS" ]]; then
  printf 'The following packages are required but not installed:\n\n' &&
  printf '  %s\n' $NEEDED_TOOLS &&
  printf '\nPlease install them with apt and try again.\n'
  exit 1
fi

# Setup the toolchain
source toolchain/bootstrap.sh

# Create the logo file
(
  echo "Converting \"$(basename "$LOGO_PATH")\" to \"logo_diamond_clut224.ppm\"..."
  pngtopnm -mix "$LOGO_PATH" | \
    ppmquant -fs 223 | \
    pnmtoplainpnm > "$SCRIPT_DIR/linux/drivers/video/logo/logo_diamond_clut224.ppm"
)

if [[ -f "$ROOTFS_BASE/$ROOTFS_PATH" ]]; then
  echo "Using existing rootfs cpio: \"$ROOTFS_PATH\""
  cp "$ROOTFS_BASE/$ROOTFS_PATH" "$NEW_ROOTFS"
else
  true | cpio -ov -H newc -O "$NEW_ROOTFS"

  # Pack the rootfs cpio
  #
  # Unpack with the following command in destination directory:
  # sudo cpio -H newc -ivdm --no-absolute-filenames -I "file_path.cpio"
  echo -n "$ROOTFS_PATH:" | tr ':' '\n' | while read rootfs_item; do

    [[ ! -n "$rootfs_item" ]] && continue   # skip empty entries
    rootfs_item="$(realpath "$ROOTFS_BASE/$rootfs_item")"
    if [[ ! "$rootfs_item" == *".cpio" ]]; then
      (
        cd "$rootfs_item" || exit 1
        FOLDERS=""

        if [[ -f "./folders.txt" ]]; then
          FOLDERS="$(cat ./folders.txt)"

          cat ./folders.txt | while read folder; do
            if [[ -n "$folder" ]]; then
              mkdir -p "$folder" || exit 0
            fi
          done

          rm ./folders.txt
        fi
        
        echo "Packing \"$rootfs_item\" into \"$NEW_ROOTFS\"..."
        fakeroot bash -c "find . -print0 | LC_ALL=C sort -z | cpio -o0 -H newc -AO \"$NEW_ROOTFS\" || exit 1"
        if [[ -n "$FOLDERS" ]]; then
          echo "$FOLDERS" > ./folders.txt
        fi
      )
    else
      rootfs_temp="$(mktemp -dp "$BUILD_TEMP")"
      echo "Packing \"$rootfs_item\" into \"$NEW_ROOTFS\"..."
      (
        cd "$rootfs_temp" || exit 1
        fakeroot bash -c "cpio -H newc -idm --no-absolute-filenames -I \"$rootfs_item\" && find . -print0 | LC_ALL=C sort -z | cpio -o0 -H newc -AO \"$NEW_ROOTFS\" || exit 1"
      )
    fi
  done

  (
    rootfs_temp="$(mktemp -dp "$BUILD_TEMP")"
    echo "Repacking \"$NEW_ROOTFS\" to ensure proper ordering..."
    cd "$rootfs_temp" || exit 1
    fakeroot bash -c "pwd && cpio -H newc -id --no-absolute-filenames -uI \"$NEW_ROOTFS\" && find . -print0 | LC_ALL=C sort -z | cpio -ov0 -H newc -O \"$NEW_ROOTFS\" || exit 1"
  )
fi

ROOTFS_PATH="$NEW_ROOTFS"

# Build the kernel
(
  cd "$SCRIPT_DIR/linux" || exit 1
  make ARCH=arm "CROSS_COMPILE=$TOOLCHAIN_CROSS-" -j"$(nproc)" distclean || exit 1
  cp "$DEF_CONFIG" ".config"
  echo "CONFIG_INITRAMFS_SOURCE=\"\"" >> .config
  echo "CONFIG_RD_GZIP=y" >> .config
  echo "CONFIG_INITRAMFS_ROOT_UID=0" >> .config
  echo "CONFIG_INITRAMFS_ROOT_GID=0" >> .config
  echo "CONFIG_INITRAMFS_COMPRESSION_NONE=y" >> .config
  echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=n" >> .config
  echo "CONFIG_INITRAMFS_COMPRESSION_BZIP2=n" >> .config
  echo "CONFIG_INITRAMFS_COMPRESSION_LZMA=n" >> .config
  echo "CONFIG_INITRAMFS_COMPRESSION_LZO=n" >> .config

  make ARCH=arm "CROSS_COMPILE=$TOOLCHAIN_CROSS-" "INSTALL_MOD_PATH=$BUILD_KMOD" -j"$(nproc)" all modules_install || exit 1
  KVER="$(ls -1 "$BUILD_KMOD/lib/modules/")"

  rm "$BUILD_KMOD/lib/modules/$KVER/build" "$BUILD_KMOD/lib/modules/$KVER/source"
  
  (
    cd "$BUILD_KMOD" || exit 1
    fakeroot bash -c "find . -print0 | LC_ALL=C sort -z | cpio -ov0 -H newc -AO \"$ROOTFS_PATH\" || exit 1"
  )
  
  gzip -kf9 "$ROOTFS_PATH"
  mkimage -A arm -O linux -T multi -C none \
    -a 0x80008000 -e 0x80008000 \
    -n "Linux+initramfs" \
    -d "$SCRIPT_DIR/linux/arch/arm/boot/zImage:$ROOTFS_PATH.gz" \
    "$SCRIPT_DIR/linux/arch/arm/boot/uImage"
)
