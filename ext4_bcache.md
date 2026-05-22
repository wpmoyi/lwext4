# `ext4_bcache` / `ext4_buf` 技术分析

> 分析范围：`include/ext4_bcache.h`、`src/ext4_bcache.c`，以及与块缓存直接交互的 `src/ext4_blockdev.c`、`src/ext4.c`、`include/ext4_blockdev.h`、`include/ext4_mp.h`、`ports/rtthread/*` 和典型元数据访问模块。  
> 说明：当前源码中没有名为 `ext4_bcache_shake` 的函数；实际承担缓存淘汰职责的是 `src/ext4_blockdev.c` 中的 `ext4_block_cache_shake()`。本文严格按当前代码实现描述，无法从代码直接证明的内容均注明“当前代码未体现”。

---

## 1. 核心数据结构

### 1.1 `struct ext4_buf`

`struct ext4_buf` 是单个缓存块描述符，保存逻辑块号、数据缓冲区、引用计数、红黑树节点、dirty 链表节点和写回回调。

**代码依据：`include/ext4_bcache.h:68-117`**

```c
68 | /**@brief   Single block descriptor*/
69 | struct ext4_buf {
70 |     /**@brief   Flags*/
71 |     int flags;
73 |     /**@brief   Logical block address*/
74 |     uint64_t lba;
76 |     /**@brief   Data buffer.*/
77 |     uint8_t *data;
79 |     /**@brief   LRU priority. (unused) */
80 |     uint32_t lru_prio;
82 |     /**@brief   LRU id.*/
83 |     uint32_t lru_id;
85 |     /**@brief   Reference count table*/
86 |     uint32_t refctr;
87 |     /* refcount for read */
88 |     uint32_t read_refctr;
90 |     /**@brief   The block cache this buffer belongs to. */
91 |     struct ext4_bcache *bc;
93 |     /**@brief   Whether or not buffer is on dirty list.*/
94 |     bool on_dirty_list;
96 |     /**@brief   LBA tree node*/
97 |     RB_ENTRY(ext4_buf) lba_node;
99 |     /**@brief   LRU tree node*/
100 |     RB_ENTRY(ext4_buf) lru_node;
102 |     /**@brief   Dirty list node*/
103 |     SLIST_ENTRY(ext4_buf) dirty_node;
105 |     /**@brief   Callback routine after a disk-write operation.
110 |     void (*end_write)(struct ext4_bcache *bc,
111 |               struct ext4_buf *buf,
112 |               int res,
113 |               void *arg);
115 |     /**@brief   argument passed to end_write() callback.*/
116 |     void *end_write_arg;
117 | };
```

| 成员 | 类型 | 作用 |
|---|---|---|
| `flags` | `int` | 缓存状态位集合，使用 `BC_UPTODATE`、`BC_DIRTY`、`BC_FLUSH`、`BC_TMP`。 |
| `lba` | `uint64_t` | 逻辑块地址，是 `lba_root` 红黑树的排序键。 |
| `data` | `uint8_t *` | 缓存数据区，大小为 `bc->itemsize`，由 `ext4_buf_alloc()` 分配。 |
| `lru_prio` | `uint32_t` | 注释标明 unused；当前代码未体现实际使用。 |
| `lru_id` | `uint32_t` | LRU 序号，是 `lru_root` 红黑树的排序键。 |
| `refctr` | `uint32_t` | 总引用计数；非 0 时表示正在使用，不在 LRU 淘汰树中。 |
| `read_refctr` | `uint32_t` | 读引用计数；`ext4_bcache_free()` 用它判断 `refctr == read_refctr` 时可刷写。当前代码仅看到宏定义和该处判断，未见完整读引用管理策略。 |
| `bc` | `struct ext4_bcache *` | 指向所属块缓存对象。 |
| `on_dirty_list` | `bool` | 标识是否已挂入 `dirty_list`，避免重复插入。 |
| `lba_node` | `RB_ENTRY(ext4_buf)` | 挂入 `bc->lba_root` 的节点。 |
| `lru_node` | `RB_ENTRY(ext4_buf)` | 挂入 `bc->lru_root` 的节点。 |
| `dirty_node` | `SLIST_ENTRY(ext4_buf)` | 挂入 `bc->dirty_list` 的节点。 |
| `end_write` | 函数指针 | `ext4_block_flush_buf()` 写盘后调用的回调。 |
| `end_write_arg` | `void *` | 传递给 `end_write` 的参数。 |

### 1.2 `struct ext4_bcache`

`struct ext4_bcache` 是缓存池对象，持有容量、块大小、LRU 计数器、缓存块数量、块设备指针、两个红黑树和 dirty 链表。

**代码依据：`include/ext4_bcache.h:119-151`**

```c
119 | /**@brief   Block cache descriptor*/
120 | struct ext4_bcache {
122 |     /**@brief   Item count in block cache*/
123 |     uint32_t cnt;
125 |     /**@brief   Item size in block cache*/
126 |     uint32_t itemsize;
128 |     /**@brief   Last recently used counter*/
129 |     uint32_t lru_ctr;
131 |     /**@brief   Currently referenced datablocks*/
132 |     uint32_t ref_blocks;
134 |     /**@brief   Maximum referenced datablocks*/
135 |     uint32_t max_ref_blocks;
137 |     /**@brief   The blockdev binded to this block cache*/
138 |     struct ext4_blockdev *bdev;
140 |     /**@brief   The cache should not be shaked */
141 |     bool dont_shake;
143 |     /**@brief   A tree holding all bufs*/
144 |     RB_HEAD(ext4_buf_lba, ext4_buf) lba_root;
146 |     /**@brief   A tree holding unreferenced bufs*/
147 |     RB_HEAD(ext4_buf_lru, ext4_buf) lru_root;
149 |     /**@brief   A singly-linked list holding dirty buffers*/
150 |     SLIST_HEAD(ext4_buf_dirty, ext4_buf) dirty_list;
151 | };
```

| 成员 | 类型 | 作用 |
|---|---|---|
| `cnt` | `uint32_t` | 缓存容量，即最多缓存的 `ext4_buf` 数量。 |
| `itemsize` | `uint32_t` | 单个缓存项大小，挂载时设为 ext4 逻辑块大小。 |
| `lru_ctr` | `uint32_t` | LRU 递增计数器，为 buf 分配新的 `lru_id`。 |
| `ref_blocks` | `uint32_t` | 当前缓存中已分配 buf 数量。注释写 referenced，但代码中分配时递增、drop 时递减，更接近缓存中 buf 总数。 |
| `max_ref_blocks` | `uint32_t` | `ref_blocks` 历史最大值。 |
| `bdev` | `struct ext4_blockdev *` | 绑定的块设备，flush 时使用。 |
| `dont_shake` | `bool` | 防止递归 shake；shake 或写回回调期间置位。 |
| `lba_root` | `RB_HEAD(...)` | 按 LBA 保存所有 buf。 |
| `lru_root` | `RB_HEAD(...)` | 按 LRU ID 保存未引用 buf。 |
| `dirty_list` | `SLIST_HEAD(...)` | 保存可延迟写回的 dirty buf。 |

### 1.3 二者关系

`ext4_bcache` 是池，`ext4_buf` 是池中的单个缓存块；`ext4_buf.bc` 反向指向所属池。对外访问时，`struct ext4_block` 持有 `lb_id`、`buf` 和 `data`。

**代码依据：`include/ext4_bcache.h:54-64`**

```c
55 | struct ext4_block {
57 |     uint64_t lb_id;
60 |     struct ext4_buf *buf;
63 |     uint8_t *data;
64 | };
```

---

## 2. 初始化与销毁

### 2.1 `ext4_bcache_init_dynamic()`

该函数仅初始化 `struct ext4_bcache` 本体，不预分配 buf 或数据区。实际 buf 在 `ext4_bcache_alloc()` 中按需分配。

**代码依据：`src/ext4_bcache.c:70-83`**

```c
70 | int ext4_bcache_init_dynamic(struct ext4_bcache *bc, uint32_t cnt,
71 |                  uint32_t itemsize)
72 | {
73 |     ext4_assert(bc && cnt && itemsize);
75 |     memset(bc, 0, sizeof(struct ext4_bcache));
77 |     bc->cnt = cnt;
78 |     bc->itemsize = itemsize;
79 |     bc->ref_blocks = 0;
80 |     bc->max_ref_blocks = 0;
82 |     return EOK;
83 | }
```

初始化行为：

- `memset` 清零整个 `bc`；
- 设置 `cnt` 和 `itemsize`；
- 显式清零 `ref_blocks`、`max_ref_blocks`；
- 当前代码没有显式调用 `RB_INIT` / `SLIST_INIT`，红黑树和链表头依赖清零后的空状态；
- `bdev` 在初始化时仍为空，随后由 `ext4_block_bind_bcache()` 设置。

### 2.2 容量 `cnt` 与块大小 `itemsize` 来源

挂载时，代码从超级块读取文件系统块大小 `bsize`，调用 `ext4_block_set_lb_size()` 设置块设备逻辑块大小，然后用 `CONFIG_BLOCK_DEV_CACHE_SIZE` 和 `bsize` 初始化 bcache。

**代码依据：`src/ext4.c:305-319`**

```c
305 |     bsize = ext4_sb_get_block_size(&mp->fs.sb);
306 |     ext4_block_set_lb_size(bd, bsize);
307 |     bc = &mp->bc;
309 |     r = ext4_bcache_init_dynamic(bc, CONFIG_BLOCK_DEV_CACHE_SIZE, bsize);
315 |     if (bsize != bc->itemsize)
316 |         return ENOTSUP;
318 |     /*Bind block cache to block device*/
319 |     r = ext4_block_bind_bcache(bd, bc);
```

`CONFIG_BLOCK_DEV_CACHE_SIZE` 默认值为 8。

**代码依据：`include/ext4_config.h:125-129`**

```c
125 | /**@brief   Cache size of block device.*/
127 | #ifndef CONFIG_BLOCK_DEV_CACHE_SIZE
128 | #define CONFIG_BLOCK_DEV_CACHE_SIZE 8
129 | #endif
```

每个挂载点内嵌一个 bcache。

**代码依据：`include/ext4_mp.h:37-60`**

```c
37 | /**@brief   Mount point descriptor.*/
38 | struct ext4_mountpoint {
46 |     /**@brief   OS dependent lock/unlock functions.*/
47 |     const struct ext4_lock *os_locks;
49 |     /**@brief   Ext4 filesystem internals.*/
50 |     struct ext4_fs fs;
58 |     /**@brief   Block cache.*/
59 |     struct ext4_bcache bc;
60 | };
```

块设备和缓存互相绑定。

**代码依据：`src/ext4_blockdev.c:112-118`**

```c
112 | int ext4_block_bind_bcache(struct ext4_blockdev *bdev, struct ext4_bcache *bc)
113 | {
115 |     bdev->bc = bc;
116 |     bc->bdev = bdev;
117 |     return EOK;
118 | }
```

### 2.3 `ext4_bcache_cleanup()`

该函数遍历 `lba_root` 中所有 buf，先强制 flush，再 drop。

**代码依据：`src/ext4_bcache.c:85-92`**

```c
85 | void ext4_bcache_cleanup(struct ext4_bcache *bc)
86 | {
87 |     struct ext4_buf *buf, *tmp;
88 |     RB_FOREACH_SAFE(buf, ext4_buf_lba, &bc->lba_root, tmp) {
89 |         ext4_block_flush_buf(bc->bdev, buf);
90 |         ext4_bcache_drop_buf(bc, buf);
91 |     }
92 | }
```

技术解读：

- 它遍历的是所有缓存块，不只是 dirty list；
- 它忽略 `ext4_block_flush_buf()` 返回值；
- 若仍有引用，`ext4_bcache_drop_buf()` 只打印警告但仍释放内存，因此调用者必须保证 cleanup 时没有活跃引用；当前代码未体现等待引用归零机制。

### 2.4 `ext4_bcache_fini_dynamic()`

该函数只清零 `bc` 本体，不释放 buf；正确顺序应先 cleanup，再 fini。

**代码依据：`src/ext4_bcache.c:94-98`**

```c
94 | int ext4_bcache_fini_dynamic(struct ext4_bcache *bc)
95 | {
96 |     memset(bc, 0, sizeof(struct ext4_bcache));
97 |     return EOK;
98 | }
```

卸载流程遵循先关闭 write-back、再 cleanup/fini 的顺序。

**代码依据：`src/ext4.c:336-350`**

```c
340 |     if (mp && mp->mounted)
341 |     {
342 |         ext4_cache_write_back(mp->name, false);
344 |         ret = ext4_fs_fini(&mp->fs);
345 |         if (ret == EOK)
346 |         {
347 |             mp->mounted = 0;
349 |             ext4_bcache_cleanup(mp->fs.bdev->bc);
350 |             ext4_bcache_fini_dynamic(mp->fs.bdev->bc);
```

---

## 3. 缓存块生命周期

### 3.1 创建

缓存 miss 时，`ext4_buf_alloc()` 分配 `bc->itemsize` 大小的数据区和 `struct ext4_buf`，设置 `lba`、`data`、`bc`。

**代码依据：`src/ext4_bcache.c:119-138`**

```c
119 | static struct ext4_buf *
120 | ext4_buf_alloc(struct ext4_bcache *bc, uint64_t lba)
121 | {
124 |     data = ext4_malloc(bc->itemsize);
125 |     if (!data)
126 |         return NULL;
128 |     buf = ext4_calloc(1, sizeof(struct ext4_buf));
129 |     if (!buf) {
130 |         ext4_free(data);
131 |         return NULL;
132 |     }
134 |     buf->lba = lba;
135 |     buf->data = data;
136 |     buf->bc = bc;
137 |     return buf;
138 | }
```

### 3.2 查找与引用：`ext4_bcache_find_get()`

命中时，若 buf 当前未引用，则从 LRU 树移除、更新 `lru_id`，dirty 时从 dirty list 移除，然后增加引用计数并填充 `ext4_block`。

**代码依据：`src/ext4_bcache.c:208-232`**

```c
212 |     struct ext4_buf *buf = ext4_buf_lookup(bc, lba);
213 |     if (buf) {
215 |         if (!buf->refctr) {
218 |             buf->lru_id = ++bc->lru_ctr;
219 |             RB_REMOVE(ext4_buf_lru, &bc->lru_root, buf);
220 |             if (ext4_bcache_test_flag(buf, BC_DIRTY))
221 |                 ext4_bcache_remove_dirty_node(bc, buf);
223 |         }
225 |         ext4_bcache_inc_ref(buf);
227 |         b->lb_id = lba;
228 |         b->buf = buf;
229 |         b->data = buf->data;
230 |     }
231 |     return buf;
```

### 3.3 分配或复用：`ext4_bcache_alloc()`

`ext4_bcache_alloc()` 先查找复用；miss 时新建 buf，插入 LBA 树，增加 `ref_blocks`，设置引用和 LRU ID。

**代码依据：`src/ext4_bcache.c:234-268`**

```c
237 |     /* Try to search the buffer with exaxt LBA. */
238 |     struct ext4_buf *buf = ext4_bcache_find_get(bc, b, b->lb_id);
239 |     if (buf) {
240 |         *is_new = false;
241 |         return EOK;
242 |     }
245 |     buf = ext4_buf_alloc(bc, b->lb_id);
249 |     RB_INSERT(ext4_buf_lba, &bc->lba_root, buf);
251 |     bc->ref_blocks++;
254 |     if (bc->max_ref_blocks < bc->ref_blocks)
255 |         bc->max_ref_blocks = bc->ref_blocks;
258 |     ext4_bcache_inc_ref(buf);
261 |     buf->lru_id = ++bc->lru_ctr;
263 |     b->buf = buf;
264 |     b->data = buf->data;
266 |     *is_new = true;
```

### 3.4 使用：`ext4_block_get()` 和 `ext4_block_set()`

`ext4_block_get()` 通过 bcache 获取块；若 `BC_UPTODATE` 未置位，则 direct read，读成功后置位。`ext4_block_set()` 释放引用，实际调用 `ext4_bcache_free()`。

**代码依据：`src/ext4_blockdev.c:244-279`**

```c
247 |     int r = ext4_block_get_noread(bdev, b, lba);
251 |     if (ext4_bcache_test_flag(b->buf, BC_UPTODATE)) {
254 |         return EOK;
255 |     }
257 |     r = ext4_blocks_get_direct(bdev, b->data, lba, 1);
266 |     ext4_bcache_set_flag(b->buf, BC_UPTODATE);
270 | int ext4_block_set(struct ext4_blockdev *bdev, struct ext4_block *b)
278 |     return ext4_bcache_free(bdev->bc, b);
```

### 3.5 标脏、释放、回写

标脏函数会同时设置 `BC_UPTODATE` 和 `BC_DIRTY`。

**代码依据：`include/ext4_bcache.h:178-186`**

```c
178 | static inline void ext4_bcache_set_dirty(struct ext4_buf *buf) {
179 |     ext4_bcache_set_flag(buf, BC_UPTODATE);
180 |     ext4_bcache_set_flag(buf, BC_DIRTY);
181 | }
183 | static inline void ext4_bcache_clear_dirty(struct ext4_buf *buf) {
184 |     ext4_bcache_clear_flag(buf, BC_UPTODATE);
185 |     ext4_bcache_clear_flag(buf, BC_DIRTY);
186 | }
```

`ext4_bcache_free()` 递减 `refctr`；最后引用释放时插入 LRU 树；dirty 且 uptodate 时根据 write-back 状态选择插入 dirty list 或立即 flush；无效块或 `BC_TMP` 块会被 drop。

**代码依据：`src/ext4_bcache.c:270-330`**

```c
286 |     ext4_bcache_dec_ref(buf);
288 |     if (buf->refctr && buf->refctr == buf->read_refctr) {
290 |         if (ext4_bcache_test_flag(buf, BC_DIRTY) &&
291 |             ext4_bcache_test_flag(buf, BC_UPTODATE)) {
292 |             if (bc->bdev->cache_write_back &&
293 |                 !ext4_bcache_test_flag(buf, BC_FLUSH) &&
294 |                 !ext4_bcache_test_flag(buf, BC_TMP))
295 |                 ext4_bcache_insert_dirty_node(bc, buf);
296 |             else {
297 |                 ext4_block_flush_buf(bc->bdev, buf);
298 |                 ext4_bcache_clear_flag(buf, BC_FLUSH);
299 |             }
300 |         }
301 |     }
303 |     if (!buf->refctr) {
305 |         RB_INSERT(ext4_buf_lru, &bc->lru_root, buf);
307 |         if (ext4_bcache_test_flag(buf, BC_DIRTY) &&
308 |             ext4_bcache_test_flag(buf, BC_UPTODATE)) {
309 |             if (bc->bdev->cache_write_back &&
310 |                 !ext4_bcache_test_flag(buf, BC_FLUSH) &&
311 |                 !ext4_bcache_test_flag(buf, BC_TMP))
312 |                 ext4_bcache_insert_dirty_node(bc, buf);
313 |             else {
314 |                 ext4_block_flush_buf(bc->bdev, buf);
315 |                 ext4_bcache_clear_flag(buf, BC_FLUSH);
316 |             }
317 |         }
320 |         if (!ext4_bcache_test_flag(buf, BC_UPTODATE) ||
321 |             ext4_bcache_test_flag(buf, BC_TMP))
322 |             ext4_bcache_drop_buf(bc, buf);
324 |     }
326 |     b->lb_id = 0;
327 |     b->data = 0;
```

真正写盘在 `ext4_block_flush_buf()`，它通过 `ext4_blocks_set_direct()` 写一个逻辑块，成功后移出 dirty list 并清除 `BC_DIRTY`。

**代码依据：`src/ext4_blockdev.c:144-171`**

```c
149 |     if (ext4_bcache_test_flag(buf, BC_DIRTY) &&
150 |         ext4_bcache_test_flag(buf, BC_UPTODATE)) {
151 |         r = ext4_blocks_set_direct(bdev, buf->data, buf->lba, 1);
162 |         ext4_bcache_remove_dirty_node(bc, buf);
163 |         ext4_bcache_clear_flag(buf, BC_DIRTY);
164 |         if (buf->end_write) {
165 |             bc->dont_shake = true;
166 |             buf->end_write(bc, buf, r, buf->end_write_arg);
167 |             bc->dont_shake = false;
168 |         }
169 |     }
```

---

## 4. 查找与 LRU 淘汰

### 4.1 LBA 红黑树与 LRU 红黑树

`lba_root` 按 `lba` 比较；`lru_root` 按 `lru_id` 比较。

**代码依据：`src/ext4_bcache.c:47-68`**

```c
47 | static int ext4_bcache_lba_compare(struct ext4_buf *a, struct ext4_buf *b)
49 |      if (a->lba > b->lba)
51 |      else if (a->lba < b->lba)
56 | static int ext4_bcache_lru_compare(struct ext4_buf *a, struct ext4_buf *b)
58 |     if (a->lru_id > b->lru_id)
60 |     else if (a->lru_id < b->lru_id)
65 | RB_GENERATE_INTERNAL(ext4_buf_lba, ext4_buf, lba_node,
67 | RB_GENERATE_INTERNAL(ext4_buf_lru, ext4_buf, lru_node,
```

源码注释直接说明：所有 buf 在 `lba_root`；未引用 buf 同时在 `lru_root`；被引用 buf 只在 `lba_root`。

**代码依据：`src/ext4_bcache.c:100-117`**

```c
104 |  *  Buffers in a bcache are sorted by their LBA and stored in a
105 |  *  RB-Tree(lba_root).
107 |  *  Bcache also maintains another RB-Tree(lru_root) right now, where
108 |  *  buffers are sorted by their LRU id.
110 |  *  A singly-linked list is used to track those dirty buffers which are
111 |  *  ready to be flushed. (Those buffers which are dirty but also referenced
112 |  *  are not considered ready to be flushed.)
114 |  *  When a buffer is not referenced, it will be stored in both lba_root
115 |  *  and lru_root, while it will only be stored in lba_root when it is
116 |  *  referenced.
```

### 4.2 查找

查找通过构造临时 `ext4_buf`，在 `lba_root` 执行 `RB_FIND`。

**代码依据：`src/ext4_bcache.c:146-154`**

```c
146 | static struct ext4_buf *
147 | ext4_buf_lookup(struct ext4_bcache *bc, uint64_t lba)
148 | {
149 |     struct ext4_buf tmp = {
150 |         .lba = lba
151 |     };
153 |     return RB_FIND(ext4_buf_lba, &bc->lba_root, &tmp);
154 | }
```

### 4.3 缓存满与淘汰规则

缓存满条件是 `bc->cnt <= bc->ref_blocks`。

**代码依据：`src/ext4_bcache.c:332-335`**

```c
332 | bool ext4_bcache_is_full(struct ext4_bcache *bc)
333 | {
334 |     return (bc->cnt <= bc->ref_blocks);
335 | }
```

`ext4_block_get_noread()` 每次分配前先调用 `ext4_block_cache_shake()`。

**代码依据：`src/ext4_blockdev.c:213-235`**

```c
227 |     b->lb_id = lba;
229 |     /*If cache is full we have to (flush and) drop it anyway :(*/
230 |     r = ext4_block_cache_shake(bdev);
234 |     r = ext4_bcache_alloc(bdev->bc, b, &is_new);
```

`ext4_block_cache_shake()` 在 `lru_root` 非空且缓存满时循环淘汰 `lru_id` 最小的未引用块；dirty 块先 flush 再 drop。

**代码依据：`src/ext4_blockdev.c:186-211`**

```c
190 |     if (bdev->bc->dont_shake)
191 |         return EOK;
193 |     bdev->bc->dont_shake = true;
195 |     while (!RB_EMPTY(&bdev->bc->lru_root) &&
196 |         ext4_bcache_is_full(bdev->bc)) {
198 |         buf = ext4_buf_lowest_lru(bdev->bc);
200 |         if (ext4_bcache_test_flag(buf, BC_DIRTY)) {
201 |             r = ext4_block_flush_buf(bdev, buf);
202 |             if (r != EOK)
203 |                 break;
204 |         }
207 |         ext4_bcache_drop_buf(bdev->bc, buf);
208 |     }
209 |     bdev->bc->dont_shake = false;
```

### 4.4 一个块在两棵树中的状态变化

| 阶段 | `lba_root` | `lru_root` | 关键代码 |
|---|---|---|---|
| 新建并引用 | 插入 | 不插入 | `RB_INSERT(lba_root)`、`refctr++` |
| 未引用块被再次命中 | 保持 | 移除 | `RB_REMOVE(lru_root)`、`refctr++` |
| 最后引用释放 | 保持 | 插入 | `RB_INSERT(lru_root)` |
| 淘汰 | 移除 | 移除 | `ext4_bcache_drop_buf()` |

**代码依据：`src/ext4_bcache.c:161-179`**

```c
164 |     if (buf->refctr) {
165 |         ext4_dbg(DEBUG_BCACHE, DBG_WARN "Buffer is still referenced. "
168 |     } else
169 |         RB_REMOVE(ext4_buf_lru, &bc->lru_root, buf);
171 |     RB_REMOVE(ext4_buf_lba, &bc->lba_root, buf);
174 |     if (ext4_bcache_test_flag(buf, BC_DIRTY))
175 |         ext4_bcache_remove_dirty_node(bc, buf);
177 |     ext4_buf_free(buf);
178 |     bc->ref_blocks--;
```

`refctr` 保护正在使用的块不进入 LRU 树，`lru_id` 决定未引用块之间的淘汰顺序。

---

## 5. 脏数据与写回策略

### 5.1 标志位

**代码依据：`include/ext4_bcache.h:153-167`**

```c
153 | /**@brief buffer state bits
155 |  *  - BC♡UPTODATE: Buffer contains valid data.
156 |  *  - BC_DIRTY: Buffer is dirty.
157 |  *  - BC_FLUSH: Buffer will be immediately flushed,
159 |  *  - BC_TMP: Buffer will be dropped once its refctr
162 | enum bcache_state_bits {
163 |     BC_UPTODATE,
164 |     BC_DIRTY,
165 |     BC_FLUSH,
166 |     BC_TMP
167 | };
```

| 标志 | 作用与设置时机 |
|---|---|
| `BC_UPTODATE` | 表示 `data` 有效；`ext4_block_get()` direct read 成功后设置；`ext4_bcache_set_dirty()` 也会设置。 |
| `BC_DIRTY` | 表示需要写回；`ext4_bcache_set_dirty()` 设置，`ext4_block_flush_buf()` 写成功后清除。 |
| `BC_FLUSH` | `ext4_bcache_free()` 中检测到该标志时跳过延迟写，直接 flush，随后清除。 |
| `BC_TMP` | `ext4_bcache_free()` 中检测到该标志时跳过延迟写；引用归零后 drop。 |

### 5.2 dirty list

`dirty_list` 保存延迟写回的 dirty buf；`on_dirty_list` 防止重复插入。

**代码依据：`include/ext4_bcache.h:196-216`**

```c
199 | static inline void
200 | ext4_bcache_insert_dirty_node(struct ext4_bcache *bc, struct ext4_buf *buf) {
201 |     if (!buf->on_dirty_list) {
202 |         SLIST_INSERT_HEAD(&bc->dirty_list, buf, dirty_node);
203 |         buf->on_dirty_list = true;
204 |     }
205 | }
210 | static inline void
211 | ext4_bcache_remove_dirty_node(struct ext4_bcache *bc, struct ext4_buf *buf) {
212 |     if (buf->on_dirty_list) {
213 |         SLIST_REMOVE(&bc->dirty_list, buf, ext4_buf, dirty_node);
214 |         buf->on_dirty_list = false;
215 |     }
216 | }
```

### 5.3 write-back 与直写

`cache_write_back` 是 `struct ext4_blockdev` 的计数器。

**代码依据：`include/ext4_blockdev.h:105-126`**

```c
105 | /**@brief   Definition of the simple block device.*/
106 | struct ext4_blockdev {
116 |     /**@brief   Block cache.*/
117 |     struct ext4_bcache *bc;
125 |     /**@brief   Cache write back mode reference counter*/
126 |     uint32_t cache_write_back;
```

`ext4_block_cache_write_back()` 开启时递增计数，关闭时递减；当计数降为 0 时 flush dirty list。

**代码依据：`src/ext4_blockdev.c:458-471`**

```c
458 | int ext4_block_cache_write_back(struct ext4_blockdev *bdev, uint8_t on_off)
459 | {
460 |     if (on_off)
461 |         bdev->cache_write_back++;
463 |     if (!on_off && bdev->cache_write_back)
464 |         bdev->cache_write_back--;
466 |     if (bdev->cache_write_back)
467 |         return EOK;
469 |     /*Flush data in all delayed cache blocks*/
470 |     return ext4_block_cache_flush(bdev);
471 | }
```

`ext4_block_cache_flush()` 循环 flush dirty list。

**代码依据：`src/ext4_blockdev.c:444-456`**

```c
444 | int ext4_block_cache_flush(struct ext4_blockdev *bdev)
445 | {
446 |     while (!SLIST_EMPTY(&bdev->bc->dirty_list)) {
448 |         struct ext4_buf *buf = SLIST_FIRST(&bdev->bc->dirty_list);
450 |         r = ext4_block_flush_buf(bdev, buf);
451 |         if (r != EOK)
452 |             return r;
454 |     }
455 |     return EOK;
456 | }
```

挂载时默认开启 write-back，卸载时关闭并触发 flush。

**代码依据：`src/ext4.c:331-342`**

```c
331 |     ext4_cache_write_back(mp->name, true);
...
342 |         ext4_cache_write_back(mp->name, false);
```

---

## 6. 与文件 I/O 的关系

### 6.1 bcache 缓存通过 `ext4_block_get()` 访问的块

`ext4_block_get()` 是缓存路径；它调用 `ext4_block_get_noread()` / `ext4_bcache_alloc()`，缺失或非 uptodate 时才 direct read。

**代码依据：`src/ext4_blockdev.c:244-268`**

```c
247 |     int r = ext4_block_get_noread(bdev, b, lba);
251 |     if (ext4_bcache_test_flag(b->buf, BC_UPTODATE)) {
254 |         return EOK;
255 |     }
257 |     r = ext4_blocks_get_direct(bdev, b->data, lba, 1);
266 |     ext4_bcache_set_flag(b->buf, BC_UPTODATE);
```

### 6.2 元数据访问证据

#### block bitmap / 块分配

**代码依据：`src/ext4_balloc.c:70-88`**

```c
70 | static int ext4_balloc_get_bitmap(struct ext4_block_group_ref *bg_ref,
73 |     uint64_t bitmap_block_addr = ext4_bg_get_block_bitmap(
76 |     return ext4_block_get(bg_ref->fs->bdev, bitmap_block, bitmap_block_addr);
79 | static int ext4_balloc_set_bitmap(struct ext4_block_group_ref *bg_ref,
84 |     bitmap_block->dirty = true;
86 |     return ext4_trans_set_block_dirty(bitmap_block);
```

#### 目录块

**代码依据：`src/ext4_dir.c:391-399`**

```c
391 |     /* Put back current data block, and load the next one */
392 |     if (it->curr_blk.lb_id) {
393 |         rc = ext4_block_set(fs->bdev, &it->curr_blk);
397 |     }
399 |     rc = ext4_block_get(fs->bdev, &it->curr_blk, next_block_phys_idx);
```

#### inode 表

**代码依据：`src/ext4_fs.c:399-408`**

```c
399 |     /* Load block, where i-node is located */
400 |     struct ext4_block block;
401 |     rc = ext4_trans_block_get(fs->bdev, &block, block_id);
407 |     ref->block = block;
408 |     ref->inode = (void *)(block.data + offset_in_block);
```

#### extent 节点

全局搜索显示 `src/ext4_extent.c` 多处调用 `ext4_block_set()`，例如：

**代码依据：`src/ext4_extent.c:721,794`（搜索结果）**

```c
721 |             ext4_block_set(inode_ref->fs->bdev, &path->block);
794 |         ext4_block_set(inode_ref->fs->bdev, bh);
```

> 当前文档不展开 extent tree 算法，只说明其直接与 block cache 释放路径交互。

#### 超级块特例

超级块读取使用字节级 direct I/O，不经过 bcache。

**代码依据：`src/ext4_super.c:50-56`**

```c
50 | int ext4_sb_read(struct ext4_blockdev *bdev, struct ext4_sblock *s)
53 |     struct ext4_block block;
55 |     r = ext4_block_readbytes(bdev, EXT4_SUPERBLOCK_OFFSET, s,
56 |                  EXT4_SUPERBLOCK_SIZE);
```

因此，“bcache 缓存超级块”在当前代码中未体现；当前代码显示超级块读取路径是 direct byte I/O。

### 6.3 文件数据 direct I/O，不经过 bcache

文件读 `ext4_fread()` 解析 inode 映射后，对文件数据使用 `ext4_block_readbytes()` 或 `ext4_blocks_get_direct()`。

**代码依据：`src/ext4.c:1681-1689`**

```c
1681 |         r = ext4_fs_get_inode_dblk_idx(&ref, iblock_idx, &fblock, true);
1686 |         if (fblock != 0) {
1687 |             uint64_t off = fblock * block_size + unalg;
1688 |             r = ext4_block_readbytes(file->mp->fs.bdev, off, u8_buf, len);
```

**代码依据：`src/ext4.c:1728-1733`**

```c
1728 |             memset(u8_buf, 0, block_size * fblock_count);
1730 |         } else {
1731 |             r = ext4_blocks_get_direct(file->mp->fs.bdev, u8_buf, fblock_start,
1732 |                        fblock_count);
1733 |         }
```

`ext4_blocks_get_direct()` 直接调用底层 `bread`。

**代码依据：`src/ext4_blockdev.c:281-293`**

```c
281 | int ext4_blocks_get_direct(struct ext4_blockdev *bdev, void *buf, uint64_t lba,
289 |     pba = (lba * bdev->lg_bsize + bdev->part_offset) / bdev->bdif->ph_bsize;
290 |     pb_cnt = bdev->lg_bsize / bdev->bdif->ph_bsize;
292 |     return ext4_bdif_bread(bdev, buf, pba, pb_cnt * cnt);
```

文件写路径使用 `ext4_block_writebytes()`，该函数也直接调用底层 `bread` / `bwrite`。

**代码依据：`src/ext4.c:2460-2464`**

```c
2460 |             goto Finish;
2462 |         off = fblock * block_size;
2463 |         r = ext4_block_writebytes(f->mp->fs.bdev, off, buf, size);
```

**代码依据：`src/ext4_blockdev.c:309-376`**

```c
337 |         r = ext4_bdif_bread(bdev, bdev->bdif->ph_bbuf, block_idx, 1);
342 |         r = ext4_bdif_bwrite(bdev, bdev->bdif->ph_bbuf, block_idx, 1);
354 |         r = ext4_bdif_bwrite(bdev, p, block_idx, blen);
366 |         r = ext4_bdif_bread(bdev, bdev->bdif->ph_bbuf, block_idx, 1);
371 |         r = ext4_bdif_bwrite(bdev, bdev->bdif->ph_bbuf, block_idx, 1);
```

结论：当前 bcache 主要服务文件系统内部块访问；普通文件数据读写使用 direct I/O，不使用 `ext4_bcache` 作为数据页缓存。

---

## 7. 并发安全

### 7.1 bcache 内部没有锁

`struct ext4_bcache` 没有锁字段，`src/ext4_bcache.c` 的核心函数也没有内部 mutex/spinlock。当前代码未体现 bcache 模块自带并发保护。

**代码依据：`include/ext4_bcache.h:119-151`**

```c
120 | struct ext4_bcache {
123 |     uint32_t cnt;
126 |     uint32_t itemsize;
129 |     uint32_t lru_ctr;
132 |     uint32_t ref_blocks;
138 |     struct ext4_blockdev *bdev;
141 |     bool dont_shake;
144 |     RB_HEAD(ext4_buf_lba, ext4_buf) lba_root;
147 |     RB_HEAD(ext4_buf_lru, ext4_buf) lru_root;
150 |     SLIST_HEAD(ext4_buf_dirty, ext4_buf) dirty_list;
151 | };
```

### 7.2 上层 mount point 锁

`ext4_mountpoint` 保存 OS 相关锁回调。

**代码依据：`include/ext4_mp.h:46-59`**

```c
46 |     /**@brief   OS dependent lock/unlock functions.*/
47 |     const struct ext4_lock *os_locks;
49 |     /**@brief   Ext4 filesystem internals.*/
50 |     struct ext4_fs fs;
58 |     /**@brief   Block cache.*/
59 |     struct ext4_bcache bc;
```

高层 API 在访问文件系统时使用 `EXT4_MP_LOCK()` / `EXT4_MP_UNLOCK()`。例如 cache flush/write-back 包装函数：

**代码依据：`src/ext4.c:1339-1365`**

```c
1347 |     EXT4_MP_LOCK(mp);
1348 |     ret = ext4_block_cache_write_back(mp->fs.bdev, on);
1349 |     EXT4_MP_UNLOCK(mp);
...
1361 |     EXT4_MP_LOCK(mp);
1362 |     ret = ext4_block_cache_flush(mp->fs.bdev);
1363 |     EXT4_MP_UNLOCK(mp);
```

RT-Thread 适配层创建全局 `lwext4` mutex，并注册文件系统。

**代码依据：`ports/rtthread/dfs_ext.c:1089-1105`**

```c
1089 | int dfs_ext_init(void)
1090 | {
1091 |     if (ext4_mutex == RT_NULL)
1092 |     {
1093 |         ext4_mutex = rt_mutex_create("lwext4", RT_IPC_FLAG_FIFO);
1101 |     /* register rom file system */
1102 |     dfs_register(&_extfs);
1103 |     return 0;
1104 | }
1105 | INIT_COMPONENT_EXPORT(dfs_ext_init);
```

### 7.3 底层块设备 I/O 锁

`ext4_blockdev.c` 在 direct read/write 包装中调用 `bdif->lock` / `bdif->unlock`。

**代码依据：`src/ext4_blockdev.c:68-85`**

```c
68 | static int ext4_bdif_bread(struct ext4_blockdev *bdev, void *buf,
71 |     ext4_bdif_lock(bdev);
72 |     int r = bdev->bdif->bread(bdev, buf, blk_id, blk_cnt);
74 |     ext4_bdif_unlock(bdev);
78 | static int ext4_bdif_bwrite(struct ext4_blockdev *bdev, const void *buf,
81 |     ext4_bdif_lock(bdev);
82 |     int r = bdev->bdif->bwrite(bdev, buf, blk_id, blk_cnt);
84 |     ext4_bdif_unlock(bdev);
```

RT-Thread 块设备适配实现了 `blockdev_lock()` / `blockdev_unlock()`，内部使用 `rt_mutex_t bdevice_mutex`。

**代码依据：`ports/rtthread/dfs_ext_blockdev.c:28-58`**

```c
28 | static rt_mutex_t bdevice_mutex = RT_NULL;
30 | static int blockdev_lock(struct ext4_blockdev *bdev)
31 | {
34 |     if (bdevice_mutex == RT_NULL)
35 |     {
37 |         bdevice_mutex = rt_mutex_create("ext_bd", RT_IPC_FLAG_PRIO);
38 |         RT_ASSERT(bdevice_mutex != RT_NULL);
39 |     }
41 |     while (result == -RT_EBUSY)
42 |     {
43 |         result = rt_mutex_take(bdevice_mutex, RT_WAITING_FOREVER);
44 |     }
51 |     return 0;
52 | }
54 | static int blockdev_unlock(struct ext4_blockdev *bdev)
55 | {
56 |     rt_mutex_release(bdevice_mutex);
57 |
58 |     return 0;
```

适配层把这些锁回调写入 `ext4_blockdev_iface`。

**代码依据：`ports/rtthread/dfs_ext_blockdev.c:191-199`**

```c
191 |         iface->open = blockdev_open;
192 |         iface->bread = blockdev_read;
193 |         iface->bwrite = blockdev_write;
194 |         iface->close = blockdev_close;
195 |         iface->lock = blockdev_lock,
196 |         iface->unlock = blockdev_unlock;
197 |         iface->ph_bsize = 4096;
198 |         iface->ph_bcnt = 0;
199 |         iface->ph_bbuf = ph_bbuf;
```

---

## 8. 总结

1. `ext4_bcache` 是每个 mount point 内嵌的块缓存池；`ext4_buf` 是缓存池中的单个缓存块。
2. 缓存初始化在 `ext4_mount()` 中完成，容量来自 `CONFIG_BLOCK_DEV_CACHE_SIZE`，默认 8；单项大小来自超级块中的 ext4 block size。
3. 当前实现是按需分配缓存块，不在 init 阶段预分配所有 buf。
4. `lba_root` 保存所有缓存块，用于按 LBA 查找；`lru_root` 只保存未引用缓存块，用于按 `lru_id` 淘汰。
5. `refctr` 防止正在使用的块进入 LRU 淘汰树；`lru_id` 决定未引用块的淘汰顺序。
6. dirty 管理由 `BC_DIRTY`、`dirty_list`、`cache_write_back` 协同完成：write-back 开启时延迟写，关闭或 flush 时统一刷盘；非 write-back 或带 `BC_FLUSH` / `BC_TMP` 时更倾向立即处理。
7. 文件系统元数据块常通过 `ext4_block_get()` / `ext4_block_set()` 使用 bcache；普通文件数据读写在 `ext4_fread()` / `ext4_fwrite()` 中走 `ext4_blocks_get_direct()`、`ext4_block_readbytes()`、`ext4_block_writebytes()`，不经过 bcache 作为数据页缓存。
8. bcache 模块自身没有内部锁；并发保护依赖上层 mount point 锁以及底层 blockdev 的 `lock` / `unlock` 回调。RT-Thread 适配层用 `rt_mutex` 实现这些锁。
9. 潜在问题：
   - `ext4_bcache_cleanup()` 忽略 flush 返回值；
   - `ext4_bcache_drop_buf()` 对仍有引用的 buf 只警告但仍释放，若调用时机不当可能造成悬空引用；
   - `ref_blocks` 名称/注释与实际行为不完全一致，实际更像“缓存中 buf 总数”；
   - 当前代码有 `read_refctr` 判断，但在分析范围内未体现完整读引用生命周期；
   - `ext4_bcache_init_dynamic()` 依赖清零后的红黑树/链表空状态，未显式初始化容器头。
