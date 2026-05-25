# lwext4 文件系统日志（Journal）分析

## 概述

该项目实现了一个基于 ext4 兼容的 **JBD (Journaling Block Device)** 日志系统。核心代码集中在以下文件：

| 文件 | 作用 |
|------|------|
| `include/ext4_journal.h` | 日志系统数据结构与 API 声明 |
| `src/ext4_journal.c` | 日志记录、提交、恢复的完整实现 |
| `include/ext4_types.h` | 磁盘上 JBD 数据结构的定义（超级块、描述符块、标签等） |
| `src/ext4_trans.c` | 事务层——将上层对块的修改操作桥接到日志系统 |

---

## 一、核心数据结构

在分析两大功能之前，先理清关键的数据结构关系：

```
ext4_fs                    -- 文件系统实例
  |-- jbd_fs               -- JBD 文件系统上下文（指向 journal inode）
  |-- jbd_journal          -- 当前日志会话
  |-- curr_trans           -- 当前活跃事务

jbd_journal                -- 日志会话（管理整个环形日志缓冲区）
  |-- first / start / last -- 环形日志的三个指针
  |-- trans_id             -- 当前日志起始事务 ID
  |-- alloc_trans_id       -- 下一个待分配的事务 ID
  |-- cp_queue             -- 检查点队列（等待写入磁盘的事务链表）
  |-- block_rec_root       -- 红黑树：所有被日志记录的块地址

jbd_trans                  -- 单个事务
  |-- trans_id             -- 事务 ID
  |-- start_iblock         -- 在日志区域中的起始块号
  |-- data_cnt             -- 脏数据块计数
  |-- written_cnt          -- 已写入磁盘的块计数
  |-- buf_queue            -- 本事务涉及的所有 jbd_buf
  |-- revoke_root          -- 本事务的撤销块红黑树
  |-- tbrec_list           -- 本事务拥有的 block_rec 链表
```

### 磁盘上的日志块类型

由 `jbd_bhdr.blocktype` 区分：

| 类型 | 值 | 含义 |
|------|-----|------|
| `JBD_DESCRIPTOR_BLOCK` | 1 | 描述符块：包含一组 `block_tag`，指向随后的数据块 |
| `JBD_COMMIT_BLOCK` | 2 | 提交块：标志一个事务的结束 |
| `JBD_SUPERBLOCK` | 3 | 日志超级块 V1 |
| `JBD_SUPERBLOCK_V2` | 4 | 日志超级块 V2 |
| `JBD_REVOKE_BLOCK` | 5 | 撤销块：记录需要撤销（不重放）的块地址 |

### JBD 超级块结构 (`struct jbd_sb`)

```
偏移      字段              说明
0x0000    header            jbd_bhdr (magic, blocktype, sequence)
0x000C    blocksize         日志设备块大小
0x0010    maxlen            日志文件总块数
0x0014    first             日志信息的第一个块
0x0018    sequence          日志中预期的第一个提交 ID
0x001C    start             日志起始块号
0x0020    error_val         错误值
0x0024    feature_compat    兼容特性集
0x0028    feature_incompat  不兼容特性集
0x002C    feature_ro_compat 只读兼容特性集
0x0030    uuid              日志的 128 位 UUID
0x0040    nr_users          共享日志的文件系统数量
0x0044    dynsuper          动态超级块副本的块号
0x0048    max_transaction   每事务最大日志块数
0x004C    max_trandata      每事务最大数据块数
0x0050    checksum_type     校验和类型
0x0100    users             共享日志的所有文件系统 ID
```

### 日志块标签结构

**`struct jbd_block_tag3`** (CSUM_V3 格式):

```
字段          大小      说明
blocknr       4 bytes   磁盘块号（低 32 位）
flags         4 bytes   标志位 (ESCAPE, SAME_UUID, DELETED, LAST_TAG)
blocknr_high  4 bytes   磁盘块号（高 32 位，64bit 模式）
checksum      4 bytes   crc32c(uuid+seq+block)
```

**`struct jbd_block_tag`** (传统格式):

```
字段          大小      说明
blocknr       4 bytes   磁盘块号（低 32 位）
checksum      2 bytes   截断的 crc32c(uuid+seq+block)
flags         2 bytes   标志位
blocknr_high  4 bytes   磁盘块号（高 32 位）
```

### 标志位定义

| 标志 | 值 | 含义 |
|------|-----|------|
| `JBD_FLAG_ESCAPE` | 1 | 磁盘块被转义（头 4 字节与 JBD_MAGIC_NUMBER 冲突） |
| `JBD_FLAG_SAME_UUID` | 2 | 块与前一标签具有相同的 UUID |
| `JBD_FLAG_DELETED` | 4 | 块被此事务删除 |
| `JBD_FLAG_LAST_TAG` | 8 | 此描述符块中的最后一个标签 |

---

## 二、日志记录（Journaling / Commit）流程

日志记录的核心目的是：**在元数据真正写入磁盘之前，先将修改记录到日志区域，确保崩溃后可以恢复**。

### 2.1 整体流程概览

```
上层操作 (如 ext4_dir_write_entry, ext4_inode_write 等)
    |
    v
ext4_trans_set_block_dirty(buf)          -- ext4_trans.c:54
    |  (如果开启了 CONFIG_JOURNALING_ENABLE)
    v
jbd_trans_set_block_dirty(trans, block)  -- ext4_journal.c:1623
    |
    |  1) 查找/创建 jbd_block_rec（红黑树管理）
    |  2) 分配 jbd_buf，加入事务的 buf_queue
    |  3) 设置 end_write 回调为 jbd_trans_end_write
    |  4) 将真实 block 标记为 BC_DIRTY
    |
    v
jbd_journal_commit_trans(journal, trans) -- ext4_journal.c:2283
    |
    v
__jbd_journal_commit_trans()             -- ext4_journal.c:2181
    |
    +-- 1) jbd_journal_prepare()          -- 写描述符块 + 数据块到日志区
    +-- 2) jbd_journal_prepare_revoke()   -- 写撤销块到日志区
    +-- 3) jbd_trans_write_commit_block() -- 写提交块（事务结束标志）
    +-- 4) 将事务加入 cp_queue（检查点队列）
```

### 2.2 详细步骤分析

#### 步骤一：标记块为脏

函数：`jbd_trans_set_block_dirty()`（[ext4_journal.c:1623](src/ext4_journal.c#L1623)）

当上层修改了某个块的数据后（如修改 inode、目录项、位图等），通过 `ext4_trans_set_block_dirty()` 调用到此函数：

1. **去重检查**：如果该 `ext4_buf` 已经有一个 `end_write` 回调且属于同一事务，直接返回 EOK。
2. **查找/创建 block_rec**：在 `journal->block_rec_root` 红黑树中按 LBA 查找。如果已存在则变更所有权到当前事务（`jbd_trans_change_ownership`）；否则新建并插入红黑树。
3. **分配 jbd_buf**：分配一个 `jbd_buf` 结构，关联 block、trans、block_rec。
4. **加入队列**：`jbd_buf` 加入 `block_rec->dirty_buf_queue`（脏缓冲队列）和 `trans->buf_queue`（事务缓冲队列）。
5. **设置回调**：将真实块的 `end_write` 设为 `jbd_trans_end_write`——这是检查点机制的关键回调，当数据真正写入磁盘后触发。
6. **处理冲突**：如果该 LBA 之前在 revoke_root 中（即曾标记为撤销），则移除之，因为现在要写入新数据了。

#### 步骤二：准备描述符块和数据块

函数：`jbd_journal_prepare()`（[ext4_journal.c:1891](src/ext4_journal.c#L1891)）

这是提交过程中最核心的部分：

1. **清理非脏缓冲**：反向遍历 `trans->buf_queue`，移除所有不再 dirty 的 `jbd_buf`（这些块在上层已被释放或回滚），并调用 `jbd_trans_finish_callback` 做回滚处理。

2. **遍历脏缓冲**：对每个仍为 dirty `jbd_buf`：
   - 计算 CRC32C 校验和（用于 CSUM_V2/V3 校验，输入为 UUID + sequence + 块数据）。
   - 检测是否需要 escape：如果数据头 4 字节恰好等于 `JBD_MAGIC_NUMBER (0xc03b3998)`，则设置 escape 标志，恢复时会还原。
   - 在描述符块中写入 `block_tag`（记录目标 LBA、flags、校验和等），调用 `jbd_write_block_tag()`。
   - 如果当前描述符块空间不足，设置元数据校验和并刷新到磁盘，然后分配新的描述符块（goto again 逻辑）。
   - 在日志区域为每个数据块分配空间（`jbd_journal_alloc_block`），将脏数据 `memcpy` 过去，标记 dirty 并写入。

3. **写入最后的描述符块**：设置元数据校验和（`jbd_meta_csum_set`），写入磁盘。

#### 步骤三：准备撤销块

函数：`jbd_journal_prepare_revoke()`（[ext4_journal.c:1997](src/ext4_journal.c#L1997)）

如果事务中包含 revoke（撤销）条目，遍历 `trans->revoke_root` 红黑树：

- 为每个需要撤销的 LBA 写入 revoke block（4 字节或 8 字节，取决于是否 64bit 模式）。
- 如果 revoke block 满了，刷新并分配新的。
- Revoke 语义：**在恢复时，对于被 revoke 的块，跳过该事务及之前事务中对该块的修改**。

#### 步骤四：写提交块

函数：`jbd_trans_write_commit_block()`（[ext4_journal.c:1841](src/ext4_journal.c#L1841)）

- 分配一个新日志块。
- 写入 `jbd_bhdr`：magic = `JBD_MAGIC_NUMBER`，blocktype = `JBD_COMMIT_BLOCK`，sequence = `trans->trans_id`。
- 如果开启了 checksum v1（`JBD_FEATURE_COMPAT_CHECKSUM`），记录 `trans->data_csum`。
- 调用 `jbd_commit_csum_set()` 设置 CSUM_V2/V3 校验和。
- 标记 dirty 并写入。

**提交块是事务完整性的关键标志——恢复时只有看到有效的 commit block 才会重放该事务。**

#### 步骤五：检查点队列管理

提交完成后，事务被加入 `journal->cp_queue`（检查点队列）：

- **首个事务**：如果 cp_queue 为空，将此事务设为队列首部，更新 journal superblock 的 start 和 sequence，然后调用 `jbd_journal_cp_trans()` 释放事务中块的引用。
- **后续事务**：直接插入队列尾部。
- **空间不足时**：当日志区域满时（`journal->last == journal->start`），触发 `jbd_journal_purge_cp_trans()` 清理旧的已完成事务。

#### 步骤六：数据最终写回磁盘

函数：`jbd_trans_end_write()`（[ext4_journal.c:2111](src/ext4_journal.c#L2111)）

当真实数据块的 I/O 完成时，回调此函数：

1. 检查写入结果，如有错误记录到 `trans->error`。
2. 从 `trans->buf_queue` 和 `block_rec->dirty_buf_queue` 中移除 `jbd_buf`。
3. 清除 `ext4_buf` 的 `end_write` 和 `end_write_arg` 字段。
4. 递增 `trans->written_cnt`。
5. **检查点推进**：当 `written_cnt == data_cnt`（事务所有数据已落盘），且此事务是 cp_queue 的首个事务时：
   - 推进 `journal->start` 指针（`start = start_iblock + alloc_blocks`）。
   - 推进 `journal->trans_id`。
   - 从 cp_queue 移除该事务并释放。
   - 调用 `jbd_journal_purge_cp_trans()` 继续清理下一个已完成事务。
   - 写回 journal superblock。

---

## 三、日志恢复（Recovery）流程

日志恢复在文件系统挂载时触发，用于**将已提交但未完全写入磁盘的事务重放到文件系统中**。

### 3.1 入口函数

函数：`jbd_recover()`（[ext4_journal.c:1315](src/ext4_journal.c#L1315)）

```c
int jbd_recover(struct jbd_fs *jbd_fs)
```

恢复过程分为**三趟扫描**，由 `jbd_iterate_log()` 以不同的 `action` 参数执行：

| 趟次 | action 值 | 目的 |
|------|-----------|------|
| 第一趟 | `ACTION_SCAN` (0) | 扫描日志，确定有效事务范围 |
| 第二趟 | `ACTION_REVOKE` (1) | 收集所有 revoke 条目，建立撤销树 |
| 第三趟 | `ACTION_RECOVER` (2) | 重放所有有效事务的数据块 |

### 3.2 第一趟：扫描

`jbd_iterate_log()` 从日志的 `start` 位置开始，逐块读取（[ext4_journal.c:1061](src/ext4_journal.c#L1061)）：

1. **验证 magic number**：检查每个块的头 4 字节是否为 `JBD_MAGIC_NUMBER (0xc03b3998)`。如果不是，说明已到达日志末尾。
2. **验证 sequence**：检查块的 sequence 号是否与期望的事务 ID 一致，不一致则认为日志结束。
3. **按类型处理**：
   - `JBD_DESCRIPTOR_BLOCK`：验证元数据校验和（`jbd_verify_meta_csum`），调试输出块标签信息。
   - `JBD_COMMIT_BLOCK`：验证提交校验和（`jbd_verify_commit_csum`）。这是一个事务的结束标志，递增 `this_trans_id`，递增事务计数 `info->trans_cnt`。
   - `JBD_REVOKE_BLOCK`：验证元数据校验和。
   - **default**：未知块类型，日志结束。
4. **回绕处理**：使用 `wrap()` 宏处理环形缓冲区边界。
5. **记录范围**：扫描结束后，记录 `info->start_trans_id`（起始事务 ID）和 `info->last_trans_id`（最后一个有效事务 ID）。

### 3.3 第二趟：收集撤销条目

再次遍历日志，对每个 `JBD_REVOKE_BLOCK`（[ext4_journal.c:999](src/ext4_journal.c#L999)）：

- 解析 revoke block 中的条目，每条记录长度为 4 字节（32bit）或 8 字节（64bit）。
- 调用 `jbd_add_revoke_block_tags()` 将每条 revoke 记录的 `(lba, trans_id)` 插入 `info->revoke_root` 红黑树:
  - 如果该 LBA 已存在，更新其 trans_id 为当前事务 ID（取较大的）。
  - 否则新建 revoke_entry 并插入。

**Revoke 的设计意义**：如果在事务 T 中某个块被 revoke，那么在恢复时，事务 T 及之前事务中对该块的修改都会被跳过。这用于处理块被删除后又被重新分配的场景——被删除的块的旧日志记录不应该被重放。

### 3.4 第三趟：重放

再次遍历日志，对每个 `JBD_DESCRIPTOR_BLOCK`，调用 `jbd_replay_descriptor_block()` → `jbd_iterate_block_table()` → `jbd_replay_block_tags()`。

`jbd_replay_block_tags()` 是重放的核心（[ext4_journal.c:824](src/ext4_journal.c#L824)）：

1. **递增块指针**：`(*this_block)++` 然后 `wrap()` 回绕。
2. **检查 revoke**：查找该块的 LBA 是否在 revoke 树中。如果在且当前事务 ID ≤ revoke 事务 ID（`trans_id_diff <= 0`），则跳过重放。
3. **读取日志块**：通过 `jbd_block_get()` 从日志区域读取对应的数据块（通过 journal inode 的块映射找到实际磁盘位置）。
4. **特殊处理超级块**：
   - 如果 `tag_info->block == 0`（目标 LBA 为 0，表示 ext4 超级块）：
     - 先从 `journal_block.data + EXT4_SUPERBLOCK_OFFSET` 恢复 `EXT4_SUPERBLOCK_SIZE` 大小的数据到 `fs->sb`。
     - 但保留原始的 `mount_count` 和 `state`（文件系统状态），因为这些是运行时信息。
   - 如果 `tag_info->block != 0`（普通块）：
     - 通过 `ext4_block_get_noread` 获取目标块。
     - `memcpy` 日志数据到目标块。
     - 标记 dirty 并写回（`ext4_block_set`）。
5. **Escape 处理**：如果块设置了 `JBD_FLAG_ESCAPE`，将头 4 字节恢复为 `JBD_MAGIC_NUMBER`（因为写入时被清零了，防止恢复时被误判为日志头部）。
6. **释放日志块**：调用 `jbd_block_set()` 释放日志块的引用。

### 3.5 恢复完成后的清理

```c
// ext4_journal.c:1341-1351
jbd_set32(&jbd_fs->sb, start, 0);                          // 清空日志起始位置
jbd_set32(&jbd_fs->sb, sequence, info.last_trans_id);       // 更新序列号
features_incompatible &= ~EXT4_FINCOM_RECOVER;               // 清除恢复标志
ext4_set32(&jbd_fs->inode_ref.fs->sb, features_incompatible, features_incompatible);
jbd_fs->dirty = true;
r = ext4_sb_write(jbd_fs->bdev, &jbd_fs->inode_ref.fs->sb); // 写回 ext4 超级块
jbd_destroy_revoke_tree(&info);                              // 释放 revoke 树内存
```

1. 清除 ext4 超级块的 `EXT4_FINCOM_RECOVER` 标志（表示文件系统已干净卸载）。
2. 将日志 `start` 设为 0，`sequence` 设为 `last_trans_id`。
3. 写回 ext4 超级块和 jbd 超级块。
4. 调用 `jbd_destroy_revoke_tree()` 释放 revoke 树中所有节点的内存。

---

## 四、日志会话生命周期

### 4.1 启动日志会话

函数：`jbd_journal_start()`（[ext4_journal.c:1375](src/ext4_journal.c#L1375)）

1. 在 ext4 超级块上设置 `EXT4_FINCOM_RECOVER` 标志（表示文件系统正在使用日志）。
2. 初始化日志指针：`first` = `start` = `last` = jbd_sb 中的 `first`。
3. 设置 `trans_id` = jbd_sb 中的 `sequence + 1`（使之前的日志记录失效）。
4. 初始化 cp_queue 和 block_rec_root。
5. 写回 jbd 超级块。

### 4.2 停止日志会话

函数：`jbd_journal_stop()`（[ext4_journal.c:1529](src/ext4_journal.c#L1529)）

1. 调用 `jbd_journal_purge_cp_trans(journal, true, false)` 刷新所有检查点事务。
2. 清除 ext4 超级块的 `EXT4_FINCOM_RECOVER` 标志。
3. 将日志 `start` 和 `trans_id` 清零。
4. 写回 ext4 和 jbd 超级块。

### 4.3 分配和释放事务

- **新建事务**：`jbd_journal_new_trans()` — 分配 `jbd_trans` 结构，初始化 buf_queue 和 revoke_root。
- **释放事务**：`jbd_journal_free_trans()` — 遍历 buf_queue，如果 abort = true 则回滚脏数据并清除 dirty 标志；清理所有 block_rec 和 revoke_rec。

---

## 五、架构总结图

```
                        +--------------------------+
                        |     ext4 文件系统操作      |
                        |  (dir/inode/balloc/...)  |
                        +------------+-------------+
                                     |
                                     v
                        +--------------------------+
                        |   ext4_trans.c (事务层)   |
                        |  set_block_dirty / revoke |
                        +------------+-------------+
                                     |
              +----------------------+----------------------+
              |                      v                      |
              |         +--------------------------+        |
              |         |   ext4_journal.c         |        |
              |         |                          |        |
              |    +----+----+              +------+------+ |
              |    |  记录    |              |    恢复      | |
              |    | (Commit) |              |  (Recover)  | |
              |    +----+----+              +------+------+ |
              |         |                          |        |
              |         v                          v        |
              |    +--------------------------------------+ |
              |    |      日志区域 (环形缓冲区)             | |
              |    |  [Desc][Data]...[Revoke]...[Commit]  | |
              |    |       ^ first    ^ start  ^ last      | |
              |    +--------------------------------------+ |
              |         |                          |        |
              |         v                          v        |
              |    +----------+             +----------+    |
              |    | 检查点队列 |             | 撤销树    |    |
              |    | cp_queue  |             | revoke   |    |
              |    +----+-----+             | root     |    |
              |         |                   +----------+    |
              |         v                                    |
              |    +----------+                               |
              |    | 磁盘写入  |                               |
              |    | (真实LBA) |                               |
              |    +----------+                               |
              +-----------------------------------------------+
```

---

## 六、关键设计特点

### 6.1 环形日志缓冲区

通过 `first`、`start`、`last` 三个指针管理日志区域：

- **first**：日志区域的物理起始位置（固定）。
- **start**：日志逻辑起始位置（随检查点推进而移动）。
- **last**：下一个可分配的日志块位置。

使用 `wrap()` 宏处理回绕：

```c
#define wrap(sb, var)                                           \
do {                                                            \
    if (var >= jbd_get32((sb), maxlen))                         \
        var -= (jbd_get32((sb), maxlen) - jbd_get32((sb), first)); \
} while (0)
```

### 6.2 检查点机制（Checkpoint）

事务提交后不立即释放日志空间，而是等真实数据落盘后才通过 `jbd_trans_end_write` 回调推进 `start` 指针。这保证了：

- 如果崩溃发生在数据写入磁盘之前，日志中有完整的事务记录可以恢复。
- 如果崩溃发生在数据写入磁盘之后但日志空间释放之前，恢复时重放也不会造成数据损坏（幂等性）。

### 6.3 撤销机制（Revoke）

支持对已删除块的撤销记录：

- 当事务需要删除一个块时（如 inode 删除、extent 收缩），通过 `jbd_trans_revoke_block()` 记录 revoke。
- 恢复时，被 revoke 的块的旧日志记录不会被重放，避免将已释放块的数据写回。
- `jbd_trans_try_revoke_block()` 检查该块是否还在某个检查点事务中，如果是则添加到 revoke 列表。

### 6.4 多级校验和

支持多种校验和方案：

| 方案 | 标志 | 覆盖范围 |
|------|------|----------|
| CRC32 v1 | `JBD_FEATURE_COMPAT_CHECKSUM` | 描述符块 + 数据块的 CRC32 |
| CRC32C v2 | `JBD_FEATURE_INCOMPAT_CSUM_V2` | 每个元数据块独立 CRC32C，标签中 16 位 |
| CRC32C v3 | `JBD_FEATURE_INCOMPAT_CSUM_V3` | 每个元数据块独立 CRC32C，标签中 32 位 |

校验和保护：
- **超级块**（`jbd_verify_sb_csum`）
- **描述符块和撤销块**（`jbd_verify_meta_csum`）
- **提交块**（`jbd_verify_commit_csum`）

所有 CRC32C 计算均以文件系统 UUID 作为初始输入。

### 6.5 Escape 机制

由于 JBD 使用 `JBD_MAGIC_NUMBER (0xc03b3998)` 来识别日志块头部，如果**普通数据块的前 4 字节恰好等于这个值**，恢复时会误判。

处理方法：
- **写入时**：检测到数据前 4 字节 == `JBD_MAGIC_NUMBER`，将其清零，并在 block_tag 中设置 `JBD_FLAG_ESCAPE`。
- **恢复时**：如果 block_tag 中有 `JBD_FLAG_ESCAPE`，将目标块的前 4 字节恢复为 `JBD_MAGIC_NUMBER`。

### 6.6 事务 ID 比较

由于事务 ID 是 32 位无符号整数，存在回绕可能，使用有符号差值比较：

```c
static inline int32_t trans_id_diff(uint32_t x, uint32_t y)
{
    int32_t diff = x - y;
    return diff;
}
```

---

## 七、校验和计算流程

### 7.1 超级块校验和 (`jbd_sb_csum`)

```
checksum = crc32c(INIT, 整个 jbd_sb 结构体, JBD_SUPERBLOCK_SIZE)
（计算前临时将 checksum 字段清零）
```

### 7.2 元数据块校验和 (`jbd_meta_csum`)

用于描述符块和撤销块：

```
checksum = crc32c(INIT, fs_uuid, UUID_SIZE)
checksum = crc32c(checksum, 整个块数据, block_size)
（计算前临时清零 block_tail.checksum）
```

### 7.3 提交块校验和 (`jbd_commit_csum`)

```
checksum = crc32c(INIT, fs_uuid, UUID_SIZE)
checksum = crc32c(checksum, 整个 commit_header 块, block_size)
```

### 7.4 数据块校验和 (`jbd_block_csum`)

```
checksum = crc32c(INIT, fs_uuid, UUID_SIZE)
checksum = crc32c(checksum, &sequence, sizeof(uint32_t))
checksum = crc32c(checksum, 块数据, block_size)
```