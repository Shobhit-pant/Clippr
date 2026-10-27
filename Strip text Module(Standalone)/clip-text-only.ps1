# clip-text-only.ps1
# Run this AFTER copying from Excel. It keeps only the plain text on the
# Windows clipboard (removes the bitmap/metafile so OpenCode pastes text, not an image).
Add-Type -AssemblyName System.Windows.Forms

$text = [System.Windows.Forms.Clipboard]::GetText()
if ([string]::IsNullOrEmpty($text)) {
    Write-Host "Clipboard has no text." -ForegroundColor Yellow
} else {
    [System.Windows.Forms.Clipboard]::SetText($text)
    Write-Host "Clipboard now holds TEXT only. Paste with Ctrl+V." -ForegroundColor Green
    Write-Host ("Characters: " + $text.Length)
}
