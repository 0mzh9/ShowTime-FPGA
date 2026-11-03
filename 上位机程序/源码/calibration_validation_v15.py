"""Check valid source pixels against the actual staged fixed-point arithmetic."""
import numpy as np
from calibration_math import FloatCalibration
from pan_math_v15 import fixed_brown,project,validate_angle

def float_from_fixed(f):
    return FloatCalibration(*(getattr(f,n+'_q12')/4096 for n in ('fx','fy','cx','cy')),
                            *(getattr(f,n+'_q30')/(1<<30) for n in ('k1','k2','p1','p2')))

def validate_runtime_geometry(f):
    if not f.flags:return {'passed':True,'errors':[],'maximum_error_px':0.,'active_overflow_pixels':0}
    cal=float_from_fixed(f);u=np.arange(1920,dtype=np.int64)
    dx=(u<<12)-f.out1080_cx_q12
    x=(dx*f.inv_fx_q40+(1<<27))>>28
    xf=(u-f.out1080_cx_q12/4096)/cal.fx
    errors=[];overflows=0;max_error=0.
    for v in range(1080):
        dy=(v<<12)-f.out1080_cy_q12
        y=np.int64((dy*f.inv_fy_q40+(1<<27))>>28)
        sx,sy,bad=fixed_brown(cal,x,y)
        yf=(v-f.out1080_cy_q12/4096)/cal.fy
        r2=xf*xf+yf*yf;rad=1+cal.k1*r2+cal.k2*r2*r2
        ex=cal.fx*(xf*rad+2*cal.p1*xf*yf+cal.p2*(r2+2*xf*xf))+cal.cx
        ey=cal.fy*(yf*rad+cal.p1*(r2+2*yf*yf)+2*cal.p2*xf*yf)+cal.cy
        active=(ex>-1)&(ex<1280)&(ey>-1)&(ey<720)
        bad|=(dx<-(1<<23))|(dx>=(1<<23))|(dy<-(1<<23))|(dy>=(1<<23))
        overflows+=int(np.count_nonzero(bad&active))
        if np.any(active):max_error=max(max_error,float(np.max(np.maximum(abs(sx[active]/4096-ex[active]),abs(sy[active]/4096-ey[active])))))
    if overflows:errors.append(f'1080P 有 {overflows} 个有效图像像素超出 FPGA 定点范围')
    if max_error>.01:errors.append(f'1080P 定点流水线误差 {max_error:.5f}px 超过 0.01px')
    pan=validate_angle(cal,0)
    if not pan.passed:errors.extend('720P 0°：'+e for e in pan.errors)
    return {'passed':not errors,'errors':errors,'maximum_error_px':max_error,'active_overflow_pixels':overflows}
