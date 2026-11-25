#!/usr/bin/env bash
# Check an opensight-ffmpeg RPM/SRPM pair on the build host and install the
# binary RPM with DNF in a clean, pinned AlmaLinux 10.2 x86_64_v2 container.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_IMAGE=${BASE_IMAGE:-quay.io/almalinuxorg/almalinux@sha256:607a7368ceaff7b76991a9d33ca489dcd6f2b699deaa65ef712d7b8d661ddcc3}
PODMAN_ROOT=${PODMAN_ROOT:-$HOME/.local/share/containers/storage}
PODMAN_RUNROOT=${PODMAN_RUNROOT:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers}

rpm_path=
srpm_path=
log_file=
mirror=${MIRROR:-https://mirrors.aliyun.com/almalinux}
while (( $# )); do
    case "$1" in
        --rpm) rpm_path=$2; shift 2 ;;
        --srpm) srpm_path=$2; shift 2 ;;
        --mirror) mirror=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        -h|--help)
            echo "usage: $0 --rpm FILE --srpm FILE [--mirror URL] [--log FILE]"
            exit 0
            ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n $rpm_path && -n $srpm_path ]] || { echo "--rpm and --srpm are required" >&2; exit 2; }
[[ -f $rpm_path && -f $srpm_path ]] || { echo "RPM or SRPM not found" >&2; exit 2; }
[[ -n $log_file ]] && exec > >(tee -a "$log_file") 2>&1

fail() {
    printf 'package verification failed: %s\n' "$*" >&2
    exit 1
}

podman_cmd=(podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT")

echo "== metadata =="
rpm -qp --qf 'NEVRA: %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\nARCH: %{ARCH}\nLICENSE: %{LICENSE}\nSOURCERPM: %{SOURCERPM}\n' "$rpm_path"
rpm -qpi "$rpm_path"

pkg_name=$(rpm -qp --qf '%{NAME}' "$rpm_path")
pkg_version=$(rpm -qp --qf '%{VERSION}' "$rpm_path")
pkg_release=$(rpm -qp --qf '%{RELEASE}' "$rpm_path")
pkg_arch=$(rpm -qp --qf '%{ARCH}' "$rpm_path")
nevra="$pkg_name-$pkg_version-$pkg_release.$pkg_arch"
[[ $pkg_name == opensight-ffmpeg ]] || fail "unexpected package name: $pkg_name"
[[ $pkg_version == 8.0 ]] || fail "unexpected version: $pkg_version"
[[ $pkg_arch == x86_64_v2 ]] || fail "unexpected architecture: $pkg_arch"
# Release carries <source revision>.<packaging revision>.<UTC date>.<dist>.
[[ $pkg_release =~ ^[1-9][0-9]*\.[1-9][0-9]*\.[0-9]{8}\.el10$ ]] \
    || fail "release does not follow the OpenSight convention: $pkg_release"
# The published flat key is the actual basename, so the file name and the RPM
# header must agree; the manifest derives both from this header.
[[ $(basename "$rpm_path") == "$nevra.rpm" ]] \
    || fail "artifact file name does not match its header NEVRA: $nevra"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm_path") == GPL-3.0-or-later ]] \
    || fail "unexpected license"
srpm_name=$(basename "$srpm_path")
[[ $srpm_name == "$pkg_name-$pkg_version-$pkg_release.src.rpm" ]] \
    || fail "source RPM file name does not match the binary Release"
[[ $(rpm -qp --qf '%{SOURCERPM}' "$rpm_path") == "$srpm_name" ]] \
    || fail "binary RPM does not reference the supplied SRPM"

echo "== payload =="
mapfile -t payload < <(rpm -qpl "$rpm_path")
for path in "${payload[@]}"; do
    case "$path" in
        /usr/bin/ffmpeg|/usr/bin/ffprobe) ;;
        /usr/lib/opensight/ffmpeg|/usr/lib/opensight/ffmpeg/bin|/usr/lib/opensight/ffmpeg/lib) ;;
        /usr/lib/opensight/ffmpeg/bin/ffmpeg|/usr/lib/opensight/ffmpeg/bin/ffprobe) ;;
        /usr/lib/opensight/ffmpeg/lib/libavcodec.so*|\
        /usr/lib/opensight/ffmpeg/lib/libavdevice.so*|\
        /usr/lib/opensight/ffmpeg/lib/libavfilter.so*|\
        /usr/lib/opensight/ffmpeg/lib/libavformat.so*|\
        /usr/lib/opensight/ffmpeg/lib/libavutil.so*|\
        /usr/lib/opensight/ffmpeg/lib/libswresample.so*|\
        /usr/lib/opensight/ffmpeg/lib/libswscale.so*|\
        /usr/lib/opensight/ffmpeg/lib/libx264.so*|\
        /usr/lib/opensight/ffmpeg/lib/libx265.so*) ;;
        /usr/share/licenses/opensight-ffmpeg) ;;
        /usr/share/licenses/opensight-ffmpeg/*.md|\
        /usr/share/licenses/opensight-ffmpeg/COPYING.*) ;;
        *) fail "unexpected payload path: $path" ;;
    esac
done
for expected in \
    /usr/bin/ffmpeg /usr/bin/ffprobe \
    /usr/lib/opensight/ffmpeg/bin/ffmpeg /usr/lib/opensight/ffmpeg/bin/ffprobe \
    /usr/lib/opensight/ffmpeg/lib/libavcodec.so \
    /usr/lib/opensight/ffmpeg/lib/libavdevice.so \
    /usr/lib/opensight/ffmpeg/lib/libavfilter.so \
    /usr/lib/opensight/ffmpeg/lib/libavformat.so \
    /usr/lib/opensight/ffmpeg/lib/libavutil.so \
    /usr/lib/opensight/ffmpeg/lib/libswresample.so \
    /usr/lib/opensight/ffmpeg/lib/libswscale.so \
    /usr/lib/opensight/ffmpeg/lib/libx264.so \
    /usr/lib/opensight/ffmpeg/lib/libx265.so; do
    found=0
    for path in "${payload[@]}"; do
        [[ $path == "$expected" ]] && { found=1; break; }
    done
    (( found )) || fail "payload is missing $expected"
done
for path in "${payload[@]}"; do
    case "$path" in
        */include/*|*/pkgconfig/*|*.a|*/share/doc/*|/usr/lib64/*)
            fail "development or system-path artifact in payload: $path" ;;
    esac
done
license_count=$(printf '%s\n' "${payload[@]}" | grep -c '^/usr/share/licenses/opensight-ffmpeg/')
(( license_count == 7 )) || fail "expected 7 license files, found $license_count"

echo "== ownership and modes =="
while IFS='|' read -r perms user group name; do
    [[ $user == root && $group == root ]] || fail "$name is not root:root"
    case "$name" in
        /usr/bin/ffmpeg|/usr/bin/ffprobe)
            [[ $perms == lrwxrwxrwx ]] || fail "$name is not a symlink" ;;
        */bin/ffmpeg|*/bin/ffprobe)
            [[ $perms == -rwxr-xr-x ]] || fail "$name is not executable" ;;
    esac
done < <(rpm -qp --qf '[%{FILEMODES:perms}|%{FILEUSERNAME}|%{FILEGROUPNAME}|%{FILENAMES}\n]' "$rpm_path")

echo "== dependencies =="
requires=$(rpm -qp --requires "$rpm_path")
provides=$(rpm -qp --provides "$rpm_path")
conflicts=$(rpm -qp --conflicts "$rpm_path")
private_soname_re='^(libav(codec|device|filter|format|util)|libsw(scale|resample)|libx26[45])\.so'
if grep -Eq "$private_soname_re" <<<"$requires"; then
    grep -E "$private_soname_re" <<<"$requires" >&2
    fail "private soname appears in generated Requires"
fi
if grep -Eq "$private_soname_re" <<<"$provides"; then
    grep -E "$private_soname_re" <<<"$provides" >&2
    fail "private soname appears in generated Provides"
fi
for soname in libcurl.so.4 libva.so.2 libasound.so.2 libssl.so.3 libcrypto.so.3 libstdc++.so.6; do
    grep -q "^$soname" <<<"$requires" \
        || fail "generated Requires is missing $soname"
done
grep -qx "opensight-ffmpeg = $pkg_version-$pkg_release" <<<"$provides" \
    || fail "package name/version Provides is missing"
grep -q '^bundled(x264) = b35605ac' <<<"$provides" \
    || fail "bundled x264 declaration is missing"
grep -q '^bundled(x265) = 4.1' <<<"$provides" \
    || fail "bundled x265 declaration is missing"
grep -qx 'ffmpeg' <<<"$conflicts" || fail "missing Conflicts: ffmpeg"
grep -qx 'ffmpeg-free' <<<"$conflicts" || fail "missing Conflicts: ffmpeg-free"

echo "== source RPM =="
srpm_payload=$(rpm -qpl "$srpm_path")
for expected in opensight-ffmpeg.spec sources.lock.json verify-sources.py \
    ffmpeg-ffmpeg_ivr_8.0-20261116-e21d6902a5.zip \
    x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2 \
    x265_4.1.tar.gz; do
    grep -qx "$expected" <<<"$srpm_payload" \
        || fail "SRPM is missing $expected"
done
# An SRPM header carries the build arch (x86_64_v2), not the ".src" file
# suffix, so compare the name-version-release portion.
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$srpm_path") \
    == "$pkg_name-$pkg_version-$pkg_release" ]] \
    || fail "SRPM does not match the binary package Release"
[[ $(rpm -qp --qf '%{ARCH}' "$srpm_path") == x86_64_v2 ]] \
    || fail "unexpected SRPM build architecture"

echo "== ELF contract =="
extract_dir=$(mktemp -d)
trap 'rm -rf "$extract_dir"' EXIT
(cd "$extract_dir" && rpm2cpio "$rpm_path" | cpio -idm --quiet)
while IFS= read -r -d '' object; do
    runpath=$(readelf -d "$object" 2>/dev/null | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p')
    [[ $runpath == *'/usr/lib/opensight/ffmpeg/lib'* ]] \
        || fail "$object does not use the private RPATH/RUNPATH"
    case "$runpath" in
        *'/work/'*|*'/build/'*|*'/tmp/'*) fail "$object leaks a build-time RPATH/RUNPATH: $runpath" ;;
    esac
done < <(find "$extract_dir/usr/lib/opensight/ffmpeg/bin" \
    "$extract_dir/usr/lib/opensight/ffmpeg/lib" \
    \( -type f -name 'ffmpeg' -o -type f -name 'ffprobe' -o -type f -name 'libav*.so.*' -o -type f -name 'libsw*.so.*' \) \
    -print0)
ffmpeg_dynamic=$(readelf -d "$extract_dir/usr/lib/opensight/ffmpeg/bin/ffmpeg")
grep -q 'libavcodec\.so\.[0-9]*' <<<"$ffmpeg_dynamic" \
    || fail "ffmpeg does not link libavcodec"
[[ $(readlink "$extract_dir/usr/bin/ffmpeg") == /usr/lib/opensight/ffmpeg/bin/ffmpeg ]] \
    || fail "unexpected /usr/bin/ffmpeg symlink target"
[[ $(readlink "$extract_dir/usr/bin/ffprobe") == /usr/lib/opensight/ffmpeg/bin/ffprobe ]] \
    || fail "unexpected /usr/bin/ffprobe symlink target"

echo "== isolated install =="
"${podman_cmd[@]}" run --rm --platform linux/amd64/v2 --network=host \
    --security-opt label=disable \
    -e "MIRROR=$mirror" \
    -v "$(cd -- "$(dirname -- "$rpm_path")" && pwd):/rpms:ro" \
    -v "$SCRIPT_DIR:/packaging:ro" \
    "$BASE_IMAGE" /bin/bash /packaging/verify-installed.sh "/rpms/$(basename "$rpm_path")"

echo "package verification passed: $nevra"
