#!/usr/bin/env bash
# Build the opensight-ffmpeg binary and source RPMs in a pinned AlmaLinux
# 10.2 x86_64_v2 Podman environment, then verify the artifacts.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
BASE_IMAGE=${BASE_IMAGE:-quay.io/almalinuxorg/almalinux@sha256:607a7368ceaff7b76991a9d33ca489dcd6f2b699deaa65ef712d7b8d661ddcc3}
PODMAN_ROOT=${PODMAN_ROOT:-$HOME/.local/share/containers/storage}
PODMAN_RUNROOT=${PODMAN_RUNROOT:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers}
MIRROR=${MIRROR:-https://mirrors.aliyun.com/almalinux}

output_dir=
source_dirs=()
download=0
jobs=$(nproc)
skip_target_verify=0
skip_srpm_rebuild=0
clean_work=0

usage() {
    cat <<'EOF'
usage: build-rpm.sh --output DIR [options]

  --output DIR          artifact directory (required)
  --sources DIR         directory holding locked source archives (repeatable;
                        defaults to packaging/rpm/sources and the current directory)
  --download            download missing locked sources from their locked URLs
  --jobs N              parallel compile jobs (default: nproc)
  --mirror URL          AlmaLinux mirror (default: https://mirrors.aliyun.com/almalinux)
  --skip-target-verify  skip the clean target install verification
  --skip-srpm-rebuild   skip the clean SRPM rebuild verification
  --clean-work          remove the intermediate work directory on success
EOF
}

while (( $# )); do
    case "$1" in
        --output) output_dir=$2; shift 2 ;;
        --sources) source_dirs+=("$2"); shift 2 ;;
        --download) download=1; shift ;;
        --jobs) jobs=$2; shift 2 ;;
        --mirror) MIRROR=$2; shift 2 ;;
        --skip-target-verify) skip_target_verify=1; shift ;;
        --skip-srpm-rebuild) skip_srpm_rebuild=1; shift ;;
        --clean-work) clean_work=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n $output_dir ]] || { echo "--output is required" >&2; usage >&2; exit 2; }
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 2; }
if (( ${#source_dirs[@]} == 0 )); then
    source_dirs=("$SCRIPT_DIR/sources" "$PWD")
fi

output_dir=$(mkdir -p "$output_dir" && cd -- "$output_dir" && pwd)
work_dir="$output_dir/.work"
# Logs stay visible next to the artifacts so they survive --clean-work.
logs_dir="$output_dir/logs"
rm -rf "$work_dir" "$logs_dir"
mkdir -p "$work_dir/sources" "$work_dir/rpmbuild" "$logs_dir"
exec > >(tee -a "$logs_dir/build-rpm.log") 2>&1

podman_cmd=(podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT")

fail() {
    printf 'build failed: %s\n' "$*" >&2
    exit 1
}

echo "== build host =="
{
    printf 'date_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'hostname: %s\n' "$(hostname)"
    printf 'uname: %s\n' "$(uname -a)"
    printf 'user: %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'os_release:\n'
    sed 's/^/  /' /etc/os-release
    printf 'podman_client: %s\n' "$("${podman_cmd[@]}" version --format '{{.Client.Version}}')"
    printf 'podman_root: %s\n' "$PODMAN_ROOT"
    printf 'podman_runroot: %s\n' "$PODMAN_RUNROOT"
    printf 'base_image: %s\n' "$BASE_IMAGE"
    printf 'mirror: %s\n' "$MIRROR"
    printf 'jobs: %s\n' "$jobs"
    printf 'free_space:\n'
    df -h "$output_dir" /var/tmp | sed 's/^/  /'
} | tee "$logs_dir/host-environment.txt"

echo "== locked sources =="
lock_file="$SCRIPT_DIR/sources.lock.json"
missing=0
while IFS=$'\t' read -r name file url; do
    found=
    for directory in "${source_dirs[@]}"; do
        if [[ -f $directory/$file ]]; then
            found=$directory/$file
            break
        fi
    done
    if [[ -n $found ]]; then
        if [[ $found != "$work_dir/sources/$file" ]]; then
            cp -a "$found" "$work_dir/sources/$file"
        fi
        printf 'source %-7s %s\n' "$name" "$found"
    elif (( download )); then
        printf 'source %-7s downloading %s\n' "$name" "$url"
        curl -fL --retry 3 --connect-timeout 30 -o "$work_dir/sources/$file" "$url" \
            || fail "could not download $url"
    else
        printf 'source %-7s MISSING %s (looked in: %s)\n' \
            "$name" "$file" "${source_dirs[*]}" >&2
        missing=1
    fi
done < <(python3 - "$lock_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    sources = json.load(handle)["sources"]
for name, entry in sources.items():
    print(name, entry["file"], entry["url"], sep="\t")
PY
)
(( missing == 0 )) || fail "locked source archives are missing; see above"

python3 "$SCRIPT_DIR/verify-sources.py" --lock "$lock_file" --source-dir "$work_dir/sources" \
    | tee "$logs_dir/source-verification.txt"

echo "== podman build environment =="
podman_cmd=(podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT")
"${podman_cmd[@]}" info >/dev/null
if ! "${podman_cmd[@]}" image exists "$BASE_IMAGE"; then
    echo "pulling $BASE_IMAGE"
    "${podman_cmd[@]}" pull --platform linux/amd64/v2 "$BASE_IMAGE" \
        || fail "could not pull the pinned build image"
fi
{
    printf 'base_image: %s\n' "$BASE_IMAGE"
    "${podman_cmd[@]}" image inspect "$BASE_IMAGE" \
        --format 'image_id: {{.Id}}
digest: {{.Digest}}
os: {{.Os}}
architecture: {{.Architecture}}
created: {{.Created}}'
    "${podman_cmd[@]}" info --format 'rootless: {{.Host.Security.Rootless}}
graph_root: {{.Store.GraphRoot}}
runtime: {{.Host.OCIRuntime.Name}}'
} | tee "$logs_dir/build-image.txt"

echo "== build =="
"${podman_cmd[@]}" run --rm --platform linux/amd64/v2 --network=host \
    --security-opt label=disable \
    -v "$SCRIPT_DIR:/packaging:ro" \
    -v "$work_dir/sources:/sources:ro" \
    -v "$work_dir/rpmbuild:/work/rpmbuild:rw" \
    -v "$logs_dir:/logs:rw" \
    -e "MIRROR=$MIRROR" -e "JOBS=$jobs" \
    "$BASE_IMAGE" /bin/bash /packaging/container-build.sh \
    || fail "container build failed; see $logs_dir/rpmbuild.log"

mapfile -t rpm_built_list < <(find "$work_dir/rpmbuild/RPMS" -type f -name 'opensight-ffmpeg-*.rpm' ! -name '*.src.rpm')
mapfile -t srpm_built_list < <(find "$work_dir/rpmbuild/SRPMS" -type f -name 'opensight-ffmpeg-*.src.rpm')
[[ ${#rpm_built_list[@]} -eq 1 ]] || fail "expected one binary RPM, found ${#rpm_built_list[@]}"
[[ ${#srpm_built_list[@]} -eq 1 ]] || fail "expected one source RPM, found ${#srpm_built_list[@]}"
rpm_built=${rpm_built_list[0]}
srpm_built=${srpm_built_list[0]}
cp -f "$rpm_built" "$output_dir/"
cp -f "$srpm_built" "$output_dir/"
rpm_file="$output_dir/$(basename "$rpm_built")"
srpm_file="$output_dir/$(basename "$srpm_built")"
echo "binary RPM: $rpm_file"
echo "source RPM: $srpm_file"

target_status=not-run
srpm_rebuild_status=not-run
overall=0
if (( ! skip_target_verify )); then
    echo "== clean target install verification =="
    if bash "$SCRIPT_DIR/verify-package.sh" --rpm "$rpm_file" --srpm "$srpm_file" \
        --log "$logs_dir/verify-package.log"; then
        target_status=passed
    else
        target_status=failed
        overall=1
    fi
fi
if (( ! skip_srpm_rebuild )); then
    echo "== clean SRPM rebuild verification =="
    if bash "$SCRIPT_DIR/verify-srpm.sh" --srpm "$srpm_file" --rpm "$rpm_file" \
        --work-dir "$work_dir/srpm-rebuild" --jobs "$jobs" \
        --log "$logs_dir/verify-srpm.log"; then
        srpm_rebuild_status=passed
    else
        srpm_rebuild_status=failed
        overall=1
    fi
fi

echo "== artifact manifest =="
build_date_tag=$(date -u +%Y%m%d)
proposed_rpm="opensight-ffmpeg-8.0-1.e21d6902a5.el10.${build_date_tag}.x86_64_v2.rpm"
proposed_srpm="opensight-ffmpeg-8.0-1.e21d6902a5.el10.${build_date_tag}.src.rpm"
(
    cd "$output_dir"
    sha256sum "$(basename "$rpm_file")" "$(basename "$srpm_file")" > SHA256SUMS
)
python3 - "$output_dir" "$rpm_file" "$srpm_file" "$srpm_rebuild_status" \
    "$target_status" "$overall" "$proposed_rpm" "$proposed_srpm" "$BASE_IMAGE" \
    "$MIRROR" "$jobs" "$lock_file" "$logs_dir" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

(output_dir, rpm_path, srpm_path, rebuild_status, target_status, overall,
 proposed_rpm, proposed_srpm, base_image, mirror, jobs, lock_file,
 logs_dir) = sys.argv[1:]


def qf(path, fmt):
    return subprocess.check_output(["rpm", "-qp", "--qf", fmt, path], text=True).strip()


def query(path, flag):
    return [
        line for line in subprocess.check_output(
            ["rpm", "-qp", flag, path], text=True
        ).splitlines() if line
    ]


def filelist(path):
    return [
        line for line in subprocess.check_output(
            ["rpm", "-qpl", path], text=True
        ).splitlines() if line
    ]


def digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


with open(lock_file, encoding="utf-8") as handle:
    lock = json.load(handle)

binary = {
    "file": os.path.basename(rpm_path),
    "nevra": qf(rpm_path, "%{NEVRA}"),
    "arch": qf(rpm_path, "%{ARCH}"),
    "license": qf(rpm_path, "%{LICENSE}"),
    "sha256": digest(rpm_path),
    "size_bytes": os.path.getsize(rpm_path),
    "files": filelist(rpm_path),
    "requires": sorted(query(rpm_path, "--requires")),
    "provides": sorted(query(rpm_path, "--provides")),
    "conflicts": sorted(query(rpm_path, "--conflicts")),
}
source = {
    "file": os.path.basename(srpm_path),
    "nevra": qf(srpm_path, "%{NEVRA}"),
    "sha256": digest(srpm_path),
    "size_bytes": os.path.getsize(srpm_path),
    "files": filelist(srpm_path),
}
manifest = {
    "issue": "OpenSight/lvr#111",
    "repository": "OpenSight/FFmpeg",
    "pilot": "AlmaLinux 10.2 x86_64_v2 bootc appliance",
    "source_baseline": lock.get("source_baseline"),
    "sources": {
        name: {
            "file": entry["file"],
            "sha256": entry["sha256"],
            "size_bytes": entry["size_bytes"],
        }
        for name, entry in lock["sources"].items()
    },
    "build": {
        "image": base_image,
        "mirror": mirror,
        "jobs": int(jobs),
        "date_tag": proposed_rpm.rsplit(".", 3)[-3],
    },
    "binary_rpm": binary,
    "source_rpm": source,
    "proposed_oss_files": {
        "binary_rpm": proposed_rpm,
        "source_rpm": proposed_srpm,
        "binary_rpm_sha256": binary["sha256"],
        "source_rpm_sha256": source["sha256"],
    },
    "verification": {
        "target_install": target_status,
        "srpm_rebuild": rebuild_status,
        "overall": "passed" if int(overall) == 0 else "failed",
        "logs": sorted(os.listdir(logs_dir)),
    },
}
with open(os.path.join(output_dir, "PACKAGE-MANIFEST.json"), "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")

lines = [
    "# opensight-ffmpeg package manifest",
    "",
    f"- Issue: {manifest['issue']}",
    f"- Repository: {manifest['repository']}",
    f"- Binary RPM: `{binary['nevra']}`",
    f"- Binary SHA-256: `{binary['sha256']}`",
    f"- Binary size: {binary['size_bytes']} bytes",
    f"- Source RPM: `{source['nevra']}`",
    f"- Source RPM SHA-256: `{source['sha256']}`",
    f"- Source RPM size: {source['size_bytes']} bytes",
    f"- Source baseline: `{lock['source_baseline']['commit']}`",
    f"- Build image: `{base_image}`",
    f"- Build mirror: {mirror}",
    f"- Clean target install: {target_status}",
    f"- Clean SRPM rebuild: {rebuild_status}",
    f"- Overall: {'passed' if int(overall) == 0 else 'failed'}",
    "",
    "## Inputs",
    "",
]
for name, entry in lock["sources"].items():
    lines.append(f"- {name}: `{entry['file']}` sha256 `{entry['sha256']}`")
lines += [
    "",
    "## Proposed immutable Hangzhou OSS names",
    "",
    f"- `{proposed_rpm}`",
    f"- `{proposed_srpm}`",
    "",
    "## Notes",
    "",
    "Uploads are intentionally deferred to the manager-coordinated delivery phase.",
]
with open(os.path.join(output_dir, "PACKAGE-MANIFEST.md"), "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
print(json.dumps(manifest["proposed_oss_files"], indent=2))
PY

if (( clean_work )); then
    rm -rf "$work_dir"
fi

printf '\nartifacts: %s\n' "$output_dir"
sha_file="$output_dir/SHA256SUMS"
[[ -f $sha_file ]] && cat "$sha_file"
if (( overall != 0 )); then
    echo "verification failed: target_install=$target_status srpm_rebuild=$srpm_rebuild_status" >&2
    exit 1
fi
echo "build and verification completed successfully"
