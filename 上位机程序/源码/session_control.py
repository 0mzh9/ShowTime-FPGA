"""V15 shared binary command state machine; independent of Qt and the capture backend."""
from enum import Enum, auto

STOP = bytes.fromhex('68 68')
START = bytes.fromhex('66 88')
MODES = {720: bytes.fromhex('12 34'), 1080: bytes.fromhex('23 45')}
SIZES = {720: (1280, 720), 1080: (1920, 1080)}

class State(Enum):
    STOPPED=auto(); WAIT_STOP=auto(); WAIT_MODE=auto(); PREPARE=auto()
    WAIT_START=auto(); RUNNING=auto(); ERROR=auto()

class SessionControl:
    """Callbacks must not block. One outstanding command, no speculative ACKs.

    reset(epoch): destroys capture and blanks displays; prepare(mode,epoch):
    configures fresh capture, then calls capture_ready(epoch). receive() accepts
    partial UART reads. A timed out session never becomes active on a late ACK.
    """
    def __init__(self, send, reset, prepare, notify, clock, timeout=15.0):
        self.send=send; self.reset=reset; self.prepare=prepare; self.notify=notify
        self.clock=clock; self.timeout=timeout; self.state=State.STOPPED
        self.epoch=0; self.mode=None; self.target=None; self.expected=None
        self.buffer=bytearray(); self.deadline=0; self.valid_types=set()

    @property
    def busy(self):
        return self.state in (State.WAIT_STOP,State.WAIT_MODE,State.PREPARE,State.WAIT_START)

    def _request(self, payload, state):
        self.state=state; self.expected=payload; self.deadline=self.clock()+self.timeout
        self.buffer.clear(); self.notify(state.name)
        try: self.send(payload)
        except Exception as e: self.fail('串口发送失败：'+str(e))

    def select(self, mode):
        if mode not in MODES: raise ValueError(mode)
        if self.busy: return False
        self._begin(mode); return True

    def stop(self):
        if self.busy: return False  # UI serializes operations; no ambiguous overlapping echoes.
        self._begin(None); return True

    def confirm_external_stop(self):
        """A separate connection handshake proved that FPGA drained old frames."""
        self.epoch+=1;self.mode=None;self.target=None;self.expected=None
        self.buffer.clear();self.valid_types.clear();self.state=State.STOPPED
        self.reset(self.epoch)

    def _begin(self, target):
        self.epoch+=1; self.target=target; self.valid_types.clear()
        self.reset(self.epoch)
        self._request(STOP, State.WAIT_STOP)

    def receive(self, data):
        if self.expected is None: return
        self.buffer.extend(data)
        # Sliding parser tolerates noise and split USB transfers. Only the
        # currently outstanding command may advance the state machine.
        while len(self.buffer)>=2 and self.expected is not None:
            if bytes(self.buffer[:2])!=self.expected:
                del self.buffer[0]; continue
            self.buffer.clear(); self.expected=None
            state=self.state
            if state==State.WAIT_STOP:
                if self.target is None:
                    self.state=State.STOPPED; self.notify('已停止；FPGA 已清除旧帧有效状态')
                else: self._request(MODES[self.target],State.WAIT_MODE)
            elif state==State.WAIT_MODE:
                self.mode=self.target; self.state=State.PREPARE
                self.deadline=self.clock()+self.timeout
                self.notify('配置采集卡，等待有效尺寸后启动 FPGA')
                try: self.prepare(self.mode,self.epoch)
                except Exception as e: self.fail('采集卡配置失败：'+str(e))
            elif state==State.WAIT_START:
                self.state=State.RUNNING; self.valid_types.clear()
                self.notify('FPGA 新图像就绪，等待两类有效画面')

    def capture_ready(self, epoch):
        if epoch==self.epoch and self.state==State.PREPARE:
            self._request(START,State.WAIT_START)

    def accept(self, epoch, size, kind):
        if epoch!=self.epoch or self.state!=State.RUNNING: return False
        if tuple(size)!=SIZES[self.mode] or kind not in ('raw','corrected'): return False
        self.valid_types.add(kind)
        return True

    def poll(self):
        if self.busy and self.clock()>self.deadline:
            self.fail('等待 '+self.state.name+' 超时；未确认成功，请检查板卡、串口和采集卡')

    def fail(self, message):
        self.epoch+=1; self.expected=None; self.buffer.clear(); self.valid_types.clear()
        self.state=State.ERROR; self.reset(self.epoch)
        # Best effort only: never report stopped without its acknowledgement.
        try: self.send(STOP)
        except Exception: pass
        self.notify(message+'。画面已清空；FPGA 停止状态未确认。')
