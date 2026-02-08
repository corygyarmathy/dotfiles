#!/usr/bin/env python3
"""
Convert comskip EDL files to ffmpeg chapter metadata.
Reads an EDL file and generates chapter markers for content segments (non-commercials).
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

    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    return float(data["format"]["duration"])


def calculate_content_chapters(
    commercials: list[tuple[float, float]], duration: float
) -> list[tuple[float, float, str]]:
    """Calculate content chapter segments (inverse of commercials)."""
    chapters = []
    current_time = 0.0
    chapter_num = 1

    for start, end in commercials:
        # Add content chapter before this commercial
        if start > current_time:
            chapters.append((current_time, start, f"Chapter {chapter_num}"))
            chapter_num += 1
        current_time = end

    # Add final content chapter after last commercial
    if current_time < duration:
        chapters.append((current_time, duration, f"Chapter {chapter_num}"))

    return chapters


def generate_ffmetadata(chapters: list[tuple[float, float, str]]) -> str:
    """Generate ffmpeg metadata format."""
    lines = [";FFMETADATA1"]

    for start, end, title in chapters:
        # Convert to milliseconds (ffmpeg timebase)
        start_ms = int(start * 1000)
        end_ms = int(end * 1000)

        lines.append("")
        lines.append("[CHAPTER]")
        lines.append("TIMEBASE=1/1000")
        lines.append(f"START={start_ms}")
        lines.append(f"END={end_ms}")
        lines.append(f"title={title}")

    return "\n".join(lines)


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

        # Calculate content chapters
        chapters = calculate_content_chapters(commercials, duration)

        # Generate and output ffmetadata
        metadata = generate_ffmetadata(chapters)
        print(metadata)

    except Exception as e:
        print(f"Error processing files: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
