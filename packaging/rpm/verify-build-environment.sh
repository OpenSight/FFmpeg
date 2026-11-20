#!/usr/bin/env bash
# Assert the build container matches the AlmaLinux 10.2 x86_64_v2 baseline.
set -euo pipefail

label=${1:-build}
require_tools=0
case "$label" in
    pre) ;;
    *) require_tools=1 ;;
esac

fail() {
    printf 'build environment check (%s) failed: %s\n' "$label" "$*" >&2
    exit 1
}

tool_required() {
    if (( require_tools )); then
        command -v "$1" >/dev/null || fail "required build tool is missing: $1"
    fi
}

tool_version() {
    local tool=$1
    shift
    if command -v "$tool" >/dev/null; then
        "$@" 2>/dev/null | head -n 1
    else
        echo 'not installed'
    fi
}

(( EUID == 0 )) || fail "must run as root inside the build container"

# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == almalinux ]] || fail "expected AlmaLinux, found ${ID:-unknown}"
[[ ${VERSION_ID:-} == 10.2 ]] || fail "expected AlmaLinux 10.2, found ${VERSION_ID:-unknown}"
[[ $(uname -m) == x86_64 ]] || fail "expected x86_64 kernel, found $(uname -m)"

glibc_arch=$(rpm -q --qf '%{ARCH}' glibc)
[[ $glibc_arch == x86_64_v2 ]] \
    || fail "glibc RPM architecture is $glibc_arch, expected x86_64_v2"

grep -Rqs 'x86_64_v2' /etc/yum.repos.d \
    || fail "no x86_64_v2 repository is configured"

target_info=$(rpm --target x86_64_v2-linux --eval '%{_target_cpu}|%{_target_platform}|%{optflags}')
[[ $target_info == x86_64_v2\|* ]] \
    || fail "RPM target is not x86_64_v2: $target_info"
[[ $target_info == *'-march=x86-64-v2'* ]] \
    || fail "RPM baseline flags do not select x86-64-v2: $target_info"

if (( require_tools )); then
    for tool in gcc g++ make cmake nasm perl python3 rpmbuild readelf; do
        tool_required "$tool"
    done
fi

if command -v gcc >/dev/null; then
    printf 'int main(void) { return 0; }\n' \
        | gcc -x c -march=x86-64-v2 -mtune=generic -o /tmp/opensight-baseline-check - \
        || fail "gcc cannot compile for x86-64-v2"
    rm -f /tmp/opensight-baseline-check
    printf 'int main(void) { return 0; }\n' \
        | g++ -x c++ -march=x86-64-v2 -mtune=generic -o /tmp/opensight-baseline-check - \
        || fail "g++ cannot compile for x86-64-v2"
    rm -f /tmp/opensight-baseline-check
fi

cat <<EOF
build environment ($label):
  os: ${PRETTY_NAME:-AlmaLinux}
  version_id: ${VERSION_ID}
  kernel_arch: $(uname -m)
  glibc_rpm_arch: ${glibc_arch}
  rpm: $(rpm --version)
  rpm_target: ${target_info%%|*}
  rpm_optflags: ${target_info##*|}
  gcc: $(tool_version gcc gcc --version)
  g++: $(tool_version g++ g++ --version)
  compiler_target: $(command -v gcc >/dev/null && gcc -dumpmachine || echo 'not installed')
  make: $(tool_version make make --version)
  cmake: $(tool_version cmake cmake --version)
  nasm: $(tool_version nasm nasm -v)
  perl: $(tool_version perl perl -e 'printf "%vd\n", $^V')
  python3: $(tool_version python3 python3 --version)
  rpmbuild: $(tool_version rpmbuild rpmbuild --version)
  ldd: $(ldd --version | head -n 1)
EOF
