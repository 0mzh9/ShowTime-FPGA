"""Decode the V15 shared four-row type marker (optional V15 shared compatibility) before resizing or painting a frame."""
from statistics import median
from PySide6.QtGui import QImage

RAW = "raw"
CORRECTED = "corrected"
TYPE_CODES = {0xA53C: RAW, 0xA5C3: CORRECTED}
MARKER_X, MARKER_Y = 0, 0
MARKER_HEIGHT = 4


def decode_type(image: QImage, legacy=False) -> str | None:
    return inspect_type(image,legacy=legacy)['kind']


def inspect_type(image: QImage, legacy=False) -> dict:
    """Use the same strict decoder, exposing why a marker was rejected."""
    result = {'kind': None, 'reason': None, 'bands': []}
    if image.isNull() or (image.width(), image.height()) not in ((1920, 1080),(1280,720)):
        result['reason'] = 'unsupported_size'
        return result
    # Convert only the small ROI, never the whole frame. RGB order is immaterial
    # here because the transmitted marker is monochrome.
    x = 896 if legacy and image.width()==1920 else 0
    height = 16 if legacy else MARKER_HEIGHT
    roi = image.copy(x, 0, 128, height).convertToFormat(QImage.Format.Format_RGB888)
    data = roi.constBits()
    stride = roi.bytesPerLine()
    codes = []
    result['roi'] = [x,0,128,height]
    for y0, y1 in (((3,7),(9,13)) if legacy else ((1,2),(2,3))):
        means = []
        for cell in range(16):
            total = 0
            for y in range(y0, y1):
                for x in range(cell*8+2, cell*8+6):
                    offset = y*stride+x*3
                    total += data[offset]+data[offset+1]+data[offset+2]
            means.append(total/(4*(y1-y0)*3))
        white = median(means[i] for i in (0, 2, 5, 7))
        black = median(means[i] for i in (1, 3, 4, 6))
        threshold = (white+black)/2
        band = {'rows': [y0, y1], 'means': means, 'white': white,
                'black': black, 'contrast': white-black, 'threshold': threshold,
                'min_margin': min(abs(value-threshold) for value in means)}
        result['bands'].append(band)
        if white-black < 96:
            result['reason'] = 'low_contrast'
            return result
        if any(abs(value-threshold) < 24 for value in means):
            result['reason'] = 'ambiguous_bit'
            return result
        code = 0
        for value in means:
            code = (code << 1) | int(value > threshold)
        band['code'] = f'{code:04X}'
        if code not in TYPE_CODES:
            result['reason'] = 'unknown_code'
            return result
        codes.append(code)
    if codes[0] != codes[1]:
        result['reason'] = 'band_mismatch'
    else:
        result['kind'] = TYPE_CODES[codes[0]]
    return result
