"""Opt-in hardware acceptance of the packaged V15 viewer.

No EEPROM writes, no programming, no desktop automation. Hardware must already
be running V15 and all other owners of COM18/capture must be closed.
"""
import os,sys,time,json,argparse
from pathlib import Path
from dataclasses import asdict
if '--offscreen' in sys.argv:os.environ['QT_QPA_PLATFORM']='offscreen'
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'host/source'))
from PySide6.QtCore import QTimer
from PySide6.QtGui import QImage,QFont
from PySide6.QtWidgets import QApplication
from viewer_v15 import Viewer
from session_control import State

def run():
    parser=argparse.ArgumentParser()
    parser.add_argument('--hardware-check',action='store_true')
    parser.add_argument('--offscreen',action='store_true')
    parser.add_argument('--test',choices=['smoke','endurance'],default='smoke')
    parser.add_argument('--duration',type=int,default=1800)
    parser.add_argument('--port',default='COM18')
    parser.add_argument('--report-dir',required=True)
    args=parser.parse_args();out=Path(args.report_dir);out.mkdir(parents=True,exist_ok=False)
    app=QApplication([]);app.setFont(QFont('Microsoft YaHei',10));app.setQuitOnLastWindowClosed(False)
    w=Viewer();w.showMaximized();w.port.setCurrentIndex(w.port.findData(args.port))
    captures=[i for i in range(w.device.count()) if 'UGREEN 25854' in w.device.itemText(i)]
    assert len(captures)==1,'Expected one UGREEN 25854 capture device'
    w.device.setCurrentIndex(captures[0]);w.view_mode.setCurrentIndex(w.view_mode.findData('compare'))
    stages=([('select',720,8),('gamma',False,5),('pan',0,5),('pan',-50,5),('pan',50,5),
             ('pan',-100,6),('pan',100,6),('gamma',True,5),('pan',-50,5),('pan',0,5),
             ('gamma',False,5),('select',1080,15),('gamma',True,5),('gamma',False,5),
             ('select',720,5),('select',None,0)] if args.test=='smoke' else
            [('select',720,args.duration),('select',1080,args.duration),('select',None,0)])
    began=time.monotonic();events=[];results=[];acks=[];pending_images=[]
    state=dict(index=-1,start=None,requested=began,done=False,mode=None,last_progress=0,last_pan=0,pan_index=0)
    def record(event,**kwargs):
        events.append(dict(seconds=time.monotonic()-began,event=event,**kwargs))
    original_finished=w.pan.finished
    def pan_result(result):
        acks.append(asdict(result));record('pan_result',**asdict(result));original_finished(result)
    w.pan.finished=pan_result
    def write_report(passed=False,message='running'):
        report=dict(passed=passed,message=message,elapsed=time.monotonic()-began,
            source='V15 Viewer with real UART and video', frozen=bool(getattr(sys,'frozen',False)),
            test=args.test,platform=app.platformName(),events=events,stages=results,pan_acks=acks,
            current_stage=state['index'],eeprom_written=False)
        (out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    def finish(passed,message):
        if state['done']:return
        state['done']=True;timer.stop();record('finish',passed=passed,message=message)
        write_report(passed,message);print(('PASS ' if passed else 'FAIL ')+message,flush=True)
        # Wait for any pending worker/transaction to settle, then close normally.
        deadline=time.monotonic()+15
        def cleanup():
            if w.close_done.is_set():
                cleanup_timer.stop()
                # PNG compression can hold the Python GIL; perform it only
                # after capture and the processing worker have stopped.
                for path,image in pending_images:image.save(str(path))
                pending_images.clear();app.exit(0 if passed else 3);return
            if time.monotonic()>deadline:
                if w.serial.isOpen():w.serial.close()
                w.pipeline.close();cleanup_timer.stop();app.exit(4);return
            w.close()
        cleanup_timer.timeout.connect(cleanup);cleanup_timer.start()
    def advance():
        state.update(index=state['index']+1,start=None,requested=time.monotonic(),epoch=w.control.epoch)
        state['request_counts']=w.pipeline.snapshot()['counts']
        action,value,duration=stages[state['index']]
        record('stage',index=state['index'],action=action,value=value)
        print(f'STAGE {state["index"]} {action} {value}',flush=True)
        if action=='select':state['mode']=value;w.select(value)
        elif action=='pan':w.request_pan(value/10)
        elif not w.control.gamma(value):finish(False,'Gamma rejected')
    def save_frames(s):
        stem=f'{state["index"]:02d}_{stages[state["index"]][0]}_{stages[state["index"]][1]}'
        meta={}
        for kind,item in s['images'].items():
            pending_images.append((out/f'{stem}_{kind}.png',QImage(item['image'])))
            meta[kind]=item['meta']
        (out/f'{stem}_metadata.json').write_text(json.dumps(meta,indent=2),encoding='utf-8')
    def tick():
        try:
            now=time.monotonic();s=w.pipeline.snapshot()
            if state['index']<0:
                if w.connection.ready:
                    assert w.connection.calibration.flags,'Need valid existing calibration; not overwriting EEPROM'
                    (out/'active_parameters.json').write_text(json.dumps(asdict(w.connection.calibration),indent=2))
                    record('connected',port=w.port.currentData(),device=w.device.currentText());advance()
                elif not w.connection.pending or now-began>30:finish(False,'Connection failed: '+w.connection.message)
                return
            if w.control.state==State.ERROR:return finish(False,w.status.text())
            action,value,duration=stages[state['index']];mode=state['mode']
            if action=='select' and value is None:
                if w.control.state==State.STOPPED:return finish(True,'All requested video/control stages passed; EEPROM unchanged')
                if now-state['requested']>20:return finish(False,'Stop timeout')
                return
            if state['start'] is None and now-state['requested']>25:
                record('not_ready',state=w.control.state.name,counts=s['counts'],status=w.status.text(),pan=w.pan_label.text())
                return finish(False,'No confirmed new video state within 25 seconds')
            meta=s['metadata']
            if (w.control.state!=State.RUNNING or w.control.gamma_pending is not None or not meta or
                meta['mode']!=mode or len(s['images'])!=2):return
            if action=='gamma' and (w.control.gamma_state!=value or meta['gamma_on']!=value):return
            if action=='pan' and (w.pan.busy or w.pan_applied!=value):return
            if any(p.painted_sequence<0 for p in w.panels.values()):return
            if state['start'] is None:
                state.update(start=now,counts=s['counts'],last_progress=now,last_pan=now,
                    last_frame={k:i['meta']['frame_id'] for k,i in s['images'].items() if i['meta']},
                    distinct={'raw':0,'corrected':0},max_queue=0,max_host_ms=0,max_gap=0,last_video=now,
                    previous_received=s['counts'].get('received',0))
                record('ready',index=state['index'],prepare=s['prepare'],request_wait_seconds=now-state['requested'],
                    queue_drops_during_request=max(0,s['counts'].get('backlog_drop',0)-state['request_counts'].get('backlog_drop',0)))
            if action in ('gamma','pan') and w.control.epoch!=state['epoch']:
                return finish(False,'Noninterrupt command reset the video session')
            for kind,item in s['images'].items():
                if item['meta'] and state['last_frame'].get(kind)!=item['meta']['frame_id']:
                    state['distinct'][kind]+=1;state['last_frame'][kind]=item['meta']['frame_id']
                state['max_host_ms']=max(state['max_host_ms'],item['host_ms'])
            state['max_queue']=max(state['max_queue'],s['queue'])
            received=s['counts'].get('received',0)
            if received!=state['previous_received']:
                state['max_gap']=max(state['max_gap'],now-state['last_video']);state['last_video']=now;state['previous_received']=received
            elif now-state['last_video']>2:return finish(False,'No captured video callbacks for 2 seconds')
            if args.test=='endurance' and mode==720 and now-state['last_pan']>=30 and not w.pan.busy:
                angles=[-50,50,-100,100,0];angle=angles[state['pan_index']%len(angles)]
                state['pan_index']+=1;state['last_pan']=now;w.request_pan(angle/10)
            if now-state['last_progress']>=30:
                record('progress',mode=mode,stage_seconds=now-state['start'],counts=s['counts'],fps=s['fps'],queue=s['queue'])
                write_report();state['last_progress']=now
                print(f'PROGRESS mode={mode} seconds={now-state["start"]:.0f} fps={s["fps"]} queue={s["queue"]}',flush=True)
            if now-state['start']<duration:return
            if w.pan.busy or (w.pan_check and w.pan_check.isRunning()):return
            elapsed=now-state['start'];counts={k:v-state['counts'].get(k,0) for k,v in s['counts'].items()}
            rates={k:counts.get(k,0)/elapsed for k in ('raw','corrected')}
            bad=sum(counts.get(k,0) for k in ('empty','size_mismatch','marker_failure','metadata_invalid','processing_error'))
            sizes={k:[i['image'].width(),i['image'].height()] for k,i in s['images'].items()}
            expected={'raw':[1280,720],'corrected':[1920,1080] if mode==1080 else [1280,720]}
            passed=(meta['layout']=='v10_single_row_4px' and bad==0 and min(rates.values())>27 and sizes==expected and
                    not s['error'] and min(state['distinct'].values())>elapsed*20)
            result=dict(action=action,value=value,mode=mode,seconds=elapsed,counts=counts,rates=rates,sizes=sizes,
                        initial_counts=state['counts'],session_total_counts=s['counts'],
                        distinct_frames=state['distinct'],metadata=meta,max_queue=state['max_queue'],
                        max_host_ms=state['max_host_ms'],max_callback_gap_s=state['max_gap'],passed=passed)
            results.append(result);save_frames(s);write_report();print(json.dumps(result),flush=True)
            if not passed:return finish(False,'Video rates, metadata, frame progression or size check failed')
            advance()
        except Exception as exc:finish(False,repr(exc))
    timer=QTimer();timer.setInterval(25);timer.timeout.connect(tick)
    cleanup_timer=QTimer();cleanup_timer.setInterval(100)
    QTimer.singleShot(300,w.connect_devices);QTimer.singleShot(350,timer.start)
    QTimer.singleShot((2*args.duration+180 if args.test=='endurance' else 240)*1000,lambda:finish(False,'Overall timeout'))
    return app.exec()

if __name__=='__main__':sys.exit(run())
