"""Transactional virtual-pan UART client. No pixel transformations."""
from dataclasses import dataclass
import binascii,struct,time

def crc16(data):return binascii.crc_hqx(data,0xffff)

def make_packet(sequence,angle_tenths):
    if not 0<=sequence<=65535 or not -300<=angle_tenths<=300:raise ValueError('转向参数超出协议范围')
    body=struct.pack('>2sHh',b'PA',sequence,angle_tenths)
    return body+struct.pack('>H',crc16(body))

@dataclass(frozen=True)
class PanResult:
    success: bool
    message: str
    sequence: int|None=None
    angle_tenths: int|None=None
    frame_id: int|None=None
    uncertain: bool=False

class PanControl:
    def __init__(self,send,finished,clock=time.monotonic):
        self.send=send;self.finished=finished;self.clock=clock;self.sequence=0
        self.state='IDLE';self.buffer=bytearray();self.deadline=0;self.angle=0

    @property
    def busy(self):return self.state!='IDLE'

    def start(self,angle_tenths):
        if self.busy:raise ValueError('上一条转向命令尚未确认')
        make_packet(0,angle_tenths)
        self.sequence=(self.sequence+1)&65535;self.angle=angle_tenths
        self.buffer.clear();self.state='READY';self.deadline=self.clock()+5
        try:self.send(b'\x0c\x0c')
        except Exception as exc:self.fail(str(exc))

    def fail(self,message,uncertain=True):
        self.state='IDLE';self.buffer.clear()
        self.finished(PanResult(False,message,uncertain=uncertain))

    def receive(self,data):
        if not self.busy:return
        self.buffer.extend(data)
        while len(self.buffer)>=2:
            if self.buffer[0]==0xe1:
                code=int.from_bytes(self.buffer[:2],'big')
                reasons={0xe101:'FPGA 当前不允许转向（需要 720P 运行且有有效标定）',0xe102:'转向包格式错误',
                         0xe103:'转向包校验失败',0xe104:'角度超出硬件范围',0xe105:'转向包接收超时',0xe106:'目标帧显示确认超时'}
                self.fail(reasons.get(code,f'转向失败 {code:04X}'),uncertain=code in (0xe106,0xe101));return
            if self.state=='READY' and self.buffer[:2]==b'\x0c\xc0':
                del self.buffer[:2];self.state='APPLY';self.deadline=self.clock()+7
                try:self.send(make_packet(self.sequence,self.angle))
                except Exception as exc:self.fail(str(exc));return
                continue
            if self.state=='APPLY' and self.buffer[:2]==b'\xdc\x15':
                if len(self.buffer)<12:return
                packet=bytes(self.buffer[:12]);del self.buffer[:12]
                if crc16(packet[:10])!=int.from_bytes(packet[10:],'big'):
                    self.fail('转向应答校验失败，请重新连接确认状态');return
                _,seq,angle,frame=struct.unpack('>HHhI',packet[:10])
                if seq!=self.sequence or angle!=self.angle:continue
                self.state='IDLE';self.buffer.clear()
                self.finished(PanResult(True,f'已生效 {angle/10:+.1f}° · FPGA 帧 {frame}',seq,angle,frame));return
            del self.buffer[0]

    def poll(self):
        if self.busy and self.clock()>=self.deadline:self.fail('转向应答超时，实际角度未确认；请重新连接设备')
