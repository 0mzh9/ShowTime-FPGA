param(
    [string]$Python = 'python',
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '构建输出')
)
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$workPath = Join-Path $OutputDirectory 'work'
$releasePath = Join-Path $OutputDirectory 'release'
New-Item -ItemType Directory -Path $workPath, $releasePath -Force | Out-Null
Push-Location $PSScriptRoot
try {
    & $Python -m PyInstaller --noconfirm --clean --workpath $workPath --distpath $releasePath (Join-Path $PSScriptRoot 'ShowTimeV15_Portable.spec')
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE" }
    Copy-Item -LiteralPath (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.md') -Destination $releasePath -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot 'licenses') -Destination $releasePath -Recurse -Force
    Write-Host (Join-Path $releasePath 'ShowTimeV15_Portable.exe')
}
finally { Pop-Location }
