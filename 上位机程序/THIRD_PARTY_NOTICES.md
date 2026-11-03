# Third-party components

The Windows single-file executable extracts and dynamically loads its bundled
libraries at startup. Keep the license notices and supplied source/build recipe
when redistributing the package. An optional folder build requires its entire
`_internal` directory.

| Component | Packaged version | Upstream |
|---|---|---|
| CPython | 3.13.12 | https://www.python.org/downloads/source/ |
| Qt / PySide6 / Shiboken6 | 6.11.2 | https://code.qt.io/cgit/pyside/pyside-setup.git/ ; https://download.qt.io/archive/qt/6.11/6.11.2/ |
| NumPy | 2.5.2 | https://github.com/numpy/numpy |
| OpenCV headless | 4.13.0.92 | https://github.com/opencv/opencv ; https://github.com/opencv/opencv-python |
| PyInstaller bootloader | 6.22.2 | https://github.com/pyinstaller/pyinstaller |

The locally installed PySide package metadata declares
`LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only`.
The package-provided license notices, GNU LGPLv3/GPLv3 texts and NumPy/Python
notices are included in `licenses`. No changes were made to these libraries.
The application source and build recipe are included in the `源码` directory
in this ShowTime V15 package.
Dynamic library replacement is not restricted by this application.

Qt's FFmpeg multimedia backend and image format plugins include further
third-party components. Their upstream source and notices are available in
the corresponding Qt source package (including `qtwebengine` only if used;
this application does not use it). Unused Qt PDF and virtual keyboard
plugins are excluded from this distribution.

The program does not ship device drivers. USB-UART and capture-device drivers
remain the responsibility of the respective device vendor.
