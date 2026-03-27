#!/bin/bash
# Adds CMD_SUSFS_ADD_SUS_MAP handler to KernelSU supercalls
# Run from kernel_platform/KernelSU directory

SUPERCALLS_FILE=$(find . -name "sucompat.c" -o -name "supercalls.c" | head -1)
if [ -z "$SUPERCALLS_FILE" ]; then
    echo "ERROR: Could not find sucompat.c or supercalls.c"
    exit 1
fi

echo "Patching $SUPERCALLS_FILE for SUS_MAP support..."

# Create a temporary file with the handler code
cat > /tmp/sus_map_handler.c << 'HANDLER'
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		if (arg2 == CMD_SUSFS_ADD_SUS_MAP) {
			int error = 0;
			if (!ksu_access_ok((void __user*)arg3, sizeof(struct st_susfs_sus_map))) {
				pr_err("susfs: CMD_SUSFS_ADD_SUS_MAP -> arg3 is not accessible\n");
				return 0;
			}
			if (!ksu_access_ok((void __user*)arg5, sizeof(error))) {
				pr_err("susfs: CMD_SUSFS_ADD_SUS_MAP -> arg5 is not accessible\n");
				return 0;
			}
			error = susfs_add_sus_map((struct st_susfs_sus_map __user*)arg3);
			pr_info("susfs: CMD_SUSFS_ADD_SUS_MAP -> ret: %d\n", error);
			if (copy_to_user((void __user*)arg5, &error, sizeof(error)))
				pr_info("susfs: copy_to_user() failed\n");
			return 0;
		}
#endif //#ifdef CONFIG_KSU_SUSFS_SUS_MAP
HANDLER

# Find the line with OPEN_REDIRECT endif and insert after it
LINE_NUM=$(grep -n "#endif.*CONFIG_KSU_SUSFS_OPEN_REDIRECT" "$SUPERCALLS_FILE" | head -1 | cut -d: -f1)
if [ -n "$LINE_NUM" ]; then
    sed -i "${LINE_NUM}r /tmp/sus_map_handler.c" "$SUPERCALLS_FILE"
    echo "SUS_MAP handler inserted after line $LINE_NUM"
else
    echo "WARNING: Could not find OPEN_REDIRECT endif, trying alternative insertion"
    # Insert before SHOW_VERSION handler
    LINE_NUM=$(grep -n "CMD_SUSFS_SHOW_VERSION" "$SUPERCALLS_FILE" | head -1 | cut -d: -f1)
    if [ -n "$LINE_NUM" ]; then
        LINE_NUM=$((LINE_NUM - 1))
        sed -i "${LINE_NUM}r /tmp/sus_map_handler.c" "$SUPERCALLS_FILE"
        echo "SUS_MAP handler inserted before SHOW_VERSION at line $LINE_NUM"
    fi
fi

# Add SUS_MAP to enabled_features bitmask (bit 13)
LINE_NUM=$(grep -n "#ifdef CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT" "$SUPERCALLS_FILE" | head -1 | cut -d: -f1)
if [ -n "$LINE_NUM" ]; then
    sed -i "${LINE_NUM}i\\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\\
\t\t\tenabled_features |= (1 << 13);\\
#endif" "$SUPERCALLS_FILE"
    echo "SUS_MAP added to enabled_features (bit 13)"
fi

# Also add Kconfig entry if there's a Kconfig file
KCONFIG_FILE=$(find . -name "Kconfig" | head -1)
if [ -n "$KCONFIG_FILE" ] && ! grep -q "CONFIG_KSU_SUSFS_SUS_MAP" "$KCONFIG_FILE"; then
    # Add after SUS_KSTAT entry
    sed -i '/config KSU_SUSFS_SUS_KSTAT/,/^$/{ /^$/a\
config KSU_SUSFS_SUS_MAP\
\tbool "KSU SUSFS SUS_MAP"\
\tdefault y\
\tdepends on KSU_SUSFS\
\thelp\
\t  Hide mmapped file entries from /proc/self/maps\
}' "$KCONFIG_FILE" 2>/dev/null || echo "Kconfig update skipped (manual may be needed)"
fi

echo "SUS_MAP handler setup complete"
rm -f /tmp/sus_map_handler.c
