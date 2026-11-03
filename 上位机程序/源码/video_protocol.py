"""Image-bound V15 shared telemetry. Values describe the corrected frame of each pair."""
import numpy as np
from PySide6.QtGui import QImage

RAW='raw'
CORRECTED='corrected'


def crc8(data):
    c=0
    for byte in data:
        c^=byte
        for _ in range(8):
            c=((c<<1)^0x07)&255 if c&128 else (c<<1)&255
    return c


def _bits(image,x,y,n,magic,legacy=False):
    height=16 if legacy else 4
    roi=image.copy(x,y,n*8,height).convertToFormat(QImage.Format.Format_RGB888)
    if roi.width()!=n*8 or roi.height()!=height:return None
    data=np.frombuffer(roi.constBits(),np.uint8).reshape(height,roi.bytesPerLine())
    pixels=data[:,:n*24].reshape(height,n,8,3)
    expected=np.array([(magic>>(15-i))&1 for i in range(16)],dtype=bool)
    decoded=[]
    for y0,y1 in (((3,7),(9,13)) if legacy else ((1,2),(2,3))):
        means=pixels[y0:y1,:,2:6,:].mean(axis=(0,2,3))
        white=np.median(means[:16][expected]);black=np.median(means[:16][~expected])
        if white-black<96:return None
        threshold=(white+black)/2
        if np.any(np.abs(means-threshold)<24):return None
        decoded.append(np.packbits(means>threshold).tobytes())
    return decoded[0] if decoded[0]==decoded[1] else None


def decode(image):
    if (image.width(),image.height()) not in ((1280,720),(1920,1080)):
        return None,None
    from frame_type_protocol import decode_type
    kind=decode_type(image)
    packet=_bits(image,128,0,120,0xD95A) if kind else None
    layout='v10_single_row_4px'
    def valid(p):return p is not None and p[:2]==b'\xd9\x5a' and crc8(p[:-1])==p[-1]
    if not valid(packet):
        # Only accept the legacy layout with a valid type AND full telemetry CRC.
        # Never reuse previous-frame metadata to repair a broken packet.
        old_kind=decode_type(image,legacy=True)
        old_packet=_bits(image,0,16,120,0xD95A,legacy=True) if old_kind else None
        if valid(old_packet):kind,packet,layout=old_kind,old_packet,'v9_two_rows_16px'
        else:return kind,None
    flags=packet[2];level=flags>>4
    if level>8 or flags&2:return kind,None
    mode=1080 if flags&4 else 720
    if image.width()!=(1920 if mode==1080 else 1280):return kind,None
    cycles=int.from_bytes(packet[7:11],'big')
    return kind,dict(frame_id=int.from_bytes(packet[3:7],'big'),cycles=cycles,
                     fpga_ms=cycles/125000.0,gamma_on=bool(flags&1),gamma=round(.6+level*.1,2),
                     gamma_epoch=bool(flags&8),mode=mode,layout=layout,mean=packet[11],
                     dark=packet[12]*100/255,high=packet[13]*100/255)


def make_packet(frame_id,cycles,gamma_on=False,level=4,mode=720,epoch=0,mean=128,dark=0,high=0):
    body=b'\xd9\x5a'+bytes([(level<<4)|(bool(epoch)<<3)|((mode==1080)<<2)|bool(gamma_on)])
    body+=frame_id.to_bytes(4,'big')+cycles.to_bytes(4,'big')+bytes([mean,dark,high])
    return body+bytes([crc8(body)])
