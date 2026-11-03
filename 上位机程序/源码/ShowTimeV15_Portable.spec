from pathlib import Path
a=Analysis([str(Path(SPECPATH)/'bootstrap_v15.py')],pathex=[SPECPATH],binaries=[],datas=[],
           hiddenimports=[],hookspath=[],hooksconfig={},runtime_hooks=[],excludes=[],noarchive=False,optimize=0)
# Use the Windows system ICU API, avoiding unrelated Poppler ICU DLLs on PATH.
a.binaries=[item for item in a.binaries if Path(item[0]).name.lower() not in
            ('icuuc.dll','icudt78.dll','qt6pdf.dll','qpdf.dll','qt6virtualkeyboard.dll','qtvirtualkeyboardplugin.dll')]
a.datas=[item for item in a.datas if 'virtualkeyboard' not in item[0].lower()]
pyz=PYZ(a.pure)
exe=EXE(pyz,a.scripts,a.binaries,a.datas,name='ShowTimeV15_Portable',debug=False,strip=False,upx=False,
        console=False,disable_windowed_traceback=False)
