# lwext4 RT-Thread 移植层接口函数逻辑详解

> 本文档对 `dfs_ext.c` 中 `struct dfs_file_ops _extfs_fops` 和 `struct dfs_filesystem_ops _extfs_ops` 的所有接口函数进行逐层分析，从 DFS 入口一直追踪到物理设备硬件读写。

---

## 一、代码架构层次概览

```
┌─────────────────────────────────────────────────────────────┐
│  RT-Thread DFS VFS 层 (用户态 API 调用)                      │
│  open/close/read/write/mkdir/unlink/stat 等 POSIX 调用       │
├─────────────────────────────────────────────────────────────┤
│  dfs_ext.c  移植适配层                                       │
│  _extfs_fops / _extfs_ops  — 将 DFS 调用翻译为 ext4 操作     │
├─────────────────────────────────────────────────────────────┤
│  ext4.c  ext4 高级 API 层                                    │
│  ext4_fopen2 / ext4_fread / ext4_fwrite / ext4_dir_open ... │
├─────────────────────────────────────────────────────────────┤
│  ext4_fs.c  ext4 文件系统核心层                               │
│  ext4_fs_get_inode_dblk_idx — I-Node 数据块映射解析           │
│  (Extent 树 / 间接块映射)                                    │
├─────────────────────────────────────────────────────────────┤
│  ext4_blockdev.c  块设备抽象层                                │
│  ext4_block_readbytes / ext4_block_writebytes /              │
│  ext4_blocks_get_direct / ext4_blocks_set_direct             │
│  — 逻辑块地址 → 物理块地址转换, 非对齐读写处理                 │
├─────────────────────────────────────────────────────────────┤
│  ext4_bcache.c  块缓存层                                     │
│  — 通过 LBA+红黑树 管理块缓存, LRU 淘汰                       │
├─────────────────────────────────────────────────────────────┤
│  dfs_ext_blockdev.c  BDIF 桥接层                             │
│  blockdev_open/read/write/close — ext4 → RT-Thread 设备框架  │
├─────────────────────────────────────────────────────────────┤
│  RT-Thread 设备驱动层                                        │
│  rt_device_read / rt_device_write — 调用硬件驱动              │
├─────────────────────────────────────────────────────────────┤
│  物理硬件 (SD卡 / eMMC / NVMe / 磁盘镜像)                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、调用链中的核心中间函数说明

在逐函数分析前,先解释几个贯穿整个调用链的关键中间函数:

### 2.1 `ext4_bdif_bread` / `ext4_bdif_bwrite` — 物理块设备读写

这两者是最底层的块设备读写接口。它们位于 [ext4_blockdev.c](file:///d:/lwext4/src/ext4_blockdev.c#L68-L85)：

```
ext4_bdif_bread(bdev, buf, blk_id, blk_cnt):
  └─ 加锁(bdev)
  └─ 调用 bdev->bdif->bread(bdev, buf, blk_id, blk_cnt)  ← 函数指针,实际指向 blockdev_read
  └─ 解锁(bdev)

ext4_bdif_bwrite(bdev, buf, blk_id, blk_cnt):
  └─ 加锁(bdev)
  └─ 调用 bdev->bdif->bwrite(bdev, buf, blk_id, blk_cnt)  ← 函数指针,实际指向 blockdev_write
  └─ 解锁(bdev)
```

这里的 `blk_id` 是**物理块号**（physical block address）。

### 2.2 `ext4_blocks_get_direct` / `ext4_blocks_set_direct` — 逻辑块直读/直写

位于 [ext4_blockdev.c](file:///d:/lwext4/src/ext4_blockdev.c#L281-L306)。它们执行**逻辑块号到物理块号的转换**，然后直接调用 `ext4_bdif_bread/bwrite`：

```
ext4_blocks_get_direct(bdev, buf, lba, cnt):
  └─ pba = (lba * lg_bsize + part_offset) / ph_bsize    ← 逻辑块→物理块
  └─ pb_cnt = lg_bsize / ph_bsize                        ← 逻辑块包含的物理块数
  └─ ext4_bdif_bread(bdev, buf, pba, pb_cnt * cnt)       ← 物理块直接读

ext4_blocks_set_direct(bdev, buf, lba, cnt):
  └─ pba = (lba * lg_bsize + part_offset) / ph_bsize    ← 逻辑块→物理块
  └─ pb_cnt = lg_bsize / ph_bsize
  └─ ext4_bdif_bwrite(bdev, buf, pba, pb_cnt * cnt)     ← 物理块直接写
```

`lg_bsize` 由超级块决定（通常4096），`ph_bsize` 是物理扇区大小（通常512）。

### 2.3 `ext4_block_readbytes` / `ext4_block_writebytes` — 字节级块读写

位于 [ext4_blockdev.c](file:///d:/lwext4/src/ext4_blockdev.c#L309-L428)。处理**非对齐**的字节范围读写：

```
ext4_block_writebytes(bdev, off, buf, len):
  ① 计算包含 part_offset 的起始物理块号 block_idx
  ② 如果起始偏移 unalg 非对齐:
     └─ 用 ph_bbuf 做中间缓冲: 先读物理块 → memcpy 修改对应部分 → 写回
  ③ 中间对齐部分:
     └─ 直接 ext4_bdif_bwrite(bdev, p, block_idx, blen)  批量写
  ④ 尾部非对齐部分:
     └─ 再次用 ph_bbuf 做读-修改-写

ext4_block_readbytes(bdev, off, buf, len):
  ① 计算起始物理块号 block_idx
  ② 如果起始偏移 unalg 非对齐:
     └─ 读物理块到 ph_bbuf → memcpy 出需要的部分
  ③ 中间对齐部分:
     └─ 直接 ext4_bdif_bread(bdev, p, block_idx, blen)  批量读
  ④ 尾部非对齐部分:
     └─ 读物理块到 ph_bbuf → memcpy 出尾部数据
```

### 2.4 `ext4_generic_open2` — 通用文件/目录打开引擎

位于 [ext4.c](file:///d:/lwext4/src/ext4.c#L846-L1045)。这是所有 `open` 操作的核心:

```
ext4_generic_open2(f, path, flags, ftype, ...):
  ① 获取挂载点 mp = ext4_get_mount(path)
  ② 跳过挂载点前缀, 得到相对路径
  ③ ext4_fs_get_inode_ref(fs, ROOT_INODE=2, &ref)  加载根目录 inode
  ④ 逐级解析路径 (while loop):
     └─ ext4_path_check(path)    取下一个路径分量的长度
     └─ ext4_dir_find_entry()    在父目录中查找子目录/文件
     └─ 如果是最后一级且 O_CREAT 且未找到 → ext4_fs_alloc_inode() + ext4_link()
     └─ 检查 inode 类型 (目录/文件) 是否匹配预期
     └─ ext4_fs_put_inode_ref() 释放父 inode
     └─ ext4_fs_get_inode_ref() 加载下一级 inode
  ⑤ 如果是文件且在 O_TRUNC → ext4_trunc_inode() 截断为 0
  ⑥ 设置 f->mp, f->fsize, f->inode, f->fpos
```

### 2.5 `ext4_fs_get_inode_dblk_idx` — I-Node 数据块号解析

位于 [ext4_fs.c](file:///d:/lwext4/src/ext4_fs.c#L1460-L1465)。这是读写操作中**最关键的一步**——将文件内的逻辑块号 (`iblock`) 转换为文件系统物理块号 (`fblock`):

```
ext4_fs_get_inode_dblk_idx(inode_ref, iblock, &fblock, support_unwritten):
  └─ 调用内部的 ext4_fs_get_inode_dblk_idx_internal()

逻辑:
  ① 检查是否启用 Extent 树:
     └─ 如果 EXT4_FINCOM_EXTENTS 标志且 inode 有 EXT4_INODE_FLAG_EXTENTS:
     └─ 调用 ext4_extent_get_blocks()  通过 B+ 树查找
  ② 否则使用传统间接块映射:
     └─ 如果 iblock < 12 (EXT4_INODE_DIRECT_BLOCK_COUNT):
        直接从 inode->blocks[iblock] 读取
     └─ 如果 iblock 在单重间接块范围:
        读 inode->blocks[12] 指向的块 → 从中读取索引 → 得到目标块号
     └─ 如果 iblock 在二重间接块范围:
        读一级块 → 再读二级块 → 得到目标块号
     └─ 如果 iblock 在三重间接块范围:
        读一级 → 二级 → 三级 → 得到目标块号
```

### 2.6 `ext4_trans_start` / `ext4_trans_stop` — JBD 事务日志

位于 [ext4.c](file:///d:/lwext4/src/ext4.c#L605-L626)。在写操作前后启用 JBD (Journaling Block Device) 事务保护:

```
ext4_trans_start(mp):
  └─ 如果启用日志 (CONFIG_JOURNALING_ENABLE) 且 jbd_journal 存在:
     └─ jbd_journal_new_trans(journal)  创建新事务对象
     └─ mp->fs.curr_trans = trans

ext4_trans_stop(mp):
  └─ jbd_journal_commit_trans()  提交事务 → 写入 Journal 区域 → 写入数据区

ext4_trans_abort(mp):
  └─ jbd_journal_free_trans()  丢弃事务, 回滚操作
```

---

## 三、struct dfs_file_ops _extfs_fops 接口函数

定义于 [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L1053-L1064):

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

### 3.1 `dfs_ext_open` — 打开文件/目录

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L596-L674)

```
dfs_ext_open(file)
  │
  ├─ [前置检查] file && file->vnode
  │
  ├─ ★ 情况一: 文件已经被 lookup 创建 (ext_file->type != EXT4_DE_UNKNOWN)
  │   ├─ 如果是目录 && file->flags 没有 O_DIRECTORY → 返回 -ENOENT
  │   ├─ 如果是目录:
  │   │   └─ rt_calloc() 分配新的 dfs_ext4_file (深拷贝)
  │   │   └─ rt_memcpy(file->data, ext_file, ...)  拷贝 vnode 中的数据
  │   │   └─ entry.dir.next_off = 0  重置目录读取位置
  │   ├─ 如果是普通文件:
  │   │   └─ file->data = ext_file  直接共享 vnode 中的数据
  │   └─ file->fpos = 0
  │
  └─ ★ 情况二: 首次打开, 需要调用 ext4 API
      ├─ dfs_dentry_full_path(file->dentry)  获取完整路径
      ├─ 如果是目录:
      │   └─ ext4_dir_open(&ext_file->entry.dir, fn)
      │       │
      │       └── ext4_dir_open(dir, path)  [ext4.c:3143]
      │           ├─ ext4_get_mount(path)  获取挂载点
      │           ├─ EXT4_MP_LOCK(mp) 互斥锁
      │           ├─ ext4_generic_open(&dir->f, path, "r", false, ...)  通用打开
      │           │   └─ 逐级路径解析 → 加载根inode → dir_find_entry → 验证类型
      │           ├─ dir->next_off = 0
      │           └─ EXT4_MP_UNLOCK(mp)
      │
      ├─ 如果是普通文件:
      │   └─ ext4_fopen2(&ext_file->entry.file, fn, file->flags)
      │       │
      │       └── ext4_fopen2(file, path, flags)  [ext4.c:1492]
      │           ├─ ext4_get_mount(path)
      │           ├─ EXT4_MP_LOCK(mp)
      │           ├─ ext4_block_cache_write_back(mp->fs.bdev, 1)  启用回写模式
      │           ├─ [如果有 O_CREAT] ext4_trans_start(mp)  开始事务
      │           ├─ ext4_generic_open2(file, path, flags, EXT4_DE_REG_FILE, ...)
      │           │   └─ 逐级路径解析 (详见 2.4 节)
      │           ├─ [如果有 O_CREAT] ext4_trans_stop(mp) 或 ext4_trans_abort(mp)
      │           ├─ ext4_block_cache_write_back(mp->fs.bdev, 0)  禁用回写模式
      │           └─ EXT4_MP_UNLOCK(mp)
      │
      └─ rt_free(fn)  释放临时路径字符串
```

**关键点**:
- 如果文件已在 `lookup` 阶段打开了 vnode,则跳过 `ext4_fopen2` 调用,直接复用已有引用
- `O_CREAT` 标志触发事务包装: `ext4_trans_start` → 操作 → `ext4_trans_stop`
- 目录打开使用 `ext4_generic_open` (只读), 文件打开使用 `ext4_generic_open2` (支持创建)

---

### 3.2 `dfs_ext_close` — 关闭文件/目录

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L555-L590)

```
dfs_ext_close(file)
  │
  ├─ [引用计数检查] file->vnode->ref_count > 1
  │   └─ 还有其他文件引用此 vnode, 直接返回 (不清除)
  │
  ├─ ext_file = (struct dfs_ext4_file *)file->data
  │
  ├─ 如果是目录:
  │   └─ ext4_dir_close(&ext_file->entry.dir)
  │       │
  │       └── ext4_dir_close(dir)  [ext4.c:3159]
  │           └─ ext4_fclose(&dir->f)
  │               │
  │               └── ext4_fclose(file)  [ext4.c:1524]
  │                   ├─ EXT4_MP_LOCK(file->mp)
  │                   ├─ ext4_block_cache_flush(file->mp->fs.bdev)
  │                   │   └─ 遍历脏块链表 → 将脏块内容写回设备
  │                   │   └─ ext4_bdif_bwrite() → blockdev_write() → rt_device_write()
  │                   ├─ EXT4_MP_UNLOCK(file->mp)
  │                   └─ file->mp = 0; file->flags = 0; file->inode = 0; file->fpos = 0
  │
  └─ 如果是普通文件:
      └─ ext4_fclose(&ext_file->entry.file)  同上的 ext4_fclose 流程
```

**关键点**:
- close 时刷新块缓存 (`ext4_block_cache_flush`),确保脏数据写回设备
- 引用计数为 1 时才真正关闭; 大于 1 时说明有 fork/dup,不释放

---

### 3.3 `dfs_ext_read` — 读取文件数据

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L453-L473)

```
dfs_ext_read(file, buf, count, pos)
  │
  ├─ [边界检查] file->vnode->size > *pos  剩余可读数据
  │
  ├─ [互斥锁] rt_mutex_take(&file->vnode->lock)
  ├─ [定位] dfs_ext_lseek(file, *pos, SEEK_SET)  设置读取位置
  │
  ├─ ext4_fread(&ext_file->entry.file, buf, count, &bytesread)
  │   │
  │   └── ext4_fread(file, buf, size, rcnt)  [ext4.c:1608]
  │       │
  │       ├─ ★ 步骤1: 获取 inode 引用
  │       │   └─ ext4_fs_get_inode_ref(fs, file->inode, &ref)
  │       │       └─ 加载 inode 所在块到缓存 → 返回 inode 引用
  │       │
  │       ├─ ★ 步骤2: 同步文件大小
  │       │   └─ file->fsize = ext4_inode_get_size(sb, ref.inode)
  │       │
  │       ├─ ★ 步骤3: 计算读取范围
  │       │   ├─ size = min(size, fsize - fpos)  不能超过文件大小
  │       │   ├─ iblock_idx = fpos / block_size  起始逻辑块号
  │       │   └─ iblock_last = (fpos + size) / block_size  结束逻辑块号
  │       │
  │       ├─ ★ 步骤4: 软链接短路径处理 (60字节以内)
  │       │   └─ 直接从 ref.inode->blocks[] 中 memcpy
  │       │
  │       ├─ ★ 步骤5: 处理首个非对齐块 (unalg != 0)
  │       │   ├─ ext4_fs_get_inode_dblk_idx(&ref, iblock_idx, &fblock, true)
  │       │   │   │
  │       │   │   └── 解析 inode 的数据块映射 (Extent树 或 间接块)
  │       │   │       ├─ 如果启用 Extent: ext4_extent_get_blocks()
  │       │   │       │   └─ 遍历 B+ 树 → 定位 extent → 返回物理块号
  │       │   │       └─ 否则: 读取 inode->blocks[] + 间接块
  │       │   │           └─ for 1~3级间接块: ext4_trans_block_get() 读取索引块
  │       │   │           └─ 从索引块中解析出物理块号
  │       │   │
  │       │   ├─ 如果 fblock != 0:
  │       │   │   └─ off = fblock * block_size + unalg
  │       │   │   └─ ext4_block_readbytes(file->mp->fs.bdev, off, u8_buf, len)
  │       │   │       │
  │       │   │       └── 字节级非对齐读取 (详见 2.3 节)
  │       │   │           ├─ block_idx = (off + part_offset) / ph_bsize  物理块号
  │       │   │           ├─ 非对齐头部: ext4_bdif_bread → memcpy 取出
  │       │   │           │   └─ blockdev_read(bdev, buf, blk_id, blk_cnt)
  │       │   │           │       └─ rt_device_read(device, blk_id, buf, blk_cnt)
  │       │   │           │           └─ 硬件驱动: SD卡/磁盘/NVMe 读操作
  │       │   │           ├─ 对齐中部: ext4_bdif_bread 批量读
  │       │   │           └─ 非对齐尾部: ext4_bdif_bread → memcpy 取出
  │       │   │
  │       │   └─ 如果 fblock == 0 (空洞):
  │       │       └─ memset(u8_buf, 0, len)  填充零
  │       │
  │       ├─ ★ 步骤6: 处理对齐块 (批量连续块读取优化)
  │       │   ├─ 循环合并连续的物理块 (fblock_start + fblock_count)
  │       │   ├─ 如果 fblock_start == 0: memset 填充零
  │       │   ├─ 否则: ext4_blocks_get_direct(bdev, u8_buf, fblock_start, fblock_count)
  │       │   │   │
  │       │   │   └── 逻辑块→物理块转换 → ext4_bdif_bread()  批量读
  │       │   │       └─ blockdev_read() → rt_device_read()
  │       │   │
  │       │   └─ 推进 u8_buf, file->fpos, rcnt 指针
  │       │
  │       └─ ★ 步骤7: 处理尾部非对齐剩余字节
  │           ├─ ext4_fs_get_inode_dblk_idx(&ref, iblock_idx, &fblock, true)
  │           └─ ext4_block_readbytes(bdev, off = fblock * block_size, u8_buf, size)
  │               └─ ... → rt_device_read()
  │
  ├─ [更新位置] *pos = ext_file->entry.file.fpos
  └─ [释放锁] rt_mutex_release(&file->vnode->lock)
```

**完整调用链 (一条数据最终怎么从硬件读上来)**:

```
dfs_ext_read()
  → ext4_fread()
    → ext4_fs_get_inode_ref()          // 加载 inode
    → ext4_fs_get_inode_dblk_idx()     // 逻辑块号 → 物理块号
      → ext4_extent_get_blocks()       // [Extent 树] 或
      → ext4_trans_block_get()         // [间接块映射]
        → ext4_block_get()
          → ext4_bcache_get()          // 先查缓存
            → [miss] ext4_bdif_bread() // 缓存未命中 → 读物理设备
    → ext4_block_readbytes()           // 字节级读取
      → ext4_bdif_bread()              // 物理块读
        → bdev->bdif->bread()          // 函数指针 → blockdev_read()
          → rt_device_read()           // RT-Thread 设备框架
            → driver->read()           // 硬件驱动层
              → 硬件寄存器/DMA 操作     // 最终从 SD/NAND/磁盘读取数据
```

---

### 3.4 `dfs_ext_write` — 写入文件数据

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L475-L499)

```
dfs_ext_write(file, buf, count, pos)
  │
  ├─ [互斥锁] rt_mutex_take(&file->vnode->lock)
  ├─ [定位] dfs_ext_lseek(file, *pos, SEEK_SET)
  │
  ├─ ext4_fwrite(&ext_file->entry.file, buf, count, &byteswritten)
  │   │
  │   └── ext4_fwrite(file, buf, size, wcnt)  [ext4.c:1773]
  │       │
  │       ├─ [权限检查] 只读挂载/只读打开 → EROFS/EPERM
  │       │
  │       ├─ ★ 步骤1: 开始事务
  │       │   ├─ EXT4_MP_LOCK(file->mp)
  │       │   └─ ext4_trans_start(file->mp)
  │       │       └─ [若启用JBD] jbd_journal_new_trans()  创建事务
  │       │
  │       ├─ ★ 步骤2: 获取 inode 引用
  │       │   └─ ext4_fs_get_inode_ref(fs, file->inode, &ref)
  │       │
  │       ├─ ★ 步骤3: 同步/扩展文件大小
  │       │   └─ 如果 fpos > fsize: 扩展 fsize, 设置 inode size, 标记 dirty
  │       │
  │       ├─ ★ 步骤4: 处理首个非对齐块 (unalg != 0)
  │       │   ├─ ext4_fs_init_inode_dblk_idx(&ref, iblk_idx, &fblk)
  │       │   │   └─ 与 get 类似, 但如果块不存在则分配新块
  │       │   └─ ext4_block_writebytes(bdev, off = fblk * block_size + unalg, ...)
  │       │       │
  │       │       └── 字节级非对齐写入
  │       │           ├─ block_idx = (off + part_offset) / ph_bsize
  │       │           ├─ 非对齐头部: ext4_bdif_bread → memcpy修改 → ext4_bdif_bwrite
  │       │           │   └─ blockdev_read() + blockdev_write()
  │       │           │       └─ rt_device_read() + rt_device_write()
  │       │           ├─ 对齐中部: ext4_bdif_bwrite 批量写
  │       │           └─ 非对齐尾部: ext4_bdif_bread → memcpy修改 → ext4_bdif_bwrite
  │       │
  │       ├─ ★ 步骤5: 启用回写模式
  │       │   └─ ext4_block_cache_write_back(file->mp->fs.bdev, 1)
  │       │
  │       ├─ ★ 步骤6: 处理对齐块 (批量连续块写入)
  │       │   ├─ 循环:
  │       │   │   ├─ 如果 iblk_idx < ifile_blocks:
  │       │   │   │   └─ ext4_fs_init_inode_dblk_idx()  获取已有块
  │       │   │   └─ 否则:
  │       │   │       └─ ext4_fs_append_inode_dblk()  分配新块
  │       │   │           │
  │       │   │           └── 调用流程:
  │       │   │               ├─ ext4_balloc_alloc_block()  从块位图分配空闲块
  │       │   │               ├─ ext4_extent_append_block() 或 间接块写入
  │       │   │               │   └─ 更新 inode 的块映射表 (Extent 或 blocks[])
  │       │   │               └─ 更新块组位图, 更新超级块空闲块计数
  │       │   │
  │       │   ├─ 合并连续物理块
  │       │   └─ ext4_blocks_set_direct(bdev, u8_buf, fblock_start, fblock_count)
  │       │       │
  │       │       └── 逻辑块→物理块 → ext4_bdif_bwrite() 批量写
  │       │           └─ blockdev_write() → rt_device_write()
  │       │               └─ 硬件驱动层 → DMA/寄存器 → 闪存设备
  │       │
  │       ├─ ★ 步骤7: 禁用回写模式, 处理尾部非对齐
  │       │   └─ ext4_block_cache_write_back(bdev, 0)
  │       │   └─ ext4_block_writebytes()  尾部字节写入
  │       │
  │       ├─ ★ 步骤8: 更新文件大小
  │       │   └─ 如果 fpos > fsize → ext4_inode_set_size()
  │       │
  │       ├─ ★ 步骤9: 提交或中止事务
  │       │   ├─ ext4_fs_put_inode_ref(&ref)
  │       │   ├─ [成功] ext4_trans_stop(file->mp)
  │       │   │   └─ jbd_journal_commit_trans()
  │       │   │       ├─ 将事务中的脏块写入 Journal 区域
  │       │   │       ├─ 写入 Commit Block (含校验和)
  │       │   │       ├─ 将数据块写入最终位置 (Checkpoint)
  │       │   │       └─ 释放事务内存
  │       │   └─ [失败] ext4_trans_abort(file->mp)
  │       │       └─ jbd_journal_free_trans()  丢弃事务
  │       │
  │       └─ EXT4_MP_UNLOCK(file->mp)
  │
  ├─ [更新大小/位置] file->vnode->size = ext4_fsize(...); *pos = ext_file->entry.file.fpos
  └─ [释放锁] rt_mutex_release(&file->vnode->lock)
```

**写操作的完整调用链 (以一条数据最终落到硬件为例)**:

```
dfs_ext_write()
  → ext4_fwrite()
    → ext4_trans_start()                     // JBD 事务开始
    → ext4_fs_get_inode_ref()                // 加载 inode
    → ext4_fs_init_inode_dblk_idx()           // 解析/分配数据块
      → ext4_fs_get_inode_dblk_idx_internal()
        → ext4_extent_get_blocks() [Extent] 或 间接块遍历
      → [如果是新块] ext4_fs_append_inode_dblk()
        → ext4_balloc_alloc_block()           // 位图分配空闲块
        → ext4_bitmap 位图修改
        → ext4_block_group 块组描述符更新
    → ext4_block_writebytes()                 // 字节级写入 (非对齐头部)
      → ext4_bdif_bread()  → blockdev_read()  → rt_device_read()
      → memcpy()           // 修改数据
      → ext4_bdif_bwrite() → blockdev_write() → rt_device_write()
    → ext4_blocks_set_direct()                // 对齐块批量写入
      → ext4_bdif_bwrite() → blockdev_write() → rt_device_write()
    → ext4_trans_stop()                       // JBD 事务提交
      → jbd_journal_commit_trans()
        → ext4_bdif_bwrite() → ...           // 写 Journal 区
        → ext4_bdif_bwrite() → ...           // 写 Checkpoint
```

---

### 3.5 `dfs_ext_lseek` — 文件定位

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L535-L553)

```
dfs_ext_lseek(file, offset, whence)
  │
  ├─ [互斥锁] rt_mutex_take(&file->vnode->lock)
  │
  ├─ 如果是目录:
  │   ├─ 如果 offset == 0:
  │   │   └─ ext4_dir_entry_rewind(&ext_file->entry.dir)
  │   │       └─ dir->next_off = 0  重置目录读取偏移
  │   └─ 否则: 返回 -EPERM (目录不支持任意lseek)
  │
  └─ 如果是普通文件:
      └─ generic_dfs_lseek(file, offset, whence)  ← RT-Thread 通用实现
          ├─ SEEK_SET: new_offset = offset
          ├─ SEEK_CUR: new_offset = fpos + offset
          └─ SEEK_END: new_offset = fsize + offset
      └─ ext_file->entry.file.fpos = ret  同步 ext4 文件对象位置
```

---

### 3.6 `dfs_ext_flush` — 刷新缓存

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L501-L533)

```
dfs_ext_flush(file)
  ├─ dfs_dentry_full_path(file->dentry)  获取完整路径
  └─ ext4_cache_flush(fn)
      │
      └── 刷新指定挂载点的所有缓存
          ├─ ext4_block_cache_flush(bdev)   脏块写回
          │   └─ 遍历缓存中所有脏块 → ext4_bdif_bwrite → ... → rt_device_write()
          └─ ext4_bcache_invalidate_lba()   失效LBA表项
```

---

### 3.7 `dfs_ext_ioctl` — I/O 控制

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L982-L995)

```
dfs_ext_ioctl(file, cmd, args)
  ├─ RT_FIOFTRUNCATE: 截断文件
  │   └─ dfs_ext_truncate(file, offset)
  │       └─ ext4_ftruncate(&ext_file->entry.file, offset)
  │           └─ ... → ext4_trunc_inode() → 释放多余块
  │
  ├─ F_GETLK / F_SETLK: 文件锁 (直接返回成功, 不实现)
  └─ 其他: 返回 -RT_EIO
```

---

### 3.8 `dfs_ext_truncate` — 截断文件

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L967-L980)

```
dfs_ext_truncate(file, offset)
  └─ ext4_ftruncate(&ext_file->entry.file, offset)
      │
      └── ext4_ftruncate(f, size)  [ext4.c:1584]
          ├─ ext4_trans_start(f->mp)  开始事务
          ├─ ext4_ftruncate_no_lock(f, size)
          │   ├─ ext4_fs_get_inode_ref()  获取 inode
          │   ├─ ext4_trunc_inode(mp, inode_index, size)
          │   │   └─ 释放超出 size 的数据块
          │   │       ├─ ext4_extent_trunc() 或 间接块释放
          │   │       └─ ext4_balloc_free_block()  将块归还位图
          │   └─ 更新 file->fsize 和 file->fpos
          └─ ext4_trans_stop(mp) / ext4_trans_abort(mp)
```

---

### 3.9 `dfs_ext_getdents` — 读取目录项

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L880-L943)

```
dfs_ext_getdents(file, dirp, count)
  │
  ├─ [计数值调整] count = (count / sizeof(struct dirent)) * sizeof(struct dirent)
  │   确保 count 是 dirent 结构大小的整数倍
  │
  ├─ [循环读取目录项]
  │   ├─ ext4_dir_entry_next(&ext_file->entry.dir)
  │   │   │
  │   │   └── ext4_dir_entry_next(dir)  [ext4.c:3164]
  │   │       │
  │   │       ├─ 如果 next_off == -1:  已读完, 返回 NULL
  │   │       ├─ EXT4_MP_LOCK(dir->f.mp)
  │   │       ├─ ext4_fs_get_inode_ref()  获取目录 inode
  │   │       ├─ ext4_dir_iterator_init(&it, &dir_inode, dir->next_off)
  │   │       │   │
  │   │       │   └── 定位到指定偏移位置
  │   │       │       ├─ ext4_fs_get_inode_dblk_idx()  找到数据块
  │   │       │       └─ ext4_trans_block_get()  加载数据块到缓存
  │   │       │           └─ ext4_block_get() → ext4_bcache_get()
  │   │       │               └─ [miss] ext4_bdif_bread() → blockdev_read()
  │   │       │
  │   │       ├─ 读取目录项字段:
  │   │       │   ├─ ext4_dir_en_get_name_len(sb, it.curr)  名字长度
  │   │       │   ├─ ext4_dir_en_get_inode(it.curr)          inode号
  │   │       │   ├─ ext4_dir_en_get_entry_len(it.curr)      条目总长度
  │   │       │   └─ ext4_dir_en_get_inode_type(sb, it.curr) 类型标记
  │   │       │
  │   │       ├─ ext4_dir_iterator_next(&it)  移动到下一项
  │   │       ├─ dir->next_off = it.curr ? it.curr_off : -1
  │   │       ├─ ext4_dir_iterator_fini(&it)  释放块引用
  │   │       └─ ext4_fs_put_inode_ref(&dir_inode)
  │   │
  │   ├─ strncpy(d->d_name, rentry->name, DIRENT_NAME_MAX)  填充名字
  │   ├─ 根据 inode_type 设置 d->d_type:
  │   │   ├─ EXT4_DE_DIR → DT_DIR
  │   │   ├─ EXT4_DE_SYMLINK → DT_SYMLINK
  │   │   └─ 其他 → DT_REG
  │   ├─ d->d_namlen = rentry->name_length
  │   └─ d->d_reclen = sizeof(struct dirent)
  │
  └─ file->fpos += index * sizeof(struct dirent)
```

**目录项在磁盘上的存储结构**:

每个目录数据块中按顺序存放 `ext4_dir_en` 条目:

```
┌──────────────┬──────────────┬──────────────┬──────┐
│ ext4_dir_en  │ ext4_dir_en  │ ext4_dir_en  │ ...  │
│ (文件名1)     │ (文件名2)     │ (文件名3)     │      │
└──────────────┴──────────────┴──────────────┴──────┘
                        ↑ 通过 entry_len 跳到下一个
```

当启用 HTree 目录索引 (DIR_INDEX) 时, 第一个块是 `ext4_dir_idx_root`, 后续是索引节点和叶子块。

---

## 四、struct dfs_filesystem_ops _extfs_ops 接口函数

定义于 [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L1066-L1090):

```c
static const struct dfs_filesystem_ops _extfs_ops =
{
    .name           = "ext",
    .flags          = FS_NEED_DEVICE,
    .default_fops   = &_extfs_fops,

    .mount      = dfs_ext_mount,
    .umount     = dfs_ext_unmount,
    .mkfs       = dfs_ext_mkfs,
    .statfs     = dfs_ext_statfs,

    .readlink   = dfs_ext_readlink,
    .link       = dfs_ext_link,
    .unlink     = dfs_ext_unlink,
    .symlink    = dfs_ext_symlink,
    .stat       = dfs_ext_stat,
    .setattr    = dfs_ext_setattr,
    .rename     = dfs_ext_rename,

    .lookup     = dfs_ext_lookup,
    .create_vnode = dfs_ext_create_vnode,
    .free_vnode = dfs_ext_free_vnode,
};
```

### 4.1 `dfs_ext_mount` — 挂载文件系统

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L335-L358)

```
dfs_ext_mount(mnt, rwflag, data)
  │
  ├─ dfs_ext4_blockdev_create(mnt->dev_id)
  │   │
  │   └── ext4_blockdev 结构体初始化  [dfs_ext_blockdev.c:171]
  │       ├─ 分配 dfs_ext4_blockdev 结构体
  │       ├─ 分配 ext4_blockdev_iface 结构体,注册函数指针:
  │       │   ├─ iface->open  = blockdev_open
  │       │   ├─ iface->bread = blockdev_read
  │       │   ├─ iface->bwrite = blockdev_write
  │       │   ├─ iface->close = blockdev_close
  │       │   ├─ iface->lock  = blockdev_lock
  │       │   └─ iface->unlock = blockdev_unlock
  │       ├─ 设置 iface->ph_bsize = 4096 (默认)
  │       └─ 设置 iface->ph_bbuf = dbd->ph_bbuf (4096字节临时缓冲)
  │
  ├─ ext4_mount(bd, mnt->fullpath, false)
  │   │
  │   └── ext4_mount(bd, mount_point, read_only)  [ext4.c:266]
  │       │
  │       ├─ 从全局 s_mp[] 数组中分配一个挂载点槽位
  │       ├─ ext4_block_init(bd)
  │       │   └─ bdev->bdif->open(bdev)  → blockdev_open()
  │       │       │
  │       │       └── blockdev_open(bdev)  [dfs_ext_blockdev.c:74]
  │       │           ├─ dfs_ext4_blockdev_from_bd(bdev)  获取设备上下文
  │       │           ├─ rt_device_open(device, RDWR)      打开 RT-Thread 设备
  │       │           ├─ rt_device_control(GETGEOME)       获取磁盘几何信息
  │       │           │   ├─ geometry.sector_count          扇区总数
  │       │           │   └─ geometry.bytes_per_sector      每扇区字节数
  │       │           ├─ bdev->part_offset = 0
  │       │           ├─ bdev->part_size = sector_count * bytes_per_sector
  │       │           ├─ bdev->bdif->ph_bsize = geometry.block_size
  │       │           └─ bdev->bdif->ph_bcnt = part_size / ph_bsize
  │       │
  │       ├─ ext4_fs_init(&mp->fs, bd, read_only)
  │       │   │
  │       │   └── 读取并解析超级块
  │       │       ├─ ext4_block_get(bd, ...) → 读超级块所在块
  │       │       │   └─ ext4_bcache_get() → ext4_bdif_bread → blockdev_read()
  │       │       ├─ 解析超级块字段: block_size, inodes_count, blocks_count...
  │       │       ├─ 读取块组描述符表 (Block Group Descriptor Table)
  │       │       ├─ 计算各级间接块的数量限制
  │       │       └─ [若启用] ext4_journal_init()  初始化 JBD 日志
  │       │
  │       ├─ ext4_block_set_lb_size(bd, bsize)  设置逻辑块大小
  │       ├─ ext4_bcache_init_dynamic(bc, CACHE_SIZE, bsize)  初始化块缓存
  │       │   └─ 分配缓存内存 (默认 CONFIG_BLOCK_DEV_CACHE_SIZE 个槽位)
  │       ├─ ext4_block_bind_bcache(bd, bc)  绑定块缓存到块设备
  │       │
  │       ├─ bd->fs = &mp->fs         关联文件系统
  │       ├─ mp->mounted = 1          标记已挂载
  │       ├─ bd->journal = (void *)mp (从 bd 中分离 journal 指针)
  │       └─ ext4_cache_write_back(mp->name, true)  启动缓存写回
  │
  ├─ ext4_mount_setup_locks(mnt->fullpath, &ext4_lock_ops)
  │   └─ 注册 mutex 锁操作给 ext4 内部使用
  │
  └─ dbd->data = bd->journal; bd->journal = 0; mnt->data = dbd
      └─ 分离 journal, 保存 blockdev 到 mnt->data
```

---

### 4.2 `dfs_ext_unmount` — 卸载文件系统

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L360-L375)

```
dfs_ext_unmount(mnt)
  ├─ dbd = (struct dfs_ext4_blockdev *)mnt->data
  │
  └─ ext4_umount_mp(dbd->data)
      │
      └── ext4_umount_mp(mp)  [ext4.c:354]
          ├─ ext4_cache_write_back(mp->name, false)  停止缓存写回
          ├─ ext4_fs_fini(&mp->fs)
          │   ├─ [若启用JBD] ext4_journal_fini()  停止日志
          │   ├─ 释放所有块组描述符内存
          │   └─ 写回所有脏的位图块和超级块
          ├─ mp->mounted = 0
          ├─ ext4_bcache_cleanup(bc)  刷新并清理所有缓存块
          │   └─ 遍历脏块 → ext4_bdif_bwrite → ... → rt_device_write()
          ├─ ext4_bcache_fini_dynamic(bc)  释放缓存内存
          └─ ext4_block_fini(bdev)
              └─ bdev->bdif->close(bdev)  → blockdev_close()
                  └─ rt_device_close(device)
```

---

### 4.3 `dfs_ext_mkfs` — 格式化文件系统

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L377-L427)

```
dfs_ext_mkfs(devid, fs_name)
  │
  ├─ dfs_ext4_blockdev_create(devid)  创建块设备描述符
  ├─ rt_device_open(devid, RDWR)       打开设备
  │
  ├─ ext4_mkfs(&fs, bd, &info, F_SET_EXT4)
  │   │
  │   └── [ext4_mkfs.c]
  │       ├─ ext4_block_init(bd)  初始化 (open设备, 获取几何信息)
  │       ├─ 计算文件系统参数:
  │       │   ├─ 根据 part_size 和 block_size 计算块组数量
  │       │   ├─ 计算每个块组中的 inode 表大小
  │       │   └─ 计算 GDT 预留块数量
  │       ├─ 写入超级块:
  │       │   ├─ 填充 ext4_sblock 结构 (magic=0xEF53, inodes_count, blocks_count...)
  │       │   ├─ ext4_block_writebytes(bd, 1024, &sb, sizeof(sb))
  │       │   │   └─ ... → ext4_bdif_bwrite → blockdev_write → rt_device_write
  │       │   └─ 同时在多个块组位置写入备份超级块
  │       ├─ 写入块组描述符表 (BGDT):
  │       │   └─ ext4_block_writebytes()  → ... → rt_device_write
  │       ├─ 初始化位图: (初始化块位图和 inode 位图)
  │       ├─ [若启用JBD] 创建 Journal 区域:
  │       │   └─ ext4_mkfs_journal_init()
  │       ├─ 创建根目录:
  │       │   ├─ 分配一个 inode → ext4_ialloc_alloc_inode()
  │       │   ├─ 分配数据块 → ext4_balloc_alloc_block()
  │       │   ├─ 写入 "." 和 ".." 目录项
  │       │   └─ [若启用 DIR_INDEX] 创建 HTree 索引
  │       └─ 写入 lost+found 目录
  │
  ├─ dfs_ext4_blockdev_destroy(dbd)  释放设备描述符
  └─ rt_device_close(devid)           关闭设备
```

---

### 4.4 `dfs_ext_statfs` — 获取文件系统统计信息

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L429-L451)

```
dfs_ext_statfs(mnt, buf)
  ├─ ext4_get_sblock(mnt->fullpath, &sb)
  │   └─ ext4_fs_get_inode_ref() → 读取超级块所在块 → 返回指针
  │
  ├─ buf->f_bsize  = ext4_sb_get_block_size(sb)        块大小 (如4096)
  ├─ buf->f_blocks = ext4_sb_get_blocks_cnt(sb)         总块数
  ├─ buf->f_bfree  = ext4_sb_get_free_blocks_cnt(sb)    空闲块数
  └─ buf->f_bavail = buf->f_bfree   (可用块数)
```

---

### 4.5 `dfs_ext_lookup` — 路径查找 (创建 VNode)

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L124-L193)

```
dfs_ext_lookup(dentry)
  │
  ├─ rt_calloc(...) 分配 dfs_ext4_file 结构
  ├─ dfs_dentry_full_path(dentry)  获取完整路径
  ├─ dfs_vnode_create()  创建 RT-Thread DFS vnode
  │
  ├─ ext4_get_inode_ref(fn, &ext_file->vnode.inode_ref)
  │   │
  │   └── 获取指定路径的 inode 引用
  │       ├─ ext4_get_mount(path)  解析挂载点
  │       ├─ ext4_generic_open2()  逐级解析路径
  │       │   └─ ... → ext4_dir_find_entry() → 找到最终 inode
  │       └─ ext4_fs_get_inode_ref(fs, f.inode, &ref)  获取 inode 引用
  │           └─ 加载 inode 所在块到缓存 → 增加引用计数
  │
  ├─ 根据 inode 类型填充 vnode:
  │   ├─ EXT4_INODE_MODE_FILE:
  │   │   ├─ vnode->type = FT_REGULAR
  │   │   ├─ vnode->size = ext4_inode_get_size(...)
  │   │   └─ [若启用 PAGECACHE] dfs_aspace_create()  创建地址空间
  │   ├─ EXT4_INODE_MODE_DIRECTORY:
  │   │   ├─ vnode->type = FT_DIRECTORY
  │   │   └─ vnode->size = 0
  │   └─ EXT4_INODE_MODE_SOFTLINK:
  │       ├─ vnode->type = FT_SYMLINK
  │       └─ vnode->size = 0
  │
  ├─ vnode->nlink = 1
  ├─ vnode->mnt = dentry->mnt
  ├─ vnode->data = ext_file
  ├─ rt_mutex_init(&vnode->lock, ...)  初始化 vnode 互斥锁
  └─ ext4_vnode_update_info(vnode)  同步 mode/uid/gid/atime/mtime/ctime
```

---

### 4.6 `dfs_ext_create_vnode` — 创建文件/目录

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L200-L332)

```
dfs_ext_create_vnode(dentry, type, mode)
  │
  ├─ dfs_vnode_create() → rt_calloc() 分配 dfs_ext4_file
  ├─ dfs_dentry_full_path(dentry)  获取路径
  │
  ├─ ★ 如果 FT_DIRECTORY:
  │   ├─ ext4_dir_mk(fn)
  │   │   └─ ... → ext4_generic_open2() 逐级找到父目录
  │   │          → ext4_fs_alloc_inode()  分配新 inode
  │   │          → ext4_link()  在父目录中创建目录项
  │   │          → 初始化新目录 ("." 和 ".." 条目)
  │   │
  │   ├─ ext4_mode_set(fn, mode)  设置权限
  │   └─ ext4_get_inode_ref(fn, ...)  重新获取 inode 引用
  │
  ├─ ★ 如果 FT_REGULAR:
  │   ├─ ext4_fopen2(&file, fn, O_CREAT)
  │   │   └─ ... → ext4_generic_open2() + O_CREAT
  │   │          → 路径不存在时: ext4_fs_alloc_inode + ext4_link
  │   ├─ ext4_fclose(&file)
  │   ├─ ext4_mode_set(fn, mode)
  │   ├─ ext4_get_inode_ref(fn, ...)
  │   └─ [若启用 PAGECACHE] dfs_aspace_create()
  │
  ├─ ★ 其他类型 (符号链接/字符设备/块设备/FIFO/Socket):
  │   └─ ext4_mknod(fn, filetype, 0)  创建特殊 inode
  │
  └─ vnode->mnt = dentry->mnt; vnode->data = ext_file; rt_mutex_init(...)
```

---

### 4.7 `dfs_ext_free_vnode` — 释放 VNode

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L317-L333)

```
dfs_ext_free_vnode(vnode)
  ├─ ext4_put_inode_ref(mp, &ext_file->vnode.inode_ref)
  │   └─ ext4_fs_put_inode_ref(&ref)
  │       ├─ [如果是脏的] 将 inode 所在的缓存块标记为脏并写回
  │       └─ ext4_block_set()  释放块引用 → 减少缓存引用计数
  │
  ├─ rt_mutex_detach(&vnode->lock)  销毁互斥锁
  ├─ rt_free(ext_file)  释放 dfs_ext4_file 内存
  └─ vnode->data = NULL
```

---

### 4.8 `dfs_ext_readlink` — 读取符号链接

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L676-L699)

```
dfs_ext_readlink(dentry, buf, len)
  ├─ dfs_dentry_full_path(dentry)  获取路径
  ├─ ext4_readlink(fn, buf, len, &size)
  │   └─ ext4_generic_open2() → ext4_inode_is_type(SOFTLINK)
  │       → 判断链接目标大小是否 < 60字节:
  │       ├─ 短链接: 数据直接存储在 inode->blocks[] 中 → memcpy
  │       └─ 长链接: ext4_fread() → inode 数据块 → 读取链接路径
  └─ buf[size] = '\0'  终止符
```

---

### 4.9 `dfs_ext_link` — 创建硬链接

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L701-L715)

```
dfs_ext_link(src_dentry, dst_dentry)
  ├─ dfs_dentry_full_path(src_dentry)  源路径
  ├─ dfs_dentry_full_path(dst_dentry)  目标路径
  └─ ext4_flink(src_path, dst_path)
      └─ ... → ext4_generic_open2() 获取源 inode
             → ext4_dir_add_entry() 在目标父目录中添加目录项
             → ext4_inode_set_links_cnt() 增加链接计数
```

---

### 4.10 `dfs_ext_symlink` — 创建符号链接

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L717-L743)

```
dfs_ext_symlink(parent_dentry, target, linkpath)
  ├─ [路径处理] 拼接父目录路径 + linkpath
  └─ ext4_fsymlink(target, fn)
      └─ ext4_generic_open2() → 创建 inode (mode=S_IFLNK)
         → 如果 target < 60字节: 直接写入 inode->blocks[]
         → 否则: 分配数据块 → ext4_fwrite 写入链接内容
```

---

### 4.11 `dfs_ext_unlink` — 删除文件/目录

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L745-L785)

```
dfs_ext_unlink(dentry)
  ├─ dfs_dentry_full_path(dentry)  获取路径
  │
  ├─ ★ 先尝试作为目录打开:
  │   ├─ ext4_dir_open(&file.entry.dir, fn)
  │   ├─ 如果成功:
  │   │   ├─ ext4_dir_close(&file.entry.dir)
  │   │   └─ ext4_dir_rm(fn)
  │   │       └─ 检查目录是否为空 (不能包含 "." ".." 之外的条目)
  │   │          → ext4_dir_remove_entry()  从父目录移除目录项
  │   │          → ext4_fs_free_inode()      释放 inode
  │   │          → ext4_balloc_free_block()  释放数据块
  │   │          → ext4_fs_inode_links_count_dec()  更新父目录链接计数
  │   │
  │   └─ 如果打开目录失败:
  │       └─ ext4_fremove(fn)  作为文件删除
  │           └─ ext4_generic_open2() → ext4_dir_remove_entry()
  │              → ext4_fs_free_inode()
  │              → ext4_trunc_inode()  释放所有数据块
  │              → 如果链接计数降为0 → 彻底释放 inode
```

---

### 4.12 `dfs_ext_stat` — 获取文件/目录属性

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L787-L843)

```
dfs_ext_stat(dentry, st)
  ├─ dfs_dentry_full_path(dentry)  获取路径
  │
  ├─ ext4_get_inode_ref(stat_path, &inode_ref)
  │   └─ 加载 inode (详见 lookup 中的路径解析)
  │
  ├─ st->st_mode  = ext4_inode_get_mode(&mp->fs.sb, inode_ref.inode)
  ├─ st->st_uid   = ext4_inode_get_uid(inode_ref.inode)
  ├─ st->st_gid   = ext4_inode_get_gid(inode_ref.inode)
  │
  ├─ st->st_size:
  │   ├─ 如果是目录: st->st_size = ext4_inode_get_size(...)
  │   └─ 如果是文件:
  │       ├─ [PAGECACHE启用] 用 vnode->size (可能是缓存的)
  │       └─ [否则] ext4_inode_get_size(...)
  │
  ├─ st->st_atime = ext4_inode_get_access_time(inode_ref.inode)
  ├─ st->st_mtime = ext4_inode_get_modif_time(inode_ref.inode)
  ├─ st->st_ctime = ext4_inode_get_change_inode_time(inode_ref.inode)
  ├─ st->st_dev   = (dev_t)(dentry->mnt->dev_id)
  ├─ st->st_ino   = inode_ref.index
  ├─ st->st_blksize = ext4_sb_get_block_size(&mp->fs.sb)
  ├─ st->st_blocks = RT_ALIGN(st->st_size, st->st_blksize) / 512
  │
  └─ ext4_put_inode_ref(mp, &inode_ref)  释放 inode 引用
```

---

### 4.13 `dfs_ext_setattr` — 设置文件属性

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L845-L878)

```
dfs_ext_setattr(dentry, attr)
  ├─ dfs_dentry_full_path(dentry)  获取路径
  │
  ├─ [ATTR_MODE]  ext4_mode_set(fn, attr->st_mode)
  │   └─ ext4_trans_get_inode_ref() → inode_set_mode() → ext4_trans_put_inode_ref()
  │
  ├─ [ATTR_ATIME] ext4_atime_set(fn, attr->ia_atime.tv_sec)
  │   └─ ext4_trans_get_inode_ref() → ext4_inode_set_access_time()
  │
  ├─ [ATTR_MTIME] ext4_mtime_set(fn, attr->ia_mtime.tv_sec)
  │   └─ ext4_trans_get_inode_ref() → ext4_inode_set_modif_time()
  │
  ├─ [ATTR_UID]   ext4_owner_set(fn, attr->st_uid, gid)
  │   └─ ext4_trans_get_inode_ref() → inode_set_uid/gid()
  │
  ├─ [ATTR_GID]   ext4_owner_set(fn, uid, attr->st_gid)
  │
  └─ ext4_vnode_update_info(dentry->vnode)
      └─ 重新同步 vnode 中的 mode/uid/gid/atime/mtime/ctime
```

---

### 4.14 `dfs_ext_rename` — 重命名文件/目录

**源文件**: [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L945-L965)

```
dfs_ext_rename(old_dentry, new_dentry)
  ├─ dfs_dentry_full_path(old_dentry)  旧路径
  ├─ dfs_dentry_full_path(new_dentry)  新路径
  │
  └─ ext4_frename(oldpath, newpath)
      │
      └── [ext4.c:1258]
          ├─ ext4_generic_open2() 获取旧路径 inode
          ├─ ext4_dir_remove_entry()  从旧路径的父目录中移除条目
          ├─ ext4_link()  在新路径的父目录中添加条目
          └─ [若为目录] ext4_dir_dx_reset_parent_inode()  更新 ".." 指针
```

---

## 五、互斥锁机制

所有 open/read/write 等接口都被两级互斥锁保护:

**全局 ext4 锁** (定义于 [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L63-L92)):

```c
static rt_mutex_t ext4_mutex = RT_NULL;   // RT-Thread 互斥量

static struct ext4_lock ext4_lock_ops = {
    ext4_lock,    // rt_mutex_take(ext4_mutex, RT_WAITING_FOREVER)
    ext4_unlock   // rt_mutex_release(ext4_mutex)
};
```

此锁被挂载时注册 (`ext4_mount_setup_locks`),并在 `EXT4_MP_LOCK(mp)` 宏中使用。

**块设备锁** (定义于 [dfs_ext_blockdev.c](file:///d:/lwext4/ports/rtthread/dfs_ext_blockdev.c#L33-L63)):

```c
static rt_mutex_t bdevice_mutex = RT_NULL;

static int blockdev_lock(struct ext4_blockdev *bdev) {
    rt_mutex_take(bdevice_mutex, RT_WAITING_FOREVER);
}

static int blockdev_unlock(struct ext4_blockdev *bdev) {
    rt_mutex_release(bdevice_mutex);
}
```

此锁在 `ext4_bdif_bread/bwrite` 的最底层保护物理设备访问。

**文件级 VNode 锁** (DFS VFS 层):

```c
rt_mutex_take(&file->vnode->lock, RT_WAITING_FOREVER);
// ... 操作 ...
rt_mutex_release(&file->vnode->lock);
```

`dfs_ext_read` / `dfs_ext_write` / `dfs_ext_lseek` 等函数在操作过程中获取此锁,保护同一个 vnode 的并发访问。

---

## 六、pagecache (可选)

当启用 `RT_USING_PAGECACHE` 时,文件支持 `mmap` 内存映射。pagecache 的回调函数位于 [dfs_ext.c](file:///d:/lwext4/ports/rtthread/dfs_ext.c#L1002-L1051):

```
dfs_ext_page_read(file, page):
  └─ 加锁 → dfs_ext_read(file, page->page, page->size, &fpos) → 解锁

dfs_ext_page_write(page):
  └─ 加锁 → ext4_fseek() → ext4_fwrite() → 解锁
```

**与普通 read/write 的区别**: pagecache 的 read/write 操作使用**页** (page) 而非用户 buffer。数据直接从文件数据块映射到 page 的物理地址,减少了内存拷贝。

---

## 七、总体架构总结图

```
                 POSIX 调用 (open/read/write/stat/...)
                              │
                    ┌─────────┴─────────┐
                    │  RT-Thread DFS    │
                    │  VFS 虚拟文件系统  │
                    └─────────┬─────────┘
                              │
                    ┌─────────┴─────────┐
                    │   dfs_ext.c       │  ← _extfs_fops / _extfs_ops
                    │   接口适配层       │
                    └─────────┬─────────┘
                              │
           ┌──────────────────┼──────────────────┐
           ▼                  ▼                  ▼
    ext4_fopen2()      ext4_fread()      ext4_dir_open()
    ext4_fclose()      ext4_fwrite()     ext4_dir_entry_next()
    ext4_fremove()     ext4_fseek()      ext4_dir_mk()
    ext4_mode_set()    ext4_ftruncate()  ext4_dir_rm()
           │                  │                  │
           └──────────────────┼──────────────────┘
                              ▼
              ┌───────────────────────────┐
              │  ext4_generic_open2()     │  ← 通用路径解析引擎
              │  ext4_dir_find_entry()    │     逐级查找目录项
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  ext4_fs.c               │
              │  ext4_fs_get_inode_dblk_idx│ ← 数据块号解析
              │     ↓                     │    Extent B+树 / 间接块
              │  ext4_extent_get_blocks() │
              │  ext4_balloc_alloc_block()│ ← 空闲块分配 (位图)
              │  ext4_fs_alloc_inode()    │ ← inode 分配 (位图)
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  ext4_blockdev.c         │
              │  ext4_block_readbytes()   │ ← 字节级块读写
              │  ext4_block_writebytes()  │   (非对齐处理)
              │  ext4_blocks_get_direct() │ ← 逻辑块 → 物理块
              │  ext4_blocks_set_direct() │   批量块读写
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  ext4_bcache.c           │
              │  ext4_bcache_get()        │ ← LRU 缓存查找
              │  ext4_bcache_set_dirty()  │   脏块标记
              │  ext4_bcache_flush()      │   脏块写回
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  ext4_blockdev.c         │
              │  ext4_bdif_bread()        │ ← 加锁 → bdev->bdif->bread()
              │  ext4_bdif_bwrite()       │   加锁 → bdev->bdif->bwrite()
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  dfs_ext_blockdev.c      │
              │  blockdev_read()          │ ← ext4 → RT-Thread 桥接
              │  blockdev_write()         │
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  RT-Thread Device I/O    │
              │  rt_device_read()         │ ← 设备框架统一接口
              │  rt_device_write()        │
              └─────────────┬─────────────┘
                            ▼
              ┌───────────────────────────┐
              │  硬件驱动层               │
              │  SD卡 / eMMC / 磁盘镜像   │ ← 寄存器/DMA 操作
              └───────────────────────────┘
```

---

## 八、关键宏与配置

| 宏名称 | 作用 |
|--------|------|
| `CONFIG_JOURNALING_ENABLE` | 启用 JBD 日志, 写操作时走事务保护 (0=关闭Writeback, 1=开启Journal) |
| `CONFIG_EXTENT_ENABLE` | 启用 Extent 区段树, 替代传统间接块映射 |
| `CONFIG_DIR_INDEX_ENABLE` | 启用 HTree 目录索引, 加速大目录文件名查找 |
| `CONFIG_BLOCK_DEV_CACHE_SIZE` | 块缓存槽位数, 控制 LRU 缓存大小 |
| `CONFIG_EXT4_MOUNTPOINTS_COUNT` | 最大挂载点数量 |
| `RT_USING_PAGECACHE` | 启用文件页缓存, 支持 mmap 内存映射 |

| ext4_lock_ops 互斥锁层级 | 保护范围 |
|----------------------------|----------|
| `ext4_lock_ops` (ext4_mutex) | EXT4_MP_LOCK/UNLOCK — 保护挂载点级别的操作 (open/close/rename 等) |
| `bdevice_mutex` | ext4_bdif_bread/bwrite — 保护物理设备访问的原子性 |
| `vnode->lock` | 保护单个文件的并发读写 |