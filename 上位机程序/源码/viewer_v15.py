"""ShowTime V15 viewer with local chessboard calibration and EEPROM upload."""
import os,sys,json,time,threading,logging
from logging.handlers import RotatingFileHandler
from datetime import datetime
from pathlib import Path
from PySide6.QtCore import Qt,QTimer,QIODevice,QRectF,QSettings,QThread,Signal
from PySide6.QtGui import QImage,QPainter,QColor,QFont,QAction,QKeySequence
from PySide6.QtMultimedia import QCamera,QMediaDevices,QMediaCaptureSession,QVideoSink,QVideoFrame
from PySide6.QtSerialPort import QSerialPort,QSerialPortInfo
from PySide6.QtWidgets import (QApplication,QMainWindow,QWidget,QLabel,QVBoxLayout,QHBoxLayout,
                               QGridLayout,QComboBox,QPushButton,QCheckBox,QFrame,QFileDialog,
                               QScrollArea,QStackedWidget,QDoubleSpinBox)
from capture_devices import choose_device,compatible_formats,device_id,device_label,resolve_format
from video_control import Control
from device_connection_v15 import DeviceConnection,preferred_board_port
from session_control import State
from video_pipeline import Pipeline
from calibration_dialog_v15 import CalibrationDialog
from calibration_upload import CalibrationUpload, UploadResult
from calibration_protocol import CalibrationPacket
from calibration_dialog_v15 import float_from_fixed
from pan_control_v15 import PanControl
from pan_math_v15 import validate_angle

STYLE="""
QMainWindow,QWidget#root{background:#f4f7fa;color:#17324d;font-family:"Segoe UI","Microsoft YaHei";font-size:13px;}
QLabel{color:#17324d;} QLabel#title{font-size:28px;font-weight:600;color:#102c47;}
QLabel#sub{color:#6d7d8e;} QLabel#metric{font-size:17px;font-weight:600;color:#176f68;}
QLabel#state{color:#26766c;background:#e8f6f2;border-radius:11px;padding:4px 10px;}
QLabel#message{color:#496278;background:#ffffff;border:1px solid #dce5ed;border-radius:7px;padding:5px 10px;}
QLabel#footerText{color:#4c6276;}
QFrame#header,QFrame#toolbar,QFrame#videoCard,QFrame#footer,QFrame#latencyDetails{background:#ffffff;border:1px solid #dce5ed;border-radius:11px;}
QComboBox{background:#f8fafc;color:#29465f;padding:9px 12px;border:1px solid #ccd8e3;border-radius:8px;min-width:180px;}
QComboBox:hover{border-color:#84bdb6;} QComboBox QAbstractItemView{background:#ffffff;color:#17324d;selection-background-color:#e7f5f2;}
QPushButton{background:#ffffff;color:#29465f;border:1px solid #c8d5df;border-radius:8px;padding:9px 16px;}
QPushButton:hover{background:#f1f7f7;border-color:#82bbb4;} QPushButton:disabled{color:#9aa8b4;background:#f2f4f6;border-color:#dce3e8;}
QPushButton[selected="true"]{background:#16857a;color:#ffffff;border-color:#16857a;}
QPushButton#gamma[enabledState="true"]{background:#e7f5f2;color:#176c65;border-color:#a8d7d0;}
QPushButton#stop{background:#fff2f0;color:#a6463c;border-color:#f0c7c1;}
QPushButton#latency{background:transparent;color:#176f68;border:0;padding:7px 4px;font-size:15px;font-weight:600;}
QPushButton#fullscreen{background:#f8fafc;color:#29465f;border:1px solid #d6e0e8;padding:4px 10px;}
QCheckBox{color:#4c6276;spacing:8px;}
"""


class Preview(QWidget):
    def __init__(self):
        super().__init__();self.setMinimumSize(360,220);self.image=QImage()
        self.virtual=(1280,720);self.sequence=-1;self.painted_sequence=-1
        self.processed=0;self.wait_ms=None;self.smooth=False
    def assign(self,item,virtual):
        if item is None:
            if not self.image.isNull():self.image=QImage();self.sequence=-1;self.painted_sequence=-1;self.wait_ms=None;self.update()
            return
        if self.sequence!=item['sequence'] or self.virtual!=virtual:
            self.image=item['image'];self.sequence=item['sequence'];self.processed=item['processed']
            self.virtual=virtual;self.update()
    def paintEvent(self,event):
        painter=QPainter(self);painter.fillRect(self.rect(),QColor('#071016'))
        if self.image.isNull():
            painter.setPen(QColor('#91a1af'))
            painter.drawText(self.rect(),Qt.AlignmentFlag.AlignCenter,'等待新会话图像');return
        vw,vh=self.virtual;scale=min(self.width()/vw,self.height()/vh)
        width,height=self.image.width()*scale,self.image.height()*scale
        rect=QRectF((self.width()-width)/2,(self.height()-height)/2,width,height)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform,self.smooth)
        painter.drawImage(rect,self.image)
        if self.painted_sequence!=self.sequence:
            self.wait_ms=(time.perf_counter()-self.processed)*1000
            self.painted_sequence=self.sequence


class FullScreenPreview(QWidget):
    """Image-only live preview for one image or the current comparison view."""
    def __init__(self,owner):
        super().__init__(owner,Qt.WindowType.Window);self.mode='raw';self.kind='raw'
        self.setWindowTitle('ShowTime 全屏预览');self.setStyleSheet('background:#071016;')
        layout=QHBoxLayout(self);layout.setContentsMargins(0,0,0,0);layout.setSpacing(0)
        self.previews={}
        for kind in ('raw','corrected'):
            preview=Preview();preview.setMinimumSize(1,1);layout.addWidget(preview,1)
            self.previews[kind]=preview
        self.preview=self.previews['raw']

    def show_kind(self,kind):
        self.show_mode(kind)

    def show_mode(self,mode):
        self.mode=mode;self.kind=mode
        self.previews['raw'].setVisible(mode in ('compare','raw'))
        self.previews['corrected'].setVisible(mode in ('compare','corrected'))
        self.preview=self.previews['corrected'] if mode=='corrected' else self.previews['raw']
        title={'compare':'左右对比','raw':'未矫正画面','corrected':'矫正画面'}[mode]
        self.setWindowTitle('ShowTime · '+title)
        self.showFullScreen();self.raise_();self.activateWindow();self.setFocus(Qt.FocusReason.OtherFocusReason)

    def keyPressEvent(self,event):
        if event.key()==Qt.Key.Key_Escape:
            self.hide();event.accept();return
        super().keyPressEvent(event)


def data_root():
    base=Path(sys.executable).resolve().parent if getattr(sys,'frozen',False) else Path(__file__).resolve().parents[1]
    try:
        folder=base/'data';folder.mkdir(parents=True,exist_ok=True)
        probe=folder/'.write_test';probe.write_bytes(b'');probe.unlink();return folder
    except OSError:pass
    return Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'ShowTimeV15'


class PanValidationWorker(QThread):
    checked=Signal(object)
    def __init__(self,fixed,angle):super().__init__();self.fixed=fixed;self.angle=angle
    def run(self):
        try:
            check=validate_angle(float_from_fixed(self.fixed),self.angle)
            message=None if check.passed else '；'.join(check.errors)
        except Exception as exc:message=str(exc) or type(exc).__name__
        self.checked.emit((self.angle,message,self.fixed))


class Viewer(QMainWindow):
    def __init__(self,offline=False):
        super().__init__();self.setWindowTitle('ShowTime · V15');self.resize(1500,900)
        self.setMinimumSize(1024,680)
        self.setStyleSheet(STYLE);self.settings=QSettings('FPGACompetition','ShowTimeV15')
        self.root=data_root();self.camera=self.session=self.sink=None
        (self.root/'logs').mkdir(parents=True,exist_ok=True)
        self.trace=logging.getLogger('ShowTimeV15.uart.'+str(id(self)))
        self.trace.setLevel(logging.INFO);self.trace.propagate=False
        self.trace_handler=RotatingFileHandler(self.root/'logs'/'uart_v13.log',maxBytes=1000000,backupCount=2,encoding='utf-8')
        self.trace_handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
        self.trace.addHandler(self.trace_handler);self.trace.info('LAUNCH SHOWTIME V15')
        self.generation=-1;self.selected_capture_id=None;self.pending_mode=720
        self.closing=False;self.close_done=threading.Event()
        self.pipeline=Pipeline(self.root/'diagnostics_v13')
        self.serial=QSerialPort(self);self.serial.setBaudRate(115200)
        self.serial.setDataBits(QSerialPort.DataBits.Data8);self.serial.setParity(QSerialPort.Parity.NoParity)
        self.serial.setStopBits(QSerialPort.StopBits.OneStop);self.serial.setFlowControl(QSerialPort.FlowControl.NoFlowControl)
        self.control=Control(self.send,self.clear_session,self.prepare,self.notify,time.monotonic)
        self.connection=DeviceConnection();self._refreshing_devices=False
        self.calibration_dialog=None;self.calibration_run=None
        self.calibration_updating=False;self.calibration_uncertain=False
        self.uploader=CalibrationUpload(self.send,self.calibration_status,self.calibration_finished)
        self.pan=PanControl(self.send,self.pan_finished)
        self.pan_applied=None
        self.pan_check=None
        self.serial.readyRead.connect(self.serial_received)
        self.serial.bytesWritten.connect(lambda count:self.trace.info('TX_WRITTEN %d bytes',count))
        self.serial.errorOccurred.connect(self.serial_error)
        self.save_busy=False;self.save_result=None;self.snapshot_data=None;self.last_info_update=0;self.last_prepare_log=0
        self._ui()
        self.fullscreen_view=FullScreenPreview(self)
        if not offline:
            self.refresh()
            self.media=QMediaDevices(self);self.media.videoInputsChanged.connect(self.devices_changed)
        self.timer=QTimer(self);self.timer.setInterval(33);self.timer.timeout.connect(self.tick);self.timer.start()

    def _ui(self):
        root=QWidget();root.setObjectName('root');self.setCentralWidget(root)
        main=QVBoxLayout(root);main.setContentsMargins(14,14,14,12);main.setSpacing(10)

        header_card=QFrame();header_card.setObjectName('header');main.addWidget(header_card)
        header=QHBoxLayout(header_card);header.setContentsMargins(18,10,14,10);header.setSpacing(10)
        title=QLabel('Show<span style="color:#16857a">Time</span>');title.setObjectName('title');header.addWidget(title)
        self.port=QComboBox();self.port.setAccessibleName('板卡串口');self.port.setToolTip('板卡串口 · 115200 / 8N1，按 F5 刷新设备')
        self.port.setMinimumWidth(220);header.addWidget(self.port,2)
        self.device=QComboBox();self.device.setAccessibleName('视频采集设备');self.device.setPlaceholderText('选择 HDMI USB 采集卡')
        self.device.setToolTip('视频采集设备，按 F5 刷新设备');self.device.setMinimumWidth(320);header.addWidget(self.device,4)
        self.port.currentIndexChanged.connect(self.selection_changed)
        self.device.currentIndexChanged.connect(self.selection_changed)
        self.refresh_button=QPushButton(root);self.refresh_button.setToolTip('刷新设备（F5）')
        self.refresh_button.clicked.connect(self.refresh);self.refresh_button.hide()
        self.connect_button=QPushButton('连接设备');self.connect_button.clicked.connect(self.connect_devices)
        header.addWidget(self.connect_button)
        self.state_label=QLabel('未连接');self.state_label.setObjectName('state');header.addWidget(self.state_label)

        toolbar_card=QFrame();toolbar_card.setObjectName('toolbar');main.addWidget(toolbar_card)
        toolbar=QHBoxLayout(toolbar_card);toolbar.setContentsMargins(11,8,11,8);toolbar.setSpacing(8)
        self.buttons=[]
        for i,(label,mode) in enumerate([('720P 裁剪图像',720),('1080P 完整图像',1080),('结束采集',None)]):
            button=QPushButton(label);button.setObjectName('stop' if mode is None else '')
            button.clicked.connect(lambda _,m=mode:self.select(m));self.buttons.append(button)
            if mode is None:continue
            toolbar.addWidget(button)
        self.gamma=QPushButton('自适应 Gamma：待确认');self.gamma.setObjectName('gamma')
        self.gamma.clicked.connect(self.toggle_gamma);toolbar.addWidget(self.gamma)
        self.calibrate_button=QPushButton('生成矫正系数')
        self.calibrate_button.clicked.connect(self.open_calibration);toolbar.addWidget(self.calibrate_button)
        toolbar.addWidget(QLabel('显示方式'))
        self.view_mode=QComboBox();self.view_mode.setMinimumWidth(120);self.view_mode.setMaximumWidth(150)
        self.view_mode.addItem('左右对比','compare');self.view_mode.addItem('仅原图','raw');self.view_mode.addItem('仅矫正图','corrected')
        self.view_mode.currentIndexChanged.connect(self.apply_view_mode);toolbar.addWidget(self.view_mode)
        self.fullscreen_current=QPushButton('全屏显示');self.fullscreen_current.setObjectName('fullscreen')
        self.fullscreen_current.setToolTip('将当前显示方式铺满整个屏幕，按 Esc 返回')
        self.fullscreen_current.clicked.connect(self.open_current_fullscreen);toolbar.addWidget(self.fullscreen_current);toolbar.addStretch()
        toolbar.addWidget(self.buttons[2])

        self.status=QLabel('请选择板卡串口和 HDMI USB 采集卡，点击连接设备；板上需运行 V15 位流。');self.status.setObjectName('message')
        self.status.setWordWrap(True);main.addWidget(self.status)
        self.gamma_status=QLabel('Gamma 状态待确认');self.gamma_status.hide()
        self.pan_card=QFrame();self.pan_card.setObjectName('toolbar');main.addWidget(self.pan_card)
        pan_row=QHBoxLayout(self.pan_card);pan_row.setContentsMargins(11,5,11,5)
        pan_row.addWidget(QLabel('720P 虚拟水平转向'))
        self.pan_input=QDoubleSpinBox();self.pan_input.setRange(-30,30);self.pan_input.setDecimals(1)
        self.pan_input.setSingleStep(1);self.pan_input.setSuffix('°');self.pan_input.setKeyboardTracking(False)
        self.pan_input.setToolTip('负数向左，正数向右。仅调整 FPGA 矫正分支；实际角度受标定范围限制。')
        pan_row.addWidget(self.pan_input);self.pan_buttons=[]
        for label,callback in [('左 5°',lambda:self.request_pan(self.pan_input.value()-5)),
                               ('应用角度',lambda:self.request_pan(self.pan_input.value())),
                               ('右 5°',lambda:self.request_pan(self.pan_input.value()+5)),
                               ('恢复 0°',lambda:self.request_pan(0))]:
            button=QPushButton(label);button.clicked.connect(callback);pan_row.addWidget(button);self.pan_buttons.append(button)
        self.pan_label=QLabel('角度待确认');pan_row.addWidget(self.pan_label,1)

        self.pages=QStackedWidget();main.addWidget(self.pages,1)
        self.video_page=QWidget();self.pages.addWidget(self.video_page)
        previews=QHBoxLayout(self.video_page);previews.setContentsMargins(0,0,0,0);previews.setSpacing(10)
        self.panels={};self.image_titles={};self.video_cards={};self.fullscreen_buttons={}
        for kind,title in [('raw','未矫正画面'),('corrected','矫正画面')]:
            card=QFrame();card.setObjectName('videoCard');previews.addWidget(card,1);self.video_cards[kind]=card
            col=QVBoxLayout(card);col.setContentsMargins(10,9,10,10);col.setSpacing(6)
            heading_row=QHBoxLayout();col.addLayout(heading_row)
            heading_row.addWidget(QLabel(title));heading_row.addStretch()
            resolution=QLabel();resolution.setObjectName('sub');heading_row.addWidget(resolution);self.image_titles[kind]=resolution
            full=QPushButton('全屏');full.setObjectName('fullscreen');full.clicked.connect(lambda _,k=kind:self.open_fullscreen(k))
            heading_row.addWidget(full);self.fullscreen_buttons[kind]=full
            self.panels[kind]=Preview();col.addWidget(self.panels[kind],1)

        self.latency_details=QFrame();self.latency_details.setObjectName('latencyDetails');self.latency_details.setVisible(False)
        detail=QGridLayout(self.latency_details);detail.setContentsMargins(14,8,14,8);detail.setHorizontalSpacing(20);detail.setVerticalSpacing(4)
        main.addWidget(self.latency_details);self.metrics={}
        for key,label in [('fpga','FPGA 处理 · ms'),('host','上位机处理 · ms'),('queue','处理队列等待 · ms'),('preview','预览等待 · ms')]:
            column=len(self.metrics);name=QLabel(label);name.setObjectName('sub');value=QLabel('—');value.setObjectName('metric')
            detail.addWidget(name,0,column);detail.addWidget(value,1,column);self.metrics[key]=value
        self.latency_note=QLabel('FPGA：开始处理到校正帧提交；其余为主机本地计时，均非摄像头到屏幕的端到端延时。')
        self.latency_note.setObjectName('sub');self.latency_note.setWordWrap(True);detail.addWidget(self.latency_note,2,0,1,4)

        footer=QFrame();footer.setObjectName('footer');main.addWidget(footer)
        foot=QHBoxLayout(footer);foot.setContentsMargins(14,5,12,5);foot.setSpacing(15)
        self.stats=QLabel('原图 0.0 fps　　矫正 0.0 fps　　异常 0');self.stats.setObjectName('footerText');foot.addWidget(self.stats)
        self.health=QLabel();self.health.hide();foot.addStretch()
        self.latency_toggle=QPushButton('总延时 —');self.latency_toggle.setObjectName('latency')
        self.latency_toggle.clicked.connect(self.toggle_latency_details);foot.addWidget(self.latency_toggle)

        # Secondary functions remain available without occupying permanent space.
        self.same=QCheckBox(root);self.same.setChecked(True);self.same.hide()
        self.save_button=QPushButton(root);self.save_button.hide()
        self.capture_folder=Path(self.settings.value('capture_folder',str(self.root/'captures_v15')))
        for sequence,slot in [('F5',self.refresh),('F11',self.open_current_fullscreen),('Ctrl+S',self.save),('Ctrl+Shift+S',self.choose_folder)]:
            action=QAction(self);action.setShortcut(QKeySequence(sequence));action.triggered.connect(slot);self.addAction(action)
        self.update_connection_controls()

    def open_calibration(self):
        if not self.connection.ready:return
        if self.calibration_dialog is not None and self.pages.currentWidget() is not self.video_page:
            self.show_preview();return
        if self.calibration_dialog is None:
            self.calibration_page=QWidget(self.pages)
            self.calibration_page.setObjectName('calibrationPage')
            self.calibration_page.setAttribute(Qt.WidgetAttribute.WA_StyledBackground,True)
            calibration_layout=QVBoxLayout(self.calibration_page)
            calibration_layout.setContentsMargins(0,0,0,0);calibration_layout.setSpacing(10)
            self.calibration_scroll=QScrollArea(self.calibration_page)
            self.calibration_scroll.setWidgetResizable(True)
            self.calibration_scroll.setFrameShape(QFrame.Shape.NoFrame)
            self.calibration_scroll.setStyleSheet('QScrollArea, QScrollArea > QWidget {background:#f3f6fa;}')
            self.calibration_dialog=CalibrationDialog(self.root/'calibrations',self.calibration_scroll)
            self.calibration_dialog.upload_requested.connect(self.upload_calibration)
            self.calibration_scroll.setWidget(self.calibration_dialog)
            self.calibration_page.setStyleSheet(self.calibration_dialog.styleSheet())
            self.calibration_page.setPalette(self.calibration_dialog.palette())
            calibration_layout.addWidget(self.calibration_scroll,1)
            self.calibration_footer=self.calibration_dialog.commit_footer
            calibration_layout.addWidget(self.calibration_footer)
            self.pages.addWidget(self.calibration_page)
        self.calibration_dialog.set_active_parameters(self.connection.calibration)
        self.fullscreen_view.hide()
        self.pages.setCurrentWidget(self.calibration_page)
        self.calibrate_button.setText('返回画面')
        self.update_connection_controls()

    def show_preview(self):
        self.pages.setCurrentWidget(self.video_page)
        self.calibrate_button.setText('生成矫正系数')
        self.update_connection_controls()

    def update_connection_controls(self):
        ready=self.connection.ready and self.serial.isOpen() and not self.calibration_uncertain
        available=ready and not self.control.busy and not self.uploader.busy and not self.pan.busy and not (self.pan_check and self.pan_check.isRunning())
        self.connect_button.setEnabled(
            not self.connection.pending and not self.control.busy and not self.uploader.busy
            and self.control.state!=State.RUNNING and self.control.gamma_pending is None
            and bool(self.port.currentData()) and bool(self.device.currentData()))
        self.connect_button.setText('重新验证' if ready else '连接设备')
        for index,mode in enumerate((720,1080)):
            self.buttons[index].setEnabled(available and mode in self.connection.modes
                                           and self.control.gamma_pending is None)
        self.buttons[2].setEnabled(available and self.control.state==State.RUNNING)
        self.gamma.setEnabled(available and self.control.gamma_pending is None
                              and self.control.state in (State.STOPPED,State.RUNNING))
        self.calibrate_button.setEnabled(available)
        on_video_page=self.pages.currentWidget() is self.video_page
        if hasattr(self,'calibration_scroll'):
            worker=self.calibration_dialog.worker
            self.calibration_scroll.setEnabled(available and not (worker and worker.isRunning()))
            self.calibration_footer.setEnabled(available and not (worker and worker.isRunning()))
        pan_visible=on_video_page and (self.control.mode or self.pending_mode)==720 and self.view_mode.currentData()!='raw'
        self.pan_card.setVisible(pan_visible)
        can_pan=available and self.control.state==State.RUNNING and self.control.gamma_pending is None and bool(self.connection.calibration and self.connection.calibration.flags)
        self.pan_input.setEnabled(can_pan)
        for button in self.pan_buttons:button.setEnabled(can_pan)
        if not self.connection.calibration or not self.connection.calibration.flags:
            self.pan_label.setText('需要先写入有效镜头标定参数；默认直通模式不转向')
        self.view_mode.setEnabled(ready and on_video_page)
        self.fullscreen_current.setEnabled(ready and on_video_page)
        for button in self.fullscreen_buttons.values():button.setEnabled(ready)
        self.latency_toggle.setEnabled(ready)
        for widget in (self.port,self.device,self.refresh_button):
            widget.setEnabled(not self.connection.pending and not self.control.busy
                              and self.control.state!=State.RUNNING and not self.uploader.busy)

    def connection_changed(self):
        if self.connection.ready:
            self.pan_applied=0;self.pan_input.setValue(0);self.pan_label.setText('已连接 · 720P 启动后角度 0°')
            modes='、'.join(f'{mode}P60' for mode in sorted(self.connection.modes))
            if self.connection.message.startswith('板卡已重新确认'):
                self.status.setText(self.connection.message)
            else:
                self.status.setText(f'设备已连接：V15、DDR、摄像头和 HDMI 状态正常；采集卡列出 {modes}。请选择采集模式。')
            self.state_label.setText('已连接')
        elif self.connection.pending:
            self.status.setText(self.connection.message)
            self.state_label.setText('连接中')
        else:
            self.status.setText(self.connection.message)
            self.state_label.setText('未连接')
            if self.pages.currentWidget() is not self.video_page:self.show_preview()
            if self.serial.isOpen() and not self.control.busy and self.control.state!=State.RUNNING:
                self.serial.close()
        self.status.setVisible(True)
        self.update_connection_controls()

    def selection_changed(self,*_):
        if self._refreshing_devices:return
        if self.connection.ready or self.connection.pending:
            self.connection.invalidate('设备选择已变化，请点击连接设备重新验证')
            self.connection_changed()

    def connect_devices(self):
        if (self.control.busy or self.uploader.busy or self.control.state==State.RUNNING
                or self.control.gamma_pending is not None):return
        self.connection.invalidate('正在检查设备…')
        try:
            port=self.port.currentData();selected_id=self.device.currentData()
            device=next((d for d in QMediaDevices.videoInputs() if device_id(d)==selected_id),None)
            if device is None:raise RuntimeError('未选择有效 HDMI USB 采集卡')
            modes={mode for mode in (720,1080) if compatible_formats(device,mode)}
            if not modes:raise RuntimeError('所选采集卡未列出 720P60 或 1080P60 格式')
            self.connect_serial()
            self.serial.clear(QSerialPort.Direction.Input)
            self.connection.begin(port,selected_id,modes,self.send)
        except Exception as exc:
            self.connection.invalidate('设备连接失败：'+str(exc))
        self.connection_changed()

    def calibration_status(self,message):
        self.trace.info('CALIBRATION %s',message)
        self.status.setText(message);self.status.setVisible(True)
        if self.calibration_dialog is not None:
            self.calibration_dialog.set_upload_status(message)

    def upload_calibration(self,run):
        if not self.connection.ready or not self.serial.isOpen():
            self.calibration_status('设备尚未连接成功，请先连接板卡和采集卡');return
        if not run.passed or not run.packet:
            self.calibration_status('标定质量门未通过，不能写入 FPGA');return
        if self.uploader.busy or self.calibration_uncertain or self.control.busy or self.control.gamma_pending is not None:
            self.calibration_status('正在执行其他控制事务，暂时不能更新系数');return
        try:
            self.connect_serial()
            self.serial.clear(QSerialPort.Direction.Input)
            self.calibration_run=run
            self.calibration_updating=True
            self.pipeline.reset(self.control.epoch,self.control.mode or 720)
            for panel in self.panels.values():panel.assign(None,(1280,720))
            self.uploader.start(run.packet)
        except Exception as exc:
            self.calibration_updating=False
            if not self.serial.isOpen():
                self.connection.invalidate('板卡串口已断开，请重新连接设备')
                self.connection_changed()
            self.calibration_status('无法开始写入：'+str(exc))

    def calibration_finished(self,result:UploadResult):
        self.calibration_updating=False
        self.calibration_uncertain=result.uncertain
        saved_message=''
        if result.success and self.calibration_run is not None:
            self.connection.calibration=CalibrationPacket.unpack(result.packet).calibration
            if self.calibration_dialog is not None:
                self.calibration_dialog.set_active_parameters(self.connection.calibration)
            self.pan_applied=0;self.pan_input.setValue(0);self.pan_label.setText('新系数已生效，转向恢复 0°')
            try:
                import hashlib
                folder=self.calibration_run.output_directory
                (folder/'fpga_coefficients_sent_v15.bin').write_bytes(result.packet)
                (folder/'upload_result.json').write_text(json.dumps({
                    'success':True,'sequence':result.sequence,
                    'sha256':hashlib.sha256(result.packet).hexdigest(),
                    'completed_at':datetime.now().isoformat(),
                },ensure_ascii=False,indent=2),encoding='utf-8')
            except OSError as exc:
                saved_message=f'；FPGA 已确认写入，但本地回执保存失败：{exc}'
                self.trace.exception('CALIBRATION_RECEIPT_WRITE_FAILED')
        self.pipeline.reset(self.control.epoch,self.control.mode or 720)
        for panel in self.panels.values():panel.assign(None,(1280,720))
        self.calibration_status(
            result.message+saved_message+
            ('；状态未确认，请重启板卡后重新连接' if result.uncertain else '')
        )
        if self.calibration_dialog is not None:
            self.calibration_dialog.set_upload_status(result.message,finished=not result.uncertain)

    def toggle_latency_details(self):
        shown=not self.latency_details.isVisible();self.latency_details.setVisible(shown)
        self.latency_toggle.setProperty('expanded',shown)

    def apply_view_mode(self):
        mode=self.view_mode.currentData() or 'compare'
        self.video_cards['raw'].setVisible(mode in ('compare','raw'))
        self.video_cards['corrected'].setVisible(mode in ('compare','corrected'))

    def open_fullscreen(self,kind):
        if not self.connection.ready:return
        self.fullscreen_view.show_kind(kind)

    def open_current_fullscreen(self):
        if not self.connection.ready or self.pages.currentWidget() is not self.video_page:return
        self.fullscreen_view.show_mode(self.view_mode.currentData() or 'compare')

    @staticmethod
    def set_selected(widget,value,property_name='selected'):
        value=bool(value)
        if widget.property(property_name)==value:return
        widget.setProperty(property_name,value);widget.style().unpolish(widget);widget.style().polish(widget)

    def notify(self,text):
        self.trace.info('STATE %s %s',self.control.state.name,text)
        text={'WAIT_STOP':'正在停止并清除旧会话…','WAIT_MODE':'正在切换 HDMI 时序…','WAIT_START':'等待 FPGA 首组新图像…'}.get(text,text)
        self.status.setText(text);self.status.setVisible(True)

    def refresh(self):
        if self.control.busy or self.control.state==State.RUNNING:return
        if self.connection.pending:
            self.connection.invalidate('设备列表已刷新，请重新连接')
            self.connection_changed()
        previous=self.port.currentData() or self.settings.value('port','COM18')
        self._refreshing_devices=True
        try:
            self.port.clear()
            ports=QSerialPortInfo.availablePorts()
            for p in ports:self.port.addItem(p.portName()+' · '+p.description(),p.portName())
            preferred_port=preferred_board_port(ports,previous)
            self.port.setCurrentIndex(self.port.findData(preferred_port) if preferred_port else -1)
            preferred=self.device.currentData()
            devices=QMediaDevices.videoInputs()
            if preferred is None:
                saved=self.settings.value('device','')
                if any(device_id(d)==saved for d in devices):preferred=saved
            self.device.clear()
            for d in devices:self.device.addItem(device_label(d),device_id(d))
            selected=choose_device(devices,preferred)
            self.device.setCurrentIndex(self.device.findData(selected) if selected else -1)
        finally:self._refreshing_devices=False
        if (self.connection.ready and not self.connection.matches(
                self.port.currentData(),self.device.currentData(),self.serial.isOpen())):
            self.connection.invalidate('已连接设备不在当前设备列表中，请重新选择并连接')
            self.connection_changed()
        else:self.update_connection_controls()

    def devices_changed(self):
        if (self.connection.ready or self.connection.pending) and self.connection.device not in {
                device_id(d) for d in QMediaDevices.videoInputs()}:
            if self.control.state==State.RUNNING:self.control.fail('采集卡已断开')
            self.connection.invalidate('采集卡已断开，请重新选择并连接')
            self.connection_changed()
        if self.control.busy or self.control.state==State.RUNNING:
            if self.selected_capture_id and not any(device_id(d)==self.selected_capture_id for d in QMediaDevices.videoInputs()):
                self.control.fail('采集卡已断开');self.refresh()
        else:self.refresh()

    def connect_serial(self):
        port=self.port.currentData()
        if not port:raise RuntimeError('未选择板卡串口')
        if self.serial.isOpen() and self.serial.portName()!=port:self.serial.close()
        if not self.serial.isOpen():
            self.serial.setPortName(port)
            if not self.serial.open(QIODevice.OpenModeFlag.ReadWrite):raise RuntimeError(self.serial.errorString())
            self.trace.info('OPEN %s 115200 8N1',port)
        self.settings.setValue('port',port)

    def send(self,payload):
        if not self.serial.isOpen() or self.serial.write(payload)!=len(payload):raise RuntimeError('串口发送失败')
        self.trace.info('TX_QUEUED %s %s',self.control.state.name,payload.hex(' ').upper())

    def serial_received(self):
        data=bytes(self.serial.readAll())
        self.trace.info('RX %s %s',self.control.state.name,data.hex(' ').upper())
        if self.connection.pending:
            if self.connection.receive(data):
                if self.connection.ready:
                    self.control.confirm_external_stop()
                    if self.uploader.reconcile_after_board_handshake():
                        self.calibration_uncertain=False
                        self.connection.message=(
                            '板卡已重新确认处于停止状态；上次系数写入结果未确认，'
                            '再次写入前将读取 EEPROM 当前序号')
                self.connection_changed()
            return
        if self.pan.busy:self.pan.receive(data)
        elif self.uploader.busy:self.uploader.receive(data)
        else:self.control.receive(data)

    def select(self,mode):
        if not self.connection.ready or not self.serial.isOpen():return
        if mode and mode not in self.connection.modes:return
        if self.control.busy or self.uploader.busy or self.calibration_uncertain or self.pan.busy:return
        if mode and self.control.gamma_pending is not None:return
        try:
            if mode:
                device,_=resolve_format(QMediaDevices.videoInputs(),self.device.currentData(),mode)
                self.selected_capture_id=device_id(device);self.pending_mode=mode
                self.settings.setValue('device',self.selected_capture_id)
            self.connect_serial()
        except Exception as e:
            if self.control.state==State.RUNNING:self.control.fail('设备已断开：'+str(e))
            self.connection.invalidate('设备检查失败：'+str(e)+'；请重新连接设备')
            self.connection_changed();return
        if mode:self.show_preview()
        self.serial.clear(QSerialPort.Direction.AllDirections)
        self.control.select(mode) if mode else self.control.stop()
        self.pan_applied=None;self.pan_input.setValue(0);self.pan_label.setText('等待新会话确认，默认角度 0°')

    def request_pan(self,degrees):
        if (not self.connection.ready or not self.serial.isOpen() or self.pan.busy or self.control.busy
            or self.uploader.busy or self.control.state!=State.RUNNING or self.control.mode!=720
            or self.control.gamma_pending is not None or self.view_mode.currentData()=='raw'):return
        fixed=self.connection.calibration
        if fixed is None or not fixed.flags:return
        if self.pan_check and self.pan_check.isRunning():return
        angle=round(degrees*10)
        self.pan_label.setText(f'正在校验 {angle/10:+.1f}° 的采样与数值范围…')
        self.pan_check=PanValidationWorker(fixed,angle);self.pan_check.checked.connect(self.pan_checked)
        self.pan_check.start();self.update_connection_controls()

    def pan_checked(self,result):
        angle,error,fixed=result
        if (not self.connection.ready or self.connection.calibration!=fixed or
            self.control.state!=State.RUNNING or self.control.mode!=720 or self.closing):return
        if error:self.pan_label.setText('未发送：'+error);return
        self.pan_input.setValue(angle/10)
        self.pan_label.setText(f'请求 {angle/10:+.1f}°，等待 FPGA 目标帧确认…')
        self.pan.start(angle);self.update_connection_controls()

    def pan_finished(self,result):
        self.pan_label.setText(result.message)
        self.trace.info('PAN_RESULT %s',result)
        if result.success:self.pan_applied=result.angle_tenths
        elif result.uncertain:
            self.pan_applied=None
            self.control.fail(result.message)
            self.connection.invalidate(result.message+'；请重新连接设备。')
            self.connection_changed()
        self.update_connection_controls()

    def toggle_gamma(self):
        if not self.connection.ready or not self.serial.isOpen():return
        if self.uploader.busy or self.calibration_uncertain or self.pan.busy:return
        try:self.connect_serial()
        except Exception as e:
            self.connection.invalidate('板卡串口连接失败：'+str(e))
            self.connection_changed();return
        enabled=self.control.gamma_state
        if enabled is None and self.snapshot_data and self.snapshot_data['metadata']:
            enabled=self.snapshot_data['metadata']['gamma_on']
        self.control.gamma(not bool(enabled))

    def clear_session(self,epoch):
        if self.generation>=0:
            previous=self.pipeline.snapshot()
            self.trace.info('SESSION_END epoch=%s counts=%s prepare=%s error=%s',
                            previous['epoch'],previous['counts'],previous['prepare'],previous['error'])
        self.generation=-1
        if self.camera is not None:self.camera.stop();self.session.setCamera(None);self.camera.deleteLater();self.camera=None
        if self.session is not None:self.session.setVideoSink(None);self.session.deleteLater();self.session=None
        if self.sink is not None:self.sink.deleteLater();self.sink=None
        self.pipeline.reset(epoch,self.pending_mode)
        for panel in self.panels.values():panel.assign(None,(1280,720))
        if hasattr(self,'fullscreen_view'):
            for panel in self.fullscreen_view.previews.values():panel.assign(None,(1280,720))

    def prepare(self,mode,epoch):
        device,fmt=resolve_format(QMediaDevices.videoInputs(),self.selected_capture_id,mode)
        self.capture_pixel_format=fmt.pixelFormat().name
        self.trace.info('CAPTURE mode=%s epoch=%s device=%s format=%s',mode,epoch,device.description(),self.capture_pixel_format)
        self.pipeline.reset(epoch,mode);self.generation=epoch
        self.session=QMediaCaptureSession(self);self.sink=QVideoSink(self);self.session.setVideoSink(self.sink)
        # This callback only hands a shared frame to the bounded worker queue.
        # Direct delivery prevents an unbounded backlog of GUI-thread signals.
        self.sink.videoFrameChanged.connect(lambda frame,g=epoch:self.received(frame,g),Qt.ConnectionType.DirectConnection)
        self.camera=QCamera(device,self)
        self.camera.errorOccurred.connect(lambda error,text,g=epoch:self.camera_error(text,g))
        self.camera.setCameraFormat(fmt);self.session.setCamera(self.camera);self.camera.start()

    def received(self,frame,epoch):
        if (not self.calibration_updating and not self.calibration_uncertain and
            epoch==self.generation and epoch==self.control.epoch):
            self.pipeline.submit(QVideoFrame(frame),epoch,self.control.state.name)

    def tick(self):
        self.control.poll();self.uploader.poll();self.pan.poll()
        if self.connection.poll():self.connection_changed()
        elif self.connection.ready and self.control.state==State.ERROR:
            self.connection.invalidate(self.status.text()+' 请重新连接设备。')
            self.connection_changed()
        elif self.connection.ready and not self.connection.matches(
                self.port.currentData(),self.device.currentData(),self.serial.isOpen()):
            self.connection.invalidate('板卡串口或采集卡连接已变化，请重新连接设备')
            self.connection_changed()
        s=self.pipeline.snapshot();self.snapshot_data=s
        if self.control.state==State.PREPARE:
            info=s['prepare']
            self.status.setText(f'正在准备采集卡：收到 {s["counts"].get("received",0)} 帧；'
                                f'停止态画面确认 {min(info["blank_streak"],3)}/3')
            if time.perf_counter()-self.last_prepare_log>1:
                self.last_prepare_log=time.perf_counter()
                self.trace.info('PREPARE counts=%s detail=%s error=%s',s['counts'],info,s['error'])
        if s['epoch']==self.control.epoch and s['ready'] and self.control.state==State.PREPARE:self.control.capture_ready(s['epoch'])
        running=(self.control.state==State.RUNNING and not self.calibration_updating
                 and not self.calibration_uncertain);mode=self.control.mode or 720
        view_mode=self.view_mode.currentData() or 'compare'
        for kind,panel in self.panels.items():
            if panel.smooth:panel.smooth=False;panel.update()
            item=s['images'].get(kind) if running else None
            virtual=(1920,1080) if mode==1080 and (kind=='corrected' or (self.same.isChecked() and view_mode!='raw')) else (1280,720)
            panel.assign(item,virtual)
        if self.fullscreen_view.isVisible():
            for kind,panel in self.fullscreen_view.previews.items():
                item=s['images'].get(kind) if running else None
                if item is not None:virtual=(item['image'].width(),item['image'].height())
                else:virtual=(1920,1080) if mode==1080 and kind=='corrected' else (1280,720)
                panel.assign(item,virtual)
        self.update_connection_controls()
        self.set_selected(self.buttons[0],running and mode==720)
        self.set_selected(self.buttons[1],running and mode==1080)
        self.save_button.setEnabled(self.connection.ready and running and len(s['images'])==2 and not self.save_busy)
        if self.save_result is not None:
            self.notify(self.save_result);self.save_result=None
        if time.perf_counter()-self.last_info_update<.2:return
        self.last_info_update=time.perf_counter()
        self.state_label.setText(('720P' if mode==720 else '1080P')+' · 采集中' if running else
                                 ('连接中' if self.connection.pending else
                                  ('已连接' if self.connection.ready else '未连接')))
        meta=s['metadata'];counts=s['counts']
        observed=meta['gamma_on'] if meta else None
        confirmed=self.control.gamma_state
        gamma_on=confirmed if confirmed is not None else observed
        self.gamma.setText('自适应 Gamma：开启' if gamma_on else ('自适应 Gamma：关闭' if gamma_on is not None else '自适应 Gamma：待确认'))
        self.set_selected(self.gamma,gamma_on,'enabledState')
        text=self.control.gamma_message
        if meta:
            text+=f'  | 视频状态：{"开启" if observed else "关闭"} · γ={meta["gamma"]:.1f} · 平均亮度 {meta["mean"]} · 暗部 {meta["dark"]:.1f}% · 高亮 {meta["high"]:.1f}%'
        self.gamma_status.setText(text);self.gamma.setToolTip(text)
        fpga_value=meta['fpga_ms'] if meta and meta['cycles'] else None
        items=list(s['images'].values())
        host_value=max((i['host_ms'] for i in items),default=None)
        queue_value=max((i['queue_ms'] for i in items),default=None)
        waits=[p.wait_ms for kind,p in self.panels.items() if self.pages.currentWidget() is self.video_page and self.video_cards[kind].isVisible() and p.wait_ms is not None]
        preview_value=max(waits) if waits else None
        values=dict(fpga=fpga_value,host=host_value,queue=queue_value,preview=preview_value)
        for key,value in values.items():self.metrics[key].setText(f'{value:.2f}' if value is not None else '—')
        total=sum(values.values()) if all(value is not None for value in values.values()) else None
        detail_word='收起' if self.latency_details.isVisible() else '详情'
        self.latency_toggle.setText((f'总延时 {total:.1f} ms · ' if total is not None else '总延时 — · ')+detail_word)
        suffix=f'最近5秒 FPGA 平均 {s["fpga_avg"]:.2f} / 最大 {s["fpga_max"]:.2f} ms。' if s['fpga_avg'] is not None else '等待有效 V15 延时信息。'
        self.latency_note.setText(suffix+' 总延时为四个当前分项之和，用于同一系统内对比；不代表摄像头曝光到显示器发光的端到端延时。')
        abnormal=sum(counts.get(key,0) for key in ('size_mismatch','marker_failure','empty','metadata_invalid','processing_error'))
        self.stats.setText(f'原图 {s["fps"]["raw"]:.1f} fps　　矫正 {s["fps"]["corrected"]:.1f} fps　　异常 {abnormal}')
        warning=''
        if running and time.perf_counter()-self.pipeline.started>7:
            if sum(s['fps'].values())<50 or any(s['fps'][k]<20 for k in ('raw','corrected')):warning='采集未稳定达到两类各约30fps；请检查采集卡与处理耗时。'
        if meta and meta.get('layout')=='v9_two_rows_16px':warning+='检测到旧版双排标记；请下载 V15 位流以启用 4 像素单条。'
        capture_format=getattr(self,'capture_pixel_format','未启动')
        health=warning+f'采集格式 {capture_format} · 队列 {s["queue"]}/3 · 过期帧丢弃 {counts.get("backlog_drop",0)} · 状态信息失败 {counts.get("metadata_invalid",0)}'
        health+=(f' · 处理错误：{s["error"]}' if s['error'] else '')+(f' · 保存错误：{s["diagnostic_error"]}' if s['diagnostic_error'] else '')
        self.health.setText(health);self.stats.setToolTip(health)
        if warning:
            self.status.setText(warning);self.status.setVisible(True)
        elif running and self.control.gamma_pending is None:self.status.setVisible(False)
        self.image_titles['raw'].setText(f'1280 × 720 · {s["fps"]["raw"]:.1f} fps')
        self.image_titles['corrected'].setText(('1920 × 1080' if mode==1080 else '1280 × 720')+f' · {s["fps"]["corrected"]:.1f} fps')

    def choose_folder(self):
        selected=QFileDialog.getExistingDirectory(self,'选择截图目录',str(self.capture_folder))
        if selected:self.capture_folder=Path(selected);self.settings.setValue('capture_folder',selected)

    def save(self):
        if not self.connection.ready:return
        s=self.pipeline.snapshot()
        if len(s['images'])!=2 or self.save_busy:return
        self.save_busy=True
        folder=self.capture_folder/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        def write():
            try:
                folder.mkdir(parents=True)
                meta={}
                for kind,name in [('raw','original_left.png'),('corrected','corrected_right.png')]:
                    item=s['images'][kind]
                    if not item['image'].save(str(folder/name)):raise OSError('图像保存失败')
                    meta[kind]=item['meta']
                (folder/'metadata.json').write_text(json.dumps(dict(application='ShowTime V15',protocol='V15-RGB565',capture_pixel_format=getattr(self,'capture_pixel_format',None),frames=meta,same_exposure_guaranteed=False),ensure_ascii=False,indent=2),encoding='utf-8')
                self.save_result='已保存：'+str(folder)
            except Exception as exc:self.save_result='保存失败：'+str(exc)
            finally:self.save_busy=False
        threading.Thread(target=write,name='save-images',daemon=False).start()

    def camera_error(self,text,epoch):
        if epoch==self.generation:self.control.fail('采集卡错误：'+text)
    def serial_error(self,error):
        if error!=QSerialPort.SerialPortError.NoError:self.trace.warning('SERIAL_ERROR %s %s',error.name,self.serial.errorString())
        if error in (QSerialPort.SerialPortError.ResourceError,QSerialPort.SerialPortError.DeviceNotFoundError) and self.uploader.busy:
            self.uploader.abort_transport('串口断开：'+self.serial.errorString())
        if error in (QSerialPort.SerialPortError.ResourceError,QSerialPort.SerialPortError.DeviceNotFoundError) and self.control.state not in (State.STOPPED,State.ERROR):
            self.control.fail('串口断开：'+self.serial.errorString())
        if error in (QSerialPort.SerialPortError.ResourceError,QSerialPort.SerialPortError.DeviceNotFoundError) and (self.connection.ready or self.connection.pending):
            self.connection.invalidate('板卡串口已断开，请重新连接设备')
            self.connection_changed()
    def closeEvent(self,event):
        if self.pan_check and self.pan_check.isRunning():
            event.ignore();self.pan_label.setText('正在完成参数校验，请稍后关闭');return
        if self.pan.busy:
            event.ignore();self.pan_label.setText('转向确认尚未完成，请等待应答或超时后关闭');return
        if self.calibration_dialog is not None and self.calibration_dialog.worker and self.calibration_dialog.worker.isRunning():
            event.ignore();self.calibration_status('标定计算正在运行，请等待完成后再关闭');return
        if self.uploader.busy:
            event.ignore();self.calibration_status('EEPROM 更新尚未完成，请等待 FPGA 应答后再关闭');return
        if self.calibration_uncertain and self.serial.isOpen():
            self.serial.close()
        if self.close_done.is_set():
            self.fullscreen_view.close()
            self.trace.info('CLOSE');self.trace.removeHandler(self.trace_handler);self.trace_handler.close()
            event.accept();return
        event.ignore()
        if self.closing:return
        self.fullscreen_view.hide()
        self.closing=True;self.timer.stop();self.centralWidget().setEnabled(False)
        if self.serial.isOpen():self.serial.write(b'\x68\x68');self.serial.waitForBytesWritten(100)
        self.clear_session(self.control.epoch);self.serial.close()
        # Drain the Qt-owned video worker without blocking window event handling.
        def cleanup():
            try:
                self.pipeline.close()
            finally:self.close_done.set()
        threading.Thread(target=cleanup,name='capture-shutdown',daemon=True).start()
        self.close_timer=QTimer(self);self.close_timer.setInterval(20)
        def completed():
            if self.close_done.is_set():self.close_timer.stop();self.close()
        self.close_timer.timeout.connect(completed);self.close_timer.start()


def main():
    if '--self-test' in sys.argv:
        from selftest_v15 import run
        return run()
    if '--hardware-check' in sys.argv:
        from hardware_check_v15 import run
        return run()
    app=QApplication(sys.argv);app.setFont(QFont('Microsoft YaHei',10))
    w=Viewer();w.showMaximized();return app.exec()


if __name__=='__main__':sys.exit(main())
