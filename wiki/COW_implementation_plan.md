# lwext4 文件级 COW（写时复制）实现计划

## 背景

当前 lwext4 写入文件时是**原地修改**——数据直接写入已有的物理块。如果系统在写入中途崩溃或掉电，文件数据处于不一致状态（半新半旧）。

**目标**：对当前打开写入的文件实现 COW——写入已有数据块时先复制到新块再写入，原块保留。文件正常关闭时释放旧块（提交），异常时保留旧块。快照仅在文件打开期间存在，关闭即删除。

**核心思路**：
```
打开文件(写模式) → 初始化 COW 状态
写入已有块     → COW：分配新块 → 复制原数据 → 写新数据到新块 → 更新映射
写入新块(扩展) → 直接分配新块（无需 COW）
正常关闭       → 释放旧块（提交）
```

## 总体架构

COW 状态**挂载在文件句柄 `ext4_file` 中**，每个打开的文件独立持有。核心拦截点在 `src/ext4.c` 的 `ext4_fwrite()` 函数中——在拿到物理块号后、写入数据前进行 COW 检查。

### 写入路径变化

```
dfs_ext_write()
  → ext4_fwrite()                              [src/ext4.c]
    → ext4_fs_get_inode_dblk_idx()              [src/ext4_fs.c]
      → ext4_extent_get_blocks(create=true)     [src/ext4_extent.c]
        返回物理块号 fblock
    → [COW 检查] 如果块已存在 AND 文件有 COW 状态：
        → 查 COW 映射表：(逻辑块 → 旧块, 新块)
        → 如果已 COW：使用已有新块
        → 如果未 COW：
            → ext4_balloc_alloc_block() 分配新块
            → 读旧块数据 → 写到新块
            → 更新 extent 树指向新块
            → 记录映射
        → 返回新块
    → 写入数据到 fblock
```

## 新建文件

### 1. `include/ext4_cow.h` — COW 头文件

```c
#ifndef EXT4_COW_H_
#define EXT4_COW_H_

#include <ext4_config.h>
#include <ext4_types.h>
#include <ext4_fs.h>

#if CONFIG_COW_ENABLE

/* 单个 COW 块映射条目 */
struct ext4_cow_entry {
    ext4_lblk_t  logical_block;   /* 文件内逻辑块号 */
    ext4_fsblk_t old_block;       /* 原始物理块号 */
    ext4_fsblk_t new_block;       /* COW 新物理块号 */
};

/* 每个文件的 COW 状态 */
struct ext4_cow_file_state {
    bool     active;              /* 是否启用 COW */
    uint32_t entry_count;         /* 当前映射条目数 */
    uint32_t entry_capacity;      /* 映射数组容量 */
    struct ext4_cow_entry *entries; /* 动态数组 */
};

int  ext4_cow_file_init(struct ext4_cow_file_state **state, uint32_t initial_cap);
void ext4_cow_file_fini(struct ext4_cow_file_state *state);
int  ext4_cow_check_and_copy(struct ext4_inode_ref *inode_ref,
                              struct ext4_cow_file_state *state,
                              ext4_lblk_t iblock, ext4_fsblk_t *fblock);
int  ext4_cow_commit(struct ext4_inode_ref *inode_ref,
                      struct ext4_cow_file_state *state);
int  ext4_cow_rollback(struct ext4_inode_ref *inode_ref,
                        struct ext4_cow_file_state *state);

#endif /* CONFIG_COW_ENABLE */
#endif /* EXT4_COW_H_ */
```

### 2. `src/ext4_cow.c` — COW 核心实现

#### `ext4_cow_file_init()`
- 分配 `ext4_cow_file_state` 结构体
- 分配初始容量的 entries 数组（默认 8 条目）
- active = true

#### `ext4_cow_file_fini()`
- 释放 entries 数组和 state 结构体

#### `ext4_cow_check_and_copy()` — 核心函数
```
输入：inode_ref, state, iblock, *fblock (in/out)
1. 遍历 state->entries，查找 logical_block == iblock
2. 找到 → *fblock = entry->new_block，返回 OK（已 COW）
3. 未找到 → 执行 COW：
   a. ext4_balloc_alloc_block() 分配 new_block
   b. ext4_block_readbytes() 读旧块数据
   c. ext4_block_writebytes() 写旧数据到新块
   d. 更新 extent 树：修改 iblock 对应 extent 指向 new_block
   e. 扩展 entries 数组，添加 {iblock, *fblock, new_block}
   f. *fblock = new_block
4. 返回 OK
```

#### `ext4_cow_commit()` — 正常关闭提交
```
遍历 entries → ext4_balloc_free_block(old_block) → fini()
```

#### `ext4_cow_rollback()` — 回滚
```
遍历 entries → 恢复 extent 指向 old_block → ext4_balloc_free_block(new_block) → fini()
```

## 需修改的文件

### 1. `include/ext4_config.h`
```c
#ifndef CONFIG_COW_ENABLE
#define CONFIG_COW_ENABLE 0
#endif
#ifndef CONFIG_COW_INITIAL_CAPACITY
#define CONFIG_COW_INITIAL_CAPACITY 8
#endif
```

### 2. `include/ext4.h` — 修改 `ext4_file`
```c
typedef struct ext4_file {
    struct ext4_mountpoint *mp;
    uint32_t inode;
    uint32_t flags;
    uint64_t fsize;
    uint64_t fpos;
#if CONFIG_COW_ENABLE
    struct ext4_cow_file_state *cow_state;
#endif
} ext4_file;
```

### 3. `src/ext4.c`

- **`ext4_fopen2()`**：如果 flags 包含 `O_RDWR` 或 `O_WRONLY`，调用 `ext4_cow_file_init(&file->cow_state, ...)`
- **`ext4_fwrite()`**：在 `ext4_fs_init_inode_dblk_idx()` 返回已有块的物理地址后，调用 `ext4_cow_check_and_copy()`
- **`ext4_fclose()`**：调用 `ext4_cow_commit()` 提交，释放旧块
- 新增 `ext4_fclose_rollback()`：回滚并关闭

### 4. `src/ext4_fs.c`
无直接修改，但 `ext4_fs_truncate_inode()` 释放块时需注意 COW 状态。

### 5. `ports/rtthread/dfs_ext.c`
- **`dfs_ext_open()`**：COW 初始化（透传到 ext4 层）
- **`dfs_ext_close()`**：COW 提交
- **`dfs_ext_ioctl()`**：添加回滚命令

### 6. `SConscript`
添加 `src/ext4_cow.c`

## 关键设计点

### COW 触发条件
| 场景 | 是否 COW | 原因 |
|------|----------|------|
| 写入已存在的文件数据块 | **是** | 需要保留旧数据 |
| 追加写入（文件扩展，新块） | 否 | 新块不存在旧数据 |
| 覆盖之前已 COW 过的块 | 否（直接用 COW 块） | 无需重复 COW |

### 块计数
`ext4_balloc_alloc_block()` 会自动增加 inode 的 `blocks_count`。COW 时旧块未释放，需要手动将 `blocks_count` 减去 `block_size/512`，避免重复计数。

### 内存
entries 数组初始 8 条目，动态翻倍扩展。每条目 ~24 字节，100 条目仅 ~2.4KB。

## 实现阶段

### 阶段一：基础结构
1. `ext4_config.h`：添加 `CONFIG_COW_ENABLE`
2. `include/ext4_cow.h`：数据结构 + API 声明
3. `ext4_file`：添加 `cow_state` 字段
4. `src/ext4_cow.c`：实现 init/fini

### 阶段二：核心 COW
5. 实现 `ext4_cow_check_and_copy()`
6. 实现 `ext4_cow_commit()`
7. 实现 `ext4_cow_rollback()`

### 阶段三：写入路径集成
8. `ext4_fopen2()`：初始化 COW
9. `ext4_fwrite()`：拦截写入
10. `ext4_fclose()`：提交 COW

### 阶段四：RT-Thread 集成
11. `dfs_ext.c`：透传 COW 生命周期
12. 更新编译配置

## 验证

1. **基本流程**：打开文件 → 写入 → 关闭 → 验证数据正确、旧块已释放
2. **回滚测试**：打开文件 → 写入 → rollback → 验证文件保持原样
3. **崩溃模拟**：写入过程中复位 → 验证文件保持写入前状态（旧块未释放）
4. **追加写入**：验证文件扩展不触发 COW
5. **同一块多次写入**：验证不重复 COW
6. **空间不足**：验证 COW 失败时文件保持一致
