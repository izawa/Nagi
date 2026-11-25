#!/bin/zsh
# Turns a nagi-render sequence (f-0000.png, f-0001.png, …, 30 fps) into the site's video
# (docs/SITE-DESK.md): WebM (VP9) and MP4 (H.264) 1600 wide, and frame 90 as the JPEG poster.
# A looping video joins its last 1.5 s to its first 1.5 s with a crossfade; pass loop=0 for one
# that doesn't loop (ripples). The poster is another frame when given (fireflies: one that is lit).
#   scripts/site/encode.sh <frames folder> <output folder> <name> [loop=1] [poster=90]
set -euo pipefail

(( $# >= 3 )) || { echo "使い方: $0 <連番のフォルダ> <出力のフォルダ> <名前> [loop=1] [poster=90]" >&2; exit 2; }
frames=${1:A}; out=${2:A}; name=$3; loop=${4:-1}; poster=$(printf %04d ${5:-90})
mkdir -p $out

pre="scale=1600:-2:flags=lanczos,format=yuv420p"
if (( loop )); then
    n=$(ls $frames/f-*.png | wc -l)
    fade=1.5
    offset=$(echo "$n/30 - 2*$fade" | bc -l)
    graph="[0:v]${pre},split[a][b];[a]trim=start=${fade},setpts=PTS-STARTPTS[body];[b]trim=end=${fade},setpts=PTS-STARTPTS[head];[body][head]xfade=transition=fade:duration=${fade}:offset=${offset}[v]"
else
    graph="[0:v]${pre}[v]"
fi

ffmpeg -loglevel error -y -framerate 30 -i $frames/f-%04d.png -filter_complex $graph -map "[v]" \
    -c:v libvpx-vp9 -b:v 0 -crf 24 -row-mt 1 -an $out/$name.webm
ffmpeg -loglevel error -y -framerate 30 -i $frames/f-%04d.png -filter_complex $graph -map "[v]" \
    -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p -movflags +faststart -an $out/$name.mp4
ffmpeg -loglevel error -y -i $frames/f-$poster.png -vf "scale=1600:-2:flags=lanczos" -q:v 4 $out/$name.jpg
echo "✓ $out/$name.{webm,mp4,jpg}"
