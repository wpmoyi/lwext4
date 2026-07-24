/*
 * Copyright (c) 2024, RT-Thread Development Team
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/** @addtogroup lwext4
 * @{
 */
/**
 * @file  ext4_cow.h
 * @brief Copy-On-Write for per-file transactional writes.
 */

#ifndef EXT4_COW_H_
#define EXT4_COW_H_

#ifdef __cplusplus
extern "C" {
#endif

#include <ext4_config.h>
#include <ext4_types.h>
#include <ext4_fs.h>

#include <stdint.h>
#include <stdbool.h>

#if CONFIG_COW_ENABLE

/**@brief Single COW block mapping entry. */
struct ext4_cow_entry {
    ext4_lblk_t  logical_block;   /**@brief Logical block index within file */
    ext4_fsblk_t old_block;       /**@brief Original physical block (preserved) */
    ext4_fsblk_t new_block;       /**@brief COW copy physical block */
};

/**@brief Per-file COW state, allocated per open file handle. */
struct ext4_cow_file_state {
    bool     active;              /**@brief COW mode is active */
    uint32_t entry_count;         /**@brief Number of active mappings */
    uint32_t entry_capacity;      /**@brief Current capacity of entries array */
    struct ext4_cow_entry *entries; /**@brief Dynamic array of COW mappings */
};

/**
 * @brief Initialize COW state for a file.
 * @param state  Output, allocated COW state pointer
 * @param initial_cap  Initial capacity of mapping array
 * @return EOK on success
 */
int ext4_cow_file_init(struct ext4_cow_file_state **state, uint32_t initial_cap);

/**
 * @brief Cleanup COW state without commit or rollback.
 *        Caller must have already committed or rolled back.
 * @param state  COW state to free
 */
void ext4_cow_file_fini(struct ext4_cow_file_state *state);

/**
 * @brief Check if a block needs COW and perform copy if necessary.
 *        On return, *fblock is the block to write to (may differ from input).
 * @param inode_ref  Inode reference
 * @param state      File COW state
 * @param iblock     Logical block index in file
 * @param fblock     [in/out] Physical block address; updated if COW occurs
 * @return EOK on success
 */
int ext4_cow_check_and_copy(struct ext4_inode_ref *inode_ref,
                             struct ext4_cow_file_state *state,
                             ext4_lblk_t iblock, ext4_fsblk_t *fblock);

/**
 * @brief Commit COW writes: free all original blocks, discard mappings.
 * @param inode_ref  Inode reference
 * @param state      File COW state
 * @return EOK on success
 */
int ext4_cow_commit(struct ext4_inode_ref *inode_ref,
                     struct ext4_cow_file_state *state);

/**
 * @brief Rollback COW writes: restore original block mappings,
 *        free all COW blocks.
 * @param inode_ref  Inode reference
 * @param state      File COW state
 * @return EOK on success
 */
int ext4_cow_rollback(struct ext4_inode_ref *inode_ref,
                       struct ext4_cow_file_state *state);

/**
 * @brief Replace a single block's physical address in the extent tree.
 *        Used internally by ext4_cow_commit.
 * @param inode_ref  Inode reference
 * @param iblock     Logical block index
 * @param old_fblock Current physical block (verified before replacement)
 * @param new_fblock New physical block to point to
 * @return EOK on success
 */
int ext4_extent_replace_block(struct ext4_inode_ref *inode_ref,
                               ext4_lblk_t iblock,
                               ext4_fsblk_t old_fblock,
                               ext4_fsblk_t new_fblock);

#endif /* CONFIG_COW_ENABLE */

#ifdef __cplusplus
}
#endif

#endif /* EXT4_COW_H_ */

/**
 * @}
 */
