"""V15 quality gates around the existing chessboard detection/calibration engine."""
import json
from dataclasses import asdict
from calibration_engine_base import CalibrationRun,CalibrationSettings,discover_images,run_calibration as _run
from calibration_protocol import CalibrationPacket
from calibration_validation_v15 import validate_runtime_geometry
from calibration_math import FloatCalibration,derive_full_view_output,validate_for_fpga

def run_calibration(paths,output,settings,progress=None):
    run=_run(paths,output,settings,progress=progress)
    return finish_validation(run)

def finish_validation(run):
    """Apply V15 geometry gates to a completed chessboard fit."""
    report=run.report
    report.update(application='ShowTime V15',source='chessboard',model='Brown4 (k1,k2,p1,p2)')
    packet=run.packet
    if run.passed:
        fixed=CalibrationPacket.unpack(packet).calibration
        k=report['K'];d=report['distortion']
        cal=FloatCalibration(k[0][0],k[1][1],k[0][2],k[1][2],*d[:4])
        hardware=validate_for_fpga(cal,fixed,derive_full_view_output(cal),cache_lines=112)
        report['hardware_validation']=asdict(hardware)
        report['gate_warnings']=list(hardware.warnings)
        report.setdefault('gate_errors',[]).extend(hardware.errors)
        exact=validate_runtime_geometry(fixed)
        report['runtime_geometry']=exact
        if not exact['passed']:
            report.setdefault('gate_errors',[]).extend(exact['errors']);packet=b''
    passed=run.passed and not report.get('gate_errors')
    if not passed:packet=b''
    report['passed']=passed
    (run.output_directory/'v15_validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    return CalibrationRun(run.output_directory,passed,report,packet)
