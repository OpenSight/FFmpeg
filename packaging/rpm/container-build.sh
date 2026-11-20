#!/usr/bin/env bash
# Run inside the pinned AlmaLinux 10.2 x86_64_v2 build container.
set -euo pipefail

: "${MIRROR:=https://mirrors.aliyun.com/almalinux}"
: "${JOBS:=$(nproc)}"
: "${RPMBUILD_TOPDIR:=/work/rpmbuild}"
: "${PACKAGING_DIR:=/packaging}"
: "${SOURCES_DIR:=/sources}"
: "${LOGS_DIR:=/logs}"

export LC_ALL=C
mkdir -p "$LOGS_DIR" "$RPMBUILD_TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

printf 'build container: mirror=%s jobs=%s\n' "$MIRROR" "$JOBS"
bash "$PACKAGING_DIR/verify-build-environment.sh" pre \
    | tee "$LOGS_DIR/build-environment-pre.txt"

python3 "$PACKAGING_DIR/configure-repos.py" --mirror "$MIRROR" \
    | tee "$LOGS_DIR/repositories.txt"

dnf -y --setopt=install_weak_deps=False install dnf-plugins-core rpm-build \
    2>&1 | tee "$LOGS_DIR/dnf-tools.log"
dnf -y --enablerepo=crb --setopt=install_weak_deps=False \
    builddep "$PACKAGING_DIR/opensight-ffmpeg.spec" \
    2>&1 | tee "$LOGS_DIR/dnf-builddep.log"

bash "$PACKAGING_DIR/verify-build-environment.sh" post \
    | tee "$LOGS_DIR/build-environment-post.txt"

cp -a "$SOURCES_DIR"/. "$RPMBUILD_TOPDIR/SOURCES/"
cp "$PACKAGING_DIR/sources.lock.json" "$PACKAGING_DIR/verify-sources.py" \
    "$RPMBUILD_TOPDIR/SOURCES/"
cp "$PACKAGING_DIR/opensight-ffmpeg.spec" "$RPMBUILD_TOPDIR/SPECS/"

python3 "$RPMBUILD_TOPDIR/SOURCES/verify-sources.py" \
    --lock "$RPMBUILD_TOPDIR/SOURCES/sources.lock.json" \
    --source-dir "$RPMBUILD_TOPDIR/SOURCES" \
    | tee "$LOGS_DIR/source-verification.txt"

rpmbuild -ba --target x86_64_v2-linux \
    --define "_topdir $RPMBUILD_TOPDIR" \
    --define "_smp_mflags -j$JOBS" \
    --define "_smp_build_ncpus $JOBS" \
    "$RPMBUILD_TOPDIR/SPECS/opensight-ffmpeg.spec" \
    2>&1 | tee "$LOGS_DIR/rpmbuild.log"

find "$RPMBUILD_TOPDIR/RPMS" "$RPMBUILD_TOPDIR/SRPMS" -type f -name '*.rpm' \
    -printf '%s %p\n'
