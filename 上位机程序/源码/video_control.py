"""Video control and non-disruptive gamma command transactions."""
from session_control import SessionControl,State
ON=b'\xaa\xbb'
OFF=b'\xab\xcd'


class Control(SessionControl):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self.gamma_pending=None;self.gamma_state=None;self.gamma_buffer=bytearray()
        self.gamma_deadline=0;self.gamma_message='Gamma 状态待确认'

    def gamma(self,enabled):
        if self.busy or self.gamma_pending is not None:return False
        if self.state not in (State.RUNNING,State.STOPPED):return False
        self.gamma_pending=ON if enabled else OFF
        self.gamma_buffer.clear();self.gamma_deadline=self.clock()+3
        self.gamma_message='等待 FPGA 在整帧边界应用…'
        try:self.send(self.gamma_pending)
        except Exception as e:
            self.gamma_pending=None;self.gamma_state=None;self.gamma_message='发送失败：'+str(e)
        return self.gamma_pending is not None

    def receive(self,data):
        if self.gamma_pending is None:return super().receive(data)
        self.gamma_buffer.extend(data)
        while len(self.gamma_buffer)>=2:
            pair=bytes(self.gamma_buffer[:2])
            if pair==self.gamma_pending:
                self.gamma_state=pair==ON;self.gamma_pending=None;self.gamma_buffer.clear()
                self.gamma_message=('已开启' if self.gamma_state else '已关闭')+('；下次采集生效' if self.state==State.STOPPED else '；等待对应视频状态')
                return
            del self.gamma_buffer[0]

    def select(self,mode):
        if self.gamma_pending is not None:return False
        return super().select(mode)

    def stop(self):
        self.gamma_pending=None;self.gamma_buffer.clear()
        return super().stop()

    def confirm_external_stop(self):
        self.gamma_pending=None;self.gamma_state=None;self.gamma_buffer.clear()
        self.gamma_message='Gamma 状态待确认'
        super().confirm_external_stop()

    def fail(self,message):
        self.gamma_pending=None;self.gamma_state=None;self.gamma_message='状态未确认'
        return super().fail(message)

    def poll(self):
        super().poll()
        if self.gamma_pending is not None and self.clock()>self.gamma_deadline:
            self.gamma_pending=None;self.gamma_state=None;self.gamma_buffer.clear()
            self.gamma_message='Gamma 回显超时；状态未确认，视频继续，可重试'
