# opensight-ffmpeg RPM pilot

This directory builds the LVR pilot runtime package for the AlmaLinux 10.2
`x86_64_v2` bootc appliance.  It owns the spec, the Podman build entry point,
source locking and package verification.  The built package keeps the FFmpeg
payload that the appliance already qualified, but makes it an owned RPM.

Tracking issue: [OpenSight/lvr#111](https://github.com/OpenSight/lvr/issues/111).

## Contract

The build produces exactly two artifacts:

| Artifact | Name |
| --- | --- |
| Runtime RPM | `opensight-ffmpeg-8.0-1.e21d6902a5.el10.x86_64_v2.rpm` |
| Source RPM | `opensight-ffmpeg-8.0-1.e21d6902a5.el10.src.rpm` |

The runtime RPM installs:

| Path | Purpose |
| --- | --- |
| `/usr/bin/ffmpeg`, `/usr/bin/ffprobe` | absolute symlinks to the private binaries |
| `/usr/lib/opensight/ffmpeg/bin/{ffmpeg,ffprobe}` | executables |
| `/usr/lib/opensight/ffmpeg/lib/lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale,x264,x265}.so*` | private shared libraries |
| `/usr/share/licenses/opensight-ffmpeg/` | FFmpeg, x264 and x265 license notices |

The paths, configure flags and codec depths match
`lvr/deploy/bootc/scripts/build-ffmpeg.sh`:

- `--enable-ffmpeg-ivr` IVR extensions (`force_decodable_start`, rotating
  log, H.264 Annex-B handling), `--enable-libcurl`, `--enable-openssl`,
  `--enable-vaapi`, `--enable-gpl --enable-version3`
- libx264 with all bit depths, libx265 linked with 8/10/12-bit support,
  H.264 VAAPI encoding, ALSA input/output devices and the `cseg` muxer
- the same restricted encoder set as the appliance build

Private library behaviour:

- The libraries live outside the system loader paths and the package has no
  `%post ldconfig` action, so they cannot satisfy unrelated package
  dependencies.
- `__provides_exclude_from` removes their soname `Provides` and
  `__requires_exclude` removes their soname `Requires`, including the
  self-references from the packaged executables.
- The FFmpeg executables and libraries carry an absolute `DT_RPATH`/`DT_RUNPATH`
  of `/usr/lib/opensight/ffmpeg/lib` and no build-time path.
- `Conflicts: ffmpeg` and `Conflicts: ffmpeg-free` prevent a distribution
  package from claiming the same command names.

## Build decisions

- The spec uses the appliance's `-O2 -march=x86-64-v2 -mtune=generic` baseline
  rather than the distribution hardening flags.  `rpmbuild` exports hardened
  `LDFLAGS`; those are cleared in `%build` because the `redhat-hardened-ld`
  spec adds `-pie` to every executable link while these CFLAGS do not add
  `-fPIE`.  Without clearing them CMake's compiler ABI probe fails to link and
  x265 silently configures 32-bit assembly (`elf32`), which then fails in
  `ssd-a.asm`.  The spec asserts `-DARCH_X86_64=1` and `-f elf64` for all three
  x265 builds so that regression cannot pass silently.
- x264 and x265 are installed into a staging prefix during `%build` and only
  their runtime `*.so*` files are copied into the package; headers,
  pkg-config files and static archives are not shipped.
- `_build_id_links none` keeps the payload closed.  Without it AlmaLinux 10.2
  adds `/usr/lib/.build-id/*` links to the main package even with
  `debug_package %{nil}`, exposing loader-visible aliases to the private
  libraries that the appliance does not have.

## Build

Host prerequisites:

- Fedora (or another host with a working rootless Podman); the pilot was
  validated with Podman 6.1.3.
- Network access to the AlmaLinux mirror for build dependencies, unless the
  build image and DNF metadata are already cached.
- The three locked source archives, either in `packaging/rpm/sources/`, in a
  directory passed with `--sources`, or fetched with `--download`.

```sh
packaging/rpm/build-rpm.sh \
  --output /home/hyt/devel/opensight/artifacts/lvr-111/ffmpeg \
  --sources /var/tmp/lvr-bootc-media.eXA0Ghyi/sources \
  --jobs 4
```

The entry point:

1. verifies every source against `sources.lock.json`;
2. starts the digest-pinned `quay.io/almalinuxorg/almalinux` 10.2 `amd64/v2`
   image (`sha256:607a7368…`), one of the `almalinux:10.2` index manifests;
3. points BaseOS, AppStream, CRB and extras at the matching
   `x86_64_v2` repository tree on the Aliyun mirror;
4. installs the spec's `BuildRequires`, runs `rpmbuild -ba --target
   x86_64_v2-linux`, and records the build environment;
5. installs the binary RPM with DNF in a clean copy of the same image and runs
   the executable, ownership, dependency and codec checks;
6. rebuilds the SRPM in a fresh container, compares metadata and payload, and
   installs that rebuilt RPM in another clean container.

Use `--skip-target-verify` or `--skip-srpm-rebuild` only when iterating; a
delivered candidate must have both enabled.

Host note: on the pilot host, `/etc/containers/storage.conf` points at the
rootful storage path, which a non-root user cannot use.  The scripts therefore
pass explicit rootless `--root`/`--runroot` values
(`$HOME/.local/share/containers/storage` and
`$XDG_RUNTIME_DIR/containers`).  Override them with `PODMAN_ROOT`,
`PODMAN_RUNROOT`, or `BASE_IMAGE` if the host layout differs.  No host
configuration is changed.

## Outputs

`PACKAGE-MANIFEST.json` and `PACKAGE-MANIFEST.md` record the NEVRA, SHA-256,
size, payload, generated dependencies, source baseline, build image,
verification status and the proposed immutable OSS file names.
`SHA256SUMS` covers the two RPMs.  `logs/` contains the host and container
environment records, repository setup, DNF and `rpmbuild` output, source
verification, and both verification runs.

Proposed Hangzhou OSS names (uploads are deferred to the delivery phase):

```
opensight-ffmpeg-8.0-1.e21d6902a5.el10.<YYYYMMDD>.x86_64_v2.rpm
opensight-ffmpeg-8.0-1.e21d6902a5.el10.<YYYYMMDD>.src.rpm
```

The `<YYYYMMDD>` build stamp keeps a rebuilt artifact from silently replacing
an earlier one.  Consumers pin the RPM header NEVRA plus SHA-256; the OSS file
name is not the identity.

## Source lock

`sources.lock.json` pins the inputs used by both this entry point and the
spec's `%prep`:

- FFmpeg `ffmpeg_ivr_8.0` snapshot `e21d6902a5c4c4e4206b38fb61dd98a0294f7b5e`
  (the LVR-locked deployed baseline)
- x264 `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`
- x265 `4.1`

`verify-sources.py` is itself in the SRPM; `rpmbuild` re-verifies the sources
before compiling.  The spec also asserts AlmaLinux 10.2, a
`x86_64_v2` glibc, matching repositories and a compiler that accepts
`-march=x86-64-v2`.

## Manual SRPM rebuild

```sh
podman run --rm --platform linux/amd64/v2 --network=host \
  --security-opt label=disable \
  -v "$PWD":/src:ro -v /tmp/rebuild:/out \
  quay.io/almalinuxorg/almalinux@sha256:607a7368ceaff7b76991a9d33ca489dcd6f2b699deaa65ef712d7b8d661ddcc3 \
  /bin/bash -c '
    python3 /src/packaging/rpm/configure-repos.py &&
    dnf -y install dnf-plugins-core rpm-build &&
    dnf -y --enablerepo=crb builddep /src/opensight-ffmpeg-8.0-1.e21d6902a5.el10.src.rpm &&
    rpmbuild --rebuild --target x86_64_v2-linux \
      --define "_topdir /out/rpmbuild" /src/opensight-ffmpeg-8.0-1.e21d6902a5.el10.src.rpm'
```

Use `verify-srpm.sh` to run the full comparison and install check.

## Self-test

`selftest.sh` exercises the source-lock verifier (success, checksum mismatch,
size mismatch, missing file, unsafe name), the repository rewriter on a fake
root, and script syntax.  It needs no network and no source archives.

## Limitations

- This directory does not compose the LVR bootc image, boot a disposable
  appliance, or qualify VAAPI on Intel hardware; those remain the consumer and
  release-verification steps from issue #111.
- The package is not GPG-signed.
- The pilot uses the public Aliyun mirror for build dependencies.  A fully
  offline rebuild needs a mirrored DNF cache.
