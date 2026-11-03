"""UART calibration upload state machine; independent of Qt and capture UI."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from typing import Callable
import time

from calibration_protocol import CalibrationPacket


class UploadState(Enum):
    IDLE = auto()
    QUERY_READY = auto()
    QUERY_LOW = auto()
    QUERY_HIGH = auto()
    WAIT_READY = auto()
    WAIT_COMMIT = auto()
    COMPLETE = auto()
    ERROR = auto()


ERROR_TEXT = {
    0xE001: "包格式错误",
    0xE002: "CRC 校验失败",
    0xE003: "系数超出硬件范围",
    0xE004: "EEPROM 写入失败",
    0xE005: "EEPROM 读回校验失败",
    0xE006: "协议版本不支持",
    0xE007: "FPGA 当前状态不允许更新",
    0xE008: "FPGA 接收数据超时",
}


@dataclass(frozen=True)
class UploadResult:
    success: bool
    message: str
    sequence: int | None
    packet: bytes
    uncertain: bool = False


class CalibrationUpload:
    """Query latest sequence, then 0A0A -> 0AA0 -> packet -> DCDC.

    The caller must exclusively own the serial receive stream while busy.
    On a timeout after 0A0A the board state is unknown and the UI must not
    issue more video commands until the board's status has been reconciled.
    """

    def __init__(
        self,
        send: Callable[[bytes], None],
        status: Callable[[str], None],
        complete: Callable[[UploadResult], None],
        clock: Callable[[], float] = time.monotonic,
    ):
        self.send = send
        self.status = status
        self.complete = complete
        self.clock = clock
        self.state = UploadState.IDLE
        self.deadline = 0.0
        self.buffer = bytearray()
        self.source_packet = b""
        self.packet = b""
        self.sequence: int | None = None
        self.low_sequence = 0
        self.uncertain = False

    @property
    def busy(self) -> bool:
        return self.state in {
            UploadState.QUERY_READY,
            UploadState.QUERY_LOW,
            UploadState.QUERY_HIGH,
            UploadState.WAIT_READY,
            UploadState.WAIT_COMMIT,
        }

    def start(self, source_packet: bytes) -> None:
        if self.busy or self.uncertain:
            raise RuntimeError("存在未完成或状态未确认的系数更新")
        CalibrationPacket.unpack(source_packet)
        self.source_packet = source_packet
        self.packet = b""
        self.sequence = None
        self.buffer.clear()
        self.state = UploadState.QUERY_READY
        self.deadline = self.clock() + 3.0
        self.status("确认 FPGA 已载入 EEPROM 系数…")
        self._send(b"\x0b\x02")

    def _send(self, data: bytes) -> None:
        try:
            self.send(data)
        except Exception as exc:
            self._finish(False, f"串口发送失败：{exc}", uncertain=self.state in {
                UploadState.WAIT_READY, UploadState.WAIT_COMMIT
            })

    def receive(self, data: bytes) -> None:
        if not self.busy:
            return
        self.buffer.extend(data)
        while len(self.buffer) >= 2 and self.busy:
            word = int.from_bytes(self.buffer[:2], "big")
            del self.buffer[:2]
            if self.state == UploadState.QUERY_READY:
                if word != 0x0B02:
                    self._finish(False, ERROR_TEXT.get(word, "FPGA 启动状态应答无效"))
                    continue
                self.state = UploadState.QUERY_LOW
                self.deadline = self.clock() + 3.0
                self.status("读取 FPGA 中现有系数序号…")
                self._send(b"\x0b\x00")
            elif self.state == UploadState.QUERY_LOW:
                self.low_sequence = word
                self.state = UploadState.QUERY_HIGH
                self.deadline = self.clock() + 3.0
                self._send(b"\x0b\x01")
            elif self.state == UploadState.QUERY_HIGH:
                current = (word << 16) | self.low_sequence
                self.sequence = (current + 1) & 0xFFFFFFFF
                calibration = CalibrationPacket.unpack(self.source_packet).calibration
                self.packet = CalibrationPacket(self.sequence, calibration).pack()
                self.state = UploadState.WAIT_READY
                self.deadline = self.clock() + 10.0
                self.status("等待 FPGA 停止图像处理并准备写入…")
                self._send(b"\x0a\x0a")
            elif self.state == UploadState.WAIT_READY:
                if word == 0x0AA0:
                    self.state = UploadState.WAIT_COMMIT
                    self.deadline = self.clock() + 120.0
                    self.status("写入 EEPROM、读回校验并恢复图像…")
                    self._send(self.packet)
                elif word in ERROR_TEXT:
                    self._finish(False, ERROR_TEXT[word])
                else:
                    # A stale reply must not be accepted as PREPARE.
                    self.buffer[:0] = bytes((word & 0xFF,))
            elif self.state == UploadState.WAIT_COMMIT:
                if word == 0xDCDC:
                    self._finish(True, "新系数已保存到 EEPROM 并恢复图像")
                elif word in ERROR_TEXT:
                    self._finish(False, ERROR_TEXT[word])
                else:
                    self.buffer[:0] = bytes((word & 0xFF,))

    def poll(self) -> None:
        if self.busy and self.clock() >= self.deadline:
            uncertain = self.state in {UploadState.WAIT_READY, UploadState.WAIT_COMMIT}
            self._finish(False, "等待 FPGA 应答超时", uncertain=uncertain)

    def abort_transport(self, message: str) -> None:
        if self.busy:
            self._finish(
                False, message,
                uncertain=self.state in {UploadState.WAIT_READY, UploadState.WAIT_COMMIT},
            )

    def reconcile_after_board_handshake(self) -> bool:
        """Clear an uncertain host transaction after a fresh stopped-board handshake.

        The caller must have confirmed 0B02, 6868 and healthy V13 diagnostics.
        The previous write result remains unknown; the next upload will query
        the active EEPROM sequence before constructing a new packet.
        """
        if self.busy:
            raise RuntimeError("cannot reconcile while an upload is active")
        was_uncertain = self.uncertain
        self.uncertain = False
        if was_uncertain:
            self.state = UploadState.IDLE
        return was_uncertain

    def _finish(self, success: bool, message: str, uncertain: bool = False) -> None:
        self.uncertain = uncertain
        self.state = UploadState.COMPLETE if success else UploadState.ERROR
        self.buffer.clear()
        self.status(message)
        self.complete(UploadResult(success, message, self.sequence, self.packet, uncertain))
