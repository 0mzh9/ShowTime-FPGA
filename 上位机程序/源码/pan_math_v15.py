"""720P virtual camera geometry. Used for validation, never live video rendering.

Positive angles look right in a camera coordinate system with x right, y down.
The FPGA uses the same 70-degree rectilinear output camera and Brown4 model.
"""
from dataclasses import dataclass, asdict
import math
import numpy as np

WIDTH, HEIGHT = 1280, 720
HFOV_DEG = 70.0
FOCAL = WIDTH / (2 * math.tan(math.radians(HFOV_DEG / 2)))
CX, CY = (WIDTH - 1) / 2, (HEIGHT - 1) / 2
MAX_ANGLE_TENTHS = 300
X_STEP_Q30 = round((1 << 30) / FOCAL)
X_FIRST_Q30 = round(-CX / FOCAL * (1 << 30))
Y_HALF_STEP_Q30 = round((1 << 30) / (2 * FOCAL))

def rays(angle_tenths, u, v):
    if not -MAX_ANGLE_TENTHS <= angle_tenths <= MAX_ANGLE_TENTHS:
        raise ValueError("angle outside FPGA limits")
    theta = math.radians(angle_tenths / 10)
    x, y = (np.asarray(u) - CX) / FOCAL, (np.asarray(v) - CY) / FOCAL
    z = math.cos(theta) - math.sin(theta) * x
    return (math.cos(theta) * x + math.sin(theta)) / z, y / z

def project(cal, angle_tenths, u, v):
    x, y = rays(angle_tenths, u, v)
    r2 = x*x + y*y
    radial = 1 + cal.k1*r2 + cal.k2*r2*r2
    xd = x*radial + 2*cal.p1*x*y + cal.p2*(r2+2*x*x)
    yd = y*radial + cal.p1*(r2+2*y*y) + 2*cal.p2*x*y
    return cal.fx*xd + cal.cx, cal.fy*yd + cal.cy

def column_fixed(angle_tenths):
    """Exact integer operations in pan_column_table; signed Q24 outputs."""
    theta = math.radians(angle_tenths / 10)
    s, c = round(math.sin(theta)*(1 << 22)), round(math.cos(theta)*(1 << 22))
    x = (X_FIRST_Q30 + np.arange(WIDTH, dtype=np.int64)*X_STEP_Q30 + 32) >> 6
    xn = ((x*c + (1 << 21)) >> 22) + (s << 2)
    zn = (c << 2) - ((x*s + (1 << 21)) >> 22)
    reciprocal = (1 << 48) // zn
    normalized_x = (xn*reciprocal + (1 << 23)) >> 24
    return normalized_x, reciprocal

def rays_fixed(angle_tenths, u, v):
    x, q = column_fixed(angle_tenths)
    u = np.asarray(u, dtype=np.int64)
    y = ((2*np.asarray(v, dtype=np.int64)-719)*Y_HALF_STEP_Q30 + 32) >> 6
    return x[u], (y*q[u] + (1 << 23)) >> 24

def fixed_project(cal,angle_tenths,u,v):
    x,y=rays_fixed(angle_tenths,u,v)
    return fixed_brown(cal,x,y)

def fixed_brown(cal,x,y):
    """Stage bounds of the actual Q24/Q30 Brown mapper, including overflow.

    Clipping after an overflow only bounds subsequent host calculations; any
    overflow permanently invalidates that pixel, just as the RTL's bad pipeline.
    """
    bad=np.zeros(np.broadcast_shapes(np.shape(x),np.shape(y)),dtype=bool)
    def bounded(a,bits):
        nonlocal bad
        lo,hi=-(1<<(bits-1)),(1<<(bits-1))-1
        bad|=(a<lo)|(a>hi)
        return np.clip(a,lo,hi)
    def rs(a,b):return (a+(1<<(b-1)))>>b
    q=lambda value,bits:math.floor(value*(1<<bits)+0.5)
    x=bounded(x,27);y=bounded(y,27)
    xx=bounded(rs(x*x,24),28);yy=bounded(rs(y*y,24),28);xy=bounded(rs(x*y,24),28)
    r2=bounded(xx+yy,28);r4=bounded(rs(r2*r2,24),28)
    k1,k2,p1,p2=(q(getattr(cal,n),30) for n in ('k1','k2','p1','p2'))
    radial=bounded((1<<30)+rs(r2*k1,24)+rs(r4*k2,24),32)
    tx=bounded(rs(2*xy*p1,30)+rs((r2+2*xx)*p2,30),28)
    ty=bounded(rs((r2+2*yy)*p1,30)+rs(2*xy*p2,30),28)
    xd=bounded(rs(x*radial,30)+tx,28);yd=bounded(rs(y*radial,30)+ty,28)
    px=bounded(rs(xd*q(cal.fx,12),24),24);py=bounded(rs(yd*q(cal.fy,12),24),24)
    sx=bounded(px+q(cal.cx,12),24);sy=bounded(py+q(cal.cy,12),24)
    return sx,sy,bad

@dataclass(frozen=True)
class PanValidation:
    passed: bool
    angle_tenths: int
    in_bounds_fraction: float
    maximum_row_span: int
    minimum_jacobian: float
    errors: tuple[str, ...]

def validate_angle(cal, angle_tenths, cache_lines=112):
    """Full 921600-pixel geometry check before issuing a pan command.

    All four bilinear taps must be within the sensor. Conservative cache margin
    protects the existing row cache from a new lens/angle's enlarged working set.
    This validates geometry, not image quality or real DDR throughput.
    """
    u = np.arange(WIDTH)[None, :]
    v = np.arange(HEIGHT)[:, None]
    x,y = rays(angle_tenths,u,v)
    sx,sy = project(cal,angle_tenths,u,v)
    r2=x*x+y*y; radial=1+cal.k1*r2+cal.k2*r2*r2; grad=cal.k1+2*cal.k2*r2
    a=radial+2*x*x*grad+2*cal.p1*y+6*cal.p2*x
    b=2*x*y*grad+2*cal.p1*x+2*cal.p2*y
    d=radial+2*y*y*grad+6*cal.p1*y+2*cal.p2*x
    jac=a*d-b*b
    valid=np.isfinite(sx)&np.isfinite(sy)&(sx>=.01)&(sx<WIDTH-1-.01)&(sy>=.01)&(sy<HEIGHT-1-.01)
    fraction=float(np.mean(valid))
    span=int(np.max(np.floor(sy).max(axis=1)-np.floor(sy).min(axis=1)+2))
    errors=[]
    qx,qy,bad=fixed_project(cal,angle_tenths,u,v)
    if np.any(bad):errors.append('该角度超出 FPGA 定点流水线的数值范围')
    if np.max(np.maximum(np.abs(qx/4096-sx),np.abs(qy/4096-sy)))>.01:
        errors.append('定点映射与浮点参考误差超限')
    if fraction<1: errors.append("该角度存在超出镜头有效画面的采样点")
    if not np.all(np.isfinite(jac)) or np.min(jac)<=0: errors.append("畸变模型在该视角出现折叠或奇异")
    if span>cache_lines-8: errors.append(f"源行跨度 {span} 超过缓存验证限制 {cache_lines-8}")
    return PanValidation(not errors,angle_tenths,fraction,span,float(np.min(jac)),tuple(errors))
