"""V15 coefficient review and manual input, using the same validated CAL1 path."""
from dataclasses import asdict
from datetime import datetime
import json,math
from pathlib import Path
from PySide6.QtCore import QSignalBlocker,QThread,Signal
from calibration_ui_v15 import build_ui,set_preview
from calibration_dialog_base import CalibrationDialog as BaseDialog,CalibrationWorker
from calibration_engine_v15 import run_calibration as run_v15_calibration
from calibration_engine_base import CalibrationRun
from calibration_math import FloatCalibration,derive_full_view_output,to_fixed,validate_for_fpga
from calibration_protocol import CalibrationPacket
from pan_math_v15 import validate_angle,HFOV_DEG
from calibration_validation_v15 import validate_runtime_geometry

FIELDS=('fx','fy','cx','cy','k1','k2','p1','p2')


def float_from_fixed(fixed):
    return FloatCalibration(*(getattr(fixed,f'{n}_q12')/4096 for n in FIELDS[:4]),
                            *(getattr(fixed,f'{n}_q30')/(1<<30) for n in FIELDS[4:]))

def manual_result(values,output):
    if set(values)!=set(FIELDS) or not all(math.isfinite(float(x)) for x in values.values()):
        raise ValueError('八个参数必须为有限数值，不能为空、NaN 或无穷大')
    cal=FloatCalibration(**values)
    if not 64<=cal.fx<=2047 or not 64<=cal.fy<=2047:raise ValueError('焦距必须在 64…2047 像素范围内')
    geometry=derive_full_view_output(cal);fixed=to_fixed(cal,geometry)
    validation=validate_for_fpga(cal,fixed,geometry,cache_lines=112)
    pan=validate_angle(cal,0)
    errors=list(validation.errors)
    exact=validate_runtime_geometry(fixed)
    errors.extend(exact['errors'])
    # Require both the complete 1080P path and the initial 70-degree 720P view.
    # Each nonzero pan angle is checked separately before issuing a command.
    report={'application':'ShowTime V15','source':'manual','model':'Brown4 (k1,k2,p1,p2)',
            'image_size':[1280,720],'K':[[cal.fx,0,cal.cx],[0,cal.fy,cal.cy],[0,0,1]],
            'distortion':[cal.k1,cal.k2,cal.p1,cal.p2,0],
            'rms_px':None,'cross_validation':None,'images':[],
            'fixed':asdict(fixed),'hardware':asdict(validation),'pan_zero':asdict(pan),
            'runtime_geometry':exact,'gate_errors':errors,'passed':not errors,
            'note':'手动输入未经棋盘图像拟合；数值/硬件检查不证明实际镜头的标定精度。'}
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    (output/'calibration.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    packet=CalibrationPacket(0,fixed).pack() if not errors else b''
    if packet:(output/'coefficients.bin').write_bytes(packet)
    return CalibrationRun(output,not errors,report,packet)

class ManualWorker(QThread):
    succeeded=Signal(object);failed=Signal(str)
    def __init__(self,values,output):super().__init__();self.values=values;self.output=output
    def run(self):
        try:self.succeeded.emit(manual_result(self.values,self.output))
        except Exception as exc:self.failed.emit('参数验证失败：'+str(exc))

class CalibrationWorkerV15(CalibrationWorker):
    def run(self):
        try:
            result=run_v15_calibration(self.paths,self.output,self.settings,
                progress=lambda done,total,name:self.progress.emit(done,total,name))
        except Exception as exc:self.failed.emit('标定失败：'+str(exc))
        else:self.succeeded.emit(result)

class CalibrationDialog(BaseDialog):
    worker_class=CalibrationWorkerV15
    def _ui(self):
        build_ui(self)

    _set_preview=staticmethod(set_preview)

    def add_paths(self,selected):
        super().add_paths(selected)
        for i in range(self.images.count()):self.images.item(i).setToolTip(self.images.item(i).text())

    def _update_summary(self,run):
        r=run.report
        if r.get('source')=='manual':self.result_summary.setText('手动输入 · 无拟合误差')
        elif r.get('rms_px') is not None:
            self.result_summary.setText(f"保留 {r.get('accepted_images',0)}/{r.get('total_images',0)} · RMS {r['rms_px']:.3f} px")
        else:self.result_summary.setText('未通过标定检查')

    def _edited(self):
        self.run_result=None;self.upload_button.setEnabled(False)
        if hasattr(self,'coefficient_status'):self.coefficient_status.setText('参数已编辑，尚未验证；旧生成结果不可写入。')

    def set_active_parameters(self,fixed):
        if fixed is None:return
        self.active_fixed=fixed
        cal=float_from_fixed(fixed)
        state='已启用矫正' if fixed.flags else '默认直通，无畸变矫正'
        lines=['FPGA 当前 · '+state,
               '   '.join(f'{name}={getattr(cal,name):.7g}' for name in FIELDS[:4]),
               '   '.join(f'{name}={getattr(cal,name):.7g}' for name in FIELDS[4:])]
        self.active_parameters.setText('\n'.join(lines))
        self.active_parameters.setToolTip('\n'.join(lines))

    def load_current(self):
        if self.active_fixed is None:return
        cal=float_from_fixed(self.active_fixed)
        for name in FIELDS:
            self.fields[name].setText(f'{getattr(cal,name):.12g}')
            self.fields[name].setCursorPosition(0)
            self.fields[name].setToolTip(self.fields[name].text())

    def _show_parameters(self,run):
        report=run.report;k=report.get('K');d=report.get('distortion')
        if k is not None and d is not None:
            for name,value in zip(FIELDS,(k[0][0],k[1][1],k[0][2],k[1][2],*d[:4])):
                with QSignalBlocker(self.fields[name]):
                    self.fields[name].setText(f'{value:.12g}')
                    self.fields[name].setCursorPosition(0)
                    self.fields[name].setToolTip(self.fields[name].text())
        source='手动输入（无重投影误差测量）' if report.get('source')=='manual' else '棋盘格标定'
        self.coefficient_status.setText(f'{source} · '+('数值检查通过' if run.passed else '未通过检查')+
                                      f'；720P 虚拟水平视野 {HFOV_DEG:g}°，每个转向角度单独验证。')

    def start_calibration(self):
        super().start_calibration()
        if self.worker and self.worker.isRunning():
            self.editor.setEnabled(False);self.worker.finished.connect(lambda:self.editor.setEnabled(True))

    def _calibration_finished(self,run):
        super()._calibration_finished(run);self._show_parameters(run);self._update_summary(run)

    def validate_manual(self):
        if self.worker and self.worker.isRunning():return
        try:values={n:float(e.text().strip()) for n,e in self.fields.items()}
        except ValueError:self.status.setText('请填写全部八个数值参数。');return
        self.run_result=None;self.upload_button.setEnabled(False);self.run_button.setEnabled(False);self.editor.setEnabled(False)
        output=self.output_root/('manual_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
        self.worker=ManualWorker(values,output)
        self.worker.succeeded.connect(self._manual_finished)
        self.worker.failed.connect(self._calibration_failed)
        self.worker.finished.connect(lambda:self.editor.setEnabled(True))
        self.status.setText('正在检查 1080P 完整画布、数值精度与 FPGA 缓存范围…');self.worker.start()

    def _manual_finished(self,run):
        self.run_result=run;self.run_button.setEnabled(True);self.upload_button.setEnabled(run.passed)
        self._show_parameters(run);self._update_summary(run)
        self.status.setText(('手动参数通过数值验证，可输入 FPGA；尚无图像标定误差测量。' if run.passed else
                            '不可输入 FPGA：'+'；'.join(run.report['gate_errors'])))
