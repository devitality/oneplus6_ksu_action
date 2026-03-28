#!/bin/bash
# Adds CONFIG_KSU_SUSFS_SUS_MAP feature to the kernel
# Run from kernel_platform directory AFTER SUSFS v1.5.5 patches are applied
set -e

echo "== Adding SUS_MAP feature to kernel =="

# 1. Add defines to susfs_def.h
echo "  [1/6] Patching include/linux/susfs_def.h..."
DEFH="include/linux/susfs_def.h"

# Add CMD define (after CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING or last CMD)
if ! grep -q "CMD_SUSFS_ADD_SUS_MAP" "$DEFH"; then
    sed -i '/CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING/a #define CMD_SUSFS_ADD_SUS_MAP 0x60020' "$DEFH" 2>/dev/null || \
    sed -i '/CMD_SUSFS_SHOW_VARIANT/a #define CMD_SUSFS_ADD_SUS_MAP 0x60020' "$DEFH"
fi

# Add AS_FLAGS_SUS_MAP (after AS_FLAGS_SDCARD_ROOT_DIR)
if ! grep -q "AS_FLAGS_SUS_MAP" "$DEFH"; then
    sed -i '/AS_FLAGS_SDCARD_ROOT_DIR/a #define AS_FLAGS_SUS_MAP 30' "$DEFH"
fi

# Add BIT_SUS_MAPS (after BIT_ANDROID_SDCARD_ROOT_DIR)
if ! grep -q "BIT_SUS_MAPS" "$DEFH"; then
    sed -i '/BIT_ANDROID_SDCARD_ROOT_DIR/a #define BIT_SUS_MAPS BIT(30)' "$DEFH"
fi

# Add struct st_susfs_sus_map (before FORWARD DECLARATION section)
if ! grep -q "st_susfs_sus_map" "$DEFH"; then
    sed -i '/FORWARD DECLARATION/i \
/* sus_map — struct always defined, guard only on functions */\
struct st_susfs_sus_map {\
\tchar target_pathname[SUSFS_MAX_LEN_PATHNAME];\
};\
' "$DEFH"
fi

# 2. Add declaration to susfs.h
echo "  [2/6] Patching include/linux/susfs.h..."
SUSH="include/linux/susfs.h"
if ! grep -q "susfs_add_sus_map" "$SUSH"; then
    # Add the function declaration WITH its own include to ensure struct visibility
    sed -i '/susfs_get_enabled_features/i \
/* sus_map */\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
#include <linux/susfs_def.h>\
int susfs_add_sus_map(struct st_susfs_sus_map* __user user_info);\
#endif\
' "$SUSH"
fi

# 3. Add function to fs/susfs.c
echo "  [3/6] Patching fs/susfs.c..."
SUSC="fs/susfs.c"
# Ensure susfs_def.h is included (needed for st_susfs_sus_map struct)
if ! grep -q "susfs_def.h" "$SUSC"; then
    LAST_INC=$(grep -n "^#include" "$SUSC" | tail -1 | cut -d: -f1)
    sed -i "${LAST_INC}a #include <linux/susfs_def.h>" "$SUSC"
    echo "    Added susfs_def.h to $SUSC"
fi
if ! grep -q "susfs_add_sus_map" "$SUSC"; then
    sed -i '/^static int copy_config_to_buf/i \
/* sus_map */\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
int susfs_add_sus_map(struct st_susfs_sus_map* __user user_info) {\
\tstruct st_susfs_sus_map info;\
\tstruct path path;\
\tstruct inode *inode = NULL;\
\tint err = 0;\
\n\terr = copy_from_user(\&info, user_info, sizeof(info));\
\tif (err) {\
\t\tSUSFS_LOGE("failed copying from userspace\\n");\
\t\treturn err;\
\t}\
\n\terr = kern_path(info.target_pathname, LOOKUP_FOLLOW, \&path);\
\tif (err) {\
\t\tSUSFS_LOGE("Failed opening file '"'"'%s'"'"'\\n", info.target_pathname);\
\t\treturn err;\
\t}\
\n\tif (!path.dentry->d_inode) {\
\t\terr = -EINVAL;\
\t\tgoto out_path_put;\
\t}\
\tinode = d_inode(path.dentry);\
\tspin_lock(\&inode->i_lock);\
\tset_bit(AS_FLAGS_SUS_MAP, \&inode->i_mapping->flags);\
\tSUSFS_LOGI("pathname: '"'"'%s'"'"', is flagged as AS_FLAGS_SUS_MAP\\n", info.target_pathname);\
\tspin_unlock(\&inode->i_lock);\
out_path_put:\
\tpath_put(\&path);\
\treturn err;\
}\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\
' "$SUSC"
fi

# Add to enabled_features output
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$SUSC"; then
    sed -i '/CONFIG_KSU_SUSFS_OPEN_REDIRECT/{n;s/.*/&\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\terr = copy_config_to_buf("CONFIG_KSU_SUSFS_SUS_MAP\\n", buf_ptr, \&copied_size, bufsize);\n\tif (err) return err;\n#endif/;}' "$SUSC" 2>/dev/null || true
fi

# 4. Add hook to fs/proc/task_mmu.c (show_map_vma — the /proc/self/maps output)
echo "  [4/6] Patching fs/proc/task_mmu.c..."
TMC="fs/proc/task_mmu.c"

# Add susfs_def.h include if not already there for SUS_MAP
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$TMC"; then
    # Replace the existing SUS_KSTAT include guard to also include SUS_MAP
    sed -i 's/#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT/#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP)/' "$TMC" 2>/dev/null || true

    # Add the maps hiding check in show_map_vma (before the dev/ino assignment)
    # Find "if (file)" block in show_map_vma and add SUS_MAP check
    # The key is to make flagged entries show as anonymous (no pathname, zero dev/ino)

    # Create a C snippet to insert
    cat > /tmp/sus_map_task_mmu.c << 'TMMUEOF'
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (file && unlikely(file_inode(vma->vm_file)->i_mapping->flags & BIT_SUS_MAPS) &&
			susfs_is_current_proc_umounted()) {
			/* Hide this mapping — show as anonymous */
			file = NULL;
			dev = 0;
			ino = 0;
		}
#endif
TMMUEOF

    # Insert after "if (file) {" in show_map_vma — find the line with "struct inode *inode"
    LINE=$(grep -n "struct inode \*inode = file_inode" "$TMC" | head -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        sed -i "${LINE}r /tmp/sus_map_task_mmu.c" "$TMC"
        echo "    Inserted SUS_MAP check at line $LINE"
    fi
    rm -f /tmp/sus_map_task_mmu.c
fi

# 5. Add hook to fs/proc/base.c (map_files hiding)
echo "  [5/6] Patching fs/proc/base.c..."
BASEC="fs/proc/base.c"
if ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$BASEC"; then
    # Add include
    sed -i '/#include <linux\/cpufreq_times.h>/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
#include <linux/susfs_def.h>\
#endif' "$BASEC" 2>/dev/null || \
    sed -i '/#include <linux\/flex_array.h>/a \
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
#include <linux/susfs_def.h>\
#endif' "$BASEC"

    # Add map_files_readdir hiding (skip flagged entries)
    LINE=$(grep -n "if (!vma->vm_file)" "$BASEC" | grep -i "continue" | tail -1 | cut -d: -f1)
    if [ -n "$LINE" ]; then
        sed -i "${LINE}a\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\tif (unlikely(file_inode(vma->vm_file)->i_mapping->flags \& BIT_SUS_MAPS) \&\&\\
\t\t\tsusfs_is_current_proc_umounted())\\
\t\t{\\
\t\t\tcontinue;\\
\t\t}\\
#endif" "$BASEC"
        echo "    Inserted map_files hiding at line $LINE"
    fi
fi

# 6. Add Kconfig entry
echo "  [6/6] Adding Kconfig entry..."
# Find the KernelSU Kconfig in the kernel tree
KCONFIG=$(find . -path "*/kernelsu/Kconfig" -o -path "*/KernelSU/kernel/Kconfig" | head -1)
if [ -n "$KCONFIG" ] && ! grep -q "KSU_SUSFS_SUS_MAP" "$KCONFIG"; then
    sed -i '/config KSU_SUSFS_SUS_KSTAT/i \
config KSU_SUSFS_SUS_MAP\
\tbool "KSU SUSFS Hide mmapped files from maps"\
\tdefault y\
\tdepends on KSU_SUSFS\
\thelp\
\t  Hide flagged mmapped file entries from /proc/self/maps\
' "$KCONFIG"
    echo "    Added KSU_SUSFS_SUS_MAP to $KCONFIG"
fi

echo "== SUS_MAP feature added successfully =="
