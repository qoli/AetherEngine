#!/usr/bin/env python3
"""Generate a deterministic color-managed BT.2020 HDR reference pattern.

The PPM stores nonlinear BT.2020 R'G'B' samples. PQ samples are encoded with
SMPTE ST 2084 from absolute luminance in nits. HLG samples are encoded with
the ARIB STD-B67 OETF from scene-linear values. FFmpeg may then perform only
the BT.2020 non-constant-luminance RGB-to-YCbCr matrix conversion; it must not
reinterpret SDR test-pattern values as HDR.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
import struct
from typing import Callable, Iterable


PQ_REFERENCE_WHITE_NITS = 203.0
PQ_GRAY_STEPS_NITS = (0.0, 0.1, 1.0, 10.0, 50.0, 100.0, 203.0, 1000.0)
HLG_REFERENCE_WHITE_SCENE = 0.265
HLG_GRAY_STEPS_SCENE = (0.0, 0.005, 0.018, 0.05, 0.18, 0.265, 0.5, 1.0)
COLOR_BAR_COMPONENTS = (
    (1.0, 1.0, 1.0),
    (1.0, 1.0, 0.0),
    (0.0, 1.0, 1.0),
    (0.0, 1.0, 0.0),
    (1.0, 0.0, 1.0),
    (1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0),
    (0.0, 0.0, 0.0),
)


def pq_oetf(luminance_nits: float) -> float:
    if not math.isfinite(luminance_nits) or not 0.0 <= luminance_nits <= 10000.0:
        raise ValueError("PQ luminance must be finite and within 0...10000 nits")
    m1 = 2610.0 / 16384.0
    m2 = 2523.0 / 32.0
    c1 = 3424.0 / 4096.0
    c2 = 2413.0 / 128.0
    c3 = 2392.0 / 128.0
    normalized = luminance_nits / 10000.0
    powered = normalized**m1
    return ((c1 + c2 * powered) / (1.0 + c3 * powered)) ** m2


def hlg_oetf(scene_linear: float) -> float:
    if not math.isfinite(scene_linear) or not 0.0 <= scene_linear <= 1.0:
        raise ValueError("HLG scene-linear value must be finite and within 0...1")
    if scene_linear <= 1.0 / 12.0:
        return math.sqrt(3.0 * scene_linear)
    a = 0.17883277
    b = 1.0 - (4.0 * a)
    c = 0.5 - (a * math.log(4.0 * a))
    return a * math.log((12.0 * scene_linear) - b) + c


def encoded_u16(value: float) -> int:
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        raise ValueError("encoded transfer value must be finite and within 0...1")
    return round(value * 65535.0)


def encoded_color(
    components: Iterable[float],
    scale: float,
    transfer: Callable[[float], float],
) -> tuple[int, int, int]:
    return tuple(encoded_u16(transfer(component * scale)) for component in components)


def segmented_row(colors: list[tuple[int, int, int]], width: int) -> bytes:
    row = bytearray()
    for index, color in enumerate(colors):
        start = round(index * width / len(colors))
        end = round((index + 1) * width / len(colors))
        row.extend(struct.pack(">HHH", *color) * (end - start))
    expected_bytes = width * 6
    if len(row) != expected_bytes:
        raise RuntimeError(
            f"malformed reference row: expected {expected_bytes} bytes, wrote {len(row)}"
        )
    return bytes(row)


def verify_transfer_anchors() -> None:
    anchors = (
        ("PQ black", pq_oetf(0.0), 0.000000730955903),
        ("PQ 100 nits", pq_oetf(100.0), 0.508078421517399),
        ("PQ 1000 nits", pq_oetf(1000.0), 0.751827096247042),
        ("PQ 10000 nits", pq_oetf(10000.0), 1.0),
        ("HLG black", hlg_oetf(0.0), 0.0),
        ("HLG branch boundary", hlg_oetf(1.0 / 12.0), 0.5),
        ("HLG peak", hlg_oetf(1.0), 1.0),
    )
    for name, actual, expected in anchors:
        if not math.isclose(actual, expected, rel_tol=0.0, abs_tol=1e-8):
            raise RuntimeError(
                f"{name} transfer anchor mismatch: expected {expected}, got {actual}"
            )


def write_pattern(path: Path, width: int, height: int, transfer_name: str) -> None:
    if width < 16 or height < 4 or width % 2 != 0 or height % 2 != 0:
        raise ValueError("reference dimensions must be even and at least 16x4")
    if path.exists():
        raise FileExistsError(f"reference output already exists: {path}")
    if not path.parent.is_dir():
        raise FileNotFoundError(f"reference output directory does not exist: {path.parent}")

    if transfer_name == "pq":
        color_scale = PQ_REFERENCE_WHITE_NITS
        grayscale_steps = PQ_GRAY_STEPS_NITS
        transfer = pq_oetf
    elif transfer_name == "hlg":
        color_scale = HLG_REFERENCE_WHITE_SCENE
        grayscale_steps = HLG_GRAY_STEPS_SCENE
        transfer = hlg_oetf
    else:
        raise ValueError(f"unsupported reference transfer: {transfer_name}")

    color_bars = [
        encoded_color(components, color_scale, transfer)
        for components in COLOR_BAR_COMPONENTS
    ]
    grayscale = [
        encoded_color((1.0, 1.0, 1.0), step, transfer)
        for step in grayscale_steps
    ]
    color_row = segmented_row(color_bars, width)
    grayscale_row = segmented_row(grayscale, width)
    color_height = (height * 2) // 3

    with path.open("xb") as output:
        output.write(
            (
                "P6\n"
                f"# AetherEngine BT.2020 {transfer_name.upper()} reference pattern\n"
                f"{width} {height}\n"
                "65535\n"
            ).encode("ascii")
        )
        for row_index in range(height):
            output.write(color_row if row_index < color_height else grayscale_row)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transfer", required=True, choices=("pq", "hlg"))
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    verify_transfer_anchors()
    write_pattern(
        arguments.output,
        arguments.width,
        arguments.height,
        arguments.transfer,
    )
    print(
        f"Generated BT.2020 {arguments.transfer.upper()} reference: "
        f"{arguments.output} ({arguments.width}x{arguments.height})"
    )


if __name__ == "__main__":
    main()
