"""Binary calibration protocol shared by ShowTime V15 shared and FPGA test models.

The wire format is intentionally fixed-width.  The FPGA never parses JSON or
floating point values; the host converts a validated calibration to these exact
integer fields before transmission.
"""

from __future__ import annotations

from dataclasses import dataclass
import struct
import zlib


MAGIC = b"CAL1"
TAIL = b"\r\n"
PROTOCOL_VERSION = 1
MODEL_PINHOLE_K1K2P1P2 = 1
PAYLOAD_LENGTH = 80
PACKET_LENGTH = 98

_HEADER = struct.Struct("<4sBBHI")
_PAYLOAD = struct.Struct("<I6H4i2q8i")
_TRAILER = struct.Struct("<I2s")


class CalibrationPacketError(ValueError):
    """The packet is malformed, corrupt, unsupported, or unsafe."""


@dataclass(frozen=True)
class FixedCalibration:
    flags: int
    input_width: int
    input_height: int
    canvas720_width: int
    canvas720_height: int
    canvas1080_width: int
    canvas1080_height: int
    fx_q12: int
    fy_q12: int
    cx_q12: int
    cy_q12: int
    inv_fx_q40: int
    inv_fy_q40: int
    k1_q30: int
    k2_q30: int
    p1_q30: int
    p2_q30: int
    out720_cx_q12: int
    out720_cy_q12: int
    out1080_cx_q12: int
    out1080_cy_q12: int

    @property
    def correction_enable(self) -> bool:
        return bool(self.flags & 1)

    def validation_errors(self) -> list[str]:
        errors: list[str] = []
        if self.flags & ~1:
            errors.append("flags contains unsupported bits")
        expected = (1280, 720, 1280, 720, 1920, 1080)
        actual = (
            self.input_width,
            self.input_height,
            self.canvas720_width,
            self.canvas720_height,
            self.canvas1080_width,
            self.canvas1080_height,
        )
        if actual != expected:
            errors.append(f"unsupported geometry {actual}, expected {expected}")

        # Broad protocol bounds.  The stricter full-frame hardware map test is
        # performed by the calibration pipeline before this object is packed.
        # The live mapper's focal registers are signed 24-bit Q12.
        if not (64 << 12 <= self.fx_q12 <= 2047 << 12):
            errors.append("fx_q12 outside supported range")
        if not (64 << 12 <= self.fy_q12 <= 2047 << 12):
            errors.append("fy_q12 outside supported range")
        if self.inv_fx_q40 <= 0 or self.inv_fy_q40 <= 0:
            errors.append("inverse focal lengths must be positive")
        for name, value in (
            ("cx_q12", self.cx_q12),
            ("cy_q12", self.cy_q12),
            ("out720_cx_q12", self.out720_cx_q12),
            ("out720_cy_q12", self.out720_cy_q12),
            ("out1080_cx_q12", self.out1080_cx_q12),
            ("out1080_cy_q12", self.out1080_cy_q12),
        ):
            if not (-4096 << 12 <= value <= 4096 << 12):
                errors.append(f"{name} outside supported range")
        for name, value, limit in (
            ("k1_q30", self.k1_q30, 2 << 30),
            ("k2_q30", self.k2_q30, 2 << 30),
            ("p1_q30", self.p1_q30, 1 << 29),
            ("p2_q30", self.p2_q30, 1 << 29),
        ):
            if not (-limit <= value <= limit):
                errors.append(f"{name} outside supported range")
        return errors

    def validate(self) -> None:
        errors = self.validation_errors()
        if errors:
            raise CalibrationPacketError("; ".join(errors))

    def payload_bytes(self) -> bytes:
        self.validate()
        payload = _PAYLOAD.pack(
            self.flags,
            self.input_width,
            self.input_height,
            self.canvas720_width,
            self.canvas720_height,
            self.canvas1080_width,
            self.canvas1080_height,
            self.fx_q12,
            self.fy_q12,
            self.cx_q12,
            self.cy_q12,
            self.inv_fx_q40,
            self.inv_fy_q40,
            self.k1_q30,
            self.k2_q30,
            self.p1_q30,
            self.p2_q30,
            self.out720_cx_q12,
            self.out720_cy_q12,
            self.out1080_cx_q12,
            self.out1080_cy_q12,
        )
        assert len(payload) == PAYLOAD_LENGTH
        return payload

    @classmethod
    def from_payload(cls, payload: bytes) -> "FixedCalibration":
        if len(payload) != PAYLOAD_LENGTH:
            raise CalibrationPacketError(
                f"payload length {len(payload)} != {PAYLOAD_LENGTH}"
            )
        value = cls(*_PAYLOAD.unpack(payload))
        value.validate()
        return value


@dataclass(frozen=True)
class CalibrationPacket:
    sequence: int
    calibration: FixedCalibration
    version: int = PROTOCOL_VERSION
    model_id: int = MODEL_PINHOLE_K1K2P1P2

    def pack(self) -> bytes:
        if not (0 <= self.sequence <= 0xFFFFFFFF):
            raise CalibrationPacketError("sequence must fit uint32")
        if self.version != PROTOCOL_VERSION:
            raise CalibrationPacketError("unsupported protocol version")
        if self.model_id != MODEL_PINHOLE_K1K2P1P2:
            raise CalibrationPacketError("unsupported camera model")
        payload = self.calibration.payload_bytes()
        header = _HEADER.pack(
            MAGIC, self.version, self.model_id, len(payload), self.sequence
        )
        crc_region = header[len(MAGIC) :] + payload
        crc = zlib.crc32(crc_region) & 0xFFFFFFFF
        packet = header + payload + _TRAILER.pack(crc, TAIL)
        assert len(packet) == PACKET_LENGTH
        return packet

    @classmethod
    def unpack(cls, packet: bytes) -> "CalibrationPacket":
        if len(packet) != PACKET_LENGTH:
            raise CalibrationPacketError(
                f"packet length {len(packet)} != {PACKET_LENGTH}"
            )
        magic, version, model_id, payload_len, sequence = _HEADER.unpack_from(packet)
        if magic != MAGIC:
            raise CalibrationPacketError("bad packet magic")
        if version != PROTOCOL_VERSION:
            raise CalibrationPacketError(f"unsupported protocol version {version}")
        if model_id != MODEL_PINHOLE_K1K2P1P2:
            raise CalibrationPacketError(f"unsupported model id {model_id}")
        if payload_len != PAYLOAD_LENGTH:
            raise CalibrationPacketError(f"unsupported payload length {payload_len}")
        payload_start = _HEADER.size
        payload_end = payload_start + payload_len
        payload = packet[payload_start:payload_end]
        received_crc, tail = _TRAILER.unpack_from(packet, payload_end)
        if tail != TAIL:
            raise CalibrationPacketError("bad packet tail")
        expected_crc = zlib.crc32(packet[len(MAGIC):payload_end]) & 0xFFFFFFFF
        if received_crc != expected_crc:
            raise CalibrationPacketError(
                f"CRC mismatch: received {received_crc:08x}, expected {expected_crc:08x}"
            )
        calibration = FixedCalibration.from_payload(payload)
        return cls(sequence, calibration, version, model_id)


def identity_factory_calibration() -> FixedCalibration:
    """Safe factory record: geometry is valid but correction is bypassed."""

    fx = 766.361276
    fy = 767.010614
    cx = 659.623611
    cy = 337.296325
    return FixedCalibration(
        flags=0,
        input_width=1280,
        input_height=720,
        canvas720_width=1280,
        canvas720_height=720,
        canvas1080_width=1920,
        canvas1080_height=1080,
        fx_q12=round(fx * (1 << 12)),
        fy_q12=round(fy * (1 << 12)),
        cx_q12=round(cx * (1 << 12)),
        cy_q12=round(cy * (1 << 12)),
        inv_fx_q40=round((1.0 / fx) * (1 << 40)),
        inv_fy_q40=round((1.0 / fy) * (1 << 40)),
        k1_q30=0,
        k2_q30=0,
        p1_q30=0,
        p2_q30=0,
        out720_cx_q12=round(cx * (1 << 12)),
        out720_cy_q12=round(cy * (1 << 12)),
        out1080_cx_q12=round((cx + 320.0) * (1 << 12)),
        out1080_cy_q12=round((cy + 180.0) * (1 << 12)),
    )
