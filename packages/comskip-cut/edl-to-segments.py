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
        # `--` ends option parsing: without it a recording named e.g.
        # `-show_streams` is read as an ffprobe flag rather than an input, and
        # ffprobe then exits 0 having probed nothing at all.
        "--",
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
        commercials = parse_edl(edl_path)

        if not commercials:
            print("No commercials found in EDL file", file=sys.stderr)
            sys.exit(1)

        duration = get_video_duration(video_path)
        segments = calculate_content_segments(commercials, duration)
        content_duration = sum(end - start for start, end in segments)

        # Output: one segment per line as "start end"
        for start, end in segments:
            print(f"{start} {end}")

        # Expected duration on stderr for validation
        print(f"EXPECTED_DURATION:{content_duration}", file=sys.stderr)

    except Exception as e:
        print(f"Error processing files: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
