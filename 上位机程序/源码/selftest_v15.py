"""Portable executable smoke test. Never opens UART, camera, or EEPROM."""
import json,os,sys,struct
from pathlib import Path

def run():
    os.environ['QT_QPA_PLATFORM']='offscreen'
    report={'version':'V15','passed':False,'checks':{}}
    try:
        import cv2,numpy
        from PySide6.QtWidgets import QApplication
        from viewer_v15 import Viewer
        from calibration_dialog_v15 import CalibrationDialog
        from calibration_protocol import CalibrationPacket,identity_factory_calibration
        from device_connection_v15 import DeviceConnection
        from pan_control_v15 import PanControl,crc16
        from pan_math_v15 import rays_fixed
        app=QApplication.instance() or QApplication([])
        packet=CalibrationPacket(0,identity_factory_calibration()).pack()
        assert CalibrationPacket.unpack(packet).calibration.flags==0
        report['checks']['calibration_protocol']=True
        sent=[];results=[];pan=PanControl(sent.append,results.append);pan.start(-50);pan.receive(b'\x0c\xc0')
        body=struct.pack('>HHhI',0xdc15,1,-50,99);reply=body+struct.pack('>H',crc16(body))
        for b in reply:pan.receive(bytes([b]))
        assert results[0].success and results[0].angle_tenths==-50
        report['checks']['pan_protocol']=True
        rays_fixed(100,numpy.arange(1280),359)
        viewer=Viewer(offline=True);viewer.timer.stop()
        assert not viewer.buttons[0].isEnabled() and not viewer.pan_input.isEnabled()
        dialog=CalibrationDialog(viewer.root/'selftest_calibration')
        dialog.set_active_parameters(identity_factory_calibration());dialog.load_current()
        assert dialog.fields['fx'].text() and not dialog.upload_button.isEnabled()
        dialog.deleteLater()
        viewer.pipeline.close();viewer.close_done.set();viewer.close();app.processEvents()
        report['checks'].update(gui_offline_gate=True,manual_editor=True,opencv=cv2.__version__,numpy=numpy.__version__)
        report['passed']=True
    except Exception as exc:report['error']=repr(exc)
    if '--report' in sys.argv:
        path=Path(sys.argv[sys.argv.index('--report')+1]);path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False));return 0 if report['passed'] else 1
