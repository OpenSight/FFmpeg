%global source_commit e21d6902a5c4c4e4206b38fb61dd98a0294f7b5e
%global source_short  e21d6902a5
%global private_prefix %{_prefix}/lib/opensight/ffmpeg
%global opensight_cflags -O2 -march=x86-64-v2 -mtune=generic

# The appliance invokes the binaries through their private RPATH.  The
# packaged libraries are intentionally outside the system loader paths.
%global debug_package %{nil}
# AlmaLinux 10.2 still emits /usr/lib/.build-id links into the main package
# after the install section.  This package ships no debuginfo and has a closed
# payload allowlist, so suppress the links rather than own loader aliases.
%global _build_id_links none
%global __brp_check_rpaths %{nil}
%global _unpackaged_files_terminate_build 1

# Do not let the bundled private libraries provide or require system sonames.
%global __provides_exclude_from ^%{private_prefix}/lib/.*$
%global __requires_exclude ^(libav(codec|device|filter|format|util)|libsw(scale|resample)|libx26[45])\.so.*$

Name:           opensight-ffmpeg
Version:        8.0
Release:        1.%{source_short}%{?dist}
Summary:        OpenSight FFmpeg with IVR extensions and private shared libraries
License:        GPL-3.0-or-later
URL:            https://github.com/OpenSight/FFmpeg
Source0:        ffmpeg-ffmpeg_ivr_8.0-20261116-e21d6902a5.zip
Source1:        x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2
Source2:        x265_4.1.tar.gz
Source3:        sources.lock.json
Source4:        verify-sources.py
ExclusiveArch:  x86_64_v2

# The package owns /usr/bin/ffmpeg and /usr/bin/ffprobe.  A distribution
# FFmpeg would own the same command names, so it must not be co-installed.
Conflicts:      ffmpeg
Conflicts:      ffmpeg-free
Provides:       bundled(x264) = b35605ac
Provides:       bundled(x265) = 4.1

BuildRequires:  gcc gcc-c++ make cmake nasm perl tar unzip bzip2 xz
BuildRequires:  pkgconf-pkg-config diffutils findutils python3 binutils
BuildRequires:  libcurl-devel openssl-devel libva-devel alsa-lib-devel

%description
OpenSight's FFmpeg build for the LVR AlmaLinux 10.2 appliance.  It keeps the
IVR command-line extensions (h264 Annex-B detection, decodable start, rotating
log), the cseg muxer and the existing codec selection: libx264, libx265 at
8/10/12-bit and H.264 VAAPI encoding, with libcurl, OpenSSL and ALSA support.

The ffmpeg and ffprobe executables and their private shared libraries are
installed under %{private_prefix} and exported through /usr/bin.  The private
libraries are deliberately not registered with the system dynamic loader, so
they cannot satisfy unrelated distribution package dependencies.

%prep
python3 %{SOURCE4} --lock %{SOURCE3} --source-dir %{_sourcedir}
rm -rf ffmpeg-src x264-src x265-src
mkdir -p ffmpeg-src x264-src x265-src
unzip -q %{SOURCE0} -d ffmpeg-src
tar -xf %{SOURCE1} -C x264-src --strip-components=1
tar -xf %{SOURCE2} -C x265-src --strip-components=1

%build
export CFLAGS="%{opensight_cflags}"
export CXXFLAGS="$CFLAGS"
# rpmbuild exports the distribution link-hardening flags in LDFLAGS.  The
# appliance build runs the same codec configure steps without them; clearing
# LDFLAGS keeps the payload on the reference baseline and lets CMake's ABI
# probe link (its hardened -pie link otherwise conflicts with these CFLAGS).
unset LDFLAGS

# Compilation baseline: the package must be built on the same AlmaLinux 10.2
# x86_64_v2 userspace that the appliance consumes.
# shellcheck disable=SC1091
. /etc/os-release
test "$ID" = almalinux
test "$VERSION_ID" = 10.2
test "$(rpm -q --qf '%%{ARCH}' glibc)" = x86_64_v2
grep -Rqs x86_64_v2 /etc/yum.repos.d
printf 'int main(void) { return 0; }\n' \
    | gcc -x c -march=x86-64-v2 -mtune=generic -o /tmp/opensight-baseline-check -
rm -f /tmp/opensight-baseline-check
printf 'build baseline: %s %s, glibc %s, gcc %s\n' \
    "$ID" "$VERSION_ID" \
    "$(rpm -q --qf '%%{ARCH}' glibc)" \
    "$(gcc -dumpversion)"

# x264: one shared library carrying all bit depths, no command-line tool.
pushd x264-src
./configure --prefix=%{private_prefix} --enable-shared --disable-cli --enable-pic \
    --bit-depth=all --extra-cflags="$CFLAGS"
make %{?_smp_mflags}
make install DESTDIR=%{_builddir}/stage
popd

# x265: link the 10-bit and 12-bit static builds into the 8-bit shared library.
for depth in 12 10; do
    main12=
    test "$depth" != 12 || main12=-DMAIN12=ON
    cmake -S x265-src/source -B "x265-build-$depth" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DENABLE_PIC=ON -DNATIVE_BUILD=OFF -DENABLE_LIBNUMA=OFF \
        -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF $main12
    cmake --build "x265-build-$depth" --parallel %{_smp_build_ncpus}
done

# A 32-bit x265 configure silently produces elf32 assembly and fails later in
# ssd-a.asm; assert the codec is built for the x86_64 target.
for depth in 12 10; do
    grep -Rqs -- '-DARCH_X86_64=1' "x265-build-$depth/common/CMakeFiles/common.dir/build.make" \
        || { echo "x265-$depth was not configured for x86_64" >&2; exit 1; }
    grep -Rqs -- '-f elf64' "x265-build-$depth/common/CMakeFiles/common.dir/build.make" \
        || { echo "x265-$depth assembly target is not elf64" >&2; exit 1; }
done

mkdir -p x265-build-8
ln -s "$PWD/x265-build-10/libx265.a" x265-build-8/libx265_main10.a
ln -s "$PWD/x265-build-12/libx265.a" x265-build-8/libx265_main12.a
cmake -S x265-src/source -B x265-build-8 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{private_prefix} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_RPATH=%{private_prefix}/lib \
    -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DENABLE_PIC=ON -DNATIVE_BUILD=OFF -DENABLE_LIBNUMA=OFF \
    -DENABLE_SHARED=ON -DENABLE_CLI=OFF \
    '-DEXTRA_LIB=x265_main10.a;x265_main12.a' '-DEXTRA_LINK_FLAGS=-L.' \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON
grep -Rqs -- '-DARCH_X86_64=1' x265-build-8/common/CMakeFiles/common.dir/build.make \
    || { echo "x265-8 was not configured for x86_64" >&2; exit 1; }
grep -Rqs -- '-f elf64' x265-build-8/common/CMakeFiles/common.dir/build.make \
    || { echo "x265-8 assembly target is not elf64" >&2; exit 1; }
cmake --build x265-build-8 --parallel %{_smp_build_ncpus}
DESTDIR=%{_builddir}/stage cmake --install x265-build-8

# FFmpeg: build against the staged codecs but record only the final private
# RPATH in the installed objects.
pushd ffmpeg-src/FFmpeg-ffmpeg_ivr_8.0
export PKG_CONFIG_PATH="%{_builddir}/stage%{private_prefix}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="%{_builddir}/stage"
./configure --prefix=%{private_prefix} --enable-shared --disable-static \
    --extra-cflags="-I%{_builddir}/stage%{private_prefix}/include $CFLAGS" \
    --extra-ldflags="-L%{_builddir}/stage%{private_prefix}/lib -Wl,-rpath,%{private_prefix}/lib" \
    --extra-libs='-lpthread -lm -ldl' \
    --enable-ffmpeg-ivr --enable-libcurl --disable-ffplay --disable-doc --disable-encoders \
    --enable-gpl --enable-version3 --enable-libx264 --enable-libx265 --enable-vaapi --enable-openssl \
    --enable-encoder=libx264 --enable-encoder=h264_vaapi --enable-encoder=libx265 \
    --enable-encoder=wrapped_avframe --enable-encoder=pcm_s16le --enable-encoder=mjpeg \
    --enable-encoder=aac --enable-indev=alsa --enable-outdev=alsa --enable-muxer=cseg
make %{?_smp_mflags}
popd

%install
pushd ffmpeg-src/FFmpeg-ffmpeg_ivr_8.0
make install DESTDIR=%{buildroot}
popd

install -d %{buildroot}%{private_prefix}/bin %{buildroot}%{private_prefix}/lib
cp -a %{_builddir}/stage%{private_prefix}/lib/libx264.so* %{buildroot}%{private_prefix}/lib/
cp -a %{_builddir}/stage%{private_prefix}/lib/libx265.so* %{buildroot}%{private_prefix}/lib/

# Only the runtime payload is packaged; headers, pkg-config files, static
# archives and documentation belong to no shipped subpackage.
rm -rf %{buildroot}%{private_prefix}/include
rm -rf %{buildroot}%{private_prefix}/lib/pkgconfig
rm -rf %{buildroot}%{private_prefix}/share
find %{buildroot}%{private_prefix} -type f -name '*.a' -delete

install -d %{buildroot}%{_bindir}
ln -s %{private_prefix}/bin/ffmpeg %{buildroot}%{_bindir}/ffmpeg
ln -s %{private_prefix}/bin/ffprobe %{buildroot}%{_bindir}/ffprobe

install -d %{buildroot}%{_licensedir}/opensight-ffmpeg
for file in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md; do
    install -m 0644 "ffmpeg-src/FFmpeg-ffmpeg_ivr_8.0/$file" \
        "%{buildroot}%{_licensedir}/opensight-ffmpeg/$file"
done
install -m 0644 x264-src/COPYING %{buildroot}%{_licensedir}/opensight-ffmpeg/COPYING.x264
install -m 0644 x265-src/COPYING %{buildroot}%{_licensedir}/opensight-ffmpeg/COPYING.x265

# Guard the private-library contract and the executable feature set.
for binary in ffmpeg ffprobe; do
    path="%{buildroot}%{private_prefix}/bin/$binary"
    readelf -d "$path" | grep -Eq '(RUNPATH|RPATH).*%{private_prefix}/lib'
    if readelf -d "$path" | grep -q '%{_builddir}'; then
        echo "build-time RPATH leaked into $binary" >&2
        exit 1
    fi
done
for library in %{buildroot}%{private_prefix}/lib/libav*.so.* %{buildroot}%{private_prefix}/lib/libsw*.so.*; do
    readelf -d "$library" | grep -Eq '(RUNPATH|RPATH).*%{private_prefix}/lib'
    if readelf -d "$library" | grep -q '%{_builddir}'; then
        echo "build-time RPATH leaked into $library" >&2
        exit 1
    fi
done
test -z "$(find %{buildroot}/usr/lib64 -name 'libav*.so*' -o -name 'libsw*.so*' 2>/dev/null)"

export LD_LIBRARY_PATH="%{buildroot}%{private_prefix}/lib"
version_output=$("%{buildroot}%{private_prefix}/bin/ffmpeg" -hide_banner -version)
for flag in --enable-ffmpeg-ivr --enable-libcurl --enable-openssl \
    --enable-libx264 --enable-libx265 --enable-vaapi; do
    printf '%s\n' "$version_output" | grep -q -- "$flag"
done
help_output=$("%{buildroot}%{private_prefix}/bin/ffmpeg" -hide_banner -h full 2>&1)
printf '%s\n' "$help_output" | grep -q -- force_decodable_start
"%{buildroot}%{private_prefix}/bin/ffmpeg" -hide_banner -h muxer=cseg 2>&1 \
    | grep -q 'Muxer cseg'
unset LD_LIBRARY_PATH

%files
%defattr(-,root,root,-)
%dir %{private_prefix}
%dir %{private_prefix}/bin
%dir %{private_prefix}/lib
%{private_prefix}/bin/ffmpeg
%{private_prefix}/bin/ffprobe
%{private_prefix}/lib/libavcodec.so*
%{private_prefix}/lib/libavdevice.so*
%{private_prefix}/lib/libavfilter.so*
%{private_prefix}/lib/libavformat.so*
%{private_prefix}/lib/libavutil.so*
%{private_prefix}/lib/libswresample.so*
%{private_prefix}/lib/libswscale.so*
%{private_prefix}/lib/libx264.so*
%{private_prefix}/lib/libx265.so*
%{_bindir}/ffmpeg
%{_bindir}/ffprobe
%license %{_licensedir}/opensight-ffmpeg/COPYING.GPLv2
%license %{_licensedir}/opensight-ffmpeg/COPYING.GPLv3
%license %{_licensedir}/opensight-ffmpeg/COPYING.LGPLv2.1
%license %{_licensedir}/opensight-ffmpeg/COPYING.LGPLv3
%license %{_licensedir}/opensight-ffmpeg/LICENSE.md
%license %{_licensedir}/opensight-ffmpeg/COPYING.x264
%license %{_licensedir}/opensight-ffmpeg/COPYING.x265

%changelog
* Fri Nov 20 2026 OpenSight <opensource@opensight.cn> - 8.0-1.e21d6902a5
- Pilot the OpenSight FFmpeg runtime package for AlmaLinux 10.2 x86_64_v2.
- Build from the LVR-locked ffmpeg_ivr_8.0 source at e21d6902a5 with the
  locked x264 and x265 inputs, preserving the appliance feature set.
