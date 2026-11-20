#!/usr/bin/env bash
# Reserve a build output directory for one exclusive, fresh build.
#
# Sourced by build-rpm.sh (and exercised by selftest.sh).  The caller keeps
# the directory descriptor open, so the advisory lock is held for the life of
# the build.  Existing content is never deleted or overwritten: a non-empty
# output path is rejected and the caller must choose a new directory.

reserve_output_dir() {
    local dir=$1
    local entries

    if ! command -v flock >/dev/null; then
        printf 'output reservation failed: flock (util-linux) is required\n' >&2
        return 1
    fi
    if [[ -e $dir && ! -d $dir ]]; then
        printf 'output reservation failed: %s exists and is not a directory\n' \
            "$dir" >&2
        return 1
    fi
    if ! mkdir -p -- "$dir"; then
        printf 'output reservation failed: cannot create %s\n' "$dir" >&2
        return 1
    fi
    # Keep the descriptor open in the caller; closing it releases the lock.
    exec {OUTPUT_DIR_LOCK_FD}< "$dir" || {
        printf 'output reservation failed: cannot open %s\n' "$dir" >&2
        return 1
    }
    if ! flock -n "$OUTPUT_DIR_LOCK_FD"; then
        printf 'output reservation failed: another build holds %s\n' "$dir" >&2
        return 1
    fi
    entries=$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)
    if [[ -n $entries ]]; then
        printf 'output reservation failed: %s is not empty (use a new --output)\n' \
            "$dir" >&2
        return 1
    fi
    return 0
}
