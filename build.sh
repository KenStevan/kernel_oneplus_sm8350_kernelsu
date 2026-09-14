#!/bin/sh

SUSFS=false
WIREGUARD=false
SCOPED_HOOK=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --with-susfs)
      SUSFS=true
      shift # past argument
      ;;
    --scoped-hook)
      SCOPED_HOOK=true
      shift # past argument
      ;;
    --wireguard)
      WIREGUARD=true
      shift # past argument
      ;;
  esac
done

BASE_PATH=$(pwd)
export KBUILD_BUILD_HOST=Stevans-MacBookPro
export KBUILD_BUILD_USER=Stevan
export ARCH=arm64
echo ">${BASE_PATH}"

# system
echo ">install tools"
sudo apt update -y 
sudo apt install -y elfutils libarchive-tools

#libufdt
echo ">clone libufdt"
git clone --branch android14-qpr2-release --depth 1 "https://android.googlesource.com/platform/system/libufdt.git" libufdt 

#AnyKernel3
echo ">clone AnyKernel3"
git clone --depth 1 https://github.com/osm0sis/AnyKernel3  AnyKernel3

# toolchain
echo ">download toolchain"
mkdir toolchain
cd toolchain
curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
chmod +x ./antman
./antman -S
./antman --patch=glibc
cd $BASE_PATH

#kernel
echo ">clone kernel source"
# 锁定与 ROM (PixelOS_lemonade-15.0-20250208) 完全相同的内核 commit, HEAD 已与旧 ROM 不配套
git init -q kernel
cd kernel
git remote add origin https://github.com/PixelOS-Lemonade/kernel_oneplus_sm8350
git fetch --depth 1 origin 07863b33c6b8c70a922fa2c9ed41b9009789bc01
git checkout -q FETCH_HEAD
cd $BASE_PATH

#Scoped Hook
if [[ $SCOPED_HOOK == "true" ]]; then
  echo ">download scoped hook patchset and patch the kernel"
  curl -LO "https://github.com/dev-sm8350/kernel_oneplus_sm8350/commit/583337f3cbfad72ad3a4109953b45a067bccd5be.patch"
  cd kernel
  git apply ../583337f3cbfad72ad3a4109953b45a067bccd5be.patch
  cd $BASE_PATH
fi

#KernelSU
echo ">clone KernelSU and patch the kernel"
cd kernel
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s v4.2.0
git apply ../0001-backport-path-umount.patch
git apply ../0002-backport-strncpy-from-user-nofault.patch
git apply ../0003-no-dirty-flag.patch
echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
echo "CONFIG_KPM=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
# 新版 Neutron clang 与 5.4 老内核的 CFI/LTO/SCS 加固不兼容 (CFI 类型哈希布局变化会导致无法启动), 全部关闭
echo "# CONFIG_LTO_CLANG is not set" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
echo "# CONFIG_CFI_CLANG is not set" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
echo "# CONFIG_SHADOW_CALL_STACK is not set" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
# 5.4 内核没有 linux/pgtable.h (5.8 才引入), 加兼容垫片给 SukiSU sucompat.c 用
echo '#include <asm/pgtable.h>' > include/linux/pgtable.h
# 5.4 里 copy_to_kernel_nofault 叫 probe_kernel_write (5.8 改名, 签名相同)
sed -i 's/copy_to_kernel_nofault/probe_kernel_write/g' KernelSU/kernel/hook/arm64/patch_memory.c KernelSU/kernel/hook/x86_64/patch_memory.c
# 5.4 没有 SECCOMP_ARCH_NATIVE_NR (新版 seccomp 动作缓存引入), arm64 上它等于 NR_syscalls
sed -i 's|#include "infra/seccomp_cache.h"|#include "infra/seccomp_cache.h"\n#include <asm/unistd.h>\n#ifndef SECCOMP_ARCH_NATIVE_NR\n#define SECCOMP_ARCH_NATIVE_NR NR_syscalls\n#endif|' KernelSU/kernel/infra/seccomp_cache.c
# 5.4: TWA_RESUME 是 5.9 的枚举, 老内核第三个参数是布尔; put_task_struct 需要 sched/task.h
sed -i 's/task_work_add(tsk, cb, TWA_RESUME)/task_work_add(tsk, cb, true)/' KernelSU/kernel/policy/allowlist.c
sed -i 's|#include <linux/task_work.h>|#include <linux/task_work.h>\n#include <linux/sched/task.h>|' KernelSU/kernel/policy/allowlist.c
# 全局替换其余 TWA_RESUME (supercall.c 等)
grep -rl TWA_RESUME KernelSU/kernel | xargs -r sed -i 's/TWA_RESUME/true/g'
# 5.4 没有 include/linux/minmax.h (min/max/clamp 宏在 kernel.h 里)
echo '#include <linux/kernel.h>' > include/linux/minmax.h
# SukiSU 的 selinux 层需要 5.7+ 内核结构。混合方案:
#   selinux.c/selinux.h 保留 SukiSU 版 (0错误, 提供 ksu_file_sid/setup_ksu_cred 等)
#   rules.c/sepolicy.c/sepolicy.h 用 rsuntk legacy 版 (全版本兼容实现)
cp "$BASE_PATH/rksu_selinux/selinux.c" KernelSU/kernel/selinux/selinux.c
cp "$BASE_PATH/rksu_selinux/selinux.h" KernelSU/kernel/selinux/selinux.h
cp "$BASE_PATH/rksu_selinux/rules.c" KernelSU/kernel/selinux/rules.c
cp "$BASE_PATH/rksu_selinux/sepolicy.c" KernelSU/kernel/selinux/sepolicy.c
cp "$BASE_PATH/rksu_selinux/sepolicy.h" KernelSU/kernel/selinux/sepolicy.h
# selinux_hide 依赖 5.7+ selinux_state 内部成员, 用空操作存根替代
cp "$BASE_PATH/selinux_hide_stub.c" KernelSU/kernel/feature/selinux_hide.c
# rsuntk 代码需要的兼容探测宏追加到 Kbuild
cat >> KernelSU/kernel/Kbuild <<'KBEOF'

# 5.4 compat detection for rsuntk selinux implementation
ifeq ($(shell grep -q " current_sid(void)" $(srctree)/security/selinux/include/objsec.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_CURRENT_SID
endif
ifeq ($(shell grep -q "struct selinux_state " $(srctree)/security/selinux/include/security.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_SELINUX_STATE
endif
ifeq ($(shell grep -q "security_inode_init_security_anon" $(srctree)/include/linux/security.h; echo $$?),0)
ccflags-y += -DKSU_COMPAT_HAS_ANON_SEC
endif
KBEOF
python3 - <<'PYEOF'
import re

def patch(path, old, new, must=True):
    s = open(path).read()
    if old not in s:
        if must:
            raise SystemExit('pattern not found in ' + path)
        return
    open(path, 'w').write(s.replace(old, new))

# 5.4: cpu_spoof 的 vdso_clock_mode 在 arm64 5.4 里是 archdata.clock_mode
patch('KernelSU/kernel/feature/cpu_spoof.c', '->vdso_clock_mode', '->archdata.clock_mode')

# 5.4: seccomp.filter_count 是 5.9+ 才有的成员, 用版本开关包起来
patch('KernelSU/kernel/policy/app_profile.c',
      '    atomic_set(&current->seccomp.filter_count, 0);',
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'
      '    atomic_set(&current->seccomp.filter_count, 0);\n'
      '#endif')

# 5.4: copy_from/to_user_nofault 是 5.8 改名, 老名字是 probe_kernel_read/write
s = open('KernelSU/kernel/runtime/ksud_integration.c').read()
s = s.replace('copy_from_user_nofault', 'probe_kernel_read')
s = s.replace('copy_to_user_nofault', 'probe_kernel_write')
open('KernelSU/kernel/runtime/ksud_integration.c', 'w').write(s)

# rsuntk legacy 文件适配 SukiSU 目录结构
for f in ('KernelSU/kernel/selinux/rules.c', 'KernelSU/kernel/selinux/sepolicy.c'):
    s = open(f).read()
    s = s.replace('#include "../klog.h"', '#include "klog.h"')
    open(f, 'w').write(s)
# avc_ss_reset 两参数版声明在 avc_ss.h, rules.c 没包含它
s = open('KernelSU/kernel/selinux/rules.c').read()
s = s.replace('#include "ss/services.h"', '#include "ss/services.h"\n#include "avc_ss.h"')
open('KernelSU/kernel/selinux/rules.c', 'w').write(s)
# kernel_compat.h 的 nofault 快速路径在 5.4 不存在, 直接走安全慢路径
s = open('KernelSU/kernel/kernel_compat.h').read()
s = s.replace('long ret = copy_from_user_nofault(to, from, count);',
              'long ret = 1; /* 5.4: no nofault api, straight to safe path */')
open('KernelSU/kernel/kernel_compat.h', 'w').write(s)
# handle_sepolicy 参数顺序: rsuntk 定义是 (arg3 未用, arg4 用户指针), 修 SukiSU 调用方
s = open('KernelSU/kernel/supercall/dispatch.c').read()
s = s.replace('handle_sepolicy((void __user *)cmd.data, cmd.data_len)',
              'handle_sepolicy((unsigned long)cmd.data_len, (void __user *)cmd.data)')
open('KernelSU/kernel/supercall/dispatch.c', 'w').write(s)

# 5.4: seccomp_filter_release 是 5.9+ 名字, 5.4 叫 put_seccomp_filter (参数相同)
s = open('KernelSU/kernel/policy/app_profile.c').read()
s = s.replace('seccomp_filter_release', 'put_seccomp_filter')
open('KernelSU/kernel/policy/app_profile.c', 'w').write(s)

# 5.4: path_mount 是 5.10 才从 do_change_type 改名导出的, 给内核补一个转发包装
ns = open('fs/namespace.c').read()
if 'int path_mount(' not in ns:
    ns += '''
// KSU 5.4 compat: expose do_change_type as path_mount (propagation-only usage)
int path_mount(const char *dev_name, struct path *path, const char *type_page,
	       unsigned long flags, void *data_page)
{
	return do_change_type(path, flags);
}
'''
    open('fs/namespace.c', 'w').write(ns)

# ROM 内核 commit 07863b33 提交时带了一处语法错误 (ROM 实际是 dirty 编译的), 修掉
s = open('fs/userfaultfd.c').read()
s = s.replace('vma_pad_fixup_flags(vma, new_flags););',
              'vma_pad_fixup_flags(vma, new_flags));')
open('fs/userfaultfd.c', 'w').write(s)

# 老内核缺 security_inode_init_security_anon (file_wrapper.c 用到), 用宏开关降级
s = open('KernelSU/kernel/infra/file_wrapper.c').read()
old = '''    inode->i_flags &= ~S_PRIVATE;
    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }'''
new = '''#ifdef KSU_COMPAT_HAS_ANON_SEC
    inode->i_flags &= ~S_PRIVATE;
    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }
#else
    (void)qname;
    (void)context_inode;
    (void)error;
#endif'''
assert old in s, 'anon sec block not found'
open('KernelSU/kernel/infra/file_wrapper.c', 'w').write(s.replace(old, new))
PYEOF
# dispatch.c 补 tasklist_lock/init_task/task_pgrp/task_session 所需头文件
sed -i 's|#include <linux/version.h>|#include <linux/version.h>\n#include <linux/sched/signal.h>\n#include <linux/sched/task.h>|' KernelSU/kernel/supercall/dispatch.c
python3 - <<'PYEOF'
p = 'KernelSU/kernel/manager/pkg_observer.c'
s = open(p).read()
old = '''static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};'''
new = '''#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};
#else
static int ksu_handle_event_legacy(struct fsnotify_group *group, struct inode *inode, u32 mask, const void *data, int data_type, const struct qstr *file_name, u32 cookie, struct fsnotify_iter_info *iter_info)
{
    return ksu_handle_inode_event(NULL, mask, inode, NULL, file_name, cookie);
}
static const struct fsnotify_ops ksu_ops = {
    .handle_event = ksu_handle_event_legacy,
};
#endif'''
assert old in s, 'pattern not found in pkg_observer.c'
open(p, 'w').write(s.replace(old, new))
PYEOF
cd $BASE_PATH

#SUSFS
if [[ $SUSFS == "true" ]]; then
  echo ">clone SUSFS and patch the kernel"
  git clone --branch kernel-5.4 --depth 1 https://gitlab.com/simonpunk/susfs4ksu susfs

  # Original patch does not fit lemonade kernel. We include additonal patches
  # to patch the patch files fiest
  cd susfs
  patch -p1 < ../0004-patch_enable_susfs_for_ksu.patch
  patch -p1 < ../0005-patch_add_susfs_in_kernel-5.4.patch
  cd $BASE_PATH

  # Include susfs. Copied from https://gitlab.com/simonpunk/susfs4ksu/-/blob/kernel-5.4/README.md
  cp susfs/kernel_patches/fs/* kernel/fs/
  cp susfs/kernel_patches/include/linux/* kernel/include/linux/
  cd kernel/KernelSU
  patch -p1 < ../../susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch
  cd ../
  patch -p1 < ../susfs/kernel_patches/50_add_susfs_in_kernel-5.4.patch
  echo "CONFIG_KSU=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  echo "CONFIG_KSU_SUSFS_SUS_SU=n" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  cd $BASE_PATH
fi

#WireGuard
if [[ $WIREGUARD == "true" ]]; then
  echo ">clone WireGuard and patch the kernel"
  git clone --branch v1.0.20220627 --depth 1 https://git.zx2c4.com/wireguard-linux-compat wireguard
  mv wireguard/src kernel/net/wireguard
  cd kernel
  sed -i '94i source "net/wireguard/Kconfig"' net/Kconfig
  sed -i '18i obj-$(CONFIG_WIREGUARD)		+= wireguard/' net/Makefile
  echo "CONFIG_WIREGUARD=y" >> arch/arm64/configs/vendor/lahaina-qgki_defconfig
  cd $BASE_PATH
fi

#build
echo ">build kernel"
cd kernel
export PATH="$BASE_PATH/toolchain/bin:${PATH}"
MAKE_ARGS="CC=clang O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 CFLAGS=-Wno-enum-compare"
make $MAKE_ARGS "vendor/lahaina-qgki_defconfig"
make $MAKE_ARGS -k -j"$(nproc --all)"
cd $BASE_PATH
cp kernel/out/arch/arm64/boot/Image AnyKernel3/

#create dtb
echo ">create dtb and dtbo.img"
cat $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtb" | sort) > AnyKernel3/dtb
python libufdt/utils/src/mkdtboimg.py create AnyKernel3/dtbo.img --page_size=4096 $(find kernel/out/arch/arm64/boot/dts/vendor/oplus/lemonadev/ -type f -name "*.dtbo" | sort)

#clean AnyKernel3
echo ">clean AnyKernel3"
rm -rf AnyKernel3/.git* AnyKernel3/README.md
echo "lineageOS oneplus sm8350 kernel with KernelSU" > AnyKernel3/README.md
sed -i 's/do.devicecheck=1/do.devicecheck=0/g' AnyKernel3/anykernel.sh
sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' AnyKernel3/anykernel.sh
sed -i 's/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' AnyKernel3/anykernel.sh
