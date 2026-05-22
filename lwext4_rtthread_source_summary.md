# lwext4 RT-Thread 移植源码总结

## 1. 项目概述

本仓库是 **RT-Thread 下的 EXT4 文件系统实现**，基于 lwext4 移植，用于在 RT-Thread 系统上支持 ext2/ext3/ext4 文件系统。

`README.md` 明确说明：

- 这是 RT-Thread 下的 EXT4 文件系统实现；
- 基于 lwext4；
- lwext4 是面向 MCU 的 ext2/3/4 文件系统实现；
- 大多数代码源自 HelenOS，原许可协议为 BSD；
- `ext4_xattr.c` 和 README 中写到的 `ext4_extents.c` 为 GPLv2 许可代码。

> 源码核对说明：当前本地仓库远端为 `git@github.com:wpmoyi/lwext4.git`。实际查询到远端存在 `main` 分支，提交为 `5b5e5d191d1af65964ad23e36cbb4498667ee5cd`；未查询到远端 `master` 分支。本文基于当前检出的实际源码。

### 1.1 与上游 lwext4 的主要差异

根据 `README.md` 的“移植到 RT-Thread 的修改”：

1. **分区表相关功能未启用**
   - README 写明：`lwext4中的分区表相关功能都未启用`。
   - 源码中保留 `src/ext4_mbr.c`、`include/ext4_mbr.h`，但 `SConscript` 没有把 `src/ext4_mbr.c` 加入 RT-Thread 构建。

2. **lwext4 原块设备功能改由 `dfs_ext_blockdev` 实现**
   - README 写明：`lwext4中本身的块设备功能移除，都由dfs_ext_blockdev来实现`。
   - 实际适配文件是 `ports/rtthread/dfs_ext_blockdev.c` 和 `ports/rtthread/dfs_ext_blockdev.h`，负责把 RT-Thread `rt_device_t` 包装为 lwext4 的 `struct ext4_blockdev`。

3. **`mkfs` 不涉及分区表操作**
   - README 写明：`mkfs格式化文件系统都不会涉及到分区表的操作`。
   - `ports/rtthread/dfs_ext.c` 中 `dfs_ext_mkfs()` 直接创建 `dfs_ext4_blockdev` 并调用 `ext4_mkfs(&fs, bd, &info, F_SET_EXT4)`，没有调用 `ext4_mbr_scan()` 或 `ext4_mbr_write()`。

4. **增加 RT-Thread DFS 适配层**
   - `ports/rtthread/dfs_ext.c` 将 lwext4 的挂载、卸载、格式化、文件、目录、link、symlink、stat、rename 等操作封装为 RT-Thread DFS 的 `struct dfs_filesystem_ops` 和 `struct dfs_file_ops`。

---

## 2. 目录结构与文件职责

### 2.1 顶层目录

| 路径 | 作用 |
|---|---|
| `src/` | lwext4 核心 C 源码，实现 ext2/3/4 挂载、超级块、块组、块缓存、inode、目录、extent、日志、mkfs、xattr 等。 |
| `include/` | lwext4 头文件，包括高层 API `ext4.h`、块设备接口 `ext4_blockdev.h`、各核心模块声明和磁盘结构定义。 |
| `ports/rtthread/` | RT-Thread 移植层，负责 DFS 文件系统接口和 `rt_device_t` 块设备适配。 |
| `blockdev/` | lwext4 原工程中的平台块设备示例/辅助实现，包括 Linux/Windows 文件块设备；RT-Thread `SConscript` 未使用。 |
| `fs_test/` | lwext4 测试程序，包括通用测试、mkfs、MBR、client/server 测试；RT-Thread `SConscript` 未使用。 |
| `toolchain/` | CMake 交叉编译工具链配置，服务于原 lwext4 CMake 构建体系。 |
| `SConscript` | RT-Thread 的 SCons 构建脚本，定义本组件参与 RT-Thread 编译的源码、头文件路径、宏和依赖条件。 |

### 2.2 `src/`

| 文件 | 职责 |
|---|---|
| `ext4.c` | 高层 API，实现挂载、卸载、文件/目录操作、link、rename、symlink、mknod、属性、xattr 高层入口等。 |
| `ext4_fs.c` | 文件系统核心对象管理，初始化/释放 fs、检查特性、块组引用、inode 引用、inode 分配释放、数据块映射、截断。 |
| `ext4_super.c` | 超级块读写、校验、块组数量计算、稀疏超级块判断、GDT 元数据计算。 |
| `ext4_block_group.c` | 块组描述符相关 CRC16 支持。 |
| `ext4_blockdev.c` | lwext4 块设备抽象，封装块设备 open/read/write/close、逻辑块大小、cache、直接字节读写。 |
| `ext4_bcache.c` | 块缓存管理，buffer 分配、查找、LRU、dirty 回写、失效。 |
| `ext4_balloc.c` | 数据块分配/释放，块位图和 checksum。 |
| `ext4_ialloc.c` | inode 分配/释放，inode 位图和 checksum。 |
| `ext4_bitmap.c` | 位图底层操作。 |
| `ext4_inode.c` | inode 字段访问、类型判断、flag 操作、extent header 获取。 |
| `ext4_dir.c` | 普通线性目录项操作：迭代、查找、添加、删除、checksum。 |
| `ext4_dir_idx.c` | HTree 目录索引：hash、初始化、查找、插入、分裂、checksum。 |
| `ext4_extent.c` | ext4 extent tree：查找、插入、删除、释放空间、逻辑块到物理块映射；文件头声明 GPLv2。 |
| `ext4_journal.c` | JBD 日志：journal superblock、transaction、revoke、recover、commit。 |
| `ext4_trans.c` | 事务封装层，将 block dirty、block get、revoke 等接入 journal transaction。 |
| `ext4_mkfs.c` | ext 文件系统格式化：计算布局、写超级块/块组、初始化位图和 inode table、创建根目录/journal inode。 |
| `ext4_mbr.c` | MBR 分区扫描/写入；RT-Thread `SConscript` 未纳入构建。 |
| `ext4_crc32.c` | CRC32/CRC32C。 |
| `ext4_hash.c` | ext2/ext4 HTree hash。 |
| `ext4_debug.c` | debug mask 设置、清除、读取。 |
| `ext4_xattr.c` | 扩展属性 xattr：list/get/set/remove、ibody/block 存储、hash/checksum；文件头声明 GPLv2。 |
| `ext4_mp.c` | mount point 相关支持，与 `include/ext4_mp.h` 配合。 |

### 2.3 `include/`

| 文件 | 职责 |
|---|---|
| `ext4.h` | 高层公开 API，定义 `ext4_file`、`ext4_dir`、挂载、文件、目录、xattr 等接口。 |
| `ext4_blockdev.h` | `struct ext4_blockdev_iface`、`struct ext4_blockdev` 和块设备 API。 |
| `ext4_fs.h` | 文件系统核心结构和内部 API。 |
| `ext4_types.h` | ext4 磁盘结构、类型、常量。 |
| `ext4_config.h` | 配置宏。 |
| `ext4_errno.h` | 错误码。 |
| `ext4_oflags.h` | open flags。 |
| `ext4_inode.h` | inode 字段访问和类型/flag 操作。 |
| `ext4_super.h` | 超级块访问、读写、校验相关声明。 |
| `ext4_block_group.h` | 块组描述符相关声明。 |
| `ext4_balloc.h` | 数据块分配接口。 |
| `ext4_ialloc.h` | inode 分配接口。 |
| `ext4_dir.h` | 目录项和目录迭代接口。 |
| `ext4_dir_idx.h` | HTree 目录索引接口。 |
| `ext4_extent.h` | extent 接口。 |
| `ext4_journal.h` | JBD journal 接口和结构。 |
| `ext4_trans.h` | transaction 封装接口。 |
| `ext4_mkfs.h` | `struct ext4_mkfs_info` 和 `ext4_mkfs()`。 |
| `ext4_xattr.h` | xattr 底层接口。 |
| `ext4_mbr.h` | MBR 分区相关接口。 |
| `ext4_bcache.h` | 块缓存结构和接口。 |
| `ext4_bitmap.h` | 位图接口。 |
| `ext4_crc32.h` | CRC32/CRC32C 接口。 |
| `ext4_hash.h` | HTree hash 接口。 |
| `ext4_mp.h` | mount point 相关结构/宏。 |
| `ext4_misc.h` | 杂项工具宏和函数。 |
| `ext4_debug.h` | debug 接口。 |

### 2.4 `ports/rtthread/`

实际包含：

| 文件 | 作用 |
|---|---|
| `dfs_ext.c` | RT-Thread DFS 文件系统适配层，注册名为 `"ext"` 的文件系统。 |
| `dfs_ext.h` | 声明 `int dfs_ext_init(void);`。 |
| `dfs_ext_blockdev.c` | RT-Thread 块设备适配层，把 `rt_device_t` 适配为 lwext4 `struct ext4_blockdev`。 |
| `dfs_ext_blockdev.h` | 定义 `struct dfs_ext4_blockdev` 和创建/销毁/转换接口。 |

`dfs_ext.c` 中核心私有结构：

```c
struct dfs_ext4_vnode
{
    struct ext4_mountpoint *mp;
    struct ext4_inode_ref inode_ref;
};

struct dfs_ext4_file
{
    uint32_t type;  /* EXT4_DE_DIR or EXT4_DE_REG_FILE */
    union
    {
        ext4_file file;
        ext4_dir dir;
    } entry;
    struct dfs_ext4_vnode vnode;
};
```

`dfs_ext_blockdev.h` 中 RT-Thread 适配块设备结构：

```c
struct dfs_ext4_blockdev 
{
    rt_device_t devid;
    struct ext4_blockdev bd;
    uint8_t ph_bbuf[4096];
    void *data;
};
```

### 2.5 `blockdev/`

| 路径 | 作用 |
|---|---|
| `blockdev/blockdev.c` / `blockdev/blockdev.h` | 原 lwext4 通用块设备辅助代码。 |
| `blockdev/linux/file_dev.c` / `.h` | Linux 文件块设备实现。 |
| `blockdev/windows/file_windows.c` / `.h` | Windows 文件块设备实现。 |
| `blockdev/CMakeLists.txt` | CMake 构建配置。 |

RT-Thread 构建不使用该目录。

### 2.6 `fs_test/`

| 文件 | 作用 |
|---|---|
| `lwext4_generic.c` | 通用测试入口。 |
| `lwext4_mkfs.c` | mkfs 测试。 |
| `lwext4_mbr.c` | MBR 测试。 |
| `lwext4_client.c` / `lwext4_server.c` | client/server 测试。 |
| `common/test_lwext4.c` / `.h` | 公共测试逻辑。 |

RT-Thread 构建不使用该目录。

### 2.7 `toolchain/`

包含 `cortex-m0.cmake`、`cortex-m3.cmake`、`cortex-m4.cmake`、`cortex-m4f.cmake`、`cortex-m7.cmake`、`msp430.cmake`、`mingw.cmake`、`generic.cmake` 以及 `common/` 下的编译器公共配置。这些文件服务于 CMake 构建，不是 RT-Thread SCons 构建入口。

---

## 3. SConscript 文件作用

`SConscript` 是 RT-Thread 的 SCons 构建脚本。

核心内容：

```python
objs = Split('''
src/ext4.c
src/ext4_balloc.c
src/ext4_bcache.c
src/ext4_bitmap.c
src/ext4_blockdev.c
src/ext4_block_group.c
src/ext4_crc32.c
src/ext4_debug.c
src/ext4_dir.c
src/ext4_dir_idx.c
src/ext4_extent.c
src/ext4_fs.c
src/ext4_hash.c
src/ext4_ialloc.c
src/ext4_inode.c
src/ext4_journal.c
src/ext4_mkfs.c
src/ext4_mp.c
src/ext4_super.c
src/ext4_trans.c
src/ext4_xattr.c
ports/rtthread/dfs_ext.c
ports/rtthread/dfs_ext_blockdev.c
''')

CPPPATH = [cwd + '/include', cwd + '/ports/rtthread']
CPPDEFINES = ['CONFIG_USE_DEFAULT_CFG', 'CONFIG_HAVE_OWN_OFLAGS=0']

group = DefineGroup('Filesystem', objs,
            depend = ['RT_USING_DFS', 'RT_USING_DFS_LWEXT4'],
            CPPPATH = CPPPATH,
            CPPDEFINES = CPPDEFINES,
            LOCAL_CCFLAGS = LOCAL_CCFLAGS)
```

作用：

- 将 lwext4 核心源码和 RT-Thread 适配源码加入 `Filesystem` 构建组；
- 添加头文件路径 `include` 和 `ports/rtthread`；
- 定义 `CONFIG_USE_DEFAULT_CFG`、`CONFIG_HAVE_OWN_OFLAGS=0`；
- 仅在启用 `RT_USING_DFS` 和 `RT_USING_DFS_LWEXT4` 时参与构建；
- 未加入 `src/ext4_mbr.c`，与“分区表功能未启用”一致。

---

## 4. 核心模块详解（按文件系统层次）

### 4.1 挂载管理

#### `src/ext4.c`

关键函数：

| 函数 | 作用 |
|---|---|
| `ext4_mount()` | 挂载 blockdev 到 mount point。 |
| `ext4_umount_mp()` | 按 `struct ext4_mountpoint *` 卸载。 |
| `ext4_umount()` | 按挂载路径卸载。 |
| `ext4_mount_setup_locks()` | 设置 OS lock 回调，RT-Thread 中绑定到 `rt_mutex`。 |
| `ext4_get_sblock()` | 获取超级块指针。 |
| `ext4_mount_point_stats()` | 获取挂载点统计信息。 |
| `ext4_cache_write_back()` | 开启/关闭 write-back cache。 |
| `ext4_cache_flush()` | flush cache。 |

`ext4_mount()` 的核心流程：

```c
int ext4_mount(struct ext4_blockdev *bd, const char *mount_point,
           bool read_only)
{
    int r;
    struct ext4_mountpoint *mp = 0;

    ext4_assert(mount_point && bd);

    /* 查找空闲 mountpoint 槽位 */
    r = ext4_block_init(bd);
    if (r != EOK)
        return r;

    r = ext4_fs_init(&mp->fs, bd, read_only);
    if (r != EOK) {
        ext4_block_fini(bd);
        return r;
    }

    /* 初始化并绑定 block cache，设置 mounted 状态 */
}
```

### 4.2 超级块

#### `src/ext4_super.c`

| 函数 | 作用 |
|---|---|
| `ext4_sb_read()` | 读取超级块。 |
| `ext4_sb_write()` | 写回超级块。 |
| `ext4_sb_check()` | 检查超级块合法性。 |
| `ext4_block_group_cnt()` | 计算块组数量。 |
| `ext4_blocks_in_group_cnt()` | 计算指定块组 blocks 数。 |
| `ext4_inodes_in_group_cnt()` | 计算指定块组 inodes 数。 |
| `ext4_sb_sparse()` | 判断 sparse superblock。 |
| `ext4_sb_is_super_in_bg()` | 判断块组是否包含超级块备份。 |
| `ext4_bg_num_gdb()` | 计算 GDT block 数。 |
| `ext4_num_base_meta_clusters()` | 计算基础元数据 cluster 数。 |

### 4.3 块组

#### `src/ext4_block_group.c`

| 函数 | 作用 |
|---|---|
| `ext4_bg_crc16()` | 计算块组相关 CRC16。 |

#### `src/ext4_fs.c`

| 函数 | 作用 |
|---|---|
| `ext4_fs_get_block_group_ref()` | 获取块组描述符引用。 |
| `ext4_fs_put_block_group_ref()` | 释放块组描述符引用。 |
| `ext4_fs_init_block_bitmap()` | 初始化 block bitmap。 |
| `ext4_fs_init_inode_bitmap()` | 初始化 inode bitmap。 |
| `ext4_fs_init_inode_table()` | 初始化 inode table。 |

### 4.4 块设备与块缓存

#### `src/ext4_blockdev.c`

| 函数 | 作用 |
|---|---|
| `ext4_block_init()` | 初始化并打开块设备。 |
| `ext4_block_fini()` | 关闭块设备。 |
| `ext4_block_bind_bcache()` | 绑定 block cache。 |
| `ext4_block_set_lb_size()` | 设置逻辑块大小。 |
| `ext4_block_get()` | 经缓存读取块。 |
| `ext4_block_get_noread()` | 分配缓存块但不读盘。 |
| `ext4_block_set()` | 释放/标脏缓存块。 |
| `ext4_blocks_get_direct()` | 直接读块。 |
| `ext4_blocks_set_direct()` | 直接写块。 |
| `ext4_block_readbytes()` | 按字节读。 |
| `ext4_block_writebytes()` | 按字节写。 |
| `ext4_block_cache_flush()` | flush block cache。 |
| `ext4_block_cache_write_back()` | 控制 write-back。 |

#### `src/ext4_bcache.c`

| 函数 | 作用 |
|---|---|
| `ext4_bcache_init_dynamic()` | 动态初始化 block cache。 |
| `ext4_bcache_cleanup()` | 清理缓存。 |
| `ext4_bcache_fini_dynamic()` | 释放动态缓存资源。 |
| `ext4_buf_alloc()` | 分配 buffer。 |
| `ext4_buf_lookup()` | 按 LBA 查找 buffer。 |
| `ext4_buf_lowest_lru()` | 找到 LRU buffer。 |
| `ext4_bcache_drop_buf()` | 移除 buffer。 |
| `ext4_bcache_invalidate_lba()` | 使指定 LBA 缓存失效。 |
| `ext4_bcache_find_get()` | 查找并引用缓存块。 |
| `ext4_bcache_alloc()` | 分配缓存块。 |
| `ext4_bcache_free()` | 释放缓存块引用。 |

### 4.5 inode

#### `src/ext4_inode.c`

| 函数 | 作用 |
|---|---|
| `ext4_inode_get_mode()` / `ext4_inode_set_mode()` | 读写 mode。 |
| `ext4_inode_get_uid()` / `ext4_inode_set_uid()` | 读写 uid。 |
| `ext4_inode_get_gid()` / `ext4_inode_set_gid()` | 读写 gid。 |
| `ext4_inode_get_size()` / `ext4_inode_set_size()` | 读写文件大小。 |
| `ext4_inode_get_access_time()` / `ext4_inode_set_access_time()` | atime。 |
| `ext4_inode_get_modif_time()` / `ext4_inode_set_modif_time()` | mtime。 |
| `ext4_inode_get_change_inode_time()` / `ext4_inode_set_change_inode_time()` | ctime。 |
| `ext4_inode_get_links_cnt()` / `ext4_inode_set_links_cnt()` | link count。 |
| `ext4_inode_get_blocks_count()` / `ext4_inode_set_blocks_count()` | blocks count。 |
| `ext4_inode_get_flags()` / `ext4_inode_set_flags()` | inode flags。 |
| `ext4_inode_type()` | 获取 inode 类型。 |
| `ext4_inode_has_flag()` | 判断 flag。 |
| `ext4_inode_set_flag()` / `ext4_inode_clear_flag()` | 设置/清除 flag。 |
| `ext4_inode_can_truncate()` | 判断是否可截断。 |
| `ext4_inode_get_extent_header()` | 获取 extent header。 |

#### `src/ext4_ialloc.c`

| 函数 | 作用 |
|---|---|
| `ext4_ialloc_alloc_inode()` | 分配 inode。 |
| `ext4_ialloc_free_inode()` | 释放 inode。 |
| `ext4_ialloc_set_bitmap_csum()` | 设置 inode bitmap checksum。 |
| `ext4_ialloc_verify_bitmap_csum()` | 校验 inode bitmap checksum。 |

#### `src/ext4_fs.c`

| 函数 | 作用 |
|---|---|
| `ext4_fs_get_inode_ref()` | 获取 inode 引用。 |
| `ext4_fs_put_inode_ref()` | 释放 inode 引用并写回。 |
| `ext4_fs_alloc_inode()` | 分配并初始化 inode。 |
| `ext4_fs_free_inode()` | 释放 inode。 |
| `ext4_fs_truncate_inode()` | 截断 inode 数据。 |
| `ext4_fs_get_inode_dblk_idx()` | 查询 inode 逻辑块到物理块映射。 |
| `ext4_fs_init_inode_dblk_idx()` | 初始化/创建数据块映射。 |
| `ext4_fs_append_inode_dblk()` | 向 inode 追加数据块。 |
| `ext4_fs_inode_links_count_inc()` | 增加 link count。 |
| `ext4_fs_inode_links_count_dec()` | 减少 link count。 |

### 4.6 目录

#### `src/ext4_dir.c`

| 函数 | 作用 |
|---|---|
| `ext4_dir_iterator_init()` | 初始化目录迭代器。 |
| `ext4_dir_iterator_next()` | 下一个目录项。 |
| `ext4_dir_iterator_fini()` | 释放目录迭代器。 |
| `ext4_dir_write_entry()` | 写目录项。 |
| `ext4_dir_add_entry()` | 添加目录项。 |
| `ext4_dir_find_entry()` | 查找目录项。 |
| `ext4_dir_remove_entry()` | 删除目录项。 |
| `ext4_dir_try_insert_entry()` | 尝试插入 entry。 |
| `ext4_dir_find_in_block()` | 在目录块中查找。 |
| `ext4_dir_destroy_result()` | 释放查找结果。 |
| `ext4_dir_csum_verify()` | 校验目录块 checksum。 |
| `ext4_dir_set_csum()` | 设置目录块 checksum。 |

#### `src/ext4_dir_idx.c`

| 函数 | 作用 |
|---|---|
| `ext4_dir_dx_init()` | 初始化 indexed directory。 |
| `ext4_dir_dx_find_entry()` | 通过 HTree 查找目录项。 |
| `ext4_dir_dx_add_entry()` | 向 HTree 目录添加 entry。 |
| `ext4_dir_dx_split_index()` | 分裂索引节点。 |
| `ext4_dir_dx_split_data()` | 分裂数据块。 |
| `ext4_dir_dx_reset_parent_inode()` | 重置父 inode 相关信息。 |

### 4.7 日志与事务

#### `src/ext4_journal.c`

| 函数 | 作用 |
|---|---|
| `jbd_get_fs()` | 获取 journal fs 对象。 |
| `jbd_put_fs()` | 释放 journal fs 对象。 |
| `jbd_recover()` | journal recovery。 |
| `jbd_journal_start()` | 启动 journal。 |
| `jbd_journal_stop()` | 停止 journal。 |
| `jbd_journal_new_trans()` | 创建 transaction。 |
| `jbd_journal_commit_trans()` | 提交 transaction。 |
| `jbd_trans_set_block_dirty()` | 标记 transaction 中块为 dirty。 |
| `jbd_trans_revoke_block()` | revoke 指定块。 |
| `jbd_trans_try_revoke_block()` | 尝试 revoke 指定块。 |

#### `src/ext4_trans.c`

| 函数 | 作用 |
|---|---|
| `ext4_trans_set_block_dirty()` | 设置 block dirty。 |
| `ext4_trans_block_get_noread()` | transaction 语义下获取未读块。 |
| `ext4_trans_block_get()` | transaction 语义下读取块。 |
| `ext4_trans_try_revoke_block()` | transaction 语义下尝试 revoke block。 |

### 4.8 扩展属性

#### `src/ext4_xattr.c`（GPLv2）

文件头部声明 GPLv2。功能：

- xattr list/get/set/remove；
- inode body 内 xattr；
- 外部 xattr block；
- xattr block 分配/释放；
- xattr hash 和 checksum。

| 函数 | 作用 |
|---|---|
| `ext4_extract_xattr_name()` | 解析 xattr namespace prefix。 |
| `ext4_get_xattr_name_prefix()` | 根据 name index 获取 prefix。 |
| `ext4_xattr_list()` | 列举 inode xattr。 |
| `ext4_xattr_get()` | 获取 xattr。 |
| `ext4_xattr_set()` | 设置 xattr。 |
| `ext4_xattr_remove()` | 删除 xattr。 |

#### `src/ext4_extent.c`（GPLv2）

README 写作 `ext4_extents.c`，但当前仓库实际文件名是 `src/ext4_extent.c`，`SConscript` 也使用该文件。该文件头部声明 GPLv2。功能：

- extent tree 初始化；
- extent 查找、插入、删除；
- 释放逻辑块范围；
- 逻辑块到物理块映射；
- unwritten extent 处理；
- extent block checksum。

| 函数 | 作用 |
|---|---|
| `ext4_extent_tree_init()` | 初始化 inode extent tree。 |
| `ext4_ext_insert_extent()` | 插入 extent。 |
| `ext4_extent_remove_space()` | 删除指定逻辑块范围。 |
| `ext4_extent_get_blocks()` | 获取/创建逻辑块到物理块映射。 |

---

## 5. RT-Thread 移植分析

### 5.1 块设备适配到 `rt_device_t`

lwext4 块设备接口：

```c
struct ext4_blockdev_iface {
    int (*open)(struct ext4_blockdev *bdev);
    int (*bread)(struct ext4_blockdev *bdev, void *buf, uint64_t blk_id,
             uint32_t blk_cnt);
    int (*bwrite)(struct ext4_blockdev *bdev, const void *buf,
              uint64_t blk_id, uint32_t blk_cnt);
    int (*close)(struct ext4_blockdev *bdev);
    int (*lock)(struct ext4_blockdev *bdev);
    int (*unlock)(struct ext4_blockdev *bdev);
    uint32_t ph_bsize;
    uint64_t ph_bcnt;
    uint8_t *ph_bbuf;
};
```

RT-Thread 适配关系：

| lwext4 | RT-Thread |
|---|---|
| `open` | `rt_device_open(device, RT_DEVICE_OFLAG_RDWR)` |
| `bread` | `rt_device_read(device, blk_id, buf, blk_cnt)` |
| `bwrite` | `rt_device_write(device, blk_id, buf, blk_cnt)` |
| `close` | `rt_device_close(device)` |
| `lock` | `rt_mutex_take(bdevice_mutex, RT_WAITING_FOREVER)` |
| `unlock` | `rt_mutex_release(bdevice_mutex)` |
| 几何信息 | `rt_device_control(device, RT_DEVICE_CTRL_BLK_GETGEOME, &geometry)` |

`blockdev_open()` 中设置：

```c
bdev->part_offset = 0;
bdev->part_size = geometry.sector_count * geometry.bytes_per_sector;
bdev->bdif->ph_bsize = geometry.block_size;
bdev->bdif->ph_bcnt = bdev->part_size / bdev->bdif->ph_bsize;
```

`part_offset = 0` 表明该适配层直接使用整个 RT-Thread 块设备，不处理分区偏移。

### 5.2 DFS 文件系统操作封装

`dfs_ext.c` 中注册：

```c
static const struct dfs_filesystem_ops _extfs_ops =
{
    .name           = "ext",
    .flags          = FS_NEED_DEVICE,
    .default_fops   = &_extfs_fops,

    .mount  = dfs_ext_mount,
    .umount = dfs_ext_unmount,
    .mkfs   = dfs_ext_mkfs,
    .statfs = dfs_ext_statfs,

    .readlink   = dfs_ext_readlink,
    .link       = dfs_ext_link,
    .unlink     = dfs_ext_unlink,
    .symlink    = dfs_ext_symlink,
    .stat       = dfs_ext_stat,
    .setattr    = dfs_ext_setattr,
    .rename     = dfs_ext_rename,

    .lookup         = dfs_ext_lookup,
    .create_vnode   = dfs_ext_create_vnode,
    .free_vnode     = dfs_ext_free_vnode,
};
```

DFS 到 lwext4 的主要映射：

| DFS 操作 | lwext4 API |
|---|---|
| `mount` | `ext4_mount()` |
| `umount` | `ext4_umount_mp()` |
| `mkfs` | `ext4_mkfs()` |
| `statfs` | `ext4_get_sblock()`、`ext4_sb_get_*()` |
| `lookup` | `ext4_get_inode_ref()` |
| `create_vnode` | `ext4_dir_mk()`、`ext4_fopen2(..., O_CREAT)`、`ext4_mknod()` |
| `free_vnode` | `ext4_put_inode_ref()` |
| `readlink` | `ext4_readlink()` |
| `link` | `ext4_flink()` |
| `unlink` | `ext4_dir_rm()` 或 `ext4_fremove()` |
| `symlink` | `ext4_fsymlink()` |
| `stat` | inode getter |
| `setattr` | `ext4_mode_set()`、`ext4_atime_set()`、`ext4_mtime_set()`、`ext4_owner_set()` |
| `rename` | `ext4_frename()` |

文件操作封装：

```c
static const struct dfs_file_ops _extfs_fops =
{
    .open       = dfs_ext_open,
    .close      = dfs_ext_close,
    .ioctl      = dfs_ext_ioctl,
    .read       = dfs_ext_read,
    .write      = dfs_ext_write,
    .flush      = dfs_ext_flush,
    .lseek      = dfs_ext_lseek,
    .truncate   = dfs_ext_truncate,
    .getdents   = dfs_ext_getdents,
};
```

| DFS file op | lwext4 API |
|---|---|
| `open` | 目录：`ext4_dir_open()`；文件：`ext4_fopen2()` |
| `close` | 目录：`ext4_dir_close()`；文件：`ext4_fclose()` |
| `read` | `ext4_fread()` |
| `write` | `ext4_fwrite()` |
| `flush` | `ext4_cache_flush()` |
| `lseek` | 文件设置 `ext4_file.fpos`；目录 offset 为 0 时 `ext4_dir_entry_rewind()` |
| `truncate` | `ext4_ftruncate()` |
| `getdents` | `ext4_dir_entry_next()` |
| `ioctl` | `RT_FIOFTRUNCATE`、`F_GETLK`、`F_SETLK` |

### 5.3 mkfs 简化

`dfs_ext_mkfs()` 的实际流程：

```c
static int dfs_ext_mkfs(rt_device_t devid, const char *fs_name)
{
    static struct ext4_fs fs;
    static struct ext4_mkfs_info info =
    {
        .block_size = 4096,
        .journal = true,
    };

    dbd = dfs_ext4_blockdev_create(devid);
    bd = &dbd->bd;

    rt_device_open(devid, RT_DEVICE_OFLAG_RDWR);
    rc = ext4_mkfs(&fs, bd, &info, F_SET_EXT4);

    dfs_ext4_blockdev_destroy(dbd);
    rt_device_close(devid);

    return -rc;
}
```

特点：

- 直接格式化 `rt_device_t`；
- 默认 block size 为 4096；
- 默认启用 journal；
- 使用 `F_SET_EXT4`；
- 不扫描/写入分区表。

---

## 6. RT-Thread 环境挂载调用链路

完整链路：

```text
应用调用 mount(device, mount_path, "ext", rwflag, data)
        ↓
RT-Thread DFS 按 fs_name = "ext" 查找文件系统
        ↓
dfs_ext_init() 注册的 _extfs 被选中
        ↓
_extfs_ops.mount = dfs_ext_mount
        ↓
dfs_ext_mount(struct dfs_mnt *mnt, ...)
        ↓
dfs_ext4_blockdev_create(mnt->dev_id)
        ↓
dfs_ext4_blockdev_init()
        ↓
填充 ext4_blockdev_iface:
    open   = blockdev_open
    bread  = blockdev_read
    bwrite = blockdev_write
    close  = blockdev_close
    lock   = blockdev_lock
    unlock = blockdev_unlock
        ↓
ext4_mount(&dbd->bd, mnt->fullpath, false)
        ↓
ext4_block_init(bd)
        ↓
blockdev_open(bd)
        ↓
rt_device_open(device, RT_DEVICE_OFLAG_RDWR)
rt_device_control(device, RT_DEVICE_CTRL_BLK_GETGEOME, &geometry)
        ↓
ext4_fs_init(&mp->fs, bd, read_only)
        ↓
读取超级块、检查特性、初始化 fs
        ↓
初始化并绑定 block cache
        ↓
ext4_mount_setup_locks(mnt->fullpath, &ext4_lock_ops)
        ↓
mnt->data = dbd
        ↓
挂载完成
```

`dfs_ext_mount()` 关键代码：

```c
static int dfs_ext_mount(struct dfs_mnt *mnt, unsigned long rwflag, const void *data)
{
    struct dfs_ext4_blockdev *dbd = dfs_ext4_blockdev_create(mnt->dev_id);
    struct ext4_blockdev *bd = &dbd->bd;

    rc = ext4_mount(bd, mnt->fullpath, false);
    if (rc != EOK)
    {
        dfs_ext4_blockdev_destroy(dbd);
        rc = -rc;
    }
    else
    {
        ext4_mount_setup_locks(mnt->fullpath, &ext4_lock_ops);
        dbd->data = bd->journal;
        bd->journal = 0;
        mnt->data = (void *)dbd;
    }

    return rc;
}
```

---

## 7. 外部接口总结

### 7.1 文件系统管理

| API | 作用 |
|---|---|
| `ext4_mount()` | 挂载。 |
| `ext4_umount_mp()` | 按 mountpoint 指针卸载。 |
| `ext4_umount()` | 按路径卸载。 |
| `ext4_journal_start()` | 启动 journaling。 |
| `ext4_journal_stop()` | 停止 journaling。 |
| `ext4_recover()` | journal recovery。 |
| `ext4_mount_point_stats()` | 获取挂载点统计。 |
| `ext4_mount_setup_locks()` | 设置 OS 锁。 |
| `ext4_get_sblock()` | 获取超级块。 |
| `ext4_cache_write_back()` | 控制 write-back cache。 |
| `ext4_cache_flush()` | flush cache。 |

### 7.2 文件操作

| API | 作用 |
|---|---|
| `ext4_fopen()` | 字符串模式打开文件。 |
| `ext4_fopen2()` | flags 打开文件。 |
| `ext4_fclose()` | 关闭文件。 |
| `ext4_fread()` | 读取文件。 |
| `ext4_fwrite()` | 写入文件。 |
| `ext4_fseek()` | seek。 |
| `ext4_ftell()` | 获取当前位置。 |
| `ext4_fsize()` | 获取文件大小。 |
| `ext4_ftruncate()` | 截断。 |
| `ext4_fremove()` | 删除文件。 |
| `ext4_frename()` | 重命名文件。 |
| `ext4_flink()` | 创建硬链接。 |
| `ext4_inode_exist()` | 判断 inode 是否存在。 |
| `ext4_raw_inode_fill()` | 获取 inode 原始信息。 |
| `ext4_get_inode_ref()` | 获取 inode 引用。 |
| `ext4_put_inode_ref()` | 释放 inode 引用。 |
| `ext4_mode_set()` / `ext4_mode_get()` | 设置/读取 mode。 |
| `ext4_owner_set()` / `ext4_owner_get()` | 设置/读取 uid/gid。 |
| `ext4_atime_set()` / `ext4_atime_get()` | 设置/读取 atime。 |
| `ext4_mtime_set()` / `ext4_mtime_get()` | 设置/读取 mtime。 |
| `ext4_ctime_set()` / `ext4_ctime_get()` | 设置/读取 ctime。 |
| `ext4_fsymlink()` | 创建符号链接。 |
| `ext4_readlink()` | 读取符号链接。 |
| `ext4_mknod()` | 创建特殊文件。 |

### 7.3 目录操作

| API | 作用 |
|---|---|
| `ext4_dir_mk()` | 创建目录。 |
| `ext4_dir_rm()` | 删除目录。 |
| `ext4_dir_mv()` | 移动/重命名目录。 |
| `ext4_dir_open()` | 打开目录。 |
| `ext4_dir_close()` | 关闭目录。 |
| `ext4_dir_entry_next()` | 获取下一个目录项。 |
| `ext4_dir_entry_rewind()` | 重置目录遍历位置。 |

### 7.4 扩展属性

| API | 作用 |
|---|---|
| `ext4_setxattr()` | 设置路径对应 inode 的 xattr。 |
| `ext4_getxattr()` | 获取 xattr。 |
| `ext4_listxattr()` | 列举 xattr。 |
| `ext4_removexattr()` | 删除 xattr。 |
| `ext4_xattr_list()` | 底层列举 inode xattr。 |
| `ext4_xattr_get()` | 底层获取 inode xattr。 |
| `ext4_xattr_set()` | 底层设置 inode xattr。 |
| `ext4_xattr_remove()` | 底层删除 inode xattr。 |

### 7.5 块设备注册/适配

| API / 结构 | 作用 |
|---|---|
| `struct ext4_blockdev_iface` | lwext4 底层块设备回调接口。 |
| `struct ext4_blockdev` | lwext4 块设备对象。 |
| `EXT4_BLOCKDEV_STATIC_INSTANCE` | 静态定义 blockdev 的宏。 |
| `ext4_block_init()` | 初始化 blockdev。 |
| `ext4_block_fini()` | 关闭 blockdev。 |
| `ext4_block_bind_bcache()` | 绑定 block cache。 |
| `ext4_blocks_get_direct()` | 直接读 blocks。 |
| `ext4_blocks_set_direct()` | 直接写 blocks。 |
| `ext4_block_cache_flush()` | flush block cache。 |
| `ext4_block_cache_write_back()` | 设置 write-back。 |
| `dfs_ext4_blockdev_create()` | 基于 `rt_device_t` 创建 RT-Thread 适配对象。 |
| `dfs_ext4_blockdev_destroy()` | 销毁适配对象。 |
| `dfs_ext4_blockdev_from_bd()` | 从 lwext4 blockdev 反查适配对象。 |
| `dfs_ext_init()` | 注册 DFS 文件系统 `"ext"`。 |

### 7.6 mkfs

| API / 结构 | 作用 |
|---|---|
| `struct ext4_mkfs_info` | 格式化参数。 |
| `ext4_mkfs_read_info()` | 从已有文件系统读取 mkfs 信息。 |
| `ext4_mkfs()` | 创建 ext 文件系统。 |

---

## 8. 构建与使用

### 8.1 RT-Thread 构建

启用条件：

```python
depend = ['RT_USING_DFS', 'RT_USING_DFS_LWEXT4']
```

需要在 RT-Thread 配置中启用：

- `RT_USING_DFS`
- `RT_USING_DFS_LWEXT4`

头文件路径：

```python
CPPPATH = [cwd + '/include', cwd + '/ports/rtthread']
```

编译宏：

```python
CPPDEFINES = ['CONFIG_USE_DEFAULT_CFG', 'CONFIG_HAVE_OWN_OFLAGS=0']
```

组件组：

```python
group = DefineGroup('Filesystem', objs,
            depend = ['RT_USING_DFS', 'RT_USING_DFS_LWEXT4'],
            CPPPATH = CPPPATH,
            CPPDEFINES = CPPDEFINES,
            LOCAL_CCFLAGS = LOCAL_CCFLAGS)
```

### 8.2 组件初始化

`dfs_ext.c` 使用：

```c
INIT_COMPONENT_EXPORT(dfs_ext_init);
```

初始化时：

```c
int dfs_ext_init(void)
{
    ext4_mutex = rt_mutex_create("lwext4", RT_IPC_FLAG_FIFO);
    dfs_register(&_extfs);
    return 0;
}
```

注册的文件系统名称：

```c
.name = "ext"
```

### 8.3 使用路径

1. RT-Thread 块设备驱动提供 `rt_device_t`；
2. 应用通过 DFS 使用文件系统类型 `"ext"` 挂载；
3. DFS 调用 `dfs_ext_mount()`；
4. `dfs_ext_mount()` 创建 `dfs_ext4_blockdev`；
5. 调用 `ext4_mount()`；
6. 文件操作通过 `_extfs_fops` 转发到 lwext4 API。

---

## 9. 许可证注意事项

`README.md` 明确说明：

- lwext4 大多数代码源自 HelenOS，原许可协议是 BSD；
- `ext4_xattr.c` 和 `ext4_extents.c` 为 GPLv2；
- 因为这两个文件 GPLv2 许可协议，会造成整体 lwext4 的文件污染。

当前源码中实际对应：

| 文件 | 协议 | 功能 |
|---|---|---|
| `src/ext4_xattr.c` | GPLv2 | ext4 扩展属性管理。 |
| `src/ext4_extent.c` | GPLv2 | ext4 extent tree 管理。 |

其中 README 写作 `ext4_extents.c`，但实际源码文件名为 `src/ext4_extent.c`。

---

## 10. 总结

本仓库是 lwext4 面向 RT-Thread DFS 的移植版本。核心文件系统逻辑位于 `src/` 和 `include/`，RT-Thread 适配集中在 `ports/rtthread/`：

- `dfs_ext_blockdev.c` 将 lwext4 块设备抽象适配到 RT-Thread `rt_device_t`；
- `dfs_ext.c` 将 lwext4 高层 API 封装为 RT-Thread DFS 的 `struct dfs_filesystem_ops` 和 `struct dfs_file_ops`；
- `SConscript` 将核心源码和 RT-Thread 适配源码编入 `Filesystem` 组件；
- RT-Thread 构建未包含 `src/ext4_mbr.c`，格式化直接调用 `ext4_mkfs()`，不处理分区表；
- 挂载链路从 DFS `mount` 进入 `dfs_ext_mount()`，创建 `dfs_ext4_blockdev`，最终调用 lwext4 `ext4_mount()` 完成挂载。
