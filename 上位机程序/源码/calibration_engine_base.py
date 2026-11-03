"""Automatic chessboard calibration pipeline used by ShowTime V15 shared.

The pipeline never deletes or modifies source images.  Rejection is based on
image/detection quality before fitting; reprojection residuals are reported but
are not repeatedly used to make the training RMS look smaller.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
import csv
import hashlib
import json
import math
from pathlib import Path
from typing import Callable, Iterable

import cv2
import numpy as np

from calibration_math import FloatCalibration, build_and_validate
from calibration_protocol import CalibrationPacket


ProgressCallback = Callable[[int, int, str], None]
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"}


@dataclass(frozen=True)
class CalibrationSettings:
    inner_cols: int
    inner_rows: int
    square_size_mm: float
    expected_width: int = 1280
    expected_height: int = 720
    minimum_views: int = 15
    quality_mad_factor: float = 2.5
    maximum_rms_px: float = 0.8
    maximum_cv_rms_px: float = 1.0
    minimum_coverage_fraction: float = 0.55
    minimum_grid_cells: int = 24

    def validate(self) -> None:
        if not (3 <= self.inner_cols <= 30 and 3 <= self.inner_rows <= 30):
            raise ValueError("棋盘格内角点行列数必须在3到30之间")
        if not (0.01 <= self.square_size_mm <= 10000.0):
            raise ValueError("方格尺寸必须是有效的正数")
        if self.expected_width != 1280 or self.expected_height != 720:
            raise ValueError("V13 FPGA标定输入必须是1280x720")
        if self.minimum_views < 10:
            raise ValueError("最少有效图片数不能小于10")


@dataclass
class ImageAssessment:
    path: str
    filename: str
    sha256: str = ""
    width: int = 0
    height: int = 0
    detected: bool = False
    accepted: bool = False
    reasons: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    metrics: dict[str, float] = field(default_factory=dict)
    corners: np.ndarray | None = field(default=None, repr=False)

    def serializable(self) -> dict:
        result = asdict(self)
        result.pop("corners", None)
        return result


@dataclass(frozen=True)
class CalibrationRun:
    output_directory: Path
    passed: bool
    report: dict
    packet: bytes


def discover_images(folder: str | Path) -> list[Path]:
    root = Path(folder)
    if not root.is_dir():
        raise ValueError(f"图片目录不存在：{root}")
    # A ShowTime capture directory also contains corrected_right.png. When
    # original_left.png exists, use only those originals, including nested
    # capture folders; never mix corrected previews into the calibration.
    originals = sorted(root.rglob("original_left.png"))
    if originals:
        return originals
    return sorted(
        (p for p in root.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES),
        key=lambda p: p.name.lower(),
    )


def _read_image(path: Path, flags: int) -> np.ndarray | None:
    try:
        raw = np.fromfile(path, dtype=np.uint8)
    except OSError:
        return None
    if raw.size == 0:
        return None
    return cv2.imdecode(raw, flags)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _robust_upper_threshold(values: Iterable[float], factor: float) -> dict[str, float]:
    data = np.asarray([v for v in values if math.isfinite(v)], dtype=np.float64)
    if data.size < 5:
        return {"median": math.nan, "scaled_mad": math.nan, "threshold": math.inf}
    median = float(np.median(data))
    sigma = float(1.4826 * np.median(np.abs(data - median)))
    # MAD can be zero for synthetic or quantized inputs.  Keep a small robust
    # percentile allowance rather than rejecting every non-median sample.
    threshold = median + factor * sigma if sigma > 1e-12 else float(np.percentile(data, 95))
    return {"median": median, "scaled_mad": sigma, "threshold": threshold}


def assess_images(
    images: list[Path],
    settings: CalibrationSettings,
    progress: ProgressCallback | None = None,
) -> tuple[list[ImageAssessment], dict[str, dict[str, float]]]:
    settings.validate()
    pattern = (settings.inner_cols, settings.inner_rows)
    sb_flags = cv2.CALIB_CB_NORMALIZE_IMAGE | cv2.CALIB_CB_EXHAUSTIVE | cv2.CALIB_CB_ACCURACY
    results: list[ImageAssessment] = []
    seen_hashes: dict[str, str] = {}

    for index, path in enumerate(images):
        if progress:
            progress(index, len(images), path.name)
        row = ImageAssessment(str(path.resolve()), path.name)
        row.sha256 = _sha256(path)
        if row.sha256 in seen_hashes:
            row.reasons.append(f"与 {seen_hashes[row.sha256]} 完全重复")
            results.append(row)
            continue
        seen_hashes[row.sha256] = row.filename
        gray = _read_image(path, cv2.IMREAD_GRAYSCALE)
        if gray is None:
            row.reasons.append("图片无法读取")
            results.append(row)
            continue
        row.height, row.width = gray.shape[:2]
        if (row.width, row.height) != (settings.expected_width, settings.expected_height):
            row.reasons.append(
                f"分辨率为{row.width}x{row.height}，要求{settings.expected_width}x{settings.expected_height}"
            )
            results.append(row)
            continue

        mean = float(np.mean(gray))
        dark_fraction = float(np.mean(gray <= 5))
        bright_fraction = float(np.mean(gray >= 250))
        laplacian_variance = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        row.metrics.update(
            mean_luma=mean,
            dark_fraction=dark_fraction,
            bright_fraction=bright_fraction,
            laplacian_variance=laplacian_variance,
        )
        if mean < 12.0:
            row.reasons.append("图像严重欠曝")
        elif mean > 245.0:
            row.reasons.append("图像严重过曝")
        if dark_fraction > 0.98 or bright_fraction > 0.98:
            row.reasons.append("有效灰度范围过小")
        if row.reasons:
            results.append(row)
            continue

        found, corners = cv2.findChessboardCornersSB(gray, pattern, flags=sb_flags)
        if not found or corners is None or len(corners) != settings.inner_cols * settings.inner_rows:
            row.reasons.append("未检测到完整棋盘格内角点")
            results.append(row)
            continue
        row.detected = True
        row.corners = np.asarray(corners, dtype=np.float32).reshape(-1, 1, 2)

        hull = cv2.convexHull(row.corners.reshape(-1, 2))
        coverage = float(cv2.contourArea(hull) / (row.width * row.height))
        row.metrics["board_hull_fraction"] = coverage
        if coverage < 0.008:
            row.reasons.append("棋盘格在画面中占比过小")

        # Start the classic sub-pixel optimiser from the SB solution.  Running
        # a second board detector is unsuitable here because a valid board may
        # be returned with a reversed corner ordering, creating false outliers.
        refined = cv2.cornerSubPix(
            gray,
            row.corners.copy(),
            (5, 5),
            (-1, -1),
            (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_MAX_ITER, 40, 0.001),
        )
        delta = np.linalg.norm(
            refined.reshape(-1, 2) - row.corners.reshape(-1, 2), axis=1
        )
        row.metrics["subpixel_refine_vs_sb_rms_px"] = float(np.sqrt(np.mean(delta * delta)))
        row.metrics["subpixel_refine_vs_sb_p95_px"] = float(np.percentile(delta, 95))

        try:
            horizontal, _ = cv2.estimateChessboardSharpness(
                gray, pattern, row.corners, rise_distance=0.8, vertical=False
            )
            vertical, _ = cv2.estimateChessboardSharpness(
                gray, pattern, row.corners, rise_distance=0.8, vertical=True
            )
            row.metrics["max_mean_edge_width_px"] = float(max(horizontal[0], vertical[0]))
            row.metrics["minimum_edge_contrast"] = float(
                min(horizontal[2] - horizontal[1], vertical[2] - vertical[1])
            )
        except cv2.error:
            row.metrics["max_mean_edge_width_px"] = math.inf
            row.metrics["minimum_edge_contrast"] = 0.0
            row.reasons.append("无法计算棋盘格清晰度")
        results.append(row)

    quality_names = (
        "max_mean_edge_width_px",
        "subpixel_refine_vs_sb_rms_px",
        "subpixel_refine_vs_sb_p95_px",
    )
    detected_clean = [r for r in results if r.detected and not r.reasons]
    thresholds = {
        name: _robust_upper_threshold(
            (r.metrics.get(name, math.inf) for r in detected_clean),
            settings.quality_mad_factor,
        )
        for name in quality_names
    }
    labels = {
        "max_mean_edge_width_px": "棋盘格边缘模糊",
        "subpixel_refine_vs_sb_rms_px": "亚像素优化与SB角点RMS差异异常",
        "subpixel_refine_vs_sb_p95_px": "亚像素优化与SB角点P95差异异常",
    }
    for row in detected_clean:
        for name in quality_names:
            if row.metrics[name] > thresholds[name]["threshold"]:
                row.reasons.append(labels[name])
        row.accepted = not row.reasons
    return results, thresholds


def _object_points(settings: CalibrationSettings) -> np.ndarray:
    points = np.zeros((settings.inner_cols * settings.inner_rows, 3), np.float32)
    points[:, :2] = np.mgrid[0 : settings.inner_cols, 0 : settings.inner_rows].T.reshape(-1, 2)
    points[:, :2] *= settings.square_size_mm
    return points


def _fit(
    corners: list[np.ndarray], settings: CalibrationSettings, seeds=(600.0, 800.0, 1000.0)
):
    obj = _object_points(settings)
    size = (settings.expected_width, settings.expected_height)
    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_MAX_ITER, 200, 1e-12)
    fits = []
    for focal in seeds:
        matrix = np.array(
            [[focal, 0.0, 639.5], [0.0, focal, 359.5], [0.0, 0.0, 1.0]],
            dtype=np.float64,
        )
        result = cv2.calibrateCamera(
            [obj] * len(corners),
            corners,
            size,
            matrix,
            np.zeros(5, np.float64),
            flags=cv2.CALIB_USE_INTRINSIC_GUESS | cv2.CALIB_FIX_K3 | cv2.CALIB_USE_LU,
            criteria=criteria,
        )
        fits.append((focal, result))
    return min(fits, key=lambda item: item[1][0]), fits


def _per_view_errors(
    corners: list[np.ndarray], settings: CalibrationSettings, fit
) -> list[float]:
    _, matrix, distortion, rvecs, tvecs = fit
    obj = _object_points(settings)
    errors = []
    for observed, rvec, tvec in zip(corners, rvecs, tvecs):
        projected, _ = cv2.projectPoints(obj, rvec, tvec, matrix, distortion)
        delta = projected.reshape(-1, 2) - observed.reshape(-1, 2)
        errors.append(float(np.sqrt(np.mean(np.sum(delta * delta, axis=1)))))
    return errors


def _coverage(rows: list[ImageAssessment], settings: CalibrationSettings) -> dict:
    points = np.concatenate([r.corners.reshape(-1, 2) for r in rows], axis=0)
    hull = cv2.convexHull(points.astype(np.float32))
    fraction = float(cv2.contourArea(hull) / (settings.expected_width * settings.expected_height))
    grid = np.zeros((4, 8), dtype=np.int64)
    gx = np.clip((points[:, 0] * 8 / settings.expected_width).astype(int), 0, 7)
    gy = np.clip((points[:, 1] * 4 / settings.expected_height).astype(int), 0, 3)
    for x, y in zip(gx, gy):
        grid[y, x] += 1
    return {
        "hull_area_fraction": fraction,
        "occupied_grid_cells": int(np.count_nonzero(grid)),
        "grid_4x8": grid.tolist(),
        "bounds_xyxy": [
            float(np.min(points[:, 0])), float(np.min(points[:, 1])),
            float(np.max(points[:, 0])), float(np.max(points[:, 1])),
        ],
    }


def _cross_validate(rows: list[ImageAssessment], settings: CalibrationSettings) -> dict:
    fold_rows = []
    pooled: list[float] = []
    obj = _object_points(settings)
    for fold in range(5):
        train = [r for index, r in enumerate(rows) if index % 5 != fold]
        test = [r for index, r in enumerate(rows) if index % 5 == fold]
        _, fit = _fit([r.corners for r in train], settings, seeds=(600.0, 1000.0))[0]
        _, matrix, distortion, _, _ = fit
        errors = []
        # Held-out images need their own extrinsics, while K/D stay frozen.
        for row in test:
            ok, rvec, tvec = cv2.solvePnP(
                obj, row.corners, matrix, distortion, flags=cv2.SOLVEPNP_ITERATIVE
            )
            if not ok:
                errors.append(math.inf)
                continue
            projected, _ = cv2.projectPoints(obj, rvec, tvec, matrix, distortion)
            delta = projected.reshape(-1, 2) - row.corners.reshape(-1, 2)
            errors.append(float(np.sqrt(np.mean(np.sum(delta * delta, axis=1)))))
        pooled.extend(errors)
        fold_rows.append({
            "fold": fold,
            "training_views": len(train),
            "held_out_files": [r.filename for r in test],
            "held_out_rms_px": errors,
        })
    finite = np.asarray([v for v in pooled if math.isfinite(v)], dtype=np.float64)
    pooled_rms = float(np.sqrt(np.mean(finite * finite))) if finite.size else math.inf
    return {
        "folds": fold_rows,
        "views": len(pooled),
        "pooled_rms_px": pooled_rms,
        "median_view_rms_px": float(np.median(finite)) if finite.size else math.inf,
        "max_view_rms_px": float(np.max(finite)) if finite.size else math.inf,
    }


def _save_preview(
    source_path: Path,
    destination: Path,
    matrix: np.ndarray,
    distortion: np.ndarray,
    output_cx: float,
    output_cy: float,
) -> None:
    image = _read_image(source_path, cv2.IMREAD_COLOR)
    if image is None:
        return
    output_matrix = np.array(
        [[matrix[0, 0], 0.0, output_cx], [0.0, matrix[1, 1], output_cy], [0.0, 0.0, 1.0]]
    )
    map_x, map_y = cv2.initUndistortRectifyMap(
        matrix, distortion, None, output_matrix, (1920, 1080), cv2.CV_32FC1
    )
    corrected = cv2.remap(image, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    cv2.imencode(".png", corrected)[1].tofile(destination)


def run_calibration(
    image_folder: str | Path | list[str | Path],
    output_directory: str | Path,
    settings: CalibrationSettings,
    sequence: int = 1,
    progress: ProgressCallback | None = None,
) -> CalibrationRun:
    settings.validate()
    if isinstance(image_folder, (str, Path)):
        images = discover_images(image_folder)
        source_directory = str(Path(image_folder).resolve())
    else:
        images = sorted({
            Path(p).resolve() for p in image_folder
            if Path(p).is_file() and Path(p).suffix.lower() in IMAGE_SUFFIXES
        })
        source_directory = "multiple selected files"
    if not images:
        raise ValueError("目录中没有支持的图片")
    output = Path(output_directory)
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"输出目录必须为空：{output}")
    output.mkdir(parents=True, exist_ok=True)

    assessments, thresholds = assess_images(images, settings, progress)
    accepted = [r for r in assessments if r.accepted]
    gate_errors: list[str] = []
    if len(accepted) < settings.minimum_views:
        gate_errors.append(
            f"有效图片仅{len(accepted)}张，至少需要{settings.minimum_views}张"
        )
    if gate_errors:
        report = {
            "passed": False,
            "settings": asdict(settings),
            "quality_thresholds": thresholds,
            "gate_errors": gate_errors,
            "images": [r.serializable() for r in assessments],
        }
        (output / "calibration_report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return CalibrationRun(output, False, report, b"")

    (best_seed, fit), all_fits = _fit([r.corners for r in accepted], settings)
    rms, matrix, distortion, _, _ = fit
    per_view = _per_view_errors([r.corners for r in accepted], settings, fit)
    for row, error in zip(accepted, per_view):
        row.metrics["reprojection_rms_px"] = error
    coverage = _coverage(accepted, settings)
    cross_validation = _cross_validate(accepted, settings)
    float_cal = FloatCalibration(
        float(matrix[0, 0]), float(matrix[1, 1]), float(matrix[0, 2]), float(matrix[1, 2]),
        float(distortion.ravel()[0]), float(distortion.ravel()[1]),
        float(distortion.ravel()[2]), float(distortion.ravel()[3]),
    )
    output_geometry, fixed, hardware = build_and_validate(float_cal)
    packet = CalibrationPacket(sequence, fixed).pack()

    if float(rms) > settings.maximum_rms_px:
        gate_errors.append(f"标定RMS {rms:.4f}px 超过 {settings.maximum_rms_px:.4f}px")
    if cross_validation["pooled_rms_px"] > settings.maximum_cv_rms_px:
        gate_errors.append(
            f"五折验证RMS {cross_validation['pooled_rms_px']:.4f}px 超过 "
            f"{settings.maximum_cv_rms_px:.4f}px"
        )
    if coverage["hull_area_fraction"] < settings.minimum_coverage_fraction:
        gate_errors.append("棋盘格角点覆盖范围不足")
    if coverage["occupied_grid_cells"] < settings.minimum_grid_cells:
        gate_errors.append("棋盘格没有充分覆盖画面各区域")
    gate_errors.extend(hardware.errors)

    report = {
        "passed": not gate_errors,
        "settings": asdict(settings),
        "source_directory": source_directory,
        "total_images": len(images),
        "accepted_images": len(accepted),
        "rejected_images": len(images) - len(accepted),
        "quality_thresholds": thresholds,
        "gate_errors": gate_errors,
        "gate_warnings": list(hardware.warnings),
        "rms_px": float(rms),
        "median_view_rms_px": float(np.median(per_view)),
        "max_view_rms_px": float(np.max(per_view)),
        "K": matrix.tolist(),
        "distortion_order": ["k1", "k2", "p1", "p2", "k3"],
        "distortion": distortion.ravel().tolist(),
        "coverage": coverage,
        "cross_validation": cross_validation,
        "multi_start": [
            {"initial_focal": seed, "rms_px": float(candidate[0])}
            for seed, candidate in all_fits
        ],
        "selected_initial_focal": best_seed,
        "output1080": asdict(output_geometry),
        "fixed": asdict(fixed),
        "hardware_validation": asdict(hardware),
        "packet_sequence": sequence,
        "packet_length": len(packet),
        "packet_sha256": hashlib.sha256(packet).hexdigest(),
        "images": [r.serializable() for r in assessments],
    }
    (output / "calibration_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (output / "fpga_coefficients_v13.bin").write_bytes(packet)
    with (output / "image_decisions.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=("filename", "accepted", "reasons", "warnings", "sha256"),
        )
        writer.writeheader()
        for row in assessments:
            writer.writerow({
                "filename": row.filename,
                "accepted": row.accepted,
                "reasons": "；".join(row.reasons),
                "warnings": "；".join(row.warnings),
                "sha256": row.sha256,
            })
    preview = output / "previews"
    preview.mkdir(exist_ok=True)
    for row in accepted[:6]:
        _save_preview(
            Path(row.path), preview / f"{Path(row.filename).stem}_corrected.png",
            matrix, distortion, output_geometry.cx, output_geometry.cy,
        )
    return CalibrationRun(output, not gate_errors, report, packet)
