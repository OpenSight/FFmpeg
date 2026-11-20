#!/usr/bin/env bash
# Rebuild an opensight-ffmpeg source RPM inside the pinned build container.
set -euo pipefail

srpm=${1:?usage: rebuild-srpm.sh SRPM}
: "${MIRROR:=https://mirrors.aliyun.com/almalinux}"
: "${JOBS:=$(nproc)}"
: "${PACKAGING_DIR:=/packaging}"
: "${OUTPUT_DIR:=/out}"

export LC_ALL=C
mkdir -p "$OUTPUT_DIR/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$OUTPUT_DIR/rebuilt"

python3 "$PACKAGING_DIR/configure-repos.py" --mirror "$MIRROR"
dnf -y --setopt=install_weak_deps=False install dnf-plugins-core rpm-build \
    2>&1 | tee "$OUTPUT_DIR/dnf-tools.log"
dnf -y --enablerepo=crb --setopt=install_weak_deps=False builddep "$srpm" \
    2>&1 | tee "$OUTPUT_DIR/dnf-builddep.log"
bash "$PACKAGING_DIR/verify-build-environment.sh" rebuild \
    | tee "$OUTPUT_DIR/build-environment.txt"

rpmbuild --rebuild --target x86_64_v2-linux \
    --define "_topdir $OUTPUT_DIR/rpmbuild" \
    --define "_smp_mflags -j$JOBS" \
    --define "_smp_build_ncpus $JOBS" \
    "$srpm" 2>&1 | tee "$OUTPUT_DIR/rpmbuild.log"

while IFS= read -r -d '' rebuilt; do
    cp -a "$rebuilt" "$OUTPUT_DIR/rebuilt/"
done < <(find "$OUTPUT_DIR/rpmbuild/RPMS" -type f -name '*.rpm' -print0)

find "$OUTPUT_DIR/rebuilt" -type f -name '*.rpm' -printf '%s %p\n'
