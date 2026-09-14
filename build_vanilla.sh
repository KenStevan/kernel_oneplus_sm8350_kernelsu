#!/bin/sh

BASE_PATH=$(pwd)
export KBUILD_BUILD_HOST=Stevans-MacBookPro
export KBUILD_BUILD_USER=Stevan
export ARCH=arm64
echo ">${BASE_PATH}"

echo ">install tools"
sudo apt update -y 
sudo apt install -y elfutils libarchive-tools

echo ">clone libufdt"
git clone --branch android14-qpr2-release --depth 1 "https://android.googlesource.com/platform/system/libufdt.git" libufdt 

echo ">clone AnyKernel3"
git clone --depth 1 https://github.com/osm0sis/AnyKernel3  AnyKernel3

echo ">download toolchain"
mkdir toolchain
cd toolchain
curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
chmod +x ./antman
./antman -S
./antman --patch=glibc
cd $BASE_PATH

echo ">clone kernel source"
git init -q kernel
cd kernel
git remote add origin https://github.com/PixelOS-Lemonade/kernel_oneplus_sm8350
git fetch --depth 1 origin 07863b33c6b8c70a922fa2c9ed41b9009789bc01
git checkout -q FETCH_HEAD
cd $BASE_PATH

# ROM commit 自带语法错误修复
python3 - <<'PYEOF'
s = open('fs/userfaultfd.c').read()
s = s.replace('vma_pad_fixup_flags(vma, new_flags););', 'vma_pad_fixup_flags(vma, new_flags));')
open('fs/userfaultfd.c', 'w').write(s)
PYEOF

echo ">build kernel"
cd kernel
export PATH="$BASE_PATH/toolchain/bin:${PATH}"
MAKE_ARGS="CC=clang O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CFLAGS=-Wno-enum-compare"
make $MAKE_ARGS "vendor/lahaina-qgki_defconfig"
make $MAKE_ARGS -j"$(nproc --all)"
cd $BASE_PATH
cp kernel/out/arch/arm64/boot/Image AnyKernel3/

echo ">create dtb and dtbo.img"
cat $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtb" | sort) > AnyKernel3/dtb
python libufdt/utils/src/mkdtboimg.py create AnyKernel3/dtbo.img --page_size=4096 $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtbo" | sort)

echo ">clean AnyKernel3"
rm -rf AnyKernel3/.git* AnyKernel3/README.md
echo "vanilla oneplus sm8350 kernel by Stevan" > AnyKernel3/README.md
sed -i 's/do.devicecheck=1/do.devicecheck=0/g' AnyKernel3/anykernel.sh
sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' AnyKernel3/anykernel.sh
sed -i 's/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' AnyKernel3/anykernel.sh
