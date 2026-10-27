# Build a Windows executable with PyInstaller.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python -m pip install -r requirements.txt pyinstaller
pyinstaller --noconfirm --clean --windowed `
  --name ClipprPy `
  --icon ..\clippr.ico `
  --add-data "assets;assets" `
  --add-data "ocr_windows.ps1;." `
  main.py
Write-Host "Built dist\ClipprPy\ClipprPy.exe"
