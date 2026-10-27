# clip-watcher-toggle.ps1
# Toggles the clipboard text watcher ON/OFF and shows a small confirmation.
Add-Type -AssemblyName System.Windows.Forms

$dir     = $PSScriptRoot
$script  = Join-Path $dir "clip-no-image-watcher.ps1"
$pidFile = Join-Path $dir "clip-watcher.pid"

$isRunning = $false
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        $isRunning = $true
    }
}

if ($isRunning) {
    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    $msg = "Clipboard watcher is now OFF.`n`nCtrl+V may paste images again.`nCtrl+Shift+V still pastes text."
    $title = "Clip Watcher: OFF"
} else {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File","`"$script`""
    ) -WindowStyle Hidden
    $msg = "Clipboard watcher is now ON.`n`nCopy from Excel, then Ctrl+V pastes TEXT."
    $title = "Clip Watcher: ON"
}

[System.Windows.Forms.MessageBox]::Show($msg, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
