# clip-no-image-watcher.ps1
# Background watcher: whenever the clipboard contains an image (e.g. after
# copying from Excel), rewrite it to TEXT ONLY so OpenCode's Ctrl+V pastes text.
# Single-instance: exits immediately if a watcher is already running.

Add-Type -AssemblyName System.Windows.Forms
$pidFile = Join-Path $PSScriptRoot "clip-watcher.pid"

# --- single-instance guard ---
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        exit   # already running
    }
}
$PID | Out-File -FilePath $pidFile -Encoding ascii -Force

while ($true) {
    try {
        Start-Sleep -Milliseconds 150
        $d = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($null -ne $d -and $d.GetDataPresent([System.Windows.Forms.DataFormats]::Bitmap)) {
            $t = [System.Windows.Forms.Clipboard]::GetText()
            if (-not [string]::IsNullOrEmpty($t)) {
                [System.Windows.Forms.Clipboard]::SetText($t)
            }
        }
    } catch {
        # clipboard busy / locked by another app - just try again
    }
}
