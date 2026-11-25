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
| Runtime RPM | `opensight-ffmpeg-8.0-1.1.20261125.el10.x86_64_v2.rpm` |
| Source RPM | `opensight-ffmpeg-8.0-1.1.20261125.el10.src.rpm` |

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

## Release and OSS key

Releases follow the shared
[OpenSight RPM publishing convention](https://github.com/OpenSight/lvr/blob/master/deploy/bootc/README.md#opensight-rpm-publishing-convention):
Release is `<source revision>.<packaging revision>.<UTC date YYYYMMDD>.<dist>`.
The three inputs live at the top of `opensight-ffmpeg.spec`:

```spec
%global opensight_source_revision    1
%global opensight_packaging_revision 1
%global opensight_release_date       20261125
```

Edit them per release and rebuild. An SRPM rebuild reuses the archived values,
so it reproduces the same Release. This release is `1.1.20261125.el10`.

The runtime RPM publishes at the flat key, with no hash directory:

```
software/ffmpeg-rpm/opensight-ffmpeg-8.0-1.1.20261125.el10.x86_64_v2.rpm
```

The build, manifest and both verification scripts derive the name from the
RPM header, so the file name, header NEVRA and manifest key cannot drift. The
source RPM and recipe are retained locally for rebuild and handoff; the source
RPM is not published.

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

- Linux with a working rootless Podman (the pilot was validated with Podman
  6.1.3) and `flock` from util-linux.
- Network access to the selected AlmaLinux mirror for build dependencies,
  unless the build image and DNF metadata are already cached.
- Roughly 10 GB of free space for the container, build tree and artifacts.
- The three locked source archives, either in `packaging/rpm/sources/`, in a
  directory passed with `--sources`, or fetched with `--download`.

Choose a **new or empty** output directory for each build.  The entry point
takes an advisory lock and refuses a non-empty path, so it cannot delete or
overwrite another build's evidence; a failed run must be retried with a new
`--output`.

```sh
packaging/rpm/build-rpm.sh \
  --output "$PWD/artifacts/ffmpeg-$(date -u +%Y%m%dT%H%M%SZ)" \
  --sources /path/to/locked-sources \
  --mirror https://mirrors.aliyun.com/almalinux \
  --jobs "$(nproc)"
```

Use `--download` instead of `--sources` to fetch the locked archives from
their recorded URLs.  `--mirror` is propagated to the build container and to
both verification containers (target install and SRPM rebuild).

The entry point:

1. verifies every source against `sources.lock.json`;
2. starts the digest-pinned `quay.io/almalinuxorg/almalinux` 10.2 `amd64/v2`
   image (`sha256:607a7368…`), one of the `almalinux:10.2` index manifests;
3. points BaseOS, AppStream, CRB and extras at the matching
   `x86_64_v2` repository tree on the selected mirror;
4. installs the spec's `BuildRequires`, runs `rpmbuild -ba --target
   x86_64_v2-linux`, and records the build environment;
5. installs the binary RPM with DNF in a clean copy of the same image and runs
   the executable, ownership, dependency and codec checks;
6. rebuilds the SRPM in a fresh container, compares metadata and payload, and
   installs that rebuilt RPM in another clean container.

Use `--skip-target-verify` or `--skip-srpm-rebuild` only when iterating; a
delivered candidate must have both enabled.

Host note: if `/etc/containers/storage.conf` points at the rootful storage
path, a non-root user cannot use it.  The scripts therefore default to
explicit rootless `--root`/`--runroot` values
(`$HOME/.local/share/containers/storage` and
`$XDG_RUNTIME_DIR/containers`).  Override them with `PODMAN_ROOT`,
`PODMAN_RUNROOT`, or `BASE_IMAGE` if the host layout differs.  No host
configuration is changed.

## Outputs

`PACKAGE-MANIFEST.json` and `PACKAGE-MANIFEST.md` record the NEVRA, SHA-256,
size, payload, generated dependencies, source baseline and URLs, release
inputs, build image, verification status, the runtime OSS key and the local
source RPM.  `SHA256SUMS` covers the two RPMs.  `logs/` contains the host and
container environment records, repository setup, DNF and `rpmbuild` output,
source verification, and both verification runs.

Hangzhou OSS runtime key (the upload is deferred to the delivery phase):

```
software/ffmpeg-rpm/opensight-ffmpeg-8.0-1.1.20261125.el10.x86_64_v2.rpm
```

The key adds no hash directory; the RPM basename is the key. A same-key
republish must serve identical bytes. Consumers pin the RPM header NEVRA plus
size and SHA-256, which the manifest records. The source RPM stays local and
is not part of the published key set.

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

The FFmpeg source archive is already published at its locked `software/` OSS
URL, and this release does not change it, so no new source publication is
required. The lock, the spec, `verify-sources.py` and all three archives are
archived in the source RPM, which is retained locally for rebuild and handoff
together with the published source archive.

## Manual SRPM rebuild

```sh
podman run --rm --platform linux/amd64/v2 --network=host \
  --security-opt label=disable \
  -v "$PWD":/src:ro -v /tmp/rebuild:/out \
  quay.io/almalinuxorg/almalinux@sha256:607a7368ceaff7b76991a9d33ca489dcd6f2b699deaa65ef712d7b8d661ddcc3 \
  /bin/bash -c '
    python3 /src/packaging/rpm/configure-repos.py &&
    dnf -y install dnf-plugins-core rpm-build &&
    dnf -y --enablerepo=crb builddep /src/opensight-ffmpeg-8.0-1.1.20261125.el10.src.rpm &&
    rpmbuild --rebuild --target x86_64_v2-linux \
      --define "_topdir /out/rpmbuild" /src/opensight-ffmpeg-8.0-1.1.20261125.el10.src.rpm'
```

Use `verify-srpm.sh` to run the full comparison and install check.

## Self-test

`selftest.sh` exercises the source-lock verifier (success, checksum mismatch,
size mismatch, missing file, unsafe name), the repository rewriter on a fake
root, the output-directory reservation (new, empty, non-empty, file and
locked paths), the private-soname pattern, and script syntax.  It needs no
network and no source archives.

## Limitations

- This directory does not compose the LVR bootc image, boot a disposable
  appliance, or qualify VAAPI on Intel hardware; those remain the consumer and
  release-verification steps from issue #111.
- The package is not GPG-signed.
- The pilot uses the public Aliyun mirror for build dependencies.  A fully
  offline rebuild needs a mirrored DNF cache.
