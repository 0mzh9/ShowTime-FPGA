"""V15 shared calibration conversion and FPGA feasibility checks.

This module deliberately contains no Qt code.  It can be exercised in unit
tests and by the future calibration wizard before a packet is ever sent.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
from typing import Iterable

import numpy as np

from calibration_protocol import FixedCalibration


@dataclass(frozen=True)
class FloatCalibration:
    fx: float
    fy: float
    cx: float
    cy: float
    k1: float
    k2: float
    p1: float
    p2: float
    width: int = 1280
    height: int = 720

    @classmethod
    def from_json(cls, path: str | Path) -> "FloatCalibration":
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        k = data["K"]
        d = data["distortion"]
        width, height = data["image_size"]
        if len(d) < 4 or (len(d) > 4 and abs(float(d[4])) > 1e-15):
            raise ValueError("V13 supports k1/k2/p1/p2 with k3 fixed to zero")
        return cls(
            float(k[0][0]), float(k[1][1]), float(k[0][2]), float(k[1][2]),
            float(d[0]), float(d[1]), float(d[2]), float(d[3]),
            int(width), int(height),
        )


@dataclass(frozen=True)
class OutputGeometry:
    width: int
    height: int
    cx: float
    cy: float
    source_output_bounds: tuple[float, float, float, float]
    margins: tuple[float, float, float, float]


@dataclass(frozen=True)
class HardwareValidation:
    passed: bool
    errors: tuple[str, ...]
    warnings: tuple[str, ...]
    min_radial: float
    min_jacobian: float
    maximum_source_row_span: int
    cache_lines: int
    validated_row_span_limit: int
    canvas1080_margins: tuple[float, float, float, float]
    fixed_float_max_error_px: float

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False, indent=2)


def _distort(cal: FloatCalibration, x: np.ndarray, y: np.ndarray):
    r2 = x * x + y * y
    radial = 1.0 + cal.k1 * r2 + cal.k2 * r2 * r2
    xd = x * radial + 2.0 * cal.p1 * x * y + cal.p2 * (r2 + 2.0 * x * x)
    yd = y * radial + cal.p1 * (r2 + 2.0 * y * y) + 2.0 * cal.p2 * x * y
    return xd, yd, radial


def _jacobian(cal: FloatCalibration, x: np.ndarray, y: np.ndarray):
    r2 = x * x + y * y
    radial = 1.0 + cal.k1 * r2 + cal.k2 * r2 * r2
    radial_gradient = cal.k1 + 2.0 * cal.k2 * r2
    a = radial + 2.0 * x * x * radial_gradient + 2.0 * cal.p1 * y + 6.0 * cal.p2 * x
    b = 2.0 * x * y * radial_gradient + 2.0 * cal.p1 * x + 2.0 * cal.p2 * y
    d = radial + 2.0 * y * y * radial_gradient + 6.0 * cal.p1 * y + 2.0 * cal.p2 * x
    return a, b, d, a * d - b * b


def inverse_distortion(
    cal: FloatCalibration, xd: np.ndarray, yd: np.ndarray, iterations: int = 20
) -> tuple[np.ndarray, np.ndarray, float, float]:
    """Newton-invert the calibrated distortion model."""

    x = np.asarray(xd, dtype=np.float64).copy()
    y = np.asarray(yd, dtype=np.float64).copy()
    min_det = math.inf
    for _ in range(iterations):
        estimate_x, estimate_y, _ = _distort(cal, x, y)
        a, b, d, determinant = _jacobian(cal, x, y)
        min_det = min(min_det, float(np.min(determinant)))
        if not np.all(np.isfinite(determinant)) or float(np.min(determinant)) <= 1e-8:
            raise ValueError("distortion map is folded or singular")
        error_x = estimate_x - xd
        error_y = estimate_y - yd
        x -= (d * error_x - b * error_y) / determinant
        y -= (-b * error_x + a * error_y) / determinant
    check_x, check_y, _ = _distort(cal, x, y)
    residual = float(np.max(np.maximum(np.abs(check_x - xd), np.abs(check_y - yd))))
    return x, y, residual, min_det


def _source_boundary(width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
    horizontal = np.arange(width, dtype=np.float64)
    vertical = np.arange(height, dtype=np.float64)
    u = np.concatenate((horizontal, horizontal, np.zeros(height), np.full(height, width - 1.0)))
    v = np.concatenate((np.zeros(width), np.full(width, height - 1.0), vertical, vertical))
    return u, v


def derive_full_view_output(
    cal: FloatCalibration, width: int = 1920, height: int = 1080
) -> OutputGeometry:
    """Preserve focal length and translate the undistorted source into a canvas."""

    u, v = _source_boundary(cal.width, cal.height)
    xd = (u - cal.cx) / cal.fx
    yd = (v - cal.cy) / cal.fy
    x, y, residual, _ = inverse_distortion(cal, xd, yd)
    if residual * max(cal.fx, cal.fy) > 1e-6:
        raise ValueError("inverse distortion failed to converge")
    ideal_x = x * cal.fx
    ideal_y = y * cal.fy
    cx = ((width - 1.0) - (float(np.min(ideal_x)) + float(np.max(ideal_x)))) / 2.0
    cy = ((height - 1.0) - (float(np.min(ideal_y)) + float(np.max(ideal_y)))) / 2.0
    output_x = ideal_x + cx
    output_y = ideal_y + cy
    bounds = (
        float(np.min(output_x)), float(np.max(output_x)),
        float(np.min(output_y)), float(np.max(output_y)),
    )
    margins = (bounds[0], width - 1.0 - bounds[1], bounds[2], height - 1.0 - bounds[3])
    if min(margins) < -1e-6:
        raise ValueError("full undistorted field does not fit the requested canvas without scaling")
    return OutputGeometry(width, height, cx, cy, bounds, margins)


def to_fixed(
    cal: FloatCalibration,
    output1080: OutputGeometry | None = None,
    correction_enable: bool = True,
) -> FixedCalibration:
    if (cal.width, cal.height) != (1280, 720):
        raise ValueError("V13 FPGA accepts only a 1280x720 calibrated input")
    if output1080 is None:
        output1080 = derive_full_view_output(cal)
    value = FixedCalibration(
        flags=1 if correction_enable else 0,
        input_width=cal.width,
        input_height=cal.height,
        canvas720_width=1280,
        canvas720_height=720,
        canvas1080_width=output1080.width,
        canvas1080_height=output1080.height,
        fx_q12=round(cal.fx * (1 << 12)),
        fy_q12=round(cal.fy * (1 << 12)),
        cx_q12=round(cal.cx * (1 << 12)),
        cy_q12=round(cal.cy * (1 << 12)),
        inv_fx_q40=round((1.0 / cal.fx) * (1 << 40)),
        inv_fy_q40=round((1.0 / cal.fy) * (1 << 40)),
        k1_q30=round(cal.k1 * (1 << 30)),
        k2_q30=round(cal.k2 * (1 << 30)),
        p1_q30=round(cal.p1 * (1 << 30)),
        p2_q30=round(cal.p2 * (1 << 30)),
        out720_cx_q12=round(cal.cx * (1 << 12)),
        out720_cy_q12=round(cal.cy * (1 << 12)),
        out1080_cx_q12=round(output1080.cx * (1 << 12)),
        out1080_cy_q12=round(output1080.cy * (1 << 12)),
    )
    value.validate()
    return value


def _fixed_as_float(value: FixedCalibration) -> tuple[FloatCalibration, float, float]:
    return (
        FloatCalibration(
            value.fx_q12 / (1 << 12), value.fy_q12 / (1 << 12),
            value.cx_q12 / (1 << 12), value.cy_q12 / (1 << 12),
            value.k1_q30 / (1 << 30), value.k2_q30 / (1 << 30),
            value.p1_q30 / (1 << 30), value.p2_q30 / (1 << 30),
            value.input_width, value.input_height,
        ),
        value.out1080_cx_q12 / (1 << 12),
        value.out1080_cy_q12 / (1 << 12),
    )


def _map_output_row(
    cal: FloatCalibration, output_cx: float, output_cy: float, v: int, width: int
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    u = np.arange(width, dtype=np.float64)
    x = (u - output_cx) / cal.fx
    y = np.full_like(x, (v - output_cy) / cal.fy)
    xd, yd, radial = _distort(cal, x, y)
    sx = xd * cal.fx + cal.cx
    sy = yd * cal.fy + cal.cy
    _, _, _, determinant = _jacobian(cal, x, y)
    return sx, sy, radial, determinant


def validate_for_fpga(
    cal: FloatCalibration,
    fixed: FixedCalibration,
    output1080: OutputGeometry,
    cache_lines: int = 64,
    validated_row_span_limit: int = 112,
) -> HardwareValidation:
    errors: list[str] = list(fixed.validation_errors())
    warnings: list[str] = []
    min_radial = math.inf
    min_jacobian = math.inf
    maximum_span = 0
    fixed_cal, fixed_out_cx, fixed_out_cy = _fixed_as_float(fixed)
    fixed_float_error = 0.0

    # Exact per-pixel row traversal matches the 1920x1080 request order and
    # measures the simultaneous source-row working set required by the cache.
    for v in range(output1080.height):
        sx, sy, radial, determinant = _map_output_row(
            cal, output1080.cx, output1080.cy, v, output1080.width
        )
        fsx, fsy, _, _ = _map_output_row(
            fixed_cal, fixed_out_cx, fixed_out_cy, v, output1080.width
        )
        min_radial = min(min_radial, float(np.min(radial)))
        min_jacobian = min(min_jacobian, float(np.min(determinant)))
        fixed_float_error = max(
            fixed_float_error,
            float(np.max(np.hypot(fsx - sx, fsy - sy))),
        )
        active = (sx > -1.0) & (sx < cal.width) & (sy > -1.0) & (sy < cal.height)
        if np.any(active):
            y0 = np.floor(sy[active]).astype(np.int64)
            span = int(np.max(y0) - np.min(y0) + 2)  # include bilinear y+1
            maximum_span = max(maximum_span, span)

    if min_radial <= 0.05:
        errors.append(f"minimum radial scale {min_radial:.6f} is unsafe")
    if min_jacobian <= 0.05:
        errors.append(f"minimum mapping Jacobian {min_jacobian:.6f} is unsafe")
    # The direct-mapped cache can evict and reload rows while walking a curved
    # output scanline, so scanline span is not identical to simultaneous RAM
    # occupancy.  Crossing the physical line count is a throughput warning.
    # V7 independently validated the current lens with a 112-row span; V13
    # rejects anything beyond that envelope until a transaction-level timing
    # simulation proves a wider mapping.
    if maximum_span > cache_lines:
        warnings.append(
            f"source row span {maximum_span} exceeds the {cache_lines}-line physical cache; "
            "DDR reload/latency simulation is required"
        )
    if maximum_span > validated_row_span_limit:
        errors.append(
            f"source row span {maximum_span} exceeds validated limit "
            f"{validated_row_span_limit}"
        )
    if fixed_float_error > 0.01:
        errors.append(f"fixed-point conversion error {fixed_float_error:.6f}px exceeds 0.01px")
    if min(output1080.margins) < 0:
        errors.append("1080p canvas does not contain the complete undistorted field")

    return HardwareValidation(
        not errors,
        tuple(errors),
        tuple(warnings),
        min_radial,
        min_jacobian,
        maximum_span,
        cache_lines,
        validated_row_span_limit,
        output1080.margins,
        fixed_float_error,
    )


def build_and_validate(cal: FloatCalibration):
    output = derive_full_view_output(cal)
    fixed = to_fixed(cal, output)
    report = validate_for_fpga(cal, fixed, output)
    return output, fixed, report
