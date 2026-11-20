#!/usr/bin/env bash
# Offline self-test for the packaging helpers.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    printf 'selftest failed: %s\n' "$*" >&2
    exit 1
}

echo "== source lock verifier =="
printf 'locked payload\n' > "$tmp_dir/good.bin"
size=$(stat -c %s "$tmp_dir/good.bin")
sha=$(sha256sum "$tmp_dir/good.bin" | awk '{print $1}')
cat > "$tmp_dir/lock.json" <<EOF
{
  "schema_version": 1,
  "sources": {
    "good": {
      "url": "https://example.invalid/good.bin",
      "file": "good.bin",
      "sha256": "$sha",
      "size_bytes": $size
    }
  }
}
EOF
python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/lock.json" \
    --source-dir "$tmp_dir" >/dev/null || fail "valid source was rejected"
[[ $(python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/lock.json" \
    --source-dir "$tmp_dir" --print-files) == good.bin ]] \
    || fail "--print-files did not print the locked name"

sed "s/$sha/$(printf '0%.0s' {1..64})/" "$tmp_dir/lock.json" > "$tmp_dir/bad-sha.json"
if python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/bad-sha.json" \
    --source-dir "$tmp_dir" >/dev/null 2>&1; then
    fail "checksum mismatch was accepted"
fi

sed "s/\"size_bytes\": $size/\"size_bytes\": $((size + 1))/" \
    "$tmp_dir/lock.json" > "$tmp_dir/bad-size.json"
if python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/bad-size.json" \
    --source-dir "$tmp_dir" >/dev/null 2>&1; then
    fail "size mismatch was accepted"
fi

sed 's/"file": "good.bin"/"file": "missing.bin"/' "$tmp_dir/lock.json" \
    > "$tmp_dir/missing.json"
if python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/missing.json" \
    --source-dir "$tmp_dir" >/dev/null 2>&1; then
    fail "missing source was accepted"
fi

sed 's/"file": "good.bin"/"file": "..\/good.bin"/' "$tmp_dir/lock.json" \
    > "$tmp_dir/unsafe.json"
if python3 "$SCRIPT_DIR/verify-sources.py" --lock "$tmp_dir/unsafe.json" \
    --source-dir "$tmp_dir" >/dev/null 2>&1; then
    fail "path traversal in the lock was accepted"
fi

echo "== repository rewriter =="
fake_root="$tmp_dir/root"
mkdir -p "$fake_root/etc/yum.repos.d"
cat > "$fake_root/etc/os-release" <<'EOF'
ID="almalinux"
VERSION_ID="10.2"
EOF
cat > "$fake_root/etc/yum.repos.d/almalinux-baseos.repo" <<'EOF'
[baseos]
name=AlmaLinux $releasever - BaseOS
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos?arch=x86_64_v2
enabled=1
gpgcheck=1

[baseos-debuginfo]
name=BaseOS Debug
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos-debug
enabled=1
gpgcheck=1
EOF
cat > "$fake_root/etc/yum.repos.d/almalinux-crb.repo" <<'EOF'
[crb]
name=AlmaLinux $releasever - CRB
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/crb
enabled=0
gpgcheck=1
EOF
cat > "$fake_root/etc/yum.repos.d/almalinux-highavailability.repo" <<'EOF'
[highavailability]
name=AlmaLinux $releasever - HighAvailability
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/highavailability
enabled=1
gpgcheck=1
EOF
cat > "$fake_root/etc/yum.repos.d/epel.repo" <<'EOF'
[epel]
name=EPEL
baseurl=https://epel.repo.almalinux.org/10.2/x86_64_v2/
enabled=1
gpgcheck=1
EOF

python3 "$SCRIPT_DIR/configure-repos.py" --root "$fake_root" \
    --mirror https://mirrors.aliyun.com/almalinux --no-verify >/dev/null

python3 - "$fake_root" <<'PY'
import configparser
import sys
from pathlib import Path

root = Path(sys.argv[1])


def sections(path):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.read(root / "etc/yum.repos.d" / path)
    return config


baseos = sections("almalinux-baseos.repo")
assert baseos["baseos"]["baseurl"] == \
    "https://mirrors.aliyun.com/almalinux/10.2/BaseOS/x86_64_v2/os/"
assert not baseos.has_option("baseos", "mirrorlist")
assert baseos["baseos"]["countme"] == "0"
assert baseos["baseos"]["enabled"] == "1"
assert baseos["baseos-debuginfo"]["enabled"] == "0"
crb = sections("almalinux-crb.repo")
assert crb["crb"]["enabled"] == "1"
assert crb["crb"]["baseurl"] == \
    "https://mirrors.aliyun.com/almalinux/10.2/CRB/x86_64_v2/os/"
highavailability = sections("almalinux-highavailability.repo")
assert highavailability["highavailability"]["enabled"] == "0"
assert sections("epel.repo")["epel"]["enabled"] == "0"
PY

if python3 "$SCRIPT_DIR/configure-repos.py" --root "$fake_root" \
    --mirror http://mirrors.aliyun.com/almalinux --no-verify >/dev/null 2>&1; then
    fail "non-HTTPS mirror was accepted"
fi

echo "== output reservation =="
# shellcheck source=output-dir.sh
. "$SCRIPT_DIR/output-dir.sh"

new_output="$tmp_dir/new-output"
reserve_output_dir "$new_output" || fail "a new output directory was rejected"
[[ -d $new_output ]] || fail "the reserved output directory was not created"

empty_output="$tmp_dir/empty-output"
mkdir -p "$empty_output"
( reserve_output_dir "$empty_output" ) \
    || fail "an empty output directory was rejected"

nonempty_output="$tmp_dir/nonempty-output"
mkdir -p "$nonempty_output"
printf 'keep me\n' > "$nonempty_output/existing-evidence"
if ( reserve_output_dir "$nonempty_output" ) 2>/dev/null; then
    fail "a non-empty output directory was accepted"
fi
[[ $(cat "$nonempty_output/existing-evidence") == 'keep me' ]] \
    || fail "a rejected output directory was modified"

file_output="$tmp_dir/file-output"
printf 'not a directory\n' > "$file_output"
if ( reserve_output_dir "$file_output" ) 2>/dev/null; then
    fail "a regular file was accepted as an output directory"
fi

locked_output="$tmp_dir/locked-output"
mkdir -p "$locked_output"
exec {holder_fd}< "$locked_output"
flock -n "$holder_fd" || fail "could not hold the test lock"
if ( reserve_output_dir "$locked_output" ) 2>/dev/null; then
    fail "an output directory locked by another build was accepted"
fi
exec {holder_fd}>&-

echo "== private soname pattern =="
soname_re=$(sed -n "s/^private_soname_re='\(.*\)'$/\1/p" "$SCRIPT_DIR/verify-package.sh")
[[ -n $soname_re ]] || fail "could not read the private soname pattern"
for soname in \
    'libavcodec.so.62()(64bit)' \
    'libavdevice.so.62()(64bit)' \
    'libavfilter.so.11()(64bit)' \
    'libavformat.so.62()(64bit)' \
    'libavutil.so.60()(64bit)' \
    'libswresample.so.6()(64bit)' \
    'libswscale.so.9()(64bit)' \
    'libx264.so.165()(64bit)' \
    'libx265.so.215()(64bit)'; do
    grep -Eq "$soname_re" <<<"$soname" \
        || fail "private soname pattern missed $soname"
done
for soname in 'libcurl.so.4()(64bit)' 'libva.so.2()(64bit)' 'libz.so.1()(64bit)'; do
    if grep -Eq "$soname_re" <<<"$soname"; then
        fail "private soname pattern matched a system library: $soname"
    fi
done

echo "== syntax =="
for script in "$SCRIPT_DIR"/*.sh; do
    bash -n "$script" || fail "bash syntax error in $script"
done
for module in "$SCRIPT_DIR"/*.py; do
    PYTHONPYCACHEPREFIX="$tmp_dir/pycache" python3 -m py_compile "$module" \
        || fail "python syntax error in $module"
done

echo "selftest passed"
