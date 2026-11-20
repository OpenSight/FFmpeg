#!/usr/bin/env bash
# Verify an installed opensight-ffmpeg package inside a clean target container.
set -euo pipefail

rpm_path=${1:?usage: verify-installed.sh RPM_PATH}
: "${MIRROR:=https://mirrors.aliyun.com/almalinux}"

fail() {
    printf 'installed package verification failed: %s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || fail "must run as root inside the target container"
[[ -f $rpm_path ]] || fail "RPM not found: $rpm_path"

python3 /packaging/configure-repos.py --mirror "$MIRROR"
dnf -y --setopt=install_weak_deps=False install "$rpm_path"
rpm -q opensight-ffmpeg

# Package ownership and the private-library layout.
for path in \
    /usr/bin/ffmpeg /usr/bin/ffprobe \
    /usr/lib/opensight/ffmpeg/bin/ffmpeg /usr/lib/opensight/ffmpeg/bin/ffprobe \
    /usr/lib/opensight/ffmpeg/lib/libavcodec.so \
    /usr/lib/opensight/ffmpeg/lib/libavformat.so \
    /usr/lib/opensight/ffmpeg/lib/libavutil.so \
    /usr/lib/opensight/ffmpeg/lib/libswresample.so \
    /usr/lib/opensight/ffmpeg/lib/libswscale.so \
    /usr/lib/opensight/ffmpeg/lib/libavfilter.so \
    /usr/lib/opensight/ffmpeg/lib/libavdevice.so \
    /usr/lib/opensight/ffmpeg/lib/libx264.so \
    /usr/lib/opensight/ffmpeg/lib/libx265.so; do
    owner=$(rpm -qf "$path")
    [[ $owner == opensight-ffmpeg-* ]] \
        || fail "$path is owned by '$owner', not opensight-ffmpeg"
done

rpm -V opensight-ffmpeg || fail "rpm -V reported package modifications"
[[ $(command -v ffmpeg) == /usr/bin/ffmpeg ]] || fail "ffmpeg is not on PATH at /usr/bin/ffmpeg"
[[ $(command -v ffprobe) == /usr/bin/ffprobe ]] || fail "ffprobe is not on PATH at /usr/bin/ffprobe"
[[ $(readlink -f /usr/bin/ffmpeg) == /usr/lib/opensight/ffmpeg/bin/ffmpeg ]] \
    || fail "/usr/bin/ffmpeg does not resolve to the private binary"
[[ $(readlink -f /usr/bin/ffprobe) == /usr/lib/opensight/ffmpeg/bin/ffprobe ]] \
    || fail "/usr/bin/ffprobe does not resolve to the private binary"

# Private libraries must stay invisible to the system loader and to RPM's
# dependency solver, so they cannot satisfy unrelated package dependencies.
# Capture command output instead of piping into "grep -q": under pipefail a
# matching grep closes the pipe and the producer's SIGPIPE fails the pipeline.
ldconfig_output=$(ldconfig -p)
if grep -Eq 'libav(codec|device|filter|format|util)\.so|libsw(scale|resample)\.so|libx26[45]\.so' \
    <<<"$ldconfig_output"; then
    grep -E 'libav|libsw|libx26' <<<"$ldconfig_output" >&2
    fail "private libraries were registered with ldconfig"
fi
if rpm -q --whatprovides 'libavcodec.so.62()(64bit)' >/dev/null 2>&1; then
    fail "opensight-ffmpeg provides its private libavcodec soname"
fi
private_soname=$(objdump -p /usr/lib/opensight/ffmpeg/lib/libavcodec.so \
    | awk '/SONAME/ { print $2; exit }')
[[ $private_soname == libavcodec.so.* ]] || fail "cannot determine libavcodec SONAME"
if rpm -q --whatprovides "$private_soname()(64bit)" >/dev/null 2>&1; then
    fail "opensight-ffmpeg provides $private_soname"
fi
system_libs=$(find /usr/lib64 /usr/lib /lib64 -maxdepth 1 \
    \( -name 'libav*.so*' -o -name 'libsw*.so*' -o -name 'libx26[45].so*' \))
if [[ -n $system_libs ]]; then
    printf '%s\n' "$system_libs" >&2
    fail "private libraries were installed in the system library directory"
fi

# Encoders, muxers and devices preserved from the appliance build.
version_output=$(ffmpeg -hide_banner -version)
[[ $(head -n 1 <<<"$version_output") == 'ffmpeg version 8.0'* ]] \
    || fail "unexpected ffmpeg version banner"
for flag in --enable-ffmpeg-ivr --enable-libcurl --enable-openssl \
    --enable-libx264 --enable-libx265 --enable-vaapi; do
    grep -q -- "$flag" <<<"$version_output" \
        || fail "ffmpeg build is missing $flag"
done
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for encoder in libx264 libx265 h264_vaapi mjpeg aac pcm_s16le wrapped_avframe; do
    grep -Eq " $encoder " <<<"$encoders" || fail "$encoder encoder missing"
done
muxers=$(ffmpeg -hide_banner -muxers 2>/dev/null)
grep -Eq ' cseg ' <<<"$muxers" || fail "cseg muxer missing"
devices=$(ffmpeg -hide_banner -devices 2>/dev/null)
grep -Eq ' alsa ' <<<"$devices" || fail "ALSA device missing"
help_output=$(ffmpeg -hide_banner -h full 2>&1)
grep -q -- force_decodable_start <<<"$help_output" \
    || fail "force_decodable_start option missing"
cseg_help=$(ffmpeg -hide_banner -h muxer=cseg 2>&1)
grep -q 'Muxer cseg' <<<"$cseg_help" || fail "cseg muxer help missing"
x265_help=$(ffmpeg -hide_banner -h encoder=libx265 2>&1)
grep -q 'yuv420p10le' <<<"$x265_help" || fail "libx265 10-bit input missing"
grep -q 'yuv420p12le' <<<"$x265_help" || fail "libx265 12-bit input missing"
ffprobe_version=$(ffprobe -hide_banner -version)
[[ $(head -n 1 <<<"$ffprobe_version") == 'ffprobe version 8.0'* ]] \
    || fail "unexpected ffprobe version banner"

# Runtime closure: every packaged object must resolve against the image.
while IFS= read -r -d '' object; do
    closure=$(ldd "$object" 2>&1)
    if [[ $closure == *'not found'* ]]; then
        printf '%s\n%s\n' "$object" "$closure" >&2
        fail "unresolved shared-library dependency"
    fi
done < <(find /usr/lib/opensight/ffmpeg/bin /usr/lib/opensight/ffmpeg/lib \
    \( -type f -name '*.so*' -o -type f -name 'ffmpeg' -o -type f -name 'ffprobe' \) \
    -print0)

# Functional codec checks used by the bootc image verifier.
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=1 \
    -frames:v 1 -c:v libx264 -threads 1 -f null -
for depth in 8 10 12; do
    pixel=yuv420p
    [[ $depth == 8 ]] || pixel="yuv420p${depth}le"
    ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=1 \
        -frames:v 1 -pix_fmt "$pixel" -c:v libx265 -threads 1 \
        -x265-params 'pools=1:frame-threads=1:log-level=error' -f null -
done

# Symlink layout: private binaries, public command names.
[[ $(readlink /usr/bin/ffmpeg) == /usr/lib/opensight/ffmpeg/bin/ffmpeg ]] \
    || fail "/usr/bin/ffmpeg symlink target changed"
[[ $(readlink /usr/bin/ffprobe) == /usr/lib/opensight/ffmpeg/bin/ffprobe ]] \
    || fail "/usr/bin/ffprobe symlink target changed"

echo "installed-package verification passed for $(rpm -q opensight-ffmpeg)"
