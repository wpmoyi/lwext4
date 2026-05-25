# lwext4 文件系统 —— 重要结构体分析

## 目录

1. [概述](#概述)
2. [磁盘数据结构 (On-Disk Structures)](#磁盘数据结构)
3. [内存管理结构 (In-Memory Structures)](#内存管理结构)
4. [API 层结构 (API Layer Structures)](#api-层结构)
5. [结构体关系图](#结构体关系图)

---

## 概述

lwext4 是一个轻量级的 ext2/ext3/ext4 文件系统实现，专为嵌入式系统（如 RT-Thread）设计。其结构体可分为三大类：

- **磁盘数据结构**：直接映射到 ext4 磁盘布局，使用 `#pragma pack(push, 1)` 确保紧凑对齐。
- **内存管理结构**：运行时使用的缓存、事务、文件系统等管理结构。
- **API 层结构**：对外暴露的文件/目录操作接口结构。

本项目使用小端字节序（Little-Endian）存储 ext4 磁盘数据，JBD（Journal Block Device）日志数据使用大端字节序（Big-Endian）。

---

## 磁盘数据结构

### 1. `struct ext4_sblock` —— 超级块

**文件位置**: [ext4_types.h:L65-L175](file:///d:/lwext4/include/ext4_types.h#L65-L175)

超级块是 ext4 文件系统的核心元数据结构，存储在磁盘偏移 1024 字节处，大小为 1024 字节。包含文件系统的全局信息和配置参数。

```c
struct ext4_sblock {
    // === 基本计数信息 ===
    uint32_t inodes_count;              // I-node 总数
    uint32_t blocks_count_lo;           // 块总数（低 32 位）
    uint32_t reserved_blocks_count_lo;  // 保留块计数（低 32 位）
    uint32_t free_blocks_count_lo;      // 空闲块计数（低 32 位）
    uint32_t free_inodes_count;         // 空闲 inode 计数
    uint32_t first_data_block;          // 第一个数据块编号
    uint32_t log_block_size;            // 块大小（以 2 为底的对数，实际大小 = 1024 << log_block_size）
    uint32_t log_cluster_size;          // 簇大小（已废弃）
    uint32_t blocks_per_group;          // 每个块组的块数量
    uint32_t frags_per_group;           // 每个块组的片段数（已废弃）
    uint32_t inodes_per_group;          // 每个块组的 inode 数量

    // === 时间与挂载信息 ===
    uint32_t mount_time;                // 最后挂载时间
    uint32_t write_time;                // 最后写入时间
    uint16_t mount_count;               // 挂载次数
    uint16_t max_mount_count;           // 最大挂载次数（超过需检查）
    uint16_t magic;                     // 魔数 0xEF53
    uint16_t state;                     // 文件系统状态
    uint16_t errors;                    // 错误处理行为
    uint16_t minor_rev_level;           // 次版本号
    uint32_t last_check_time;           // 最后检查时间
    uint32_t check_interval;            // 最大检查间隔
    uint32_t creator_os;                // 创建者操作系统
    uint32_t rev_level;                 // 版本级别
    uint16_t def_resuid;                // 保留块的默认 UID
    uint16_t def_resgid;                // 保留块的默认 GID

    // === EXT4 动态版本扩展字段 ===
    uint32_t first_inode;               // 第一个非保留 inode（通常为 11）
    uint16_t inode_size;                // inode 结构体大小
    uint16_t block_group_index;         // 此超级块所在的块组索引
    uint32_t features_compatible;       // 兼容特性集
    uint32_t features_incompatible;     // 不兼容特性集
    uint32_t features_read_only;        // 只读兼容特性集
    uint8_t  uuid[16];                  // 128 位 UUID
    char     volume_name[16];           // 卷名
    char     last_mounted[64];          // 最后挂载目录
    uint32_t algorithm_usage_bitmap;    // 压缩算法使用位图
    uint8_t  s_prealloc_blocks;         // 预分配块数
    uint8_t  s_prealloc_dir_blocks;     // 目录预分配块数
    uint16_t s_reserved_gdt_blocks;     // 在线增长的保留 GDT 块

    // === 日志支持 ===
    uint8_t  journal_uuid[16];          // 日志超级块 UUID
    uint32_t journal_inode_number;      // 日志文件 inode 号
    uint32_t journal_dev;               // 日志文件设备号
    uint32_t last_orphan;               // 待删除 inode 链表头
    uint32_t hash_seed[4];              // HTREE 哈希种子
    uint8_t  default_hash_version;      // 默认哈希版本
    uint8_t  journal_backup_type;       // 日志备份类型
    uint16_t desc_size;                 // 块组描述符大小
    uint32_t default_mount_opts;        // 默认挂载选项
    uint32_t first_meta_bg;             // 第一个元块组
    uint32_t mkfs_time;                 // 文件系统创建时间
    uint32_t journal_blocks[17];        // 日志 inode 备份

    // === 64 位支持 ===
    uint32_t blocks_count_hi;           // 块总数（高 32 位）
    uint32_t reserved_blocks_count_hi;  // 保留块计数（高 32 位）
    uint32_t free_blocks_count_hi;      // 空闲块计数（高 32 位）
    uint16_t min_extra_isize;           // 所有 inode 至少包含的额外字节数
    uint16_t want_extra_isize;          // 新 inode 应保留的额外字节数
    uint32_t flags;                     // 杂项标志
    uint16_t raid_stride;               // RAID 条带大小
    uint16_t mmp_interval;              // MMP 检查间隔（秒）
    uint64_t mmp_block;                 // 多挂载保护块
    uint32_t raid_stripe_width;         // 所有数据盘上的块数（N * stride）
    uint8_t  log_groups_per_flex;       // FLEX_BG 组大小
    uint8_t  checksum_type;             // 校验和类型
    uint16_t reserved_pad;              // 保留填充
    uint64_t kbytes_written;            // 生命周期写入的千字节数
    uint32_t snapshot_inum;             // 活动快照的 inode 号
    uint32_t snapshot_id;               // 活动快照的顺序 ID
    uint64_t snapshot_r_blocks_count;   // 活动快照保留块数
    uint32_t snapshot_list;             // 磁盘快照链表头 inode 号
    uint32_t error_count;               // 文件系统错误计数
    uint32_t first_error_time;          // 首次错误时间
    uint32_t first_error_ino;           // 首次错误涉及的 inode
    uint64_t first_error_block;         // 首次错误涉及的块
    uint8_t  first_error_func[32];      // 错误发生的函数名
    uint32_t first_error_line;          // 错误发生的行号
    uint32_t last_error_time;           // 最近错误时间
    uint32_t last_error_ino;            // 最近错误涉及的 inode
    uint32_t last_error_line;           // 最近错误行号
    uint64_t last_error_block;          // 最近错误涉及的块
    uint8_t  last_error_func[32];       // 最近错误发生的函数名
    uint8_t  mount_opts[64];            // 挂载选项
    uint32_t usr_quota_inum;            // 用户配额 inode
    uint32_t grp_quota_inum;            // 组配额 inode
    uint32_t overhead_clusters;         // 文件系统开销簇
    uint32_t backup_bgs[2];             // sparse_super2 备份块组
    uint8_t  encrypt_algos[4];          // 使用的加密算法
    uint8_t  encrypt_pw_salt[16];       // string2key 算法盐值
    uint32_t lpf_ino;                   // lost+found inode
    uint32_t padding[100];              // 填充至块末尾
    uint32_t checksum;                  // crc32c 校验和
};
```

**关键宏定义**:
| 宏 | 值 | 描述 |
|---|---|---|
| `EXT4_SUPERBLOCK_MAGIC` | `0xEF53` | 超级块魔数 |
| `EXT4_SUPERBLOCK_SIZE` | `1024` | 超级块大小 |
| `EXT4_SUPERBLOCK_OFFSET` | `1024` | 超级块在磁盘上的偏移 |

---

### 2. `struct ext4_bgroup` —— 块组描述符

**文件位置**: [ext4_types.h:L318-L345](file:///d:/lwext4/include/ext4_types.h#L318-L345)

每个块组都有一个块组描述符，记录该组的元数据位置和统计信息。

```c
struct ext4_bgroup {
    // === 低 32 位字段 ===
    uint32_t block_bitmap_lo;             // 块位图所在块号（低 32 位）
    uint32_t inode_bitmap_lo;             // Inode 位图所在块号（低 32 位）
    uint32_t inode_table_first_block_lo;  // Inode 表起始块号（低 32 位）
    uint16_t free_blocks_count_lo;        // 空闲块计数（低 16 位）
    uint16_t free_inodes_count_lo;        // 空闲 inode 计数（低 16 位）
    uint16_t used_dirs_count_lo;          // 已用目录计数（低 16 位）
    uint16_t flags;                       // 块组标志（INODE_UNINIT 等）
    uint32_t exclude_bitmap_lo;           // 快照排除位图（低 32 位）
    uint16_t block_bitmap_csum_lo;        // 块位图校验和（低 16 位）
    uint16_t inode_bitmap_csum_lo;        // Inode 位图校验和（低 16 位）
    uint16_t itable_unused_lo;            // 未使用 inode 计数（低 16 位）
    uint16_t checksum;                    // crc16(sb_uuid+group+desc)

    // === 高 32 位字段（64 位支持） ===
    uint32_t block_bitmap_hi;             // 块位图所在块号（高 32 位）
    uint32_t inode_bitmap_hi;             // Inode 位图所在块号（高 32 位）
    uint32_t inode_table_first_block_hi;  // Inode 表起始块号（高 32 位）
    uint16_t free_blocks_count_hi;        // 空闲块计数（高 16 位）
    uint16_t free_inodes_count_hi;        // 空闲 inode 计数（高 16 位）
    uint16_t used_dirs_count_hi;          // 已用目录计数（高 16 位）
    uint16_t itable_unused_hi;            // 未使用 inode 计数（高 16 位）
    uint32_t exclude_bitmap_hi;           // 快照排除位图（高 32 位）
    uint16_t block_bitmap_csum_hi;        // 块位图校验和（高 16 位）
    uint16_t inode_bitmap_csum_hi;        // Inode 位图校验和（高 16 位）
    uint32_t reserved;                    // 保留填充
};
```

**关键宏定义**:
| 宏 | 值 | 描述 |
|---|---|---|
| `EXT4_MIN_BLOCK_GROUP_DESCRIPTOR_SIZE` | `32` | 最小块组描述符大小 |
| `EXT4_MAX_BLOCK_GROUP_DESCRIPTOR_SIZE` | `64` | 最大块组描述符大小 |

---

### 3. `struct ext4_inode` —— I-Node 结构

**文件位置**: [ext4_types.h:L370-L416](file:///d:/lwext4/include/ext4_types.h#L370-L416)

每个文件和目录在磁盘上都由一个 inode 表示，包含文件元数据和数据块指针。

```c
struct ext4_inode {
    uint16_t mode;                // 文件模式（类型 + 权限）
    uint16_t uid;                 // 所有者 UID（低 16 位）
    uint32_t size_lo;             // 文件大小（低 32 位）
    uint32_t access_time;         // 最后访问时间
    uint32_t change_inode_time;   // Inode 变更时间
    uint32_t modification_time;   // 最后修改时间
    uint32_t deletion_time;       // 删除时间
    uint16_t gid;                 // 组 GID（低 16 位）
    uint16_t links_count;         // 硬链接计数
    uint32_t blocks_count_lo;     // 占用块数（低 32 位，以 512 字节为单位）
    uint32_t flags;               // 文件标志（EXTENTS, IMMUTABLE 等）
    uint32_t unused_osd1;         // OS 相关保留
    uint32_t blocks[15];          // 数据块指针数组（12 直接 + 1 间接 + 1 双重间接 + 1 三重间接）
    uint32_t generation;          // 文件版本号（NFS 用）
    uint32_t file_acl_lo;         // 扩展属性块（低 32 位）
    uint32_t size_hi;             // 文件大小（高 32 位）
    uint32_t obso_faddr;          // 废弃的片段地址

    // === OS 相关联合体 ===
    union {
        struct { // Linux
            uint16_t blocks_high;    // 块计数高 16 位
            uint16_t file_acl_high;  // 扩展属性块高 16 位
            uint16_t uid_high;       // UID 高 16 位
            uint16_t gid_high;       // GID 高 16 位
            uint16_t checksum_lo;    // crc32c 校验和低 16 位（LE）
            uint16_t reserved2;
        } linux2;
        struct { // Hurd
            uint16_t reserved1;
            uint16_t mode_high;      // 文件模式高 16 位
            uint16_t uid_high;
            uint16_t gid_high;
            uint32_t author;
        } hurd2;
    } osd2;

    uint16_t extra_isize;         // 额外 inode 大小（超出 128 字节的部分）
    uint16_t checksum_hi;         // crc32c 校验和高 16 位（BE）
    uint32_t ctime_extra;         // 额外变更时间
    uint32_t mtime_extra;         // 额外修改时间
    uint32_t atime_extra;         // 额外访问时间
    uint32_t crtime;              // 创建时间
    uint32_t crtime_extra;        // 额外创建时间
    uint32_t version_hi;          // 64 位版本号高 32 位
};
```

**Inode 数据块指针数组** (`blocks[15]`):
| 索引 | 描述 |
|---|---|
| 0-11 | 直接块指针（12 个） |
| 12 | 单级间接块指针 |
| 13 | 双级间接块指针 |
| 14 | 三级间接块指针 |

---

### 4. 目录相关结构

#### 4.1 `struct ext4_dir_en` —— 目录项（线性目录）

**文件位置**: [ext4_types.h:L462-L469](file:///d:/lwext4/include/ext4_types.h#L462-L469)

ext4 目录是一个包含变长目录项的链表。

```c
union ext4_dir_en_internal {
    uint8_t name_length_high;  // 文件名长度高 8 位
    uint8_t inode_type;        // 引用的 inode 类型（rev >= 0.5）
};

struct ext4_dir_en {
    uint32_t inode;                  // 目录项的 inode 号
    uint16_t entry_len;              // 距下一个目录项的距离（总长度）
    uint8_t  name_len;               // 文件名长度低 8 位
    union ext4_dir_en_internal in;   // 内部联合体
    uint8_t  name[];                 // 柔性数组：文件名
};
```

#### 4.2 `struct ext4_dir_entry_tail` —— 目录块尾部校验

**文件位置**: [ext4_types.h:L558-L563](file:///d:/lwext4/include/ext4_types.h#L558-L563)

放在每个目录叶子块末尾，用于记录校验和。

```c
struct ext4_dir_entry_tail {
    uint32_t reserved_zero1;   // 伪装成未使用
    uint16_t rec_len;          // 记录长度 = 12
    uint8_t  reserved_zero2;   // 零名称长度
    uint8_t  reserved_ft;      // 0xDE，伪文件类型
    uint32_t checksum;         // crc32c(uuid+inum+dirblock)
};
```

#### 4.3 `struct ext4_dir_idx_dot_en` —— HTree 索引目录的 `.` 和 `..` 条目

**文件位置**: [ext4_types.h:L498-L503](file:///d:/lwext4/include/ext4_types.h#L498-L503)

```c
struct ext4_dir_idx_dot_en {
    uint32_t inode;
    uint16_t entry_length;
    uint8_t  name_length;
    uint8_t  inode_type;
    uint8_t  name[4];     // ".\\0\\0\\0" 或 "..\\0\\0"
};
```

#### 4.4 `struct ext4_dir_idx_rinfo` —— HTree 根节点信息

**文件位置**: [ext4_types.h:L505-L509](file:///d:/lwext4/include/ext4_types.h#L505-L509)

```c
struct ext4_dir_idx_rinfo {
    uint32_t reserved_zero;
    uint8_t  hash_version;       // 哈希版本
    uint8_t  info_length;        // 信息长度
    uint8_t  indirect_levels;    // 间接层级数
    uint8_t  unused_flags;       // 未用标志
};
```

#### 4.5 `struct ext4_dir_idx_entry` —— HTree 索引条目

**文件位置**: [ext4_types.h:L511-L514](file:///d:/lwext4/include/ext4_types.h#L511-L514)

```c
struct ext4_dir_idx_entry {
    uint32_t hash;    // 哈希值
    uint32_t block;   // 数据块号
};
```

#### 4.6 `struct ext4_dir_idx_root` —— HTree 根节点

**文件位置**: [ext4_types.h:L516-L520](file:///d:/lwext4/include/ext4_types.h#L516-L520)

```c
struct ext4_dir_idx_root {
    struct ext4_dir_idx_dot_en dots[2];  // "." 和 ".." 条目
    struct ext4_dir_idx_rinfo info;       // 根信息
    struct ext4_dir_idx_entry en[];       // 柔性数组：索引条目
};
```

#### 4.7 `struct ext4_fake_dir_entry` —— 伪目录条目（HTree 内部节点用）

**文件位置**: [ext4_types.h:L531-L536](file:///d:/lwext4/include/ext4_types.h#L531-L536)

```c
struct ext4_fake_dir_entry {
    uint32_t inode;          // = 0
    uint16_t entry_length;   // 条目长度
    uint8_t  name_length;    // = 0
    uint8_t  inode_type;     // = 0
};
```

#### 4.8 `struct ext4_dir_idx_node` —— HTree 内部节点

**文件位置**: [ext4_types.h:L538-L541](file:///d:/lwext4/include/ext4_types.h#L538-L541)

```c
struct ext4_dir_idx_node {
    struct ext4_fake_dir_entry fake;         // 伪目录条目
    struct ext4_dir_idx_entry entries[];     // 柔性数组：索引条目
};
```

#### 4.9 `struct ext4_dir_idx_tail` —— HTree 块尾部

**文件位置**: [ext4_types.h:L546-L549](file:///d:/lwext4/include/ext4_types.h#L546-L549)

```c
struct ext4_dir_idx_tail {
    uint32_t reserved;
    uint32_t checksum;  // crc32c(uuid+inum+dirblock)
};
```

#### 4.10 `struct ext4_dir_idx_climit` —— 目录索引计数限制

**文件位置**: [ext4_types.h:L492-L495](file:///d:/lwext4/include/ext4_types.h#L492-L495)

```c
struct ext4_dir_idx_climit {
    uint16_t limit;
    uint16_t count;
};
```

---

### 5. Extent（区段树）相关结构

**文件位置**: [ext4_extent.c:L84-L126](file:///d:/lwext4/src/ext4_extent.c#L84-L126)

ext4 使用 extent 树替代传统的间接块映射，提供更高效的大文件支持。

#### 5.1 `struct ext4_extent_header` —— 区段树头

```c
struct ext4_extent_header {
    uint16_t magic;              // 魔数 0xF30A
    uint16_t entries_count;      // 当前有效条目数
    uint16_t max_entries_count;  // 最大容量
    uint16_t depth;              // 树深度（叶子节点为 0）
    uint32_t generation;         // 树的代数
};
```

#### 5.2 `struct ext4_extent` —— 区段（叶子节点）

```c
struct ext4_extent {
    uint32_t first_block;  // 区段覆盖的第一个逻辑块
    uint16_t block_count;  // 区段覆盖的块数（MSB 表示是否已初始化）
    uint16_t start_hi;     // 物理块号高 16 位
    uint32_t start_lo;     // 物理块号低 32 位
};
```

#### 5.3 `struct ext4_extent_index` —— 区段索引（内部节点）

```c
struct ext4_extent_index {
    uint32_t first_block;  // 索引覆盖的逻辑块起始
    uint32_t leaf_lo;      // 下一级物理块号低 32 位
    uint16_t leaf_hi;      // 下一级物理块号高 16 位
    uint16_t padding;      // 填充
};
```

#### 5.4 `struct ext4_extent_tail` —— 区段块尾部校验

**文件位置**: [ext4_extent.c:L84-L87](file:///d:/lwext4/src/ext4_extent.c#L84-L87)

```c
struct ext4_extent_tail {
    uint32_t et_checksum;  // crc32c(uuid+inum+extent_block)
};
```

#### 5.5 `struct ext4_extent_path` —— 区段树路径（运行时用）

**文件位置**: [ext4_extent.c:L64-L72](file:///d:/lwext4/src/ext4_extent.c#L64-L72)

```c
struct ext4_extent_path {
    ext4_fsblk_t p_block;                     // 当前块号
    struct ext4_block block;                   // 块缓存引用
    int32_t depth;                             // 当前深度
    int32_t maxdepth;                          // 最大深度
    struct ext4_extent_header *header;          // 区段头指针
    struct ext4_extent_index *index;           // 区段索引指针
    struct ext4_extent *extent;                // 区段指针
};
```

---

### 6. JBD（Journal Block Device）日志结构

**文件位置**: [ext4_types.h:L621-L782](file:///d:/lwext4/include/ext4_types.h#L621-L782)

JBD 使用大端字节序（Big-Endian）。日志用于保证文件系统操作的一致性。

#### 6.1 `struct jbd_bhdr` —— JBD 通用块头

```c
struct jbd_bhdr {
    uint32_t magic;       // 魔数 0xC03B3998
    uint32_t blocktype;   // 块类型（描述符/提交/超级块/撤销）
    uint32_t sequence;    // 序列号
};
```

#### 6.2 `struct jbd_sb` —— JBD 超级块

```c
struct jbd_sb {
    struct jbd_bhdr header;        // 0x0000: 通用块头
    uint32_t blocksize;            // 0x000C: 日志设备块大小
    uint32_t maxlen;               // 0x0010: 日志文件总块数
    uint32_t first;                // 0x0014: 日志信息的第一个块
    uint32_t sequence;             // 0x0018: 预期的第一个提交 ID
    uint32_t start;                // 0x001C: 日志起始块号
    int32_t  error_val;            // 0x0020: 错误值
    uint32_t feature_compat;       // 0x0024: 兼容特性集
    uint32_t feature_incompat;     // 0x0028: 不兼容特性集
    uint32_t feature_ro_compat;    // 0x002C: 只读兼容特性集
    uint8_t  uuid[16];             // 0x0030: 128 位 UUID
    uint32_t nr_users;             // 0x0040: 共享日志的文件系统数
    uint32_t dynsuper;             // 0x0044: 动态超级块副本的块号
    uint32_t max_transaction;      // 0x0048: 每事务最大日志块数
    uint32_t max_trandata;         // 0x004C: 每事务最大数据块数
    uint8_t  checksum_type;        // 0x0050: 校验和类型
    uint8_t  padding2[3];
    uint32_t padding[42];
    uint32_t checksum;             // crc32c(superblock)
    uint8_t  users[768];           // 0x0100: 共享日志的所有文件系统 ID
};
```

#### 6.3 `struct jbd_commit_header` —— 提交块头

```c
struct jbd_commit_header {
    struct jbd_bhdr header;
    uint8_t  chksum_type;
    uint8_t  chksum_size;
    uint8_t  padding[2];
    uint32_t chksum[8];         // 校验和数组
    uint64_t commit_sec;        // 提交时间（秒）
    uint32_t commit_nsec;       // 提交时间（纳秒）
};
```

#### 6.4 `struct jbd_block_tag3` —— 块标签 v3（CSUM_V3 格式）

```c
struct jbd_block_tag3 {
    uint32_t blocknr;       // 磁盘块号
    uint32_t flags;         // 标志位
    uint32_t blocknr_high;  // 块号高 32 位
    uint32_t checksum;      // crc32c(uuid+seq+block)
};
```

#### 6.5 `struct jbd_block_tag` —— 块标签（CSUM_V1/V2 格式）

```c
struct jbd_block_tag {
    uint32_t blocknr;       // 磁盘块号
    uint16_t checksum;      // 截断的 crc32c(uuid+seq+block)
    uint16_t flags;         // 标志位
    uint32_t blocknr_high;  // 块号高 32 位
};
```

#### 6.6 `struct jbd_block_tail` —— 描述符块尾部

```c
struct jbd_block_tail {
    uint32_t checksum;
};
```

#### 6.7 `struct jbd_revoke_header` —— 撤销描述符

```c
struct jbd_revoke_header {
    struct jbd_bhdr header;
    uint32_t count;    // 块中使用的字节数
};
```

#### 6.8 `struct jbd_revoke_tail` —— 撤销块尾部

```c
struct jbd_revoke_tail {
    uint32_t checksum;
};
```

---

### 7. 扩展属性（xattr）结构

**文件位置**: [ext4_xattr.c:L92-L113](file:///d:/lwext4/src/ext4_xattr.c#L92-L113)

#### 7.1 `struct ext4_xattr_header` —— 扩展属性块头

```c
struct ext4_xattr_header {
    uint32_t h_magic;         // 魔数
    uint32_t h_refcount;      // 引用计数
    uint32_t h_blocks;        // 使用的磁盘块数
    uint32_t h_hash;          // 所有属性的哈希值
    uint32_t h_checksum;      // crc32c(uuid+id+xattrblock)
    uint32_t h_reserved[3];   // 保留
};
```

#### 7.2 `struct ext4_xattr_ibody_header` —— 扩展属性 inode 内嵌头

```c
struct ext4_xattr_ibody_header {
    uint32_t h_magic;    // 魔数
};
```

#### 7.3 `struct ext4_xattr_entry` —— 扩展属性条目

```c
struct ext4_xattr_entry {
    uint8_t  e_name_len;     // 属性名长度
    uint8_t  e_name_index;   // 属性名前缀索引
    uint16_t e_value_offs;   // 值在磁盘块中的偏移
    uint32_t e_value_block;  // 值所在的磁盘块
    uint32_t e_value_size;   // 属性值大小
    uint32_t e_hash;         // 名称和值的哈希
};
```

---

## 内存管理结构

### 8. `struct ext4_blockdev` —— 块设备描述符

**文件位置**: [ext4_blockdev.h:L99-L115](file:///d:/lwext4/include/ext4_blockdev.h#L99-L115)

```c
struct ext4_blockdev {
    struct ext4_blockdev_iface *bdif;  // 块设备接口（驱动函数表）
    uint64_t part_offset;              // 分区偏移（多分区模式）
    uint64_t part_size;                // 分区大小（多分区模式）
    struct ext4_bcache *bc;            // 块缓存
    uint32_t lg_bsize;                 // 逻辑块大小（字节）
    uint64_t lg_bcnt;                  // 逻辑块计数
    uint32_t cache_write_back;         // 写回缓存引用计数
    struct ext4_fs *fs;                // 所属文件系统
    void *journal;                     // 日志相关
};
```

### 9. `struct ext4_blockdev_iface` —— 块设备接口

**文件位置**: [ext4_blockdev.h:L43-L88](file:///d:/lwext4/include/ext4_blockdev.h#L43-L88)

```c
struct ext4_blockdev_iface {
    int (*open)(struct ext4_blockdev *bdev);     // 打开设备
    int (*bread)(struct ext4_blockdev *bdev,      // 块读取
                 void *buf, uint64_t blk_id, uint32_t blk_cnt);
    int (*bwrite)(struct ext4_blockdev *bdev,     // 块写入
                  const void *buf, uint64_t blk_id, uint32_t blk_cnt);
    int (*close)(struct ext4_blockdev *bdev);     // 关闭设备
    int (*lock)(struct ext4_blockdev *bdev);       // 锁定设备
    int (*unlock)(struct ext4_blockdev *bdev);     // 解锁设备
    uint32_t ph_bsize;     // 物理块大小
    uint64_t ph_bcnt;      // 物理块计数
    uint8_t *ph_bbuf;      // 物理块缓冲区
    uint32_t ph_refctr;    // 引用计数
    uint32_t bread_ctr;    // 物理读计数
    uint32_t bwrite_ctr;   // 物理写计数
    void* p_user;           // 用户数据指针
};
```

### 10. `struct ext4_bcache` —— 块缓存

**文件位置**: [ext4_bcache.h:L99-L119](file:///d:/lwext4/include/ext4_bcache.h#L99-L119)

```c
struct ext4_bcache {
    uint32_t cnt;              // 缓存项数量
    uint32_t itemsize;         // 单项大小
    uint32_t lru_ctr;          // LRU 计数器
    uint32_t ref_blocks;       // 当前被引用的数据块数
    uint32_t max_ref_blocks;   // 最大引用数据块数
    struct ext4_blockdev *bdev; // 绑定的块设备
    bool dont_shake;            // 禁止抖动标志
    RB_HEAD(ext4_buf_lba, ext4_buf) lba_root;    // LBA 红黑树
    RB_HEAD(ext4_buf_lru, ext4_buf) lru_root;    // LRU 红黑树
    SLIST_HEAD(ext4_buf_dirty, ext4_buf) dirty_list; // 脏缓冲链表
};
```

### 11. `struct ext4_buf` —— 缓冲区描述符

**文件位置**: [ext4_bcache.h:L62-L93](file:///d:/lwext4/include/ext4_bcache.h#L62-L93)

```c
struct ext4_buf {
    int flags;                   // 状态标志（BC_UPTODATE, BC_DIRTY, BC_FLUSH, BC_TMP）
    uint64_t lba;                // 逻辑块地址
    uint8_t *data;               // 数据缓冲区
    uint32_t lru_prio;           // LRU 优先级
    uint32_t lru_id;             // LRU ID
    uint32_t refctr;             // 引用计数
    uint32_t read_refctr;        // 读引用计数
    struct ext4_bcache *bc;      // 所属块缓存
    bool on_dirty_list;          // 是否在脏链表上
    RB_ENTRY(ext4_buf) lba_node;   // LBA 红黑树节点
    RB_ENTRY(ext4_buf) lru_node;   // LRU 红黑树节点
    SLIST_ENTRY(ext4_buf) dirty_node; // 脏链表节点
    void (*end_write)(...);      // 写完成回调
    void *end_write_arg;         // 回调参数
};
```

### 12. `struct ext4_block` —— 块描述符

**文件位置**: [ext4_bcache.h:L52-L59](file:///d:/lwext4/include/ext4_bcache.h#L52-L59)

```c
struct ext4_block {
    uint64_t lb_id;       // 逻辑块 ID
    struct ext4_buf *buf; // 缓冲区指针
    uint8_t *data;        // 数据指针（指向 buf->data）
};
```

### 13. `struct ext4_fs` —— 文件系统运行时结构

**文件位置**: [ext4_fs.h:L57-L70](file:///d:/lwext4/include/ext4_fs.h#L57-L70)

```c
struct ext4_fs {
    bool read_only;                       // 只读标志
    struct ext4_blockdev *bdev;           // 块设备
    struct ext4_sblock sb;                // 超级块副本
    uint64_t inode_block_limits[4];       // inode 块限制
    uint64_t inode_blocks_per_level[4];   // 每级的 inode 块数
    uint32_t last_inode_bg_id;            // 最后分配的 inode 块组
    struct jbd_fs *jbd_fs;                // JBD 文件系统
    struct jbd_journal *jbd_journal;      // JBD 日志
    struct jbd_trans *curr_trans;         // 当前事务
};
```

### 14. `struct ext4_block_group_ref` —— 块组引用

**文件位置**: [ext4_fs.h:L72-L77](file:///d:/lwext4/include/ext4_fs.h#L72-L77)

```c
struct ext4_block_group_ref {
    struct ext4_block block;         // 块缓存引用
    struct ext4_bgroup *block_group; // 指向块内块组描述符的指针
    struct ext4_fs *fs;              // 所属文件系统
    uint32_t index;                  // 块组索引
    bool dirty;                      // 脏标志
};
```

### 15. `struct ext4_inode_ref` —— Inode 引用

**文件位置**: [ext4_fs.h:L79-L84](file:///d:/lwext4/include/ext4_fs.h#L79-L84)

```c
struct ext4_inode_ref {
    struct ext4_block block;  // 块缓存引用
    struct ext4_inode *inode; // 指向块内 inode 的指针
    struct ext4_fs *fs;       // 所属文件系统
    uint32_t index;           // inode 号
    bool dirty;               // 脏标志
};
```

### 16. 目录操作运行时结构

#### 16.1 `struct ext4_dir_iter` —— 目录迭代器

**文件位置**: [ext4_dir.h:L52-L56](file:///d:/lwext4/include/ext4_dir.h#L52-L56)

```c
struct ext4_dir_iter {
    struct ext4_inode_ref *inode_ref; // 目录 inode
    struct ext4_block curr_blk;       // 当前块
    uint64_t curr_off;                // 当前偏移
    struct ext4_dir_en *curr;         // 当前条目指针
};
```

#### 16.2 `struct ext4_dir_search_result` —— 目录搜索结果

**文件位置**: [ext4_dir.h:L58-L61](file:///d:/lwext4/include/ext4_dir.h#L58-L61)

```c
struct ext4_dir_search_result {
    struct ext4_block block;    // 找到条目所在的块
    struct ext4_dir_en *dentry; // 指向目录项的指针
};
```

#### 16.3 `struct ext4_dir_idx_block` —— 索引目录块

**文件位置**: [ext4_dir_idx.h:L49-L53](file:///d:/lwext4/include/ext4_dir_idx.h#L49-L53)

```c
struct ext4_dir_idx_block {
    struct ext4_block b;                    // 块
    struct ext4_dir_idx_entry *entries;     // 条目数组
    struct ext4_dir_idx_entry *position;    // 当前位置
};
```

### 17. JBD 运行结构

**文件位置**: [ext4_journal.h:L50-L112](file:///d:/lwext4/include/ext4_journal.h#L50-L112)

#### 17.1 `struct jbd_fs` —— JBD 文件系统

```c
struct jbd_fs {
    struct ext4_blockdev *bdev;      // 块设备
    struct ext4_inode_ref inode_ref; // 日志 inode 引用
    struct jbd_sb sb;                // JBD 超级块
    bool dirty;                      // 脏标志
};
```

#### 17.2 `struct jbd_buf` —— JBD 缓冲区

```c
struct jbd_buf {
    uint32_t jbd_lba;                    // JBD 逻辑块地址
    struct ext4_block block;             // ext4 块
    struct jbd_trans *trans;             // 所属事务
    struct jbd_block_rec *block_rec;     // 所属块记录
    TAILQ_ENTRY(jbd_buf) buf_node;       // 缓冲区链表节点
    TAILQ_ENTRY(jbd_buf) dirty_buf_node; // 脏缓冲区链表节点
};
```

#### 17.3 `struct jbd_revoke_rec` —— JBD 撤销记录

```c
struct jbd_revoke_rec {
    ext4_fsblk_t lba;                    // 逻辑块地址
    RB_ENTRY(jbd_revoke_rec) revoke_node; // 红黑树节点
};
```

#### 17.4 `struct jbd_block_rec` —— JBD 块记录

```c
struct jbd_block_rec {
    ext4_fsblk_t lba;                          // 逻辑块地址
    struct jbd_trans *trans;                    // 所属事务
    RB_ENTRY(jbd_block_rec) block_rec_node;     // 红黑树节点
    LIST_ENTRY(jbd_block_rec) tbrec_node;       // 事务块记录链表
    TAILQ_HEAD(jbd_buf_dirty, jbd_buf) dirty_buf_queue; // 脏缓冲区队列
};
```

#### 17.5 `struct jbd_trans` —— JBD 事务

```c
struct jbd_trans {
    uint32_t trans_id;                                  // 事务 ID
    uint32_t start_iblock;                              // 起始 iblock
    int alloc_blocks;                                   // 分配的块数
    int data_cnt;                                       // 数据计数
    uint32_t data_csum;                                 // 数据校验和
    int written_cnt;                                    // 已写入计数
    int error;                                          // 错误码
    struct jbd_journal *journal;                        // 所属日志
    TAILQ_HEAD(jbd_trans_buf, jbd_buf) buf_queue;       // 缓冲区队列
    RB_HEAD(jbd_revoke_tree, jbd_revoke_rec) revoke_root; // 撤销红黑树
    LIST_HEAD(jbd_trans_block_rec, jbd_block_rec) tbrec_list; // 块记录链表
    TAILQ_ENTRY(jbd_trans) trans_node;                  // 事务链表节点
};
```

#### 17.6 `struct jbd_journal` —— JBD 日志

```c
struct jbd_journal {
    uint32_t first;                                     // 第一个块
    uint32_t start;                                     // 起始块
    uint32_t last;                                      // 最后块
    uint32_t trans_id;                                  // 事务 ID
    uint32_t alloc_trans_id;                            // 分配的事务 ID
    uint32_t block_size;                                // 块大小
    TAILQ_HEAD(jbd_cp_queue, jbd_trans) cp_queue;       // 检查点队列
    RB_HEAD(jbd_block, jbd_block_rec) block_rec_root;   // 块记录红黑树
    struct jbd_fs *jbd_fs;                              // JBD 文件系统
};
```

### 18. `struct ext4_mountpoint` —— 挂载点

**文件位置**: [ext4_mp.h:L39-L57](file:///d:/lwext4/include/ext4_mp.h#L39-L57)

```c
struct ext4_mountpoint {
    bool mounted;                                       // 已挂载标志
    char name[CONFIG_EXT4_MAX_MP_NAME + 1];             // 挂载点名
    const struct ext4_lock *os_locks;                   // OS 锁接口
    struct ext4_fs fs;                                  // ext4 文件系统
    struct jbd_fs jbd_fs;                               // JBD 文件系统
    struct jbd_journal jbd_journal;                     // JBD 日志
    struct ext4_bcache bc;                              // 块缓存
};
```

### 19. 扩展属性操作结构

**文件位置**: [ext4_xattr.h:L48-L76](file:///d:/lwext4/include/ext4_xattr.h#L48-L76)

#### 19.1 `struct ext4_xattr_info` —— 扩展属性信息

```c
struct ext4_xattr_info {
    uint8_t name_index;       // 属性名前缀索引
    const char *name;         // 属性名
    size_t name_len;          // 属性名长度
    const void *value;        // 属性值
    size_t value_len;         // 属性值长度
};
```

#### 19.2 `struct ext4_xattr_list_entry` —— 扩展属性列表条目

```c
struct ext4_xattr_list_entry {
    uint8_t name_index;                    // 属性名前缀索引
    char *name;                            // 属性名
    size_t name_len;                       // 属性名长度
    struct ext4_xattr_list_entry *next;    // 下一个条目
};
```

#### 19.3 `struct ext4_xattr_search` —— 扩展属性搜索上下文

```c
struct ext4_xattr_search {
    struct ext4_xattr_entry *first;  // 缓冲区中的首个条目
    void *base;                      // 缓冲区地址
    void *end;                       // 首个不可访问地址
    struct ext4_xattr_entry *here;   // 当前条目
    bool not_found;                  // 未找到标志
};
```

### 20. `struct ext4_hash_info` —— 哈希信息

**文件位置**: [ext4_hash.h:L42-L47](file:///d:/lwext4/include/ext4_hash.h#L42-L47)

```c
struct ext4_hash_info {
    uint32_t hash;            // 主哈希值
    uint32_t minor_hash;      // 次哈希值
    uint32_t hash_version;    // 哈希版本
    const uint32_t *seed;     // 哈希种子
};
```

### 21. `struct ext4_mkfs_info` —— 格式化参数

**文件位置**: [ext4_mkfs.h:L49-L63](file:///d:/lwext4/include/ext4_mkfs.h#L49-L63)

```c
struct ext4_mkfs_info {
    uint64_t len;                    // 设备长度
    uint32_t block_size;             // 块大小
    uint32_t blocks_per_group;       // 每块组块数
    uint32_t inodes_per_group;       // 每块组 inode 数
    uint32_t inode_size;             // inode 大小
    uint32_t inodes;                 // inode 总数
    uint32_t journal_blocks;         // 日志块数
    uint32_t feat_ro_compat;         // 只读兼容特性
    uint32_t feat_compat;            // 兼容特性
    uint32_t feat_incompat;          // 不兼容特性
    uint32_t bg_desc_reserve_blocks; // 块组描述符保留块
    uint16_t dsc_size;               // 描述符大小
    uint8_t  uuid[16];               // UUID
    bool journal;                    // 是否启用日志
    const char *label;               // 卷标
};
```

---

## API 层结构

### 22. `struct ext4_lock` —— OS 锁接口

**文件位置**: [ext4.h:L60-L64](file:///d:/lwext4/include/ext4.h#L60-L64)

```c
struct ext4_lock {
    void (*lock)(void);    // 锁定函数
    void (*unlock)(void);  // 解锁函数
};
```

### 23. `ext4_file` —— 文件描述符

**文件位置**: [ext4.h:L68-L77](file:///d:/lwext4/include/ext4.h#L68-L77)

```c
typedef struct ext4_file {
    struct ext4_mountpoint *mp;  // 挂载点句柄
    uint32_t inode;               // 文件 inode 号
    uint32_t flags;               // 打开标志
    uint64_t fsize;               // 文件大小
    uint64_t fpos;                // 当前文件位置
} ext4_file;
```

### 24. `ext4_direntry` —— 目录条目描述符

**文件位置**: [ext4.h:L80-L85](file:///d:/lwext4/include/ext4.h#L80-L85)

```c
typedef struct ext4_direntry {
    uint32_t inode;          // inode 号
    uint16_t entry_length;   // 条目长度
    uint8_t name_length;     // 名称长度
    uint8_t inode_type;      // inode 类型
    uint8_t name[255];       // 名称
} ext4_direntry;
```

### 25. `ext4_dir` —— 目录描述符

**文件位置**: [ext4.h:L88-L93](file:///d:/lwext4/include/ext4.h#L88-L93)

```c
typedef struct ext4_dir {
    ext4_file f;             // 文件描述符
    ext4_direntry de;        // 当前目录条目
    uint64_t next_off;       // 下一个条目偏移
} ext4_dir;
```

### 26. `struct ext4_mount_stats` —— 文件系统统计

**文件位置**: [ext4.h:L144-L154](file:///d:/lwext4/include/ext4.h#L144-L154)

```c
struct ext4_mount_stats {
    uint32_t inodes_count;         // inode 总数
    uint32_t free_inodes_count;    // 空闲 inode 数
    uint64_t blocks_count;         // 块总数
    uint64_t free_blocks_count;    // 空闲块数
    uint32_t block_size;           // 块大小
    uint32_t block_group_count;    // 块组数
    uint32_t blocks_per_group;     // 每组块数
    uint32_t inodes_per_group;     // 每组 inode 数
    char volume_name[16];          // 卷名
};
```

### 27. MBR 相关结构

**文件位置**: [ext4_mbr.h:L46-L56](file:///d:/lwext4/include/ext4_mbr.h#L46-L56)

#### 27.1 `struct ext4_mbr_bdevs` —— MBR 分区设备

```c
struct ext4_mbr_bdevs {
    struct ext4_blockdev partitions[4];  // 4 个主分区
};
```

#### 27.2 `struct ext4_mbr_parts` —— MBR 分区比例

```c
struct ext4_mbr_parts {
    uint8_t division[4];  // 百分比分配（总和 <= 100）
};
```

---

## 结构体关系图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ext4_mountpoint                             │
│  (挂载点：一切操作的入口)                                              │
├─────────────────────────────────────────────────────────────────────┤
│  ├── ext4_fs ───────────────────────────────────────────────────┐   │
│  │   │  ext4_sblock (超级块副本)                                  │   │
│  │   │  ext4_blockdev* ──► ext4_blockdev ──► ext4_blockdev_iface │   │
│  │   │  jbd_fs*, jbd_journal*, curr_trans*                       │   │
│  │   └── 通过 ext4_block_group_ref / ext4_inode_ref 访问磁盘     │   │
│  │                                                                  │   │
│  ├── ext4_bcache (块缓存)                                           │   │
│  │   └── ext4_buf[] (缓冲区数组，LRU + LBA 红黑树管理)               │   │
│  │                                                                  │   │
│  ├── jbd_fs                                                         │   │
│  │   └── jbd_sb (JBD 超级块)                                        │   │
│  │                                                                  │   │
│  └── jbd_journal (日志管理器)                                        │   │
│      └── jbd_trans (事务链表)                                        │   │
│          └── jbd_buf[] (事务缓冲区)                                  │   │
└─────────────────────────────────────────────────────────────────────┘

磁盘布局:
┌─────────────────────────────────────────────────────────────────────┐
│ SuperBlock │ GDT │ Block Bitmap │ Inode Bitmap │ Inode Table │ Data │
│  (1024B)   │     │              │              │             │      │
└─────────────────────────────────────────────────────────────────────┘

Inode → 数据块映射:
  if EXTENTS:  blocks[] → ext4_extent_header → ext4_extent (叶子)
  if 传统:     blocks[0..11] 直接, blocks[12] 单间接, blocks[13] 双间接

目录结构:
  线性: ext4_dir_en 链表
  HTree: ext4_dir_idx_root → ext4_dir_idx_node → ext4_dir_en (叶子)
```

---

## 关键设计特点

1. **紧凑打包**：所有磁盘结构使用 `#pragma pack(push, 1)`，确保跨平台兼容。

2. **64 位支持**：通过 `_lo`/`_hi` 字段对实现 64 位值，兼容 32 位系统。

3. **字节序处理**：
   - ext4 磁盘数据：小端序（Little-Endian），通过 `to_le32()`/`to_le16()` 宏访问
   - JBD 日志数据：大端序（Big-Endian），通过 `to_be32()`/`to_be16()` 宏访问

4. **双模式文件映射**：Inode 支持传统间接块映射和 ext4 extent 区段树两种方式。

5. **块缓存层**：使用红黑树实现 LBA 索引和 LRU 淘汰策略。

6. **HTree 目录索引**：使用哈希 B 树加速大目录的文件名查找。

7. **JBD 事务日志**：完整实现 JBD2 日志，支持 CSUM_V2/V3 校验和格式。