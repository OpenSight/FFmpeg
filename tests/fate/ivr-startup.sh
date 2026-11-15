#!/bin/sh
# Regression tests for the CONFIG_FFMPEG_IVR -force_decodable_start option.
#
# A stream can be joined mid-GOP, where the demuxer emits leading video packets
# whose timestamps are not established yet. This script drives the real ffmpeg
# CLI through the stream-copy-to-FLV path, corrupting only the timestamps of
# the first video packets with the input-side setts bitstream filter while
# leaving every later packet, key flag and B-frame untouched.
#
# It checks that:
#   - without the option the corrupted startup is fatal (default stays off);
#   - with the option stream copy starts on the next keyframe that carries
#     present, ordered timestamps, and the output decodes as H.264/H.265 video
#     with B-frame presentation reordering and monotonic DTS;
#   - initial audio-first and video-first interleaving keeps audio timing;
#   - valid B-frame and non-B-frame streams are unchanged by the option at
#     the packet level.
#
# Usage: ivr-startup.sh <ffmpeg> <ffprobe>

set -eu

FFMPEG=$1
FFPROBE=$2
work=${TMPDIR:-/tmp}/ffmpeg-ivr-startup.$$
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work"

MISSING='setts=pts=if(lt(N\,3)\,NOPTS\,PTS):dts=if(lt(N\,3)\,NOPTS\,DTS)'
REVERSED='setts=pts=if(eq(N\,0)\,0\,PTS):dts=if(eq(N\,0)\,40\,DTS)'
MUXER_ERROR='Timestamps are unset|Packet is missing PTS|Invalid DTS|Non-monotonic DTS|Error submitting a packet to the muxer'

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# make_video <codec> <name> <bframes>
make_video() {
    codec=$1
    name=$2
    bframes=$3
    if [ "$codec" = h264 ]; then
        enc="-c:v libx264 -g 25 -bf $bframes"
    else
        enc="-c:v libx265 -x265-params bframes=$bframes:keyint=25:min-keyint=25:scenecut=0:log-level=error"
    fi
    # shellcheck disable=SC2086
    "$FFMPEG" -nostdin -v error -y -f lavfi -i testsrc2=size=320x180:rate=25 \
        -t 2 $enc -pix_fmt yuv420p "$work/$name.mp4" ||
        fail "could not create $name fixture"
}

# write_flv <log> <option> [ffmpeg input/output arguments...]
write_flv() {
    logfile=$1
    option=$2
    shift 2
    # shellcheck disable=SC2086
    if "$FFMPEG" -nostdin -v warning -hide_banner -y -xerror $option \
        "$@" -codec copy -flvflags no_duration_filesize -f flv \
        "$work/$logfile.flv" >"$work/$logfile.log" 2>&1; then
        grep -Eq "$MUXER_ERROR" "$work/$logfile.log" &&
            fail "unexpected muxer timestamp error in $logfile"
        return 0
    fi
    return 1
}

packets() {
    stream=$1
    file=$2
    "$FFPROBE" -v error -select_streams "$stream" \
        -show_entries packet=pts,dts,flags -of csv=p=0 "$file"
}

first_packet() {
    packets "$1" "$2" | head -n 1
}

assert_decodes() {
    file=$1
    stream=$2
    "$FFMPEG" -nostdin -v error -xerror -i "$file" -map "0:$stream" \
        -f null - >/dev/null 2>&1 || fail "output does not decode: $stream in $file"
}

assert_video_start() {
    file=$1
    bframes=$2
    first=$(first_packet v:0 "$file")
    [ -n "$first" ] || fail "no video packets in $file"

    oldifs=$IFS
    IFS=,
    # shellcheck disable=SC2086
    set -- $first
    IFS=$oldifs
    pts=$1
    dts=$2
    flags=$3
    case $flags in
        *K*) ;;
        *) fail "first video packet is not a keyframe in $file: $first" ;;
    esac
    [ "$pts" != N/A ] || fail "first video packet has no PTS in $file"
    [ "$dts" != N/A ] || fail "first video packet has no DTS in $file"
    [ "$pts" -ge "$dts" ] || fail "first video packet has PTS < DTS in $file: $first"

    packets v:0 "$file" | awk -F, '
        $1 == "N/A" || $2 == "N/A" { exit 1 }
        NR > 1 && $2 <= prev_dts { exit 1 }
        NR > 1 && $1 < prev_pts { reordered = 1 }
        { prev_dts = $2; prev_pts = $1 }
        END { print reordered ? 1 : 0 }
    ' >"$work/reordered.txt" || fail "video timestamps are not a valid copy in $file"
    reordered=$(cat "$work/reordered.txt")
    if [ "$bframes" -gt 0 ]; then
        [ "$reordered" -eq 1 ] || fail "B-frame presentation reordering was lost in $file"
    else
        [ "$reordered" -eq 0 ] || fail "non-B-frame stream has reordered PTS in $file"
    fi

    frames=$("$FFPROBE" -v error -select_streams v:0 -count_frames \
        -show_entries stream=nb_read_frames -of csv=p=0 "$file")
    case $frames in
        ''|*[!0-9]*) fail "could not count decoded video frames in $file" ;;
    esac
    [ "$frames" -ge 15 ] || fail "decoded only $frames video frames in $file"
    has_b=$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=has_b_frames -of csv=p=0 "$file")
    if [ "$bframes" -gt 0 ]; then
        [ "$has_b" -ge 1 ] || fail "B-frame stream lost reordering in $file"
    else
        [ "$has_b" -eq 0 ] || fail "non-B-frame stream reports B-frames in $file"
    fi
    assert_decodes "$file" v:0
}

assert_audio() {
    file=$1
    assert_decodes "$file" a:0
    count=$(packets a:0 "$file" | wc -l)
    [ "$count" -ge 80 ] || fail "decoded only $count audio packets in $file"
    packets a:0 "$file" | awk -F, '
        $1 == "N/A" || $2 == "N/A" { exit 1 }
        NR > 1 && $2 <= prev_dts { exit 1 }
        NR > 1 && $1 < prev_pts { reordered = 1 }
        { prev_dts = $2; prev_pts = $1 }
        END { if (reordered) exit 1 }
    ' || fail "audio timestamps are not monotonic in $file"
}

assert_muxer_failure() {
    logfile=$1
    grep -Eq "$MUXER_ERROR" "$work/$logfile.log" ||
        fail "expected a muxer timestamp error, got:\n$(cat "$work/$logfile.log")"
}

make_video h264 h264-b 3
make_video h264 h264-nob 0
make_video hevc hevc-b 3
make_video hevc hevc-nob 0
"$FFMPEG" -nostdin -v error -y -f lavfi -i sine=frequency=1000:sample_rate=48000 \
    -t 2 -c:a aac -b:a 64k "$work/audio.m4a" || fail "could not create audio fixture"

for codec in h264 hevc; do
    # The option defaults to off: the corrupted start must stay fatal.
    write_flv "$codec-off" "" -bsf:v "$MISSING" -i "$work/$codec-b.mp4" &&
        fail "$codec: corrupted start unexpectedly succeeded without the option"
    assert_muxer_failure "$codec-off"

    # The option starts the copy on the next decodable keyframe.
    write_flv "$codec-on" -force_decodable_start \
        -bsf:v "$MISSING" -i "$work/$codec-b.mp4" ||
        fail "$codec: -force_decodable_start could not start stream copy"
    assert_video_start "$work/$codec-on.flv" 1

    # Reversed first-packet timestamps are the other observed startup shape.
    write_flv "$codec-reversed" -force_decodable_start \
        -bsf:v "$REVERSED" -i "$work/$codec-b.mp4" ||
        fail "$codec: could not recover from reversed first timestamps"
    assert_video_start "$work/$codec-reversed.flv" 1

    # A valid stream must be unaffected by the option, including B-frames.
    write_flv "$codec-valid-off" "" -i "$work/$codec-b.mp4" ||
        fail "$codec: valid stream failed without the option"
    write_flv "$codec-valid-on" -force_decodable_start -i "$work/$codec-b.mp4" ||
        fail "$codec: valid stream failed with the option"
    packets v:0 "$work/$codec-valid-off.flv" >"$work/$codec-valid-off.txt"
    packets v:0 "$work/$codec-valid-on.flv" >"$work/$codec-valid-on.txt"
    cmp -s "$work/$codec-valid-off.txt" "$work/$codec-valid-on.txt" ||
        fail "$codec: the option changed a valid B-frame stream"
    assert_video_start "$work/$codec-valid-on.flv" 1

    # Non-B-frame streams keep monotonic PTS and are unchanged as well.
    write_flv "$codec-nob-off" "" -i "$work/$codec-nob.mp4" ||
        fail "$codec: valid non-B stream failed without the option"
    write_flv "$codec-nob-on" -force_decodable_start -i "$work/$codec-nob.mp4" ||
        fail "$codec: valid non-B stream failed with the option"
    packets v:0 "$work/$codec-nob-off.flv" >"$work/$codec-nob-off.txt"
    packets v:0 "$work/$codec-nob-on.flv" >"$work/$codec-nob-on.txt"
    cmp -s "$work/$codec-nob-off.txt" "$work/$codec-nob-on.txt" ||
        fail "$codec: the option changed a valid non-B stream"
    assert_video_start "$work/$codec-nob-on.flv" 0
done

# Initial interleaving: audio first. The first copied video keyframe is the
# second GOP; audio still starts at 0 and must keep its timing.
for codec in h264 hevc; do
    write_flv "$codec-av-audio-first" -force_decodable_start \
        -itsoffset 0.4 -bsf:v "$MISSING" -i "$work/$codec-b.mp4" \
        -i "$work/audio.m4a" -map 0:v:0 -map 1:a:0 ||
        fail "$codec: audio-first start failed"
    assert_video_start "$work/$codec-av-audio-first.flv" 1
    assert_audio "$work/$codec-av-audio-first.flv"
    audio_dts=$(first_packet a:0 "$work/$codec-av-audio-first.flv" | cut -d, -f2)
    video_dts=$(first_packet v:0 "$work/$codec-av-audio-first.flv" | cut -d, -f2)
    [ "$audio_dts" -lt "$video_dts" ] ||
        fail "$codec: audio-first ordering was not preserved"

    # Without corruption the option must leave the whole A/V copy unchanged.
    write_flv "$codec-av-valid-off" "" \
        -itsoffset 0.4 -i "$work/$codec-b.mp4" \
        -i "$work/audio.m4a" -map 0:v:0 -map 1:a:0 ||
        fail "$codec: valid audio-first stream failed without the option"
    write_flv "$codec-av-valid-on" -force_decodable_start \
        -itsoffset 0.4 -i "$work/$codec-b.mp4" \
        -i "$work/audio.m4a" -map 0:v:0 -map 1:a:0 ||
        fail "$codec: valid audio-first stream failed with the option"
    for stream in v:0 a:0; do
        packets "$stream" "$work/$codec-av-valid-off.flv" >"$work/$codec-av-valid-off.txt"
        packets "$stream" "$work/$codec-av-valid-on.flv" >"$work/$codec-av-valid-on.txt"
        cmp -s "$work/$codec-av-valid-off.txt" "$work/$codec-av-valid-on.txt" ||
            fail "$codec: the option changed valid $stream timing"
    done
done

# Initial interleaving: video first. Audio starts after the first copied
# keyframe, so the video packet leads and audio timing is still untouched.
for codec in h264 hevc; do
    write_flv "$codec-av-video-first" -force_decodable_start \
        -bsf:v "$MISSING" -i "$work/$codec-b.mp4" \
        -itsoffset 1.2 -i "$work/audio.m4a" -map 0:v:0 -map 1:a:0 ||
        fail "$codec: video-first start failed"
    assert_video_start "$work/$codec-av-video-first.flv" 1
    assert_audio "$work/$codec-av-video-first.flv"
    audio_dts=$(first_packet a:0 "$work/$codec-av-video-first.flv" | cut -d, -f2)
    video_dts=$(first_packet v:0 "$work/$codec-av-video-first.flv" | cut -d, -f2)
    [ "$video_dts" -lt "$audio_dts" ] ||
        fail "$codec: video-first ordering was not preserved"
done

log "ivr startup tests passed"
