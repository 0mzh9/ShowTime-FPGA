"""Capture capability checks, independent of enumeration order and brand."""
from session_control import SIZES


def device_id(device):
    return bytes(device.id()).hex()


def is_integrated(device):
    name = device.description().lower()
    return any(word in name for word in ('integrated', 'built-in', 'builtin', '内置'))


def compatible_formats(device, mode):
    target = SIZES[mode]
    # QCamera uses the advertised format's rate; a 120fps-only entry is not 60fps.
    return [f for f in device.videoFormats()
            if (f.resolution().width(), f.resolution().height()) == target
            and 59 <= f.maxFrameRate() <= 61]


def format_priority(fmt):
    # V12 first asks for an uncompressed packed RGB stream when the capture
    # card and Qt backend expose one. NV12 remains the practical uncompressed
    # fallback; MJPEG is last because it is lossy and some cards emit damaged
    # packets. The viewer never applies denoise, sharpening, Gamma or colour
    # enhancement to the decoded frame.
    priority = {
        'Format_RGBX8888': 0, 'Format_RGBA8888': 0,
        'Format_XRGB8888': 0, 'Format_ARGB8888': 0,
        'Format_BGRX8888': 0, 'Format_BGRA8888': 0,
        'Format_XBGR8888': 0, 'Format_ABGR8888': 0,
        'Format_YUYV': 1, 'Format_UYVY': 1,
        'Format_NV12': 2, 'Format_NV21': 2,
        'Format_Jpeg': 3,
    }
    # Pixel fidelity is the first criterion. A 59.94 Hz packed-RGB mode must
    # not lose to a nominal 60.00 Hz NV12/MJPEG mode.
    return (priority.get(fmt.pixelFormat().name, 4), abs(fmt.maxFrameRate()-60))


def choose_device(devices, previous=None):
    if previous:
        # Never silently substitute another device after the selected one vanishes.
        return next((device_id(d) for d in devices if device_id(d) == previous), None)
    candidates = [d for d in devices if not is_integrated(d)
                  and any(compatible_formats(d, mode) for mode in SIZES)]
    if len(candidates) == 1:
        return device_id(candidates[0])
    # Ambiguous sources need an explicit selection; no fallback to index zero.
    return None


def device_label(device):
    modes = [f'{mode}P60' for mode in SIZES if compatible_formats(device, mode)]
    hint = '内置摄像头；' if is_integrated(device) else ''
    return device.description() + ' · ' + hint + (' / '.join(modes) if modes else '未列出所需60fps格式')


def resolve_format(devices, selected_id, mode):
    device = next((d for d in devices if device_id(d) == selected_id), None)
    if device is None:
        raise RuntimeError('未选择有效采集卡，或所选设备已断开；请连接 HDMI USB 采集卡并刷新设备')
    formats = compatible_formats(device, mode)
    if not formats:
        width, height = SIZES[mode]
        rates = [f.maxFrameRate() for f in device.videoFormats()
                 if (f.resolution().width(), f.resolution().height()) == (width, height)]
        available = f'该尺寸最高列出 {max(rates):g} fps' if rates else '未列出该尺寸'
        alternatives = [d.description() for d in devices if not is_integrated(d)
                        and compatible_formats(d, mode)]
        suggestion = ('；请在采集设备中选择：' + '、'.join(alternatives)) if alternatives else '；请检查 HDMI USB 采集卡连接和格式支持'
        raise RuntimeError(f'所选“{device.description()}”不提供 {width}×{height} 60fps（{available}）{suggestion}')
    fmt = min(formats, key=format_priority)
    return device, fmt
