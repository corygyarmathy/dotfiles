#!/usr/bin/env python3
"""
Convert comskip EDL files to ffmpeg concat demuxer input.
Generates segment list for content (non-commercial) portions.
"""

import sys
from pathlib import Path


def parse_edl(edl_path: Path) -> list[tuple[float, float]]:
    """Parse EDL file and return list of (start, end) commercial segments."""
    commercials = []

    with open(edl_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            parts = line.split()
            if len(parts) >= 2:
                start = float(parts[0])
                end = float(parts[1])
                commercials.append((start, end))

    return sorted(commercials)


def get_video_duration(video_path: Path) -> float:
    """Get video duration using ffprobe."""
    import subprocess
    import json

    cmd = [
        "ffprobe",
        "-v",
        "quiet",
        "-print_format",
        "json",
        "-show_format",
        str(video_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    data = json.loads(result.stdout)
    return float(data["format"]["duration"])


def calculate_content_segments(
    commercials: list[tuple[float, float]], duration: float
) -> list[tuple[float, float]]:
    """Calculate content segments (inverse of commercials)."""
    segments = []
    current_time = 0.0

    for start, end in commercials:
        # Add content segment before this commercial
        if start > current_time:
            segments.append((current_time, start))
        current_time = end

    # Add final content segment after last commercial
    if current_time < duration:
        segments.append((current_time, duration))

    return segments


def generate_concat_script(
    video_path: Path, segments: list[tuple[float, float]]
) -> str:
    """Generate ffmpeg filter_complex script for cutting."""
    filters = []

    for i, (start, end) in enumerate(segments):
        # Each segment: trim, then set presentation timestamp
        duration = end - start
        filters.append(
            f"[0:v]trim=start={start}:end={end},setpts=PTS-STARTPTS[v{i}];"
            + f"[0:a]atrim=start={start}:end={end},asetpts=PTS-STARTPTS[a{i}]"
        )

    # Concatenate all segments
    v_streams = "".join(f"[v{i}]" for i in range(len(segments)))
    a_streams = "".join(f"[a{i}]" for i in range(len(segments)))

    filters.append(
        f"{v_streams}concat=n={len(segments)}:v=1:a=0[outv];"
        + f"{a_streams}concat=n={len(segments)}:v=0:a=1[outa]"
    )

    return ";".join(filters)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <video_file> <edl_file>", file=sys.stderr)
        sys.exit(1)

    video_path = Path(sys.argv[1])
    edl_path = Path(sys.argv[2])

    if not video_path.exists():
        print(f"Error: Video file not found: {video_path}", file=sys.stderr)
        sys.exit(1)

    if not edl_path.exists():
        print(f"Error: EDL file not found: {edl_path}", file=sys.stderr)
        sys.exit(1)

    try:
        # Parse commercial breaks from EDL
        commercials = parse_edl(edl_path)

        if not commercials:
            print("No commercials found in EDL file", file=sys.stderr)
            sys.exit(1)

        # Get video duration
        duration = get_video_duration(video_path)

        # Calculate content segments
        segments = calculate_content_segments(commercials, duration)

        # Output: filter_complex script and expected duration
        filter_script = generate_concat_script(video_path, segments)
        content_duration = sum(end - start for start, end in segments)

        # Print filter script for ffmpeg
        print(filter_script)

        # Print expected duration to stderr for validation
        print(f"EXPECTED_DURATION:{content_duration}", file=sys.stderr)

    except Exception as e:
        print(f"Error processing files: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
