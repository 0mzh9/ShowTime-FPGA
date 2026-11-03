"""Portable entry point; keep diagnostics alongside V15, with read-only fallback."""
import os,sys,traceback,json
from pathlib import Path

def main():
    base=Path(sys.executable).resolve().parent if getattr(sys,'frozen',False) else Path(__file__).resolve().parents[1]
    root=base/'data'
    try:(root/'logs').mkdir(parents=True,exist_ok=True)
    except OSError:
        root=Path(os.environ.get('LOCALAPPDATA',str(Path.home())))/'ShowTimeV15'
        (root/'logs').mkdir(parents=True,exist_ok=True)
    log=root/'logs/viewer_v15.log'
    if log.exists() and log.stat().st_size>2_000_000:log.replace(log.with_suffix('.previous.log'))
    with log.open('a',encoding='utf-8',buffering=1) as stream:
        if sys.stdout is None:sys.stdout=stream
        if sys.stderr is None:sys.stderr=stream
        try:
            from viewer_v15 import main as app_main
            return app_main()
        except Exception:
            error=traceback.format_exc();stream.write(error)
            if '--report' in sys.argv:
                Path(sys.argv[sys.argv.index('--report')+1]).write_text(json.dumps({'passed':False,'startup_error':error},indent=2),encoding='utf-8')
            return 1

if __name__=='__main__':sys.exit(main())
