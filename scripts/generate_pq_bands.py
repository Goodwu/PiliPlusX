#!/usr/bin/env python3
"""Generate a six-band ST 2084 PQ reference frame as a 10-bit HEVC clip."""

from __future__ import annotations

import argparse
import math
import struct
import subprocess
import tempfile
from pathlib import Path


WIDTH = 1920
HEIGHT = 1080
FPS = 30
DURATION = 2
LEVELS_NITS = (100.0, 203.0, 400.0, 1000.0, 2000.0, 4000.0)


def pq_code(nits: float) -> float:
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    luminance = (nits / 10000.0) ** m1
    return ((c1 + c2 * luminance) / (1.0 + c3 * luminance)) ** m2


def write_ppm(path: Path) -> None:
    with path.open("wb") as output:
        output.write(f"P6\n{WIDTH} {HEIGHT}\n65535\n".encode("ascii"))
        for _ in range(HEIGHT):
            row = bytearray()
            for x in range(WIDTH):
                level = LEVELS_NITS[min(len(LEVELS_NITS) - 1, x * len(LEVELS_NITS) // WIDTH)]
                value = round(pq_code(level) * 65535.0)
                row.extend(struct.pack(">HHH", value, value, value))
            output.write(row)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="luna-pq-") as temporary:
        ppm = Path(temporary) / "bands.ppm"
        write_ppm(ppm)
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-loop",
                "1",
                "-i",
                str(ppm),
                "-t",
                str(DURATION),
                "-r",
                str(FPS),
                "-c:v",
                "libx265",
                "-pix_fmt",
                "yuv420p10le",
                "-color_primaries",
                "bt2020",
                "-color_trc",
                "smpte2084",
                "-colorspace",
                "bt2020nc",
                "-x265-params",
                "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                "-tag:v",
                "hvc1",
                "-y",
                str(args.output),
            ],
            check=True,
        )
    print("PQ codes:", ", ".join(f"{level:g} nits={pq_code(level):.8f}" for level in LEVELS_NITS))


if __name__ == "__main__":
    main()
