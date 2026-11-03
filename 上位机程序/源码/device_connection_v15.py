"""Explicit V15 board handshake for the viewer's connection gate."""

from __future__ import annotations

from enum import Enum, auto
import time
import binascii
from calibration_protocol import FixedCalibration

from board_status import decode_live_status, decode_camera_status, health_message


def preferred_board_port(ports, saved=None):
    """Prefer a remembered USB UART; never silently default to Bluetooth."""
    eligible = [port for port in ports if "bluetooth" not in port.description().lower()
                and "蓝牙" not in port.description()]
    remembered = next((port for port in eligible if port.portName() == saved), None)
    if remembered:
        return remembered.portName()
    cp210x = next((port for port in eligible if "cp210" in port.description().lower()), None)
    if cp210x:
        return cp210x.portName()
    return eligible[0].portName() if len(eligible) == 1 else None


class ConnectionState(Enum):
    DISCONNECTED = auto()
    WAIT_BOARD = auto()
    WAIT_CAPABILITY = auto()
    WAIT_PARAMETERS = auto()
    WAIT_PARAMETER_CRC = auto()
    WAIT_STOP = auto()
    WAIT_STATUS_MARKER = auto()
    WAIT_STATUS_WORD = auto()
    WAIT_CAMERA_WORD = auto()
    READY = auto()


class DeviceConnection:
    QUERY = b"\x0b\x02"
    STOP = b"\x68\x68"
    STATUS = b"\x5a\x00"
    NOT_READY = b"\xe0\x07"

    def __init__(self, clock=time.monotonic, timeout=5.0, stop_timeout=15.0):
        self.clock = clock
        self.timeout = timeout
        self.stop_timeout = stop_timeout
        self.invalidate("请选择板卡串口和 HDMI USB 采集卡，然后点击连接设备")

    @property
    def ready(self):
        return self.state is ConnectionState.READY

    @property
    def pending(self):
        return self.state in (ConnectionState.WAIT_BOARD, ConnectionState.WAIT_STOP,
                              ConnectionState.WAIT_CAPABILITY,ConnectionState.WAIT_PARAMETERS,ConnectionState.WAIT_PARAMETER_CRC,
                              ConnectionState.WAIT_STATUS_MARKER, ConnectionState.WAIT_STATUS_WORD,
                              ConnectionState.WAIT_CAMERA_WORD)

    def invalidate(self, message):
        self.state = ConnectionState.DISCONNECTED
        self.port = None
        self.device = None
        self.modes = frozenset()
        self.deadline = 0.0
        self.buffer = bytearray()
        self.send = None
        self.status = None
        self.camera_words = []
        self.parameters=bytearray()
        self.calibration=None
        self.message = message

    def begin(self, port, device, modes, send):
        if not port or not device or not modes:
            raise ValueError("必须选中板卡串口和支持至少一种目标格式的采集卡")
        self.invalidate("等待 FPGA 回传 0B 02…")
        self.port = port
        self.device = device
        self.modes = frozenset(modes)
        self.state = ConnectionState.WAIT_BOARD
        self.deadline = self.clock() + self.timeout
        self.send = send
        try:
            send(self.QUERY)
        except Exception:
            self.invalidate("板卡串口发送失败，设备未连接")
            raise

    def receive(self, data):
        """Return true only when the pending connection changes state."""
        if not self.pending:
            return False
        self.buffer.extend(data)
        while len(self.buffer) >= 2:
            pair = bytes(self.buffer[:2])
            if pair == self.NOT_READY and self.state not in (ConnectionState.WAIT_PARAMETERS,ConnectionState.WAIT_PARAMETER_CRC):
                self.invalidate("FPGA 尚未完成 EEPROM 启动读取" if self.state is ConnectionState.WAIT_BOARD
                                else "FPGA 拒绝停止旧会话；请检查板卡状态")
                return True
            if self.state is ConnectionState.WAIT_BOARD and pair == self.QUERY:
                self.buffer.clear()
                self.state=ConnectionState.WAIT_CAPABILITY
                self.deadline=self.clock()+self.timeout
                self.message='正在核对 V15 转向协议…'
                self._send(b'\x0c\x00')
                return True
            if self.state is ConnectionState.WAIT_CAPABILITY and pair == b'\x15\xc0':
                self.buffer.clear()
                self.state = ConnectionState.WAIT_STOP
                self.deadline = self.clock() + self.stop_timeout
                self.message = "V15 板卡已应答，正在确认停止旧会话…"
                try:
                    self.send(self.STOP)
                except Exception:
                    self.invalidate("发送停止旧会话指令失败，设备未连接")
                return True
            if self.state is ConnectionState.WAIT_STOP and pair == self.STOP:
                self.buffer.clear()
                self.state = ConnectionState.WAIT_STATUS_MARKER
                self.deadline = self.clock() + self.timeout
                self.message = "已停止旧会话，正在核对 FPGA 的摄像头与 DDR 状态…"
                self._send(self.STATUS)
                return True
            if self.state is ConnectionState.WAIT_STATUS_MARKER and pair == b"\x9d\x09":
                self.buffer.clear()
                self.state = ConnectionState.WAIT_STATUS_WORD
                self.deadline = self.clock() + self.timeout
                self._send(b"\x5a\x01")
                return True
            if self.state is ConnectionState.WAIT_STATUS_WORD:
                self.buffer.clear()
                self.status = decode_live_status(int.from_bytes(pair, "big"))
                reason = health_message(self.status)
                if reason is None:
                    self.state=ConnectionState.WAIT_PARAMETERS
                    self.parameters.clear();self.deadline=self.clock()+self.timeout
                    self.message='正在读取 FPGA 当前 EEPROM 标定参数…'
                    self._send(b'\x0b\x10')
                elif not self.status["camera_ready"] and self.status["signature"] == 9:
                    self.state = ConnectionState.WAIT_CAMERA_WORD
                    self.deadline = self.clock() + self.timeout
                    self.message = "摄像头未就绪，正在读取 I²C 错误详情…"
                    self.camera_words = []
                    self._send(b"\x5a\x02")
                else:
                    self.invalidate(reason)
                return True
            if self.state is ConnectionState.WAIT_PARAMETERS:
                self.buffer.clear()
                self.parameters.extend(int.from_bytes(pair,'big').to_bytes(2,'little'))
                self.deadline=self.clock()+self.timeout
                if len(self.parameters)<80:self._send(bytes((0x0b,0x10+len(self.parameters)//2)))
                else:
                    self.state=ConnectionState.WAIT_PARAMETER_CRC;self._send(b'\x0b\x03')
                return True
            if self.state is ConnectionState.WAIT_PARAMETER_CRC:
                self.buffer.clear()
                try:
                    if binascii.crc_hqx(self.parameters,0xffff)!=int.from_bytes(pair,'big'):
                        raise ValueError('参数读回校验不一致')
                    self.calibration=FixedCalibration.from_payload(bytes(self.parameters))
                except ValueError as exc:self.invalidate('FPGA 参数读取失败：'+str(exc));return True
                self.state=ConnectionState.READY;self.send=None
                self.message='V15 协议、板卡状态及当前标定参数均已确认'
                return True
            if self.state is ConnectionState.WAIT_CAMERA_WORD:
                self.buffer.clear()
                self.camera_words.append(int.from_bytes(pair, "big"))
                if len(self.camera_words) < 6:
                    self.deadline = self.clock() + self.timeout
                    self._send(bytes((0x5A, 2 + len(self.camera_words))))
                else:
                    self.invalidate(health_message(self.status,
                                                   decode_camera_status(self.camera_words)))
                return True
            del self.buffer[0]
        return False

    def _send(self, command):
        try:
            self.send(command)
        except Exception:
            self.invalidate("板卡诊断命令发送失败，请重新连接设备")

    def poll(self):
        if self.pending and self.clock() >= self.deadline:
            message = ("板卡握手超时：未收到 V15 的 0B 02" if self.state is ConnectionState.WAIT_BOARD
                       else "V15 协议确认超时：未收到 15 C0，可能仍在运行旧版本位流" if self.state is ConnectionState.WAIT_CAPABILITY
                       else "板卡停止确认超时：未收到 68 68" if self.state is ConnectionState.WAIT_STOP
                       else "板卡状态诊断超时：未收到完整应答")
            self.invalidate(message+"；请检查位流、串口和连接")
            return True
        return False

    def matches(self, port, device, serial_open):
        return self.ready and serial_open and self.port == port and self.device == device
