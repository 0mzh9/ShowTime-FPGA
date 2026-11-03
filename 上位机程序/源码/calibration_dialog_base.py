"""ShowTime V15 shared chessboard calibration page and coefficient review."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QThread, Qt, Signal
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import (
    QDoubleSpinBox, QFileDialog, QGridLayout, QHBoxLayout, QLabel,
    QListWidget, QListWidgetItem, QMessageBox, QPushButton, QSpinBox,
    QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from calibration_engine_base import (
    CalibrationRun, CalibrationSettings, discover_images, run_calibration,
)


class ImageList(QListWidget):
    paths_dropped = Signal(object)

    def __init__(self):
        super().__init__()
        self.setAcceptDrops(True)
        self.setToolTip("拖入原始棋盘照片或包含 original_left.png 的采集目录")

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            super().dragEnterEvent(event)

    def dragMoveEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            super().dragMoveEvent(event)

    def dropEvent(self, event):
        paths = [Path(url.toLocalFile()) for url in event.mimeData().urls()
                 if url.isLocalFile()]
        self.paths_dropped.emit(paths)
        event.acceptProposedAction()


class CalibrationWorker(QThread):
    progress = Signal(int, int, str)
    succeeded = Signal(object)
    failed = Signal(str)

    def __init__(self, paths: list[Path], output: Path, settings: CalibrationSettings):
        super().__init__()
        self.paths, self.output, self.settings = paths, output, settings

    def run(self):
        try:
            result = run_calibration(
                self.paths, self.output, self.settings,
                progress=lambda done, total, name: self.progress.emit(done, total, name),
            )
        except Exception as exc:
            self.failed.emit(f"标定失败：{exc}")
        else:
            self.succeeded.emit(result)


class CalibrationDialog(QWidget):
    upload_requested = Signal(object)
    worker_class = CalibrationWorker

    def __init__(self, output_root: Path, parent: QWidget | None = None):
        super().__init__(parent)
        self.output_root = output_root
        self.output_root.mkdir(parents=True, exist_ok=True)
        self.run_result: CalibrationRun | None = None
        self.worker: CalibrationWorker | None = None
        self.paths: list[Path] = []
        self._ui()

    def _ui(self):
        main = QVBoxLayout(self)
        heading = QLabel("棋盘格自动标定")
        heading.setStyleSheet("font-size:20px;font-weight:600;color:#000000")
        main.addWidget(heading)
        hint = QLabel(
            "仅使用 1280×720 原图。拖入图片或采集目录；目录中存在 original_left.png 时只读取这些原图。"
            "内角点数指交点数，不是方格数。原文件不会被改动。"
            "生成系数期间仅隐藏上位机预览；点击输入系数后，FPGA 才暂停图像并写入 EEPROM。"
        )
        hint.setWordWrap(True)
        main.addWidget(hint)
        controls = QHBoxLayout()
        add_files = QPushButton("添加图片")
        add_folder = QPushButton("添加目录")
        remove = QPushButton("移除选中")
        clear = QPushButton("清空列表")
        add_files.clicked.connect(self._select_files)
        add_folder.clicked.connect(self._select_folder)
        remove.clicked.connect(self._remove_selected)
        clear.clicked.connect(self._clear)
        for button in (add_files, add_folder, remove, clear):
            controls.addWidget(button)
        controls.addStretch()
        main.addLayout(controls)
        self.images = ImageList()
        self.images.paths_dropped.connect(self.add_paths)
        self.images.setMinimumHeight(125)
        main.addWidget(self.images, 1)

        settings = QHBoxLayout()
        self.cols = QSpinBox();self.cols.setRange(3, 30);self.cols.setValue(11)
        self.rows = QSpinBox();self.rows.setRange(3, 30);self.rows.setValue(8)
        self.square = QDoubleSpinBox()
        self.square.setRange(0.01, 10000.0);self.square.setDecimals(3)
        self.square.setValue(15.0);self.square.setSuffix(" mm")
        for title, widget in (
            ("内角点列数", self.cols), ("内角点行数", self.rows),
            ("方格边长", self.square),
        ):
            settings.addWidget(QLabel(title));settings.addWidget(widget)
        settings.addStretch()
        main.addLayout(settings)

        actions = QHBoxLayout()
        self.run_button = QPushButton("检测并生成系数")
        self.run_button.clicked.connect(self.start_calibration)
        self.upload_button = QPushButton("输入矫正系数到 FPGA")
        self.upload_button.setEnabled(False)
        self.upload_button.clicked.connect(self._request_upload)
        actions.addWidget(self.run_button);actions.addWidget(self.upload_button)
        actions.addStretch()
        main.addLayout(actions)
        self.status = QLabel("等待导入棋盘格原图")
        self.status.setWordWrap(True)
        main.addWidget(self.status)

        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(("图片", "结果", "原因", "重投影 RMS"))
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.table.itemSelectionChanged.connect(self._preview_selection)
        main.addWidget(self.table, 2)
        preview_row = QHBoxLayout()
        self.original_preview = QLabel("原图预览")
        self.corrected_preview = QLabel("矫正预览")
        for panel in (self.original_preview, self.corrected_preview):
            panel.setAlignment(Qt.AlignmentFlag.AlignCenter)
            panel.setMinimumHeight(150)
            panel.setStyleSheet("background:#ffffff;color:#000000;border:1px solid #d0d0d0")
            preview_row.addWidget(panel, 1)
        main.addLayout(preview_row, 1)

    def _select_files(self):
        files, _ = QFileDialog.getOpenFileNames(
            self, "选择原始棋盘格图片", "",
            "图片 (*.png *.jpg *.jpeg *.bmp *.tif *.tiff)",
        )
        self.add_paths([Path(name) for name in files])

    def _select_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "选择原始棋盘格目录")
        if folder:
            self.add_paths([Path(folder)])

    def add_paths(self, selected):
        current = set(self.paths)
        for item in selected:
            path = Path(item)
            try:
                candidates = discover_images(path) if path.is_dir() else [path]
            except ValueError:
                continue
            for candidate in candidates:
                candidate = candidate.resolve()
                if candidate.is_file() and candidate.suffix.lower() in {
                    ".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff"
                } and candidate not in current:
                    self.paths.append(candidate)
                    self.images.addItem(str(candidate))
                    current.add(candidate)
        self.status.setText(f"已导入 {len(self.paths)} 张候选原图")
        self.run_result = None
        self.upload_button.setEnabled(False)

    def _remove_selected(self):
        for item in self.images.selectedItems():
            self.paths.remove(Path(item.text()))
            self.images.takeItem(self.images.row(item))
        self.upload_button.setEnabled(False)
        self.run_result = None
        self.status.setText(f"已导入 {len(self.paths)} 张候选原图")

    def _clear(self):
        self.images.clear()
        self.paths.clear()
        self.run_result = None
        self.upload_button.setEnabled(False)
        self.table.setRowCount(0)
        self.status.setText("等待导入棋盘格原图")

    def start_calibration(self):
        if self.worker and self.worker.isRunning():
            return
        if len(self.paths) < 10:
            QMessageBox.warning(self, "图片不足", "请导入至少 10 张原始棋盘格图片。")
            return
        settings = CalibrationSettings(
            inner_cols=self.cols.value(),
            inner_rows=self.rows.value(),
            square_size_mm=self.square.value(),
        )
        output = self.output_root / datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        self.run_result = None
        self.run_button.setEnabled(False)
        self.upload_button.setEnabled(False)
        self.status.setText("正在检测棋盘格和评估图片质量…")
        self.worker = self.worker_class(list(self.paths), output, settings)
        self.worker.progress.connect(
            lambda done, total, name:
            self.status.setText(f"检测图片 {done + 1}/{total}：{name}")
        )
        self.worker.succeeded.connect(self._calibration_finished)
        self.worker.failed.connect(self._calibration_failed)
        self.worker.start()

    def _calibration_finished(self, run: CalibrationRun):
        self.run_button.setEnabled(True)
        self.run_result = run
        report = run.report
        rows = report.get("images", [])
        self.table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            cells = (
                row["filename"],
                "保留" if row["accepted"] else "剔除",
                "；".join(row.get("reasons", [])),
                f"{row.get('metrics', {}).get('reprojection_rms_px', 0):.4f}"
                if row["accepted"] else "—",
            )
            for column, value in enumerate(cells):
                cell = QTableWidgetItem(value)
                if column == 0:
                    cell.setData(Qt.ItemDataRole.UserRole, row["path"])
                self.table.setItem(index, column, cell)
        if run.passed:
            self.status.setText(
                f"通过：{report['accepted_images']}/{report['total_images']} 张；"
                f"RMS {report['rms_px']:.4f} px；五折验证 "
                f"{report['cross_validation']['pooled_rms_px']:.4f} px。结果：{run.output_directory}"
            )
            self.upload_button.setEnabled(True)
        else:
            self.status.setText(
                "未通过质量门，不允许发送 FPGA：" +
                "；".join(report.get("gate_errors", ["有效图片不足"]))
            )

    def _calibration_failed(self, message: str):
        self.run_button.setEnabled(True)
        self.status.setText(message)

    def _preview_selection(self):
        row = self.table.currentRow()
        if row < 0:
            return
        item = self.table.item(row, 0)
        if item is None:
            return
        source = Path(item.data(Qt.ItemDataRole.UserRole))
        self._set_preview(self.original_preview, source, "原图预览")
        corrected = None
        if self.run_result:
            candidate = self.run_result.output_directory / "previews" / f"{source.stem}_corrected.png"
            if candidate.exists():
                corrected = candidate
        self._set_preview(self.corrected_preview, corrected, "矫正预览仅为前 6 张保留图片生成")

    @staticmethod
    def _set_preview(widget: QLabel, path: Path | None, empty: str):
        if path is None:
            widget.setPixmap(QPixmap())
            widget.setText(empty)
            return
        pixmap = QPixmap(str(path))
        if pixmap.isNull():
            widget.setText("图片无法预览")
            return
        widget.setText("")
        widget.setPixmap(pixmap.scaled(
            470, 180, Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation,
        ))

    def _request_upload(self):
        if self.run_result and self.run_result.passed and self.run_result.packet:
            self.upload_requested.emit(self.run_result)

    def set_upload_status(self, message: str, finished: bool = False):
        self.status.setText(message)
        self.upload_button.setEnabled(
            finished and bool(self.run_result and self.run_result.passed)
        )

    def closeEvent(self, event):
        if self.worker and self.worker.isRunning():
            event.ignore()
            self.status.setText("标定计算正在运行，请等待完成后关闭上位机")
            return
        super().closeEvent(event)
