#!/bin/bash
# Adds SUS_MAP hooks to stock LineageOS kernel files
# Adapted from Andrey0800770's implementation for LineageOS function signatures
set -e

echo "== Adding SUS_MAP hooks to kernel =="

# ─── 1. fs/proc/task_mmu.c ──────────────────────────────────────────────
TMC="fs/proc/task_mmu.c"
echo "  [1/2] Patching $TMC..."

# Add include after existing includes
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$TMC"; then
    # Find last #include line
    LAST_INC=$(grep -n "^#include" "$TMC" | tail -1 | cut -d: -f1)
    sed -i "${LAST_INC}a\\
#if defined(CONFIG_KSU_SUSFS_SUS_MAP)\\
#include <linux/susfs_def.h>\\
#endif" "$TMC"
    echo "    Added SUS_MAP include"

    # Hook in show_map_vma: inside "if (file)" block, before "dev = inode->..."
    # Stock LineageOS has: dev = inode->i_sb->s_dev;
    DEV_LINE=$(grep -n "dev = inode->i_sb->s_dev" "$TMC" | head -1 | cut -d: -f1)
    if [ -n "$DEV_LINE" ]; then
        sed -i "${DEV_LINE}i\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\tif (unlikely(inode->i_mapping->flags \\& BIT_SUS_MAPS) \\&\\& susfs_is_current_proc_umounted()) {\\
\t\t\tfile = NULL;\\
\t\t\tgoto done;\\
\t\t}\\
#endif" "$TMC"
        echo "    Added show_map_vma hook at line $DEV_LINE"
    fi

    # Check if "done:" label already exists (from susfs-kernel.patch)
    if ! grep -q "^done:" "$TMC" && ! grep -q "^#.*done:" "$TMC"; then
        DONE_LINE=$(grep -n "seq_putc(m, '\\\\n')" "$TMC" | head -1 | cut -d: -f1)
        if [ -n "$DONE_LINE" ]; then
            sed -i "${DONE_LINE}i\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
done:\\
#endif" "$TMC"
            echo "    Added done: label"
        fi
    else
        echo "    done: label already exists"
    fi

    # Hook in show_smap: skip stats for hidden maps
    SMAP_GATHER=$(grep -n "smap_gather_stats" "$TMC" | head -1 | cut -d: -f1)
    if [ -n "$SMAP_GATHER" ]; then
        sed -i "${SMAP_GATHER}i\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\tif (vma->vm_file \\&\\&\\
\t\tunlikely(file_inode(vma->vm_file)->i_mapping->flags \\& BIT_SUS_MAPS) \\&\\&\\
\t\tsusfs_is_current_proc_umounted())\\
\t\treturn 0;\\
#endif" "$TMC"
        echo "    Added show_smap hook"
    fi

    echo "    $TMC patched"
else
    echo "    $TMC already has SUS_MAP hooks"
fi

# ─── 2. fs/proc/base.c ──────────────────────────────────────────────────
BC="fs/proc/base.c"
echo "  [2/2] Patching $BC..."

if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$BC"; then
    # Add include
    LAST_INC=$(grep -n "^#include" "$BC" | tail -1 | cut -d: -f1)
    sed -i "${LAST_INC}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
#include <linux/susfs_def.h>\\
#endif" "$BC"

    # Hook in proc_map_files_readdir: skip hidden mappings
    # Find "if (!vma->vm_file)" or the vma iteration in map_files
    MAP_FILES_SKIP=$(grep -n "!vma->vm_file" "$BC" | grep -i "continue" | head -1 | cut -d: -f1)
    if [ -n "$MAP_FILES_SKIP" ]; then
        sed -i "$((MAP_FILES_SKIP+1))a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\t\tif (vma->vm_file \\&\\& unlikely(file_inode(vma->vm_file)->i_mapping->flags \\& BIT_SUS_MAPS) \\&\\& susfs_is_current_proc_umounted()) continue;\\
#endif" "$BC"
        echo "    Added map_files hook"
    fi

    echo "    $BC patched"
else
    echo "    $BC already has SUS_MAP hooks"
fi

echo "== SUS_MAP hooks added =="
