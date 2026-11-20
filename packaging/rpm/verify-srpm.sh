#!/usr/bin/env bash
# Rebuild the supplied SRPM in a fresh container, compare it with the
# candidate binary RPM, then install and exercise the rebuilt RPM.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_IMAGE=${BASE_IMAGE:-quay.io/almalinuxorg/almalinux@sha256:607a7368ceaff7b76991a9d33ca489dcd6f2b699deaa65ef712d7b8d661ddcc3}
PODMAN_ROOT=${PODMAN_ROOT:-$HOME/.local/share/containers/storage}
PODMAN_RUNROOT=${PODMAN_RUNROOT:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers}

srpm_path=
rpm_path=
work_dir=
log_file=
jobs=$(nproc)
while (( $# )); do
    case "$1" in
        --srpm) srpm_path=$2; shift 2 ;;
        --rpm) rpm_path=$2; shift 2 ;;
        --work-dir) work_dir=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        -h|--help)
            echo "usage: $0 --srpm FILE --rpm FILE --work-dir DIR [--log FILE] [--jobs N]"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $srpm_path && -n $rpm_path && -n $work_dir ]] \
    || { echo "--srpm, --rpm and --work-dir are required" >&2; exit 2; }
[[ -f $srpm_path && -f $rpm_path ]] || { echo "RPM or SRPM not found" >&2; exit 2; }
[[ -n $log_file ]] && exec > >(tee -a "$log_file") 2>&1

fail() {
    printf 'SRPM rebuild verification failed: %s\n' "$*" >&2
    exit 1
}

podman_cmd=(podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT")
mkdir -p "$work_dir"

echo "== rebuild =="
"${podman_cmd[@]}" run --rm --platform linux/amd64/v2 --network=host \
    --security-opt label=disable \
    -v "$(cd -- "$(dirname -- "$srpm_path")" && pwd):/src:ro" \
    -v "$(cd -- "$work_dir" && pwd):/out" \
    -v "$SCRIPT_DIR:/packaging:ro" \
    -e "JOBS=$jobs" \
    "$BASE_IMAGE" /bin/bash /packaging/rebuild-srpm.sh "/src/$(basename "$srpm_path")"

mapfile -t rebuilt_rpms < <(find "$work_dir/rebuilt" -maxdepth 1 -type f -name 'opensight-ffmpeg-*.rpm')
[[ ${#rebuilt_rpms[@]} -eq 1 ]] \
    || fail "expected exactly one rebuilt binary RPM, found ${#rebuilt_rpms[@]}"
rebuilt_rpm=${rebuilt_rpms[0]}

echo "== comparison =="
candidate_nevra=$(rpm -qp --qf '%{NEVRA}' "$rpm_path")
rebuilt_nevra=$(rpm -qp --qf '%{NEVRA}' "$rebuilt_rpm")
[[ $candidate_nevra == "$rebuilt_nevra" ]] \
    || fail "rebuilt NEVRA $rebuilt_nevra differs from $candidate_nevra"
candidate_files=$(rpm -qpl "$rpm_path" | sort)
rebuilt_files=$(rpm -qpl "$rebuilt_rpm" | sort)
[[ $candidate_files == "$rebuilt_files" ]] || {
    diff <(printf '%s\n' "$candidate_files") <(printf '%s\n' "$rebuilt_files") >&2 || true
    fail "rebuilt payload file list differs"
}
candidate_requires=$(rpm -qp --requires "$rpm_path" | sort)
rebuilt_requires=$(rpm -qp --requires "$rebuilt_rpm" | sort)
[[ $candidate_requires == "$rebuilt_requires" ]] \
    || fail "rebuilt generated Requires differ"
candidate_provides=$(rpm -qp --provides "$rpm_path" | sort)
rebuilt_provides=$(rpm -qp --provides "$rebuilt_rpm" | sort)
[[ $candidate_provides == "$rebuilt_provides" ]] \
    || fail "rebuilt generated Provides differ"

candidate_sha=$(sha256sum "$rpm_path" | awk '{print $1}')
rebuilt_sha=$(sha256sum "$rebuilt_rpm" | awk '{print $1}')
printf 'candidate sha256: %s\nrebuilt sha256:   %s\n' "$candidate_sha" "$rebuilt_sha"
[[ $candidate_sha == "$rebuilt_sha" ]] \
    && echo "rebuilt RPM is byte-identical to the candidate" \
    || echo "rebuilt RPM is not byte-identical; payload and metadata match"

echo "== rebuilt package checks and isolated install =="
bash "$SCRIPT_DIR/verify-package.sh" --rpm "$rebuilt_rpm" --srpm "$srpm_path"

echo "SRPM rebuild verification passed for $rebuilt_nevra"
