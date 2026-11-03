"""Bounded capture processing. No per-frame queued GUI signals."""
import time
import threading
from collections import deque,Counter
from queue import Queue,Empty,Full
from PySide6.QtGui import QImage
from PySide6.QtCore import QThread
from video_protocol import decode
from frame_diagnostics import FrameDiagnostics
from frame_type_protocol import inspect_type


def stopped_black(image):
    """Allow black-level offsets, but reject textured/dark pictures and markers."""
    from numpy import frombuffer,uint8
    rgb=image.convertToFormat(QImage.Format.Format_RGB888)
    pixels=frombuffer(rgb.constBits(),uint8).reshape(rgb.height(),rgb.bytesPerLine())
    pixels=pixels[:,:rgb.width()*3]  # Padding bytes are not image content.
    low,high=int(pixels.min()),int(pixels.max())
    return high<=20 and high-low<=3,(low,high)


class ProcessingThread(QThread):
    def __init__(self,target):
        super().__init__();self.target=target;self.setObjectName('video-processing')
    def run(self):self.target()


class Pipeline:
    def __init__(self,diagnostic_root):
        self.lock=threading.Lock();self.queue=Queue(maxsize=3)
        self.stop_event=threading.Event();self.epoch=-1
        self.diagnostics=FrameDiagnostics(diagnostic_root)
        self.reset(-1,720)
        self.thread=ProcessingThread(self._run);self.thread.start()

    def reset(self,epoch,mode):
        with self.lock:
            self.epoch=epoch;self.mode=mode;self.started=time.perf_counter()
            self.images={};self.counts=Counter();self.events=deque();self.samples=deque();self.seen={}
            self.last_processed_id=None
            self.latest_meta=None;self.blank_count=0;self.ready=False;self.sequence=0;self.error=''
            self.prepare_info=dict(frames=0,blank_streak=0)
            self.diagnostics.reset(epoch)
        while True:
            try:self.queue.get_nowait()
            except Empty:break

    def submit(self,frame,epoch,phase):
        stamp=time.perf_counter()
        with self.lock:
            if epoch!=self.epoch:return
            self.counts['received']+=1
        try:self.queue.put_nowait((frame,epoch,phase,stamp))
        except Full:
            try:
                self.queue.get_nowait()
                with self.lock:self.counts['backlog_drop']+=1
            except Empty:pass
            try:self.queue.put_nowait((frame,epoch,phase,stamp))
            except Full:
                with self.lock:self.counts['backlog_drop']+=1

    def _run(self):
        while not self.stop_event.is_set():
            try:frame,epoch,phase,arrival=self.queue.get(timeout=.1)
            except Empty:continue
            with self.lock:
                if epoch!=self.epoch:continue
            started=time.perf_counter()
            try:
                image=frame if isinstance(frame,QImage) else frame.toImage()
                kind,meta=decode(image) if not image.isNull() else (None,None)
                # An NV12 black frame can decode to RGB 7..8 (or limited-range
                # black 16). Exact zero is not a portable readiness condition.
                full_black=False;black_range=None
                if kind is None and not image.isNull():
                    full_black,black_range=stopped_black(image)
                view=image.copy(320,180,1280,720) if kind=='raw' and self.mode==1080 else image
                ended=time.perf_counter()
                with self.lock:
                    if epoch!=self.epoch:continue
                    if image.isNull():
                        self.counts['empty']+=1
                        info=dict(mode=self.mode,state=phase,
                                  seconds_since_capture_start=ended-self.started)
                        if not isinstance(frame,QImage):
                            info.update(valid=frame.isValid(),pixel_format=frame.pixelFormat().name,
                                        size=[frame.width(),frame.height()],
                                        start_us=frame.startTime(),end_us=frame.endTime())
                        self.diagnostics.record('empty',image,info)
                        continue
                    expected=(1280,720) if self.mode==720 else (1920,1080)
                    if (image.width(),image.height())!=expected:
                        self._reject('size_mismatch',image,epoch,phase);continue
                    if phase=='PREPARE':
                        self.blank_count=self.blank_count+1 if full_black else 0
                        self.ready=self.blank_count>=3
                        self.prepare_info=dict(frames=self.prepare_info['frames']+1,
                                               blank_streak=self.blank_count,rgb_range=black_range,
                                               type=kind,size=[image.width(),image.height()])
                        continue
                    if phase!='RUNNING':continue
                    if kind is None:
                        if not (self.counts['raw'] or self.counts['corrected']) and full_black:self.counts['startup']+=1
                        else:self._reject('marker_failure',image,epoch,phase)
                        continue
                    self.counts[kind]+=1;self.events.append((ended,kind))
                    if meta is None:self.counts['metadata_invalid']+=1
                    else:
                        self.latest_meta=meta
                        if kind=='corrected' and meta['cycles'] and meta['frame_id']!=self.last_processed_id and meta['frame_id'] not in self.seen:
                            self.last_processed_id=meta['frame_id']
                            self.seen[meta['frame_id']]=ended
                            self.samples.append((ended,meta['frame_id'],meta['fpga_ms']))
                    self.sequence+=1
                    self.images[kind]=dict(image=view,meta=meta,sequence=self.sequence,
                                          processed=ended,host_ms=(ended-started)*1000,
                                          queue_ms=(started-arrival)*1000)
                    self._prune(ended)
            except Exception as exc:
                with self.lock:
                    if epoch==self.epoch:self.error=str(exc);self.counts['processing_error']+=1
            finally:frame=None

    def _reject(self,reason,image,epoch,phase):
        self.counts[reason]+=1
        self.diagnostics.record(reason,image,dict(mode=self.mode,state=phase,
            actual_size=[image.width(),image.height()],marker=inspect_type(image),
            accepted_counts_before_rejection={k:self.counts[k] for k in ('raw','corrected')},
            startup_transition_frames=self.counts['startup'],seconds_since_capture_start=time.perf_counter()-self.started))

    def _prune(self,now):
        while self.events and self.events[0][0]<now-5:self.events.popleft()
        while self.samples and self.samples[0][0]<now-5:
            _,identity,_=self.samples.popleft();self.seen.pop(identity,None)
        # Upper bounds also protect against unexpected high-rate duplicate callbacks.
        while len(self.events)>1000:self.events.popleft()
        while len(self.samples)>300:
            _,identity,_=self.samples.popleft();self.seen.pop(identity,None)

    def snapshot(self):
        with self.lock:
            now=time.perf_counter();self._prune(now);self.diagnostics.poll()
            fps={kind:sum(k==kind and t>=now-2 for t,k in self.events)/2 for kind in ('raw','corrected')}
            values=[s[2] for s in self.samples]
            return dict(epoch=self.epoch,counts=dict(self.counts),images=dict(self.images),fps=fps,
                        ready=self.ready,error=self.error,queue=self.queue.qsize(),metadata=self.latest_meta,
                        prepare=dict(self.prepare_info),
                        fpga_avg=sum(values)/len(values) if values else None,
                        fpga_max=max(values) if values else None,
                        diagnostic_folder=str(self.diagnostics.folder),diagnostic_error=self.diagnostics.error)

    def close(self):
        self.stop_event.set()
        if not self.thread.wait(5000):raise RuntimeError('Video worker did not finish within 5 seconds')
        self.diagnostics.close()
