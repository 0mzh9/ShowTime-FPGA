"""Decode the read-only 5A00..07 V15 shared UART diagnostic snapshot."""


def decode_live_status(word):
    return {
        "signature": (word >> 12) & 15,
        "video_state": (word >> 8) & 15,
        "ddr_ready": bool(word & (1 << 7)),
        "camera_ready": bool(word & (1 << 6)),
        "pipeline_fault": bool(word & (1 << 5)),
        "frame_ready": bool(word & (1 << 4)),
        "video_configured": bool(word & (1 << 3)),
        "clock_ready": bool(word & (1 << 2)),
        "pipe_enable": bool(word & (1 << 1)),
        "quiesce": bool(word & 1),
    }


def decode_camera_status(words):
    if len(words) != 6:
        raise ValueError("camera diagnostic requires six words")
    value = sum(word << (16 * index) for index, word in enumerate(words))
    field = lambda lo, width: (value >> lo) & ((1 << width) - 1)
    return {
        "sensor_id": field(0, 16),
        "register": field(16, 16),
        "error_code": field(58, 4),
        "state": field(62, 3),
        "nack_stage": field(69, 4),
        "done": bool(field(73, 1)),
        "error": bool(field(74, 1)),
    }


def health_message(status, camera=None):
    if status["signature"] != 9:
        return "板卡诊断版本不匹配；请下载 V13 位流"
    if status["video_state"] != 2:
        return "FPGA 未进入已停止状态；请检查控制链路"
    if not status["ddr_ready"]:
        return "FPGA DDR 尚未初始化完成"
    if status["pipeline_fault"]:
        return "FPGA 图像处理通路报告故障"
    if not status["clock_ready"]:
        return "FPGA HDMI 视频时钟尚未就绪"
    if not status["video_configured"]:
        return "FPGA HDMI 配置尚未完成"
    if not status["camera_ready"]:
        if camera and camera["error"]:
            detail = (f"摄像头 I²C 初始化失败：芯片 ID 0x{camera['sensor_id']:04X}，"
                      f"寄存器 0x{camera['register']:04X}，错误码 {camera['error_code']}，"
                      f"NACK 阶段 {camera['nack_stage']}")
            return detail
        return "摄像头尚未初始化完成；请检查摄像头连接和供电"
    return None
