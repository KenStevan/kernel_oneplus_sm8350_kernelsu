// SPDX-License-Identifier: GPL-2.0
// 5.4 兼容存根: 原 SukiSU selinux_hide 实现依赖 5.7+ 的 selinux_state
// 内部成员 (status_page/status_lock/policy), 在 5.4 上以空操作代替。
#include <linux/version.h>
#include "selinux_hide.h"

void ksu_selinux_hide_init() {}
void ksu_selinux_hide_exit() {}
void ksu_selinux_hide_drop_backup_if_unused() {}
void ksu_selinux_hide_handle_second_stage() {}
void ksu_selinux_hide_handle_post_fs_data() {}
