# ext4 DFS 读写缓冲区设计

> 实现文件：[`ports/rtthread/dfs_ext.c`](../ports/rtthread/dfs_ext.c)

---

## 1. 缓存设计规则

### 1.1 核心原则

| 规则 | 说明 |
|------|------|
| **写合并** | 小写入优先进入缓冲区，连续追加可合并为一次磁盘写入 |
| **读预取** | 每次磁盘读取 4KB 到缓冲区，后续小读从缓冲区零拷贝命中 |
| **写穿透 (大 I/O)** | ≥ 4KB 的写入绕过缓冲区直接写盘，避免无用拷贝 |
| **读己写一致性** | 读操作优先检查脏缓冲，脏数据范围内的读取直接从缓冲区返回 |
| **惰性刷盘** | 脏缓冲延迟刷盘，直到缓冲满、不连续写入、lseek 跳离、flush 或 close |
| **回退路径** | 若 `rt_malloc` 失败（`rw_buffer == NULL`），退化为原始直接 I/O 路径 |

### 1.2 缓冲区状态模型

```
                        ┌──────────────────┐
         ext4_fread     │   rw_buf_dirty=0  │
      ┌───────────────→ │   干净缓冲（读）   │
      │                 └────────┬─────────┘
      │                          │ 小写入
      │                          │ (rw_buf_dirty=1)
      │                 ┌────────▼─────────┐
      │                 │   rw_buf_dirty=1  │──── ext4_fwrite ──→ 磁盘
      │                 │   脏缓冲（写）     │    (刷盘后清零)
      │                 └──────────────────┘
      │                          │
      │         读命中（脏缓冲内）│         读未命中 / 写不连续 / lseek跳离
      │         直接返回缓冲数据  │         先刷盘再操作
      │                          │
      └──────────────────────────┘
```

### 1.3 缓冲区有效性判断

```c
// 读命中条件：请求位置在 [buf_pos, buf_pos + buf_len) 范围内
pos >= rw_buf_pos && pos < rw_buf_pos + rw_buf_len

// 写追加条件：脏缓冲非满 && 请求位置紧邻缓冲末尾
rw_buf_dirty && rw_buf_len < EXT4_RW_BUFFER_SIZE
    && pos == rw_buf_pos + rw_buf_len
```

---

## 2. 数据结构与生命周期

### 2.1 结构体定义

```c
#define EXT4_RW_BUFFER_SIZE  4096   // 可通过编译时 -D 覆盖

struct dfs_ext4_file
{
    uint32_t type;                   // EXT4_DE_DIR 或 EXT4_DE_REG_FILE
    union { ext4_file file; ext4_dir dir; } entry;
    struct dfs_ext4_vnode vnode;

    /* 读写缓存 */
    uint8_t *rw_buffer;              // 动态分配，失败时为 NULL
    off_t    rw_buf_pos;             // 缓冲区在文件中的起始偏移
    size_t   rw_buf_len;             // 有效数据长度
    int      rw_buf_dirty;           // 是否有未刷盘的脏数据
};
```

### 2.2 内存管理

```
dfs_ext_open (打开文件)
  │
  ├─ 常规文件 (FT_REGULAR)
  │     rw_buffer = rt_malloc(EXT4_RW_BUFFER_SIZE)
  │     成功 → 初始化 rw_buf_pos=0, rw_buf_len=0, rw_buf_dirty=0
  │     失败 → rw_buffer = NULL (回退到直接 I/O)
  │
  ├─ 目录 (FT_DIRECTORY)
  │     不分配缓冲区 (目录操作不需要)
  │
  └─ 重新打开 (type != EXT4_DE_UNKNOWN)
        常规文件: 共享已有缓冲区 (如果是 NULL 则尝试分配)
        目录:    新副本 (rt_calloc, rw_buffer 为 NULL)


dfs_ext_close (关闭文件)
  │
  ├─ ref_count > 1  → 立即返回 (还有其他句柄在使用)
  │
  └─ ref_count == 1 (最后一个句柄)
        rw_buf_dirty? → 先 ext4_fwrite 刷盘
        rt_free(rw_buffer)
        rw_buffer = NULL
```

---

## 3. 读缓冲设计

### 3.1 流程

```
dfs_ext_read(file, buf, count, &pos)
  │
  ├─ rw_buffer == NULL? ──→ 回退：ext4_fread 直接读
  │
  └─ rw_buffer != NULL? ──→ 缓冲读：
        │
        while (count > 0 && pos < vnode->size)
        {
          if (缓冲命中) {
            memcpy(buf, rw_buffer + (pos - rw_buf_pos), chunk);
            pos += chunk; count -= chunk;
          } else {
            if (脏) { flush_dirty(); }     // 先刷脏
            ext4_fread(rw_buffer, 4096);    // 填充 4KB
            if (读失败 || 读到0字节) break;
          }
        }
```

### 3.2 关键行为

| 场景 | 行为 | 磁盘 I/O |
|------|------|----------|
| 首次读 pos=0, 100B | 读 4KB 到缓冲，拷贝 100B | 1 次读 |
| 紧接着读 pos=100, 200B | 缓冲命中，直接拷贝 | 0 |
| 紧接着读 pos=5000, 100B | 缓冲未命中，重新读 4KB | 1 次读 |
| 读位置在脏缓冲内 | 直接从脏缓冲返回（读己写） | 0 |
| 读位置不在脏缓冲内 | 先刷脏缓冲，再读 4KB | 1 写 + 1 读 |

---

## 4. 写缓冲设计

### 4.1 流程

```
dfs_ext_write(file, buf, count, &pos)
  │
  ├─ rw_buffer == NULL? ──→ 回退：ext4_fwrite 直接写
  │
  └─ rw_buffer != NULL? ──→ 缓冲写：
        │
        while (count > 0)
        {
          if (脏 && 有空间 && pos == rw_buf_pos + rw_buf_len)
          {
            // 连续追加 — 合并写入
            memcpy(rw_buffer + rw_buf_len, src, chunk);
            rw_buf_len += chunk;
            if (缓冲满) flush_buffer();
          }
          else
          {
            if (脏) flush_buffer();           // 不连续 — 先刷旧缓冲

            if (count >= 4096)
              ext4_fwrite(direct, count);     // 大写入 — 绕过缓冲
            else
              memcpy(rw_buffer, src, count);  // 小写入 — 新建缓冲
          }
        }
        if (pos > vnode->size) vnode->size = pos;  // 更新文件大小
```

### 4.2 关键行为

| 场景 | 行为 | 磁盘 I/O |
|------|------|----------|
| 连续 64 次写入各 64B | 全部合并到 4KB 缓冲，满时刷 1 次 | 1 次写 |
| 写入 5000B 大块 | 绕过缓冲，直接写盘 | 1 次写 |
| pos=0 写 100B → pos=50 写 50B | 先刷 pos=0..99, 再缓冲 pos=50..99 | 1 次写 |
| pos=0 写 100B → pos=100 写 50B | 追加到同一缓冲 | 0 |
| 缓冲分配失败 | 回退到直接 ext4_fwrite | 每次 1 写 |

---

## 5. 刷盘路径汇总

脏数据在以下 7 个时机被写入磁盘：

```
┌─────────────────────────┬──────────────────────┬────────────────────────────┐
│ 触发场景                 │ 函数                  │ 触发条件                    │
├─────────────────────────┼──────────────────────┼────────────────────────────┤
│ ① 缓冲写满              │ dfs_ext_write        │ rw_buf_len >= 4096         │
│ ② 写入位置不连续        │ dfs_ext_write        │ pos ≠ rw_buf_pos+buf_len  │
│ ③ 读未命中时有脏        │ dfs_ext_read         │ 读前检测到 rw_buf_dirty    │
│ ④ lseek 跳离脏缓冲      │ dfs_ext_lseek        │ ret < buf_pos || ret > end│
│ ⑤ 显式 flush / fsync   │ dfs_ext_flush        │ 用户调用                   │
│ ⑥ 文件关闭              │ dfs_ext_close        │ ref_count == 1            │
└─────────────────────────┴──────────────────────┴────────────────────────────┘
```

---

## 6. lseek 处理

### 6.1 设计目标

lseek 改变文件位置时，若跳出了脏缓冲的范围，**立即刷盘**。这确保即使应用在 seek 后崩溃，已写入的数据也不会丢失。

### 6.2 判断条件

```
新位置 ret 满足:  ret < rw_buf_pos  或  ret > rw_buf_pos + rw_buf_len
                                        ↓
                                   跳出脏缓冲范围
                                        ↓
                                   ext4_fwrite 刷盘
                                   rw_buf_dirty = 0
```

### 6.3 场景覆盖

```
缓冲:   [rw_buf_pos ─────────── buf_end]
位置:   ↑              ↑              ↑
       seek到这里     seek到这里    seek到这里
       刷盘 ✅        不刷盘          不刷盘
                     (下次写自动     (可追加,
                     先刷再覆盖)     连续写优化)
```

| 场景 | 操作序列 | 刷盘? | 原因 |
|------|---------|-------|------|
| 随机跳转 | write(0,100) → lseek(5000) | ✅ 刷 | 5000 > 100，跳离缓冲 |
| 覆盖写 | write(0,100) → lseek(50) | ❌ 不刷 | 50 在 [0, 100) 内 |
| 连续追加 | write(0,100) → lseek(100) | ❌ 不刷 | 100 紧邻缓冲末尾 |
| 纯读后 seek | read(0,100) → lseek(2000) | ❌ 不刷 | 无脏数据 |
| SEEK_END | write(0,100) → lseek(0, SEEK_END) | ❌ 不刷 | 返回 100，在缓冲末尾 |

### 6.4 刷盘失败处理

若 `ext4_fwrite` 失败，保留 `rw_buf_dirty` 标记和 `rw_buf_len`，fpos 仍设为 seek 目标。下次写/读/close 会重试刷盘。

---

## 7. 多句柄读同一文件

### 7.1 共享模型

```
进程 A: fd1 = open("/file", O_RDONLY)
进程 B: fd2 = open("/file", O_RDONLY)

          ┌─────────────────────────┐
          │    struct dfs_vnode     │  ← vnode 唯一，被两个 dentry 共享
          │    .lock  (互斥锁)      │
          │    .data ───────────┐   │
          └─────────────────────│───┘
                                │
          ┌─────────────────────▼───┐
          │ struct dfs_ext4_file    │  ← ext_file 唯一
          │   .entry.file           │     共享 ext4_file 状态
          │   .rw_buffer ──→ [4KB]  │     共享缓冲区 (仅一块!)
          │   .rw_buf_pos           │
          │   .rw_buf_len           │
          │   .rw_buf_dirty         │
          └─────────────────────────┘
                ↑           ↑
    file->data──┘           └──file->data
    fd1.fpos = 0            fd2.fpos = 0    ← fpos 各自独立
```

> **关键约束**：所有句柄共享**唯一**一块 4KB 缓冲区。这意味着任一句柄的读操作都会改写 `rw_buf_pos` 和 `rw_buf_len`，影响所有其他句柄。

### 7.2 同区域读（最优场景）

两个句柄读取位置接近时，缓冲区有效复用：

```
fd1 read(pos=0,    100B) → 缓冲 miss → 读 4KB (pos=0..4095)
fd2 read(pos=0,     50B) → 缓冲 hit!  直接从 buf[0..49] 拷贝
fd1 read(pos=100,  200B) → 缓冲 hit!  直接从 buf[100..299] 拷贝
fd2 read(pos=300,  100B) → 缓冲 hit!  直接从 buf[300..399] 拷贝

磁盘 I/O: 1 次 (fd1 首次预读)
缓冲区利用率: 高
```

### 7.3 异区域读——缓冲乒乓问题

当两个句柄读取位置差异过大时，共享缓冲频繁失效：

```
fd1 read(pos=0,      100B) → 缓冲 miss → 读 4KB  (pos=0..4095)
fd2 read(pos=100000,  50B) → 缓冲 miss → 读 4KB  (pos=100000..104095)
                               ↑ fd1 的 4KB 预读被整体丢弃!
fd1 read(pos=4096,   100B) → 缓冲 miss → 读 4KB  (pos=4096..8191)
                               ↑ fd2 的 4KB 预读被整体丢弃!
fd2 read(pos=104096,  50B) → 缓冲 miss → 读 4KB  (pos=104096..108191)
                               ↑ fd1 的预读又被丢弃!

...无限循环，每次读都 miss
```

```
磁盘 I/O 对比:

          无缓冲 (原始)                    有缓冲 (当前)
fd1:      ext4_fread(100B)               ext4_fread(4096B)
fd2:      ext4_fread(50B)                ext4_fread(4096B)
fd1:      ext4_fread(100B)               ext4_fread(4096B)
fd2:      ext4_fread(50B)                ext4_fread(4096B)
          ────────────────                ─────────────────
总读取:   300B 磁盘                       16384B 磁盘 (54× 放大!)
```

### 7.4 问题根因

```
句柄 A                    句柄 B
  │                         │
  ├─ read(pos=0)            │
  │   填充 buf[0..4095]     │
  │                         ├─ read(pos=100000)
  │                         │   填充 buf[100000..104095]
  │                         │   ↳ buf_pos 从 0 变为 100000
  │                         │
  ├─ read(pos=4096)         │
  │   检查: pos=4096,       │
  │   buf_pos=100000        │  ← 被句柄 B 改了!
  │   4096 < 100000 → miss  │
  │   重新读 4KB            │
  │                         │
  │                         ├─ read(pos=104096)
  │                         │   检查: pos=104096,
  │                         │   buf_pos=4096  ← 又被句柄 A 改了!
  │                         │   104096 > 8191 → miss
  │                         │   重新读 4KB
  ...                       ...
```

**根因**：两个句柄共享 `rw_buf_pos`/`rw_buf_len`，任一句柄的磁盘读取都会覆盖这些状态，使另一个句柄的位置信息失效。而每个句柄的 `file->fpos` 虽然独立，但缓冲命中检查依赖的是**共享**的 `rw_buf_pos`。

### 7.5 当前缓解措施

| 手段 | 效果 | 局限 |
|------|------|------|
| `vnode->lock` 串行化 | 防止并发竞态，同一时刻只有一个句柄操作缓冲 | 无法阻止交替访问造成的乒乓效应 |
| 缓冲命中优先 | 同区域内读可以复用 | 异区域读无帮助 |
| ext4 块缓存 | ext4 层自身有块缓存，重复读同一块不会真正读盘 | 仅对已缓存块有效，冷数据仍需读盘 |

实际上，**ext4 层自身的块缓存**（block cache）可以缓解部分问题：当两个句柄读取的位置落在 ext4 已缓存的块内时，`ext4_fread` 直接从块缓存返回，不会真正访问磁盘。但 DFS 层的 4KB `memcpy` 开销和函数调用开销依然存在。

### 7.6 何时成为问题

| 场景 | 是否触发乒乓 | 影响 |
|------|-------------|------|
| 两个句柄顺序读同一大文件的不同段 | ✅ 触发 | 严重：每次 4KB 读盘，大部分被丢弃 |
| 两个句柄随机访问同一文件 | ✅ 触发 | 中等：取决于访问模式 |
| 两个句柄都在文件开头附近读 | ❌ 不触发 | 缓冲命中率高 |
| 单句柄读（最常见场景） | ❌ 不触发 | 缓冲有效 |
| 两个句柄但 ext4 块缓存已覆盖热点 | ⚠️ 部分 | 无物理磁盘 I/O，但有 memcpy 开销 |

### 7.7 改进方向

#### 方案 A：按句柄分配缓冲

```
将 rw_buffer 从 dfs_ext4_file (per-vnode) 移到 dfs_file (per-handle)

fd1 → rw_buffer_1 [4KB]     // 句柄 1 独立缓冲
fd2 → rw_buffer_2 [4KB]     // 句柄 2 独立缓冲
```

| 优点 | 缺点 |
|------|------|
| 彻底消除乒乓问题 | 内存翻倍 (N 个句柄 × 4KB) |
| 每个句柄的缓冲完全独立 | 写合并失效（多个写句柄各写各的缓冲） |
| 实现简单，改动聚焦 | 需要变更数据结构归属 |

#### 方案 B：读缓冲按句柄，写缓冲共享

```
dfs_ext4_file (per-vnode):
  rw_buffer_write  [4KB]    // 写缓冲共享（保持写合并）

dfs_file (per-handle):
  rw_buffer_read   [4KB]    // 读缓冲独立（避免乒乓）
```

| 优点 | 缺点 |
|------|------|
| 读乒乓和写合并同时解决 | 内存增加 (1 + N) × 4KB |
| 读写分明 | 实现复杂，struct 改动大 |

#### 方案 C：自适应降级——检测低命中率

```
在 dfs_ext4_file 中增加统计:
  buf_hit_count, buf_miss_count

当 miss_rate > 阈值 (如 75%) 且 ref_count > 1:
  → 禁用缓冲读，回退到直接 ext4_fread
```

| 优点 | 缺点 |
|------|------|
| 无额外内存开销 | 需要采样周期，检测有滞后 |
| 自动适应访问模式 | 增加少量计数逻辑 |
| 对现有结构改动最小 | 阈值选择需要调优 |

#### 方案 D：接受限制（当前实现）

当前实现选择了方案 D：优先保证**单句柄顺序访问**这一最常见场景的性能，多句柄异区域读的场景依赖 ext4 层块缓存兜底。

选择理由：
- 嵌入式场景中多句柄读同一文件且位置差异大的情况罕见
- ext4 块缓存已提供一层保护
- 零额外内存和复杂度开销

---

## 8. 多句柄写同一文件

### 8.1 共享模型

```
进程 A: fd1 = open("/file", O_WRONLY)
进程 B: fd2 = open("/file", O_WRONLY)

          ┌─────────────────────────┐
          │ struct dfs_ext4_file    │  ← 两个句柄共享同一个 ext_file
          │   rw_buffer ──→ [4KB]  │     共享同一个写缓冲
          └─────────────────────────┘
                ↑           ↑
              fd1          fd2
```

### 8.2 连续写入场景（协作合并）

```
fd1 write(pos=0,   100B)  → rw_buf_pos=0,   len=100, dirty=1
fd2 write(pos=100,  50B)  → 追加: len=150           (命中追加条件)
fd1 write(pos=150,  30B)  → 追加: len=180           (命中追加条件)
fd2 write(pos=180, 200B)  → 追加: len=380
...
fd1 write(pos=4080, 16B)  → 缓冲满! flush 4096B      (触发刷盘)
```

两个句柄交替写入，数据无缝合并到同一个缓冲区，最终 **N 次小写合并为 1 次磁盘写入**。

### 8.3 不连续写入场景

```
fd1 write(pos=0, 100B)    → buf: pos=0, len=100, dirty
fd2 write(pos=5000, 50B)  → pos(5000) ≠ buf_pos+len(100)
                          → 先 flush buf(0..99) 到磁盘
                          → 新建 buf: pos=5000, len=50, dirty
```

### 8.4 注意事项

- **文件大小更新**：缓冲写不立即更新磁盘上的 i_size，仅在 `*pos > vnode->size` 时更新内存中的 `vnode->size`
- **文件打开模式**：所有句柄共享 `ext_file->entry.file.flags`（取首次打开时的模式）。若第一个句柄以 `O_RDONLY` 打开，后续 `O_WRONLY` 句柄写入时 `ext4_fwrite` 可能因权限检查失败
- **互斥锁**：所有操作通过 `vnode->lock` 串行化，不会出现缓冲竞争

---

## 9. 读写句柄并存 (RDWR)

### 9.1 单句柄 O_RDWR

```
fd = open("/file", O_RDWR)

fd write(pos=0, 100B) → buf: pos=0, len=100, dirty
fd read(pos=0, 100B)  → 脏缓冲命中! 直接返回缓冲数据 (读己写一致性)
fd read(pos=50, 20B)  → 脏缓冲命中! 返回 buf[50..69]
fd write(pos=100, 20B) → 追加: len=120
fd read(pos=100, 20B) → 脏缓冲命中! (刚追加的数据)
```

**核心保证**：对同一位置的写入立即可读，即使数据尚未刷盘。

### 9.2 读写交替（缓冲回绕）

```
fd write(pos=0,    100B)  → buf: pos=0,   len=100, dirty
fd read(pos=4096,   50B)  → 读未命中，且脏缓冲在 [0,100)
                          → 先 flush buf 到磁盘
                          → 然后读 4KB: buf: pos=4096, len=4096, clean
fd read(pos=0,      50B)  → 读未命中 (buf 在 4096..8192)
                          → buf 干净，直接读: buf: pos=0, len=4096, clean
```

### 9.3 读写句柄并存（两个独立句柄共享同一缓冲）

```
fd1 = open("/file", O_RDONLY)
fd2 = open("/file", O_WRONLY)

fd1 read(pos=0, 4KB)   → 填充缓冲: pos=0, len=4096, clean
fd2 write(pos=100, 20B) → 写追加条件失败 (dirty=0)
                        → 小写入: buf[pos=100..119] 被覆盖, dirty=1
                        → ⚠️ 原来 buf[0..99] 和 buf[120..4095] 的数据仍在缓冲中

fd1 read(pos=0, 50B)   → 脏缓冲命中! 返回 buf[0..49]
                        → 包含未被 fd2 覆盖的部分 (正确)

fd2 write(pos=5000, 10B) → 不连续 → flush buf(pos=100,len=20) 到磁盘
                          → ⚠️ 只写了 20B！未修改的 buf 区域不写盘
                          → 新建 buf: pos=5000, len=10, dirty
```

> **注意**：两个句柄共享 `ext_file->entry.file.flags`。若 fd1 先以 `O_RDONLY` 打开，则 `flags` 为 `O_RDONLY`。fd2 的写入调用 `ext4_fwrite` 时可能在 ext4 层被拒绝。

---

## 10. 线程安全

### 10.1 锁层级

```
vnode->lock (DFS 层互斥锁 — rt_mutex)
    │
    ├─ dfs_ext_read    ─── 持锁
    ├─ dfs_ext_write   ─── 持锁
    ├─ dfs_ext_lseek   ─── 持锁 (递归获取，因调用者已持锁)
    ├─ dfs_ext_flush   ─── 持锁 (缓冲刷盘时)
    ├─ dfs_ext_close   ─── 不持锁 (ref_count 保证独占)
    │
    └─ ext4 全局锁 (ext4_lock_ops → ext4_mutex)
         └─ ext4_fread / ext4_fwrite 内部持有
```

### 10.2 ref_count 保护

```
open("/file")   → ref_count++
open("/file")   → ref_count++
close(fd1)      → ref_count--  (仍 >1, 不刷盘不释放)
close(fd2)      → ref_count--  (==1, 刷盘 + 释放缓冲区 + ext4_fclose)
```

- 缓冲区的生命周期与 vnode 绑定，而非与单个句柄绑定
- 最后一个句柄关闭时才释放缓冲区，防止 use-after-free

### 10.3 竞态分析

| 竞态场景 | 保护机制 |
|----------|---------|
| 两个读句柄同时读 | vnode->lock 串行化，缓冲命中只是 memcpy |
| 两个写句柄同时写 | vnode->lock 串行化，缓冲状态一致 |
| 读 + 写同时 | vnode->lock 串行化，先到先服务 |
| 写中途 close | ref_count 确保最后一个 close 才释放 |
| lseek + read/write 并发 | 均在 vnode->lock 保护下 |

---

## 11. 与 RT_USING_PAGECACHE 的关系

本缓冲区设计**独立于** `RT_USING_PAGECACHE` 宏，无论是否启用页缓存均可正常工作。

- **不启用页缓存**（默认场景）：`dfs_ext_read`/`dfs_ext_write` 直接使用 4KB 缓冲，减少 ext4 层调用次数
- **启用页缓存**：页缓存层 (`dfs_pcache`) 位于 4KB 缓冲之上，双层缓存并存。页缓存写绕过 4KB 写缓冲（直接调用 `ext4_fwrite`），写前会先刷脏缓冲保证数据一致性

> 本设计文档以**不启用页缓存**为基准场景描述。启用页缓存的完整分析见代码注释。

---

## 12. 错误处理

### 12.1 内存分配失败

```
rt_malloc(4096) 失败
  → rw_buffer = NULL
  → 读写函数走回退路径（直接 ext4_fread/ext4_fwrite）
  → 功能不受影响，仅性能退化
```

### 12.2 磁盘 I/O 失败

| 失败点 | 行为 |
|--------|------|
| 读缓冲填充时 `ext4_fread` 失败 | `break` 退出循环，返回已读字节数 |
| 写缓冲刷盘时 `ext4_fwrite` 失败 | `goto write_out`，返回 0（或已写字节数），保留脏标记 |
| lseek 中刷盘失败 | 保留 `rw_buf_dirty`，下次操作重试 |
| flush 刷盘失败 | 立即返回错误码，保留脏标记 |

### 12.3 截断处理

```
ftruncate(offset)
  → ext4_ftruncate
  → rw_buf_len = 0; rw_buf_dirty = 0   // 废弃缓冲
```

截断后缓冲内容无效（可能包含超出新文件大小的数据），直接清空。

---

## 13. 性能模型

### 13.1 小顺序写入

```
64 次 64B 写入 (共 4096B)

无缓冲:  64 × ext4_fwrite → 64 次锁获取 → 64 次块缓存操作
有缓冲:  1  × ext4_fwrite → 1  次锁获取 → 1  次块缓存操作

合并比: 64:1
```

### 13.2 小顺序读取

```
32 次 128B 读取 (共 4096B)

无缓冲:  32 × ext4_fread → 32 次锁获取
有缓冲:  1  × ext4_fread (首次 4KB 预读) + 31 × memcpy (缓冲命中)

磁盘 I/O 减少: 97%
```

### 13.3 折衷

| 方面 | 收益 | 代价 |
|------|------|------|
| CPU | 减少函数调用和锁操作 | 小量 memcpy 开销 |
| 内存 | — | 每个打开的文件 4KB |
| 延迟 | 缓冲命中几乎零延迟 | lseek 跳离时额外刷盘 |
| 数据安全 | close/flush/lseek 时自动刷盘 | 崩溃可能丢失未刷盘的脏数据 |
