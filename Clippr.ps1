# ============================================================
#  Clippr - friendly neighborhood clipboard manager (four switchable themes)
#  Tabs, history, On/Off capture switch, screen capture, OCR.
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ClipprNative {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);
    [DllImport("user32.dll")] public static extern bool ShowScrollBar(IntPtr hWnd, int wBar, bool bShow);
    [DllImport("uxtheme.dll", EntryPoint="#135")] public static extern int SetPreferredAppMode(int appMode);
    [DllImport("uxtheme.dll", EntryPoint="#136")] public static extern void FlushMenuThemes();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX; public int CY; }
    [StructLayout(LayoutKind.Sequential, Pack=1)] public struct BLENDFUNCTION {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }
}
"@

Add-Type -ReferencedAssemblies ([System.Windows.Forms.Form].Assembly.Location), ([System.Drawing.Color].Assembly.Location) -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

// ListBox with smooth, eased mouse-wheel scrolling and flicker-free owner drawing.
public class FluidListBox : ListBox {
    private readonly Timer anim;
    private int target;

    public FluidListBox() {
        DoubleBuffered = true;
        anim = new Timer();
        anim.Interval = 15;
        anim.Tick += (s, e) => {
            if (TopIndex == target) { anim.Stop(); return; }
            int step = target > TopIndex ? 1 : -1;
            int next = TopIndex + step;
            if (next < 0) next = 0;
            if (next > Items.Count - 1) next = Items.Count - 1;
            TopIndex = next;
            if (TopIndex == target) anim.Stop();
        };
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        int h = Math.Max(1, ItemHeight);
        int visible = Math.Max(1, ClientSize.Height / h - 1);
        int maxTop = Math.Max(0, Items.Count - visible);
        int start = anim.Enabled ? target : TopIndex;
        int t = start - Math.Sign(e.Delta) * 3;
        if (t < 0) t = 0;
        if (t > maxTop) t = maxTop;
        target = t;
        if (target != TopIndex) anim.Start();
    }

    public event EventHandler TopIndexChanged;

    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        // LB_SETTOPINDEX
        if (m.Msg == 0x0197 && TopIndexChanged != null) TopIndexChanged(this, EventArgs.Empty);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) anim.Dispose();
        base.Dispose(disposing);
    }
}

// Flicker-free panel used for the slim custom scrollbar.
public class BufferedPanel : Panel {
    public BufferedPanel() {
        DoubleBuffered = true;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
    }
}

"@

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
try {
    [ClipprNative]::SetPreferredAppMode(2) | Out-Null
    [ClipprNative]::FlushMenuThemes()
} catch { }

# ---------- single instance ----------
$script:isOcrJob = ($env:CLIPPR_OCR_JOB -eq '1')
if (-not $script:isOcrJob) {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, 'Clippr_SingleInstance')
    if (-not $script:instanceMutex.WaitOne(0)) {
        $h = [ClipprNative]::FindWindow($null, 'Clippr')
        if ($h -ne [IntPtr]::Zero) {
            [ClipprNative]::ShowWindow($h, 9) | Out-Null
            [ClipprNative]::SetForegroundWindow($h) | Out-Null
        }
        exit
    }
}

# ---------- storage ----------
$script:BaseDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:SelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:AppDir   = Join-Path $env:APPDATA 'Clippr'
$script:DataFile  = Join-Path $script:AppDir 'clippr.json'
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'
$script:ImagesDir = Join-Path $script:AppDir 'images'
New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
New-Item -ItemType Directory -Force -Path $script:ImagesDir | Out-Null

# one-time migration from the old ClipVault data folder (keeps existing history)
$script:LegacyDir = Join-Path $env:APPDATA 'ClipVault'
$script:LegacyData = Join-Path $script:LegacyDir 'clipvault.json'
if (-not (Test-Path -LiteralPath $script:DataFile) -and (Test-Path -LiteralPath $script:LegacyData)) {
    try {
        Copy-Item -LiteralPath $script:LegacyData -Destination $script:DataFile -Force
        $legacyImages = Join-Path $script:LegacyDir 'images'
        if (Test-Path -LiteralPath $legacyImages) {
            Get-ChildItem -LiteralPath $legacyImages -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:ImagesDir $_.Name) -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- palette defaults (replaced at startup by Set-ThemePalette) ----------
$C_BG      = [System.Drawing.Color]::FromArgb(11,15,23)
$C_PANEL   = [System.Drawing.Color]::FromArgb(15,23,42)
$C_PANEL2  = [System.Drawing.Color]::FromArgb(17,24,39)
$C_PANEL3  = [System.Drawing.Color]::FromArgb(30,41,59)
$C_TEXT    = [System.Drawing.Color]::FromArgb(248,250,252)
$C_MUTED   = [System.Drawing.Color]::FromArgb(148,163,184)
$C_SUBTLE  = [System.Drawing.Color]::FromArgb(203,213,225)
$C_ACCENT  = [System.Drawing.Color]::FromArgb(34,211,238)
$C_ACCENT2 = [System.Drawing.Color]::FromArgb(103,232,249)
$C_ACCENT_SOFT = [System.Drawing.Color]::FromArgb(165,243,252)
$C_EMERALD = [System.Drawing.Color]::FromArgb(52,211,153)
$C_EMERALD_SOFT = [System.Drawing.Color]::FromArgb(167,243,208)
$C_VIOLET  = [System.Drawing.Color]::FromArgb(167,139,250)
$C_VIOLET_SOFT = [System.Drawing.Color]::FromArgb(221,214,254)
$C_SEL     = [System.Drawing.Color]::FromArgb(8,47,73)
$C_BORDER  = [System.Drawing.Color]::FromArgb(22,78,99)
$C_GLASS   = [System.Drawing.Color]::FromArgb(15,23,42)
$C_GLASS_HI = [System.Drawing.Color]::FromArgb(30,41,59)
$C_GLASS_BORDER = [System.Drawing.Color]::FromArgb(28,94,112)
$C_GLASS_TOP = [System.Drawing.Color]::FromArgb(24, 148, 163, 184)
$C_GLASS_BOT = [System.Drawing.Color]::FromArgb(18, 15, 23, 42)
$C_CARD      = [System.Drawing.Color]::FromArgb(104, 15, 23, 42)
$C_CARD_HI   = [System.Drawing.Color]::FromArgb(144, 30, 41, 59)
$C_CARD_SEL  = [System.Drawing.Color]::FromArgb(172, 8, 47, 73)
$C_INK     = [System.Drawing.Color]::FromArgb(2,6,23)
$C_POP     = [System.Drawing.Color]::FromArgb(167,139,250)
$C_FONT    = 'Segoe UI'

# ---------- theme system ----------
function Col([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
function ColA([int]$a, [string]$hex) {
    $c = Col $hex
    return [System.Drawing.Color]::FromArgb($a, $c.R, $c.G, $c.B)
}
function Get-ColorRef([System.Drawing.Color]$c) {
    return [int]($c.R -bor ($c.G -shl 8) -bor ($c.B -shl 16))
}

$script:ThemeBase = @{
    Key = 'Swiss'; Name = 'Swiss Paper'; IsLight = $true
    Font = 'Segoe UI'
    SubText = 'FRIENDLY NEIGHBORHOOD CLIPBOARD MANAGER'
    SubFont = 'Segoe UI'; SubSize = 7.5; SubStyle = [System.Drawing.FontStyle]::Regular
    CardFont = 'Segoe UI Semibold'; CardFontSize = 10.5; CardFontStyle = [System.Drawing.FontStyle]::Regular; CardUppercase = $false
    MetaFont = 'Segoe UI'; MetaFontSize = 8.25
    TabFont = 'Segoe UI'; TabFontSize = 9.5; TabUppercase = $false
    ButtonFont = 'Segoe UI'; ButtonFontSize = 8.5
    LabelFont = 'Segoe UI'; LabelSize = 8
    DisplayFont = 'Segoe UI'; DisplaySize = 27; DisplayStyle = [System.Drawing.FontStyle]::Bold
    DisplayColor = $null; TitleY = 8; TitleUppercase = $false
    AccentInk = Col '#FFFFFF'; Ink = Col '#101215'
    CardShadowColor = (ColA 24 '#0F172A'); CardShadowOffset = 1; HardShadow = $false
    CardBorderWidth = 1; ButtonBorderWidth = 1; TagBorderWidth = 1; ListBorderWidth = 1
    CardBarWidth = 3; CardBarOpacity = 0.3
    PanelRadius = 10; ButtonRadius = 6; CardRadius = 8; SearchRadius = 8; TagRadius = 4
    BackgroundStyle = 'soft'; LogoMode = 'color'
    DwmDark = $false; DwmCaption = (Col '#FFFFFF'); DwmBorder = (Col '#D8E0EA')
    StatusLineWidth = 1; HeaderLineWidth = 1; SidebarBorderWidth = 1; TabBorderWidth = 1
}

function New-Theme([hashtable]$overrides) {
    $h = @{}
    foreach ($k in $script:ThemeBase.Keys) { $h[$k] = $script:ThemeBase[$k] }
    foreach ($k in $overrides.Keys) { $h[$k] = $overrides[$k] }
    if ($null -eq $h.DisplayColor) { $h.DisplayColor = $h.Text }
    return [pscustomobject]$h
}

$script:Themes = @{}
$script:Themes['Swiss'] = New-Theme @{
    Key = 'Swiss'; Name = 'Swiss Paper'; IsLight = $true
    Bg = (Col '#F3EFE6'); Surface = (Col '#FBF9F4'); Surface2 = (Col '#FFFDF9'); Surface3 = (Col '#F1ECE2')
    Text = (Col '#1A1815'); Muted = (Col '#746D62'); Subtle = (Col '#8C8477'); Border = (Col '#DAD3C5')
    Accent = (Col '#C8432F'); Accent2 = (Col '#8C5A4A'); AccentSoft = (Col '#F3E5E0'); AccentInk = (Col '#FFFFFF')
    Card = (Col '#FFFDF9'); CardHi = (Col '#F8F4EC'); CardSel = (Col '#F6E9E4')
    CardBorder = (Col '#E2DCCF'); CardHoverBorder = (Col '#D6CEC0'); CardSelBorder = (Col '#C8432F')
    CardBarWidth = 3; CardBarOpacity = 0.35
    ListBg = (Col '#FBF9F4'); ListBg2 = (Col '#F7F3EA'); ListBorder = (Col '#DCD5C7')
    Sidebar = (Col '#EDE8DD'); Sidebar2 = (Col '#E8E2D6')
    StatusBg = (Col '#E8E2D6'); StatusText = (Col '#6B6459'); StatusLine = (Col '#D8D1C3')
    SearchBg = (Col '#FFFDF9'); SearchBorder = (Col '#DCD5C7')
    TagBg = (Col '#F1ECE2'); TagText = (Col '#5E574D'); TagBorder = (Col '#DED7C9')
    TabSelBg = (Col '#1A1815'); TabSelText = (Col '#FFFFFF'); TabSelBorder = (Col '#1A1815')
    TabSelDot = (Col '#C8432F'); TabSelCount = (Col '#B9B3A9'); TabHoverBg = (Col '#F6F1E8'); TabText = (Col '#1A1815')
    ToggleOnBg = (Col '#1A1815'); ToggleOnText = (Col '#FFFFFF'); ToggleOnBorder = (Col '#1A1815'); ToggleOnDot = (Col '#C8432F')
    ToggleOffBg = (Col '#FBF9F4'); ToggleOffText = (Col '#1A1815'); ToggleOffBorder = (Col '#CFC7B8')
    BtnPrimaryBg = (Col '#1A1815'); BtnPrimaryText = (Col '#FFFFFF'); BtnPrimaryBorder = (Col '#1A1815')
    BtnPrimaryHover = (Col '#2B2722'); BtnPrimaryDown = (Col '#000000')
    BtnSecondaryBg = (Col '#FBF9F4'); BtnSecondaryText = (Col '#1A1815'); BtnSecondaryBorder = (Col '#CFC7B8')
    BtnSecondaryHover = (Col '#F2EDE3'); BtnSecondaryDown = (Col '#E8E2D6')
    DisplayFont = 'Georgia'; DisplaySize = 29; DisplayStyle = [System.Drawing.FontStyle]::Regular; TitleY = 8
    CardFont = 'Segoe UI Semibold'; CardFontSize = 10.5
    PanelRadius = 3; ButtonRadius = 2; CardRadius = 2; SearchRadius = 2; TagRadius = 1
    CardShadowColor = (ColA 16 '#4A3826'); CardShadowOffset = 1
    BackgroundStyle = 'paper'; LogoMode = 'contrast'
    DwmDark = $true; DwmCaption = (Col '#1A1815'); DwmBorder = (Col '#1A1815')
}

$script:Themes['Brass'] = New-Theme @{
    Key = 'Brass'; Name = 'Midnight Brass'; IsLight = $false
    Bg = (Col '#0D0F12'); Surface = (Col '#12151A'); Surface2 = (Col '#161A20'); Surface3 = (Col '#1B2028')
    Text = (Col '#F0EBDD'); Muted = (Col '#8C877B'); Subtle = (Col '#B8B2A4'); Border = (Col '#2A2E36')
    Accent = (Col '#C6A15B'); Accent2 = (Col '#D8B87A'); AccentSoft = (Col '#E8D9B8'); AccentInk = (Col '#101215')
    Card = (Col '#161A20'); CardHi = (Col '#1B2028'); CardSel = (Col '#1C2027')
    CardBorder = (Col '#272C35'); CardHoverBorder = (Col '#3A404A'); CardSelBorder = (Col '#C6A15B')
    CardBarWidth = 3; CardBarOpacity = 0.35
    ListBg = (Col '#12151A'); ListBg2 = (Col '#0F1216'); ListBorder = (Col '#2A2F38')
    Sidebar = (Col '#0A0C0F'); Sidebar2 = (Col '#0D0F12')
    StatusBg = (Col '#080A0D'); StatusText = (Col '#8C877B'); StatusLine = (Col '#22262D')
    SearchBg = (Col '#161A20'); SearchBorder = (Col '#2A2F38')
    TagBg = (Col '#222730'); TagText = (Col '#C6A15B'); TagBorder = (Col '#343A45')
    TabSelBg = (Col '#C6A15B'); TabSelText = (Col '#101215'); TabSelBorder = (Col '#C6A15B')
    TabSelDot = (Col '#101215'); TabSelCount = (Col '#5A4E38'); TabHoverBg = (Col '#1A1E25'); TabText = (Col '#F0EBDD')
    ToggleOnBg = (Col '#C6A15B'); ToggleOnText = (Col '#101215'); ToggleOnBorder = (Col '#C6A15B'); ToggleOnDot = (Col '#101215')
    ToggleOffBg = (Col '#12151A'); ToggleOffText = (Col '#F0EBDD'); ToggleOffBorder = (Col '#3A3F48')
    BtnPrimaryBg = (Col '#C6A15B'); BtnPrimaryText = (Col '#101215'); BtnPrimaryBorder = (Col '#C6A15B')
    BtnPrimaryHover = (Col '#D4B270'); BtnPrimaryDown = (Col '#A88545')
    BtnSecondaryBg = (Col '#12151A'); BtnSecondaryText = (Col '#F0EBDD'); BtnSecondaryBorder = (Col '#343A45')
    BtnSecondaryHover = (Col '#1A1E25'); BtnSecondaryDown = (Col '#222730')
    DisplayFont = 'Georgia'; DisplaySize = 29; DisplayStyle = [System.Drawing.FontStyle]::Regular; TitleY = 8
    CardFont = 'Segoe UI Semibold'; CardFontSize = 10.5
    PanelRadius = 4; ButtonRadius = 3; CardRadius = 3; SearchRadius = 3; TagRadius = 2
    CardShadowColor = (ColA 45 '#000000'); CardShadowOffset = 1
    BackgroundStyle = 'ink'; LogoMode = 'sepia'
    DwmDark = $true; DwmCaption = (Col '#080A0D'); DwmBorder = (Col '#262A31')
}

$script:Themes['Brutal'] = New-Theme @{
    Key = 'Brutal'; Name = 'Neo-Brutalist'; IsLight = $true
    Bg = (Col '#F1EDE2'); Surface = (Col '#FFFDF5'); Surface2 = (Col '#FFFFFF'); Surface3 = (Col '#E7E1D3')
    Text = (Col '#0D0D0D'); Muted = (Col '#4A4A4A'); Subtle = (Col '#5A5A5A'); Border = (Col '#0D0D0D')
    Accent = (Col '#2B4DFF'); Accent2 = (Col '#D6FF3F'); AccentSoft = (Col '#D6FF3F'); AccentInk = (Col '#FFFFFF')
    Card = (Col '#FFFFFF'); CardHi = (Col '#F7F4EA'); CardSel = (Col '#D6FF3F')
    CardBorder = (Col '#0D0D0D'); CardHoverBorder = (Col '#0D0D0D'); CardSelBorder = (Col '#0D0D0D')
    CardBarWidth = 5; CardBarOpacity = 1.0
    ListBg = (Col '#FFFDF5'); ListBg2 = (Col '#FFFDF5'); ListBorder = (Col '#0D0D0D')
    Sidebar = (Col '#E7E1D3'); Sidebar2 = (Col '#F1EDE2')
    StatusBg = (Col '#0D0D0D'); StatusText = (Col '#D6FF3F'); StatusLine = (Col '#D6FF3F')
    SearchBg = (Col '#FFFDF5'); SearchBorder = (Col '#0D0D0D')
    TagBg = (Col '#0D0D0D'); TagText = (Col '#D6FF3F'); TagBorder = (Col '#0D0D0D')
    TabSelBg = (Col '#0D0D0D'); TabSelText = (Col '#D6FF3F'); TabSelBorder = (Col '#0D0D0D')
    TabSelDot = (Col '#D6FF3F'); TabSelCount = (Col '#A8C72E'); TabHoverBg = (Col '#F7F4EA'); TabText = (Col '#0D0D0D')
    ToggleOnBg = (Col '#D6FF3F'); ToggleOnText = (Col '#0D0D0D'); ToggleOnBorder = (Col '#0D0D0D'); ToggleOnDot = (Col '#0D0D0D')
    ToggleOffBg = (Col '#FFFDF5'); ToggleOffText = (Col '#0D0D0D'); ToggleOffBorder = (Col '#0D0D0D')
    BtnPrimaryBg = (Col '#2B4DFF'); BtnPrimaryText = (Col '#FFFFFF'); BtnPrimaryBorder = (Col '#0D0D0D')
    BtnPrimaryHover = (Col '#1F3EDB'); BtnPrimaryDown = (Col '#1732B0')
    BtnSecondaryBg = (Col '#FFFDF5'); BtnSecondaryText = (Col '#0D0D0D'); BtnSecondaryBorder = (Col '#0D0D0D')
    BtnSecondaryHover = (Col '#D6FF3F'); BtnSecondaryDown = (Col '#C2E936')
    DisplayFont = 'Arial Black'; DisplaySize = 24; DisplayStyle = [System.Drawing.FontStyle]::Bold; TitleY = 10; TitleUppercase = $true
    SubFont = 'Consolas'; SubSize = 7.5
    CardFont = 'Arial Black'; CardFontSize = 9.5; CardFontStyle = [System.Drawing.FontStyle]::Regular
    MetaFont = 'Consolas'; MetaFontSize = 8.25
    TabFont = 'Segoe UI'; TabFontSize = 9.0; TabUppercase = $true
    ButtonFont = 'Arial Black'; ButtonFontSize = 8.0
    PanelRadius = 0; ButtonRadius = 0; CardRadius = 0; SearchRadius = 0; TagRadius = 0
    CardBorderWidth = 2; ButtonBorderWidth = 2; TagBorderWidth = 2; ListBorderWidth = 2
    HardShadow = $true; CardShadowColor = (Col '#0D0D0D'); CardShadowOffset = 4
    BackgroundStyle = 'flat'; LogoMode = 'contrast'
    DwmDark = $true; DwmCaption = (Col '#0D0D0D'); DwmBorder = (Col '#0D0D0D')
    StatusLineWidth = 2; HeaderLineWidth = 2; SidebarBorderWidth = 2; TabBorderWidth = 2
}

$script:Themes['Calm'] = New-Theme @{
    Key = 'Calm'; Name = 'Calm Slate'; IsLight = $true
    Bg = (Col '#EEF2F7'); Surface = (Col '#F8FAFC'); Surface2 = (Col '#FFFFFF'); Surface3 = (Col '#F4F7FB')
    Text = (Col '#172033'); Muted = (Col '#64748B'); Subtle = (Col '#94A3B8'); Border = (Col '#D8E0EA')
    Accent = (Col '#2563EB'); Accent2 = (Col '#2563EB'); AccentSoft = (Col '#E7EFFE'); AccentInk = (Col '#FFFFFF')
    Card = (Col '#FFFFFF'); CardHi = (Col '#F5F8FD'); CardSel = (Col '#F2F7FF')
    CardBorder = (Col '#DFE6EF'); CardHoverBorder = (Col '#C9D6E6'); CardSelBorder = (Col '#BFD3FA')
    CardBarWidth = 3; CardBarOpacity = 0.38
    ListBg = (Col '#F4F7FB'); ListBg2 = (Col '#F0F5FB'); ListBorder = (Col '#D8E0EA')
    Sidebar = (Col '#FFFFFF'); Sidebar2 = (Col '#F8FAFC')
    StatusBg = (Col '#FFFFFF'); StatusText = (Col '#64748B'); StatusLine = (Col '#D8E0EA')
    SearchBg = (Col '#FFFFFF'); SearchBorder = (Col '#D6DFEA')
    TagBg = (Col '#E8F0FE'); TagText = (Col '#1D4ED8'); TagBorder = (Col '#D2E0FC')
    TabSelBg = (Col '#E7EFFE'); TabSelText = (Col '#1D4ED8'); TabSelBorder = (Col '#C7D9FB')
    TabSelDot = (Col '#2563EB'); TabSelCount = (Col '#64748B'); TabHoverBg = (Col '#F5F8FD'); TabText = (Col '#172033')
    ToggleOnBg = (Col '#0E9F6E'); ToggleOnText = (Col '#FFFFFF'); ToggleOnBorder = (Col '#0E9F6E'); ToggleOnDot = (Col '#FFFFFF')
    ToggleOffBg = (Col '#FFFFFF'); ToggleOffText = (Col '#334155'); ToggleOffBorder = (Col '#D8E0EA')
    BtnPrimaryBg = (Col '#2563EB'); BtnPrimaryText = (Col '#FFFFFF'); BtnPrimaryBorder = (Col '#2563EB')
    BtnPrimaryHover = (Col '#1D4ED8'); BtnPrimaryDown = (Col '#1E40AF')
    BtnSecondaryBg = (Col '#FFFFFF'); BtnSecondaryText = (Col '#334155'); BtnSecondaryBorder = (Col '#D8E0EA')
    BtnSecondaryHover = (Col '#F5F8FD'); BtnSecondaryDown = (Col '#E7EFFE')
    DisplayFont = 'Segoe UI'; DisplaySize = 26; DisplayStyle = [System.Drawing.FontStyle]::Bold; TitleY = 9
    SubText = 'Friendly Neighborhood Clipboard manager'; SubFont = 'Segoe UI'; SubSize = 8.5
    CardFont = 'Segoe UI Semibold'; CardFontSize = 10.5
    PanelRadius = 10; ButtonRadius = 7; CardRadius = 8; SearchRadius = 8; TagRadius = 4
    CardShadowColor = (ColA 18 '#0F172A'); CardShadowOffset = 1
    BackgroundStyle = 'soft'; LogoMode = 'color'
    DwmDark = $true; DwmCaption = (Col '#172033'); DwmBorder = (Col '#172033')
}

function Set-ThemePalette([string]$key) {
    if (-not $key -or -not $script:Themes.ContainsKey($key)) { $key = 'Swiss' }
    $t = $script:Themes[$key]
    $script:Theme = $t
    $script:ThemeKey = $key
    $script:C_BG = $t.Bg
    $script:C_PANEL = $t.Surface
    $script:C_PANEL2 = $t.Surface2
    $script:C_PANEL3 = $t.Surface3
    $script:C_TEXT = $t.Text
    $script:C_MUTED = $t.Muted
    $script:C_SUBTLE = $t.Subtle
    $script:C_ACCENT = $t.Accent
    $script:C_ACCENT2 = $t.Accent2
    $script:C_ACCENT_SOFT = $t.AccentSoft
    $script:C_EMERALD = $t.ToggleOnBg
    $script:C_EMERALD_SOFT = $t.AccentSoft
    $script:C_VIOLET = $t.Accent2
    $script:C_VIOLET_SOFT = $t.AccentSoft
    $script:C_SEL = $t.TabSelBg
    $script:C_BORDER = $t.Border
    $script:C_GLASS = $t.Surface2
    $script:C_GLASS_HI = $t.Surface3
    $script:C_GLASS_BORDER = $t.ListBorder
    $script:C_GLASS_TOP = (ColA 18 '#FFFFFF')
    $script:C_GLASS_BOT = (ColA 10 '#000000')
    $script:C_CARD = $t.Card
    $script:C_CARD_HI = $t.CardHi
    $script:C_CARD_SEL = $t.CardSel
    $script:C_INK = $t.Ink
    $script:C_POP = $t.Accent2
    $script:C_FONT = $t.Font
    $script:ThemeDwmDark = if ($t.DwmDark) { 1 } else { 0 }
    $script:ThemeDwmCaption = Get-ColorRef $t.DwmCaption
    $script:ThemeDwmBorder = Get-ColorRef $t.DwmBorder
}

# ---------- drawing helpers ----------
function Get-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($w -lt 1) { $w = 1 }
    if ($h -lt 1) { $h = 1 }
    $d = [single]([Math]::Min($r * 2, [Math]::Min($w, $h)))
    if ($d -lt 1) { $d = 1 }
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-RoundedRegion($ctrl, [single]$r = 10) {
    if (-not $ctrl) { return }
    try {
        if ($ctrl.Width -le 0 -or $ctrl.Height -le 0) { return }
        $p = Get-RoundedPath 0 0 $ctrl.Width $ctrl.Height $r
        $old = $ctrl.Region
        $ctrl.Region = New-Object System.Drawing.Region($p)
        if ($old) { try { $old.Dispose() } catch { } }
        $p.Dispose()
    } catch { }
}

function Set-DarkScrollBars($ctrl) {
    if (-not $ctrl) { return }
    try {
        [void]$ctrl.Handle
        [ClipprNative]::SetWindowTheme($ctrl.Handle, 'DarkMode_Explorer', $null) | Out-Null
    } catch { }
}

# Cached crop of the form background with a translucent frosted tint.
# WinForms list boxes cannot be transparent, so each owner-drawn row paints
# this crop first; the result reads as real glass over the mesh background.
function Get-GlassCrop([System.Windows.Forms.Control]$ctrl) {
    if (-not $ctrl) { return $null }
    try {
        $w = $ctrl.ClientSize.Width
        $h = $ctrl.ClientSize.Height
        if ($w -lt 2 -or $h -lt 2) { return $null }
        $key = [int]$ctrl.Handle
        $hit = $script:glassCache[$key]
        if ($hit -and $hit.W -eq $w -and $hit.H -eq $h) { return $hit.Bmp }
        if ($hit -and $hit.Bmp) { try { $hit.Bmp.Dispose() } catch { } }

        $t = $script:Theme
        $isTabs = ($script:tabList -and [object]::ReferenceEquals($ctrl, $script:tabList))
        $bg = if ($isTabs) { $t.Sidebar } else { $t.ListBg }
        $bg2 = if ($isTabs) { $t.Sidebar2 } else { $t.ListBg2 }

        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $gg = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $gg.Clear($bg)
            $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
            $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $bg, $bg2, 90)
            $gg.FillRectangle($lg, $rect)
            $lg.Dispose()
            $sheen = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(16, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 90)
            $gg.FillRectangle($sheen, $rect)
            $sheen.Dispose()
        } finally {
            $gg.Dispose()
        }
        $script:glassCache[$key] = [pscustomobject]@{ Bmp = $bmp; W = $w; H = $h }
        return $bmp
    } catch { return $null }
}

function Get-HistScrollMetrics {
    $list = $script:histList
    $ov = $script:histScroll
    if (-not $list -or -not $ov) { return $null }
    $total = $list.Items.Count
    $h = [Math]::Max(1, $list.ClientSize.Height)
    $vis = [Math]::Max(1, [int][Math]::Floor($h / [double]$list.ItemHeight))
    $maxTop = [Math]::Max(0, $total - $vis)
    $trackH = [Math]::Max(1, $ov.Height)
    $thumbH = $trackH
    if ($total -gt 0) {
        $ratio = [Math]::Min(1.0, $vis / [double]$total)
        $thumbH = [Math]::Max(30.0, $trackH * $ratio)
    }
    if ($thumbH -gt $trackH) { $thumbH = $trackH }
    $pos = 0.0
    if ($maxTop -gt 0) { $pos = ($trackH - $thumbH) * ($list.TopIndex / [double]$maxTop) }
    if ($pos -lt 0) { $pos = 0 }
    if ($pos + $thumbH -gt $trackH) { $pos = $trackH - $thumbH }
    return [pscustomobject]@{ Total = $total; Visible = $vis; MaxTop = $maxTop; TrackH = $trackH; ThumbH = $thumbH; ThumbY = $pos }
}

function Update-HistScroll {
    if (-not $script:histScroll -or -not $script:histList) { return }
    try {
        $list = $script:histList
        $x = $list.Left + $list.Width - 17
        $y = $list.Top
        $bh = [Math]::Max(10, $list.Height)
        $script:histScroll.Bounds = New-Object System.Drawing.Rectangle($x, $y, 17, $bh)
        $script:histScroll.BringToFront()
        try { [void][ClipprNative]::ShowScrollBar($list.Handle, 1, $false) } catch { }
        $m = Get-HistScrollMetrics
        if (-not $m -or $m.Total -le $m.Visible -or $m.Total -le 0) {
            $script:histScroll.Visible = $false
            return
        }
        $script:histScroll.Visible = $true
        $script:histScroll.Invalidate()
    } catch { }
}

function Add-GlowBlob($g, [double]$cx, [double]$cy, [double]$rx, [double]$ry, [int]$cr, [int]$cg, [int]$cb, [int]$ca = 150) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $path.AddEllipse([single]($cx - $rx), [single]($cy - $ry), [single]($rx * 2), [single]($ry * 2))
        $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
        $pgb.CenterColor = [System.Drawing.Color]::FromArgb($ca, $cr, $cg, $cb)
        $sur = New-Object 'System.Drawing.Color[]' $path.PointCount
        for ($i = 0; $i -lt $path.PointCount; $i++) {
            $sur[$i] = [System.Drawing.Color]::FromArgb(0, $cr, $cg, $cb)
        }
        $pgb.SurroundColors = $sur
        $g.FillPath($pgb, $path)
        $pgb.Dispose()
    } catch {
        # Fallback: layered ellipses give a similar soft falloff on older GDI+ builds.
        for ($i = 0; $i -lt 16; $i++) {
            $k = 1.0 - ($i * 0.055)
            $a = [int](4 + $i * 1.4)
            $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $cr, $cg, $cb))
            $w = $rx * 2 * $k
            $h = $ry * 2 * $k
            $g.FillEllipse($b, [single]($cx - $w / 2), [single]($cy - $h / 2), [single]$w, [single]$h)
            $b.Dispose()
        }
    } finally {
        $path.Dispose()
    }
}

function New-DialogBackground([int]$w, [int]$h) {
    $bmp = New-GlassBackground $w $h
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $t = $script:Theme
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $alpha = if ($t.IsLight) { 236 } else { 218 }
        $veil = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, $t.Surface.R, $t.Surface.G, $t.Surface.B))
        $g.FillRectangle($veil, $rect)
        $veil.Dispose()
        $sheen = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(20, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 90)
        $g.FillRectangle($sheen, $rect)
        $sheen.Dispose()
        $g.Dispose()
    } catch { }
    return $bmp
}

function New-GlassBackground([int]$w, [int]$h) {
    if ($w -lt 1) { $w = 1 }
    if ($h -lt 1) { $h = 1 }
    $t = $script:Theme
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)

        switch ($t.BackgroundStyle) {
            'paper' {
                $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $t.Bg, $t.Surface, 90)
                $g.FillRectangle($lg, $rect); $lg.Dispose()
                Add-GlowBlob $g ($w * 0.10) ($h * 0.05) ($w * 0.56) ($h * 0.56) $t.Accent.R $t.Accent.G $t.Accent.B 10
                Add-GlowBlob $g ($w * 0.88) ($h * 0.86) ($w * 0.38) ($h * 0.38) $t.Accent2.R $t.Accent2.G $t.Accent2.B 8
                $rnd = New-Object System.Random(13)
                for ($i = 0; $i -lt 2000; $i++) {
                    $sx = $rnd.NextDouble() * $w
                    $sy = $rnd.NextDouble() * $h
                    $sa = $rnd.Next(2, 8)
                    $ss = [single]($rnd.NextDouble() * 0.9 + 0.3)
                    $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($sa, 88, 68, 48))
                    $g.FillEllipse($sb, [single]$sx, [single]$sy, $ss, $ss)
                    $sb.Dispose()
                }
            }
            'ink' {
                $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $t.Bg, $t.Surface, 35)
                $g.FillRectangle($lg, $rect); $lg.Dispose()
                Add-GlowBlob $g ($w * 0.86) ($h * 0.05) ($w * 0.52) ($h * 0.50) $t.Accent.R $t.Accent.G $t.Accent.B 26
                Add-GlowBlob $g ($w * 0.08) ($h * 0.92) ($w * 0.42) ($h * 0.42) $t.Accent2.R $t.Accent2.G $t.Accent2.B 14
                Add-GlowBlob $g ($w * 0.45) ($h * 0.44) ($w * 0.34) ($h * 0.34) 226 232 240 10
                $rnd = New-Object System.Random(11)
                for ($i = 0; $i -lt 1600; $i++) {
                    $sx = $rnd.NextDouble() * $w
                    $sy = $rnd.NextDouble() * $h
                    $sa = $rnd.Next(2, 8)
                    $ss = [single]($rnd.NextDouble() * 1.0 + 0.3)
                    $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($sa, 255, 255, 255))
                    $g.FillEllipse($sb, [single]$sx, [single]$sy, $ss, $ss)
                    $sb.Dispose()
                }
            }
            'flat' {
                $g.Clear($t.Bg)
                $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(12, 13, 13, 13), 1)
                for ($x = 0; $x -lt $w; $x += 32) { $g.DrawLine($pen, $x, 0, $x, $h) }
                for ($y = 0; $y -lt $h; $y += 32) { $g.DrawLine($pen, 0, $y, $w, $y) }
                $pen.Dispose()
            }
            default {
                $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $t.Bg, $t.Surface, 90)
                $g.FillRectangle($lg, $rect); $lg.Dispose()
                Add-GlowBlob $g ($w * 0.12) ($h * 0.02) ($w * 0.56) ($h * 0.52) 255 255 255 32
                Add-GlowBlob $g ($w * 0.86) ($h * 0.18) ($w * 0.46) ($h * 0.46) $t.Accent.R $t.Accent.G $t.Accent.B 14
            }
        }
    } finally {
        $g.Dispose()
    }
    return $bmp
}


# ---------- state ----------
$script:capturing    = $true
$script:stripImages  = $true
$script:activeTab    = ''
$script:tabs         = @()
$script:viewTabs     = @('All items', 'Text', 'Images')
$script:captureTab   = ''
$script:lastCaptured = ''
$script:exiting      = $false
$script:thumbCache   = @{}
$script:ignoreClipboardUntil = [datetime]::MinValue
$script:lastImageFingerprint = ''
$script:settings     = $null
$script:ocrNotice    = ''
$script:oauthToken   = ''
$script:oauthTokenKey = ''
$script:oauthTokenExpiry = [datetime]::MinValue
$script:autoNameQueue = New-Object System.Collections.ArrayList
$script:autoNameBusy = $false
$script:autoNameProc = $null
$script:autoNameOut = ''
$script:autoNameCurrent = $null
$script:autoNameStarted = [datetime]::MinValue
$script:glassCache   = @{}
$script:scrollDrag   = $false
$script:scrollGrab   = 0

# ---------- functions ----------
function Save-State {
    try {
        $obj = [pscustomobject]@{
            Capturing   = [bool]$script:capturing
            StripImages = [bool]$script:stripImages
            ActiveTab   = [string]$script:activeTab
            CaptureTab  = [string]$script:captureTab
            Tabs        = @($script:tabs)
        }
        $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:DataFile -Encoding UTF8
    } catch { }
}

function Load-State {
    if (Test-Path -LiteralPath $script:DataFile) {
        try {
            $j = Get-Content -LiteralPath $script:DataFile -Raw | ConvertFrom-Json
            $script:capturing   = [bool]$j.Capturing
            $script:stripImages = [bool]$j.StripImages
            $script:tabs        = @()
            foreach ($t in @($j.Tabs)) {
                $items = @()
                foreach ($it in @($t.Items)) {
                    if ($null -ne $it) {
                        $itype = 'text'
                        if ($it.PSObject.Properties['Type'] -and $it.Type) { $itype = [string]$it.Type }
                        $ifile = ''
                        if ($it.PSObject.Properties['ImageFile']) { $ifile = [string]$it.ImageFile }
                        $iw = 0; $ih = 0
                        if ($it.PSObject.Properties['W']) { $iw = [int]$it.W }
                        if ($it.PSObject.Properties['H']) { $ih = [int]$it.H }
                        $items += [pscustomobject]@{
                            Type      = $itype
                            Text      = [string]$it.Text
                            ImageFile = $ifile
                            W         = $iw
                            H         = $ih
                            Time      = [string]$it.Time
                        }
                    }
                }
                $script:tabs += [pscustomobject]@{ Name = [string]$t.Name; Items = $items }
            }
            $script:activeTab = [string]$j.ActiveTab
            if ($j.PSObject.Properties['CaptureTab']) { $script:captureTab = [string]$j.CaptureTab }
        } catch { }
    }
    if (-not $script:tabs -or @($script:tabs).Count -eq 0) {
        $script:tabs = @([pscustomobject]@{ Name = 'General'; Items = @() })
    }
    $foundCapture = $script:tabs | Where-Object { $_.Name -eq $script:captureTab } | Select-Object -First 1
    if (-not $foundCapture) { $script:captureTab = @($script:tabs)[0].Name }
    $found = $script:tabs | Where-Object { $_.Name -eq $script:activeTab } | Select-Object -First 1
    if (-not $found -and -not (Test-ViewTab $script:activeTab)) { $script:activeTab = $script:captureTab }
}

function New-DefaultSettings {
    return [pscustomobject]@{
        Theme            = 'Swiss'
        OcrProvider      = 'Auto'
        OcrSpaceKey      = ''
        OcrSpaceLanguage = 'eng'
        AzureEndpoint    = ''
        AzureKey         = ''
        GoogleKey        = ''
        PaddleEndpoint   = ''
        PaddleKey        = ''
        PaddleKeyHeader  = 'Authorization'
        PaddleMode       = 'Hub'
        PaddleTokenUrl   = ''
        PaddleClientId   = ''
        PaddleClientSecret = ''
        PaddleScope      = ''
        AutoNameImages   = 'True'
    }
}

function Load-Settings {
    $script:settings = New-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in @($script:settings.PSObject.Properties)) {
                if ($j.PSObject.Properties[$p.Name]) { $p.Value = [string]$j.($p.Name) }
            }
        } catch { }
    }
}

function Save-Settings {
    try {
        $script:settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { }
}

function Get-ActiveTab {
    return ($script:tabs | Where-Object { $_.Name -eq $script:activeTab } | Select-Object -First 1)
}

function Test-ViewTab([string]$name) {
    foreach ($v in @($script:viewTabs)) {
        if ($v -eq $name) { return $true }
    }
    return $false
}

function Get-ViewFilter([string]$name) {
    if ($name -eq 'Text') { return 'text' }
    if ($name -eq 'Images') { return 'image' }
    return 'all'
}

function Get-ViewItems([string]$name) {
    $filter = Get-ViewFilter $name
    $out = @()
    foreach ($t in @($script:tabs)) {
        foreach ($it in @($t.Items)) {
            if ($filter -eq 'all' -or [string]$it.Type -eq $filter) { $out += $it }
        }
    }
    if (@($out).Count -gt 1) { $out = @($out | Sort-Object -Property Time -Descending) }
    return @($out)
}

function Get-StorageTab {
    $name = [string]$script:activeTab
    if (Test-ViewTab $name) { $name = [string]$script:captureTab }
    $t = $script:tabs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $t) { $t = @($script:tabs)[0] }
    return $t
}

function Find-ItemTab($item) {
    foreach ($t in @($script:tabs)) {
        foreach ($i in @($t.Items)) {
            if ([object]::ReferenceEquals($i, $item)) { return $t }
        }
    }
    return $null
}

function Get-RecentItem {
    $best = $null
    foreach ($t in @($script:tabs)) {
        foreach ($it in @($t.Items)) {
            if (-not $best -or [string]$it.Time -gt [string]$best.Time) { $best = $it }
        }
    }
    return $best
}

function Update-ToggleUI {
    if (-not $script:btnToggle) { return }
    $t = $script:Theme
    if ($script:capturing) {
        $script:btnToggle.Text      = ([char]0x25CF).ToString() + '  CAPTURING'
        $script:btnToggle.BackColor = $t.ToggleOnBg
        $script:btnToggle.ForeColor = $t.ToggleOnText
        $script:btnToggle.FlatAppearance.BorderColor = $t.ToggleOnBorder
        $script:btnToggle.FlatAppearance.BorderSize = $t.ButtonBorderWidth
        $script:btnToggle.FlatAppearance.MouseOverBackColor = $t.BtnPrimaryHover
        $script:btnToggle.FlatAppearance.MouseDownBackColor = $t.BtnPrimaryDown
        if ($script:timer) { $script:timer.Start() }
        if ($script:notify) { $script:notify.Text = 'Clippr - capturing' }
    } else {
        $script:btnToggle.Text      = ([char]0x25CB).ToString() + '  PAUSED'
        $script:btnToggle.BackColor = $t.ToggleOffBg
        $script:btnToggle.ForeColor = $t.ToggleOffText
        $script:btnToggle.FlatAppearance.BorderColor = $t.ToggleOffBorder
        $script:btnToggle.FlatAppearance.BorderSize = $t.ButtonBorderWidth
        $script:btnToggle.FlatAppearance.MouseOverBackColor = $t.BtnSecondaryHover
        $script:btnToggle.FlatAppearance.MouseDownBackColor = $t.BtnSecondaryDown
        if ($script:timer) { $script:timer.Stop() }
        if ($script:notify) { $script:notify.Text = 'Clippr - paused' }
    }
    $script:btnToggle.Font = New-Object System.Drawing.Font($t.ButtonFont, 9.5, [System.Drawing.FontStyle]::Bold)
    Set-RoundedRegion $script:btnToggle $t.ButtonRadius
}

function Refresh-Tabs {
    if (-not $script:tabList) { return }
    $script:tabList.BeginUpdate()
    $script:tabList.Items.Clear()
    foreach ($v in @($script:viewTabs)) { [void]$script:tabList.Items.Add($v) }
    foreach ($t in $script:tabs) { [void]$script:tabList.Items.Add($t.Name) }
    $script:tabList.EndUpdate()
    $names = @($script:viewTabs) + @($script:tabs | ForEach-Object { $_.Name })
    $idx = -1
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ($names[$i] -eq $script:activeTab) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        $script:activeTab = @($script:tabs)[0].Name
        $idx = @($script:viewTabs).Count
    }
    $script:tabList.SelectedIndex = $idx
}

function Refresh-Hist {
    if (-not $script:histList) { return }
    $prev = $script:histList.SelectedItem
    $prevKey = ''
    if ($prev) { $prevKey = [string]$prev.Time + '|' + [string]$prev.ImageFile + '|' + [string]$prev.Type }
    $script:histList.BeginUpdate()
    $script:histList.Items.Clear()
    $script:histList.SelectedIndex = -1
    $isView = Test-ViewTab $script:activeTab
    if ($isView) {
        $items = @(Get-ViewItems $script:activeTab)
    } else {
        $tab = Get-ActiveTab
        if ($tab) { $items = @($tab.Items) } else { $items = @() }
    }
    $count = 0
    $restore = -1
    $filter = ''
    if ($script:txtSearch) { $filter = $script:txtSearch.Text.Trim().ToLower() }
    foreach ($it in @($items)) {
        if ($filter) {
            $hay = ([string]$it.Text + ' ' + [string]$it.Type).ToLower()
            if (-not $hay.Contains($filter)) { continue }
        }
        [void]$script:histList.Items.Add($it)
        if ($prevKey -and (([string]$it.Time + '|' + [string]$it.ImageFile + '|' + [string]$it.Type) -eq $prevKey)) {
            $restore = $script:histList.Items.Count - 1
        }
        $count++
    }
    if ($restore -ge 0) { $script:histList.SelectedIndex = $restore }
    $script:histList.EndUpdate()
    try { [void][ClipprNative]::ShowScrollBar($script:histList.Handle, 1, $false) } catch { }
    Set-DarkScrollBars $script:histList
    Update-HistScroll
    if ($script:lblStatus) {
        if ($isView) {
            $script:lblStatus.Text = "$count item(s) in '$($script:activeTab)' view    |    New clips go to '$($script:captureTab)'    |    Saved: $($script:DataFile)"
        } else {
            $script:lblStatus.Text = "$count item(s) in '$($script:activeTab)'    |    Saved: $($script:DataFile)"
        }
        if ($count -eq 0 -and -not $filter) {
            $script:lblStatus.Text = "Empty in here, hero. Copy something and it lands in '$($script:captureTab)'.    |    Saved: $($script:DataFile)"
        }
    }
}

function ConvertTo-Crlf([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    return (($s -replace "`r`n", "`n") -replace "`n", "`r`n")
}

function Add-Clip([string]$text) {
    $text = ConvertTo-Crlf $text
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -eq $script:lastCaptured) { return $false }
    if ($text.Length -gt 200000) { $text = $text.Substring(0, 200000) }
    $script:lastCaptured = $text
    $tab = Get-StorageTab
    if (-not $tab) { return $false }
    $it = [pscustomobject]@{
        Type      = 'text'
        Text      = $text
        ImageFile = ''
        W         = 0
        H         = 0
        Time      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $tab.Items = @($it) + @($tab.Items)
    if (@($tab.Items).Count -gt 500) { $tab.Items = @(@($tab.Items)[0..499]) }
    Save-State
    Refresh-Hist
    return $true
}

function Get-ImageFingerprint($img) {
    try {
        $w = $img.Width; $h = $img.Height
        $n = 24
        $bmp = New-Object System.Drawing.Bitmap($n, $n)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($img, 0, 0, $n, $n)
        $g.Dispose()
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($w).Append(' x ').Append($h)
        for ($yy = 0; $yy -lt $n; $yy++) {
            for ($xx = 0; $xx -lt $n; $xx++) {
                [void]$sb.Append(':').Append($bmp.GetPixel($xx, $yy).ToArgb())
            }
        }
        $bmp.Dispose()
        return $sb.ToString()
    } catch { return [guid]::NewGuid().ToString() }
}

function Add-Image($img, [string]$label = 'Image') {
    if (-not $img) { return $false }
    $tab = Get-StorageTab
    if (-not $tab) { return $false }
    $name = [guid]::NewGuid().ToString('N') + '.png'
    $path = Join-Path $script:ImagesDir $name
    try { $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } catch { return $false }
    $it = [pscustomobject]@{
        Type      = 'image'
        Text      = $label
        ImageFile = $name
        W         = [int]$img.Width
        H         = [int]$img.Height
        Time      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $tab.Items = @($it) + @($tab.Items)
    if (@($tab.Items).Count -gt 500) { $tab.Items = @(@($tab.Items)[0..499]) }
    $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
    Save-State
    Refresh-Hist
    Queue-AutoName $it
    return $true
}

# ---------- background image naming (OCR title) ----------
function Queue-AutoName($it) {
    if (-not $script:settings) { return }
    if ([string]$script:settings.AutoNameImages -ne 'True') { return }
    if (-not $it -or [string]$it.Type -ne 'image' -or [string]::IsNullOrEmpty([string]$it.ImageFile)) { return }
    [void]$script:autoNameQueue.Add($it)
    if ($script:nameTimer -and -not $script:nameTimer.Enabled) { $script:nameTimer.Start() }
}

function Get-FirstOcrLine([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    foreach ($ln in ($text -split "\r?\n")) {
        $s = ($ln -replace '\s+', ' ').Trim()
        if ($s.Length -ge 2) { return $s }
    }
    return ''
}

function Start-AutoNameJob($it, [string]$path) {
    $out = Join-Path $script:AppDir ('autoname-' + [guid]::NewGuid().ToString('N') + '.txt')
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + [string]$script:SelfPath + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.EnvironmentVariables['CLIPPR_OCR_JOB'] = '1'
    $psi.EnvironmentVariables['CLIPPR_OCR_IMAGE'] = $path
    $psi.EnvironmentVariables['CLIPPR_OCR_OUT'] = $out
    try {
        $script:autoNameProc = [System.Diagnostics.Process]::Start($psi)
        $script:autoNameOut = $out
        $script:autoNameCurrent = $it
        $script:autoNameStarted = Get-Date
        $script:autoNameBusy = $true
        return $true
    } catch {
        try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch { }
        $script:autoNameProc = $null
        $script:autoNameOut = ''
        $script:autoNameCurrent = $null
        $script:autoNameBusy = $false
        return $false
    }
}

function Complete-AutoNameJob {
    $p = $script:autoNameProc
    if (-not $p) { return $false }
    $timedOut = $false
    try {
        if (-not $p.HasExited) {
            if (((Get-Date) - $script:autoNameStarted).TotalSeconds -gt 150) {
                $timedOut = $true
                try { $p.Kill() } catch { }
            } else {
                return $false
            }
        }
    } catch { }

    $text = ''
    $out = $script:autoNameOut
    if ($out -and (Test-Path -LiteralPath $out)) {
        for ($i = 0; $i -lt 5; $i++) {
            try { $text = [System.IO.File]::ReadAllText($out); break } catch { Start-Sleep -Milliseconds 80 }
        }
    }
    $it = $script:autoNameCurrent
    try { $p.WaitForExit(2000) | Out-Null } catch { }
    try { $p.Dispose() } catch { }
    $script:autoNameProc = $null
    $script:autoNameOut = ''
    $script:autoNameCurrent = $null
    $script:autoNameStarted = [datetime]::MinValue
    $script:autoNameBusy = $false
    if ($out) { try { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue } catch { } }

    if ($it -and -not $timedOut) {
        $line = Get-FirstOcrLine ([string]$text)
        if ($line.Length -gt 80) { $line = $line.Substring(0, 77) + '...' }
        if ($line.Length -ge 2) {
            $owner = Find-ItemTab $it
            if ($owner) {
                $it.Text = $line
                Save-State
                Refresh-Hist
                if ($script:lblStatus) {
                    $script:lblStatus.Text = "Named image: $line    |    Saved: $($script:DataFile)"
                }
            }
        }
    }
    return $true
}

function Invoke-AutoNameQueue {
    [void](Complete-AutoNameJob)
    if ($script:autoNameProc) { return }
    while ($script:autoNameQueue -and $script:autoNameQueue.Count -gt 0) {
        $it = $script:autoNameQueue[0]
        $script:autoNameQueue.RemoveAt(0)
        if (-not $it) { continue }
        $path = Join-Path $script:ImagesDir ([string]$it.ImageFile)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (-not (Find-ItemTab $it)) { continue }
        if (Start-AutoNameJob $it $path) {
            if ($script:lblStatus) { $script:lblStatus.Text = 'Image saved. Reading its name in the background...' }
            return
        }
    }
}

function Get-Thumb([string]$file) {
    if ([string]::IsNullOrEmpty($file)) { return $null }
    if ($script:thumbCache.ContainsKey($file)) { return $script:thumbCache[$file] }
    $path = Join-Path $script:ImagesDir $file
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $src = [System.Drawing.Image]::FromFile($path)
        $box = 48
        $ratio = [Math]::Min($box / $src.Width, $box / $src.Height)
        $nw = [int]($src.Width * $ratio); $nh = [int]($src.Height * $ratio)
        if ($nw -lt 1) { $nw = 1 }
        if ($nh -lt 1) { $nh = 1 }
        $thumb = New-Object System.Drawing.Bitmap($box, $box)
        $tg = [System.Drawing.Graphics]::FromImage($thumb)
        $tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $tg.Clear([System.Drawing.Color]::FromArgb(24, 24, 24))
        $tg.DrawImage($src, [int](($box - $nw) / 2), [int](($box - $nh) / 2), $nw, $nh)
        $tg.Dispose()
        $src.Dispose()
        $script:thumbCache[$file] = $thumb
        return $thumb
    } catch { return $null }
}

function Get-OcrText([string]$path) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.IRandomAccessStream, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

    function AwaitLocal($op, $type) {
        $asTask = $asTaskGeneric.MakeGenericMethod($type)
        $task = $asTask.Invoke($null, @($op))
        $task.Wait(-1) | Out-Null
        return $task.Result
    }

    $file = AwaitLocal ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = AwaitLocal ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = AwaitLocal ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $soft = AwaitLocal ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) {
        $lang = New-Object Windows.Globalization.Language('en-US')
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    }
    if (-not $engine) { throw 'No OCR engine is installed on this PC.' }

    $res = AwaitLocal ($engine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])
    return [string]$res.Text
}

function Get-ImageBase64([string]$path, [int]$maxDim = 2000, [int]$quality = 82) {
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        $w = $img.Width; $h = $img.Height
        $scale = 1.0
        if ($w -gt $maxDim -or $h -gt $maxDim) {
            $scale = [Math]::Min([double]$maxDim / $w, [double]$maxDim / $h)
        }
        $nw = [int][Math]::Max(1, [Math]::Round($w * $scale))
        $nh = [int][Math]::Max(1, [Math]::Round($h * $scale))
        $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $nw, $nh)
            $g.Dispose()

            $codec = $null
            foreach ($c in [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()) {
                if ($c.MimeType -eq 'image/jpeg') { $codec = $c; break }
            }
            $ms = New-Object System.IO.MemoryStream
            if ($codec) {
                $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
                $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter -ArgumentList @([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
                $bmp.Save($ms, $codec, $ep)
                $ep.Dispose()
            } else {
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            }
            $bytes = $ms.ToArray()
            $ms.Dispose()
            return [Convert]::ToBase64String($bytes)
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

function Get-ImageBase64Png([string]$path, [int]$maxDim = 2200) {
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        $w = $img.Width; $h = $img.Height
        $scale = 1.0
        if ($w -gt $maxDim -or $h -gt $maxDim) {
            $scale = [Math]::Min([double]$maxDim / $w, [double]$maxDim / $h)
        }
        if ($scale -ge 0.999) {
            return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
        }
        $nw = [int][Math]::Max(1, [Math]::Round($w * $scale))
        $nh = [int][Math]::Max(1, [Math]::Round($h * $scale))
        $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $nw, $nh)
            $g.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Dispose()
            return [Convert]::ToBase64String($bytes)
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

function Invoke-OcrSpace([string]$path) {
    $key = ([string]$script:settings.OcrSpaceKey).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'OCR.space API key is not set.' }
    $lang = ([string]$script:settings.OcrSpaceLanguage).Trim()
    if ([string]::IsNullOrWhiteSpace($lang)) { $lang = 'eng' }

    $b64 = Get-ImageBase64 $path 1600 82
    $body = @{
        apikey      = $key
        base64Image = 'data:image/jpeg;base64,' + $b64
        language    = $lang
        OCREngine   = '2'
        scale       = 'true'
        isTable     = 'false'
    }
    $r = Invoke-RestMethod -Method Post -Uri 'https://api.ocr.space/parse/image' -Body $body -TimeoutSec 90
    if ($r.IsErroredOnProcessing) {
        $msg = @($r.ErrorMessage) -join ' '
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'unknown error' }
        throw "OCR.space: $msg"
    }
    $out = ''
    foreach ($p in @($r.ParsedResults)) {
        if ($p -and $p.ParsedText) { $out += [string]$p.ParsedText }
    }
    return $out
}

function Invoke-AzureOcr([string]$path) {
    $ep  = ([string]$script:settings.AzureEndpoint).Trim()
    $key = ([string]$script:settings.AzureKey).Trim()
    if ([string]::IsNullOrWhiteSpace($ep)) { throw 'Azure endpoint is not set.' }
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Azure key is not set.' }
    $ep = $ep.TrimEnd('/')
    $uri = "$ep/vision/v3.2/ocr?language=unk&detectOrientation=true"
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $r = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ 'Ocp-Apim-Subscription-Key' = $key } -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 90

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($reg in @($r.regions)) {
        foreach ($ln in @($reg.lines)) {
            $words = @()
            foreach ($wd in @($ln.words)) { $words += [string]$wd.text }
            if ($words.Count -gt 0) { [void]$lines.Add(($words -join ' ')) }
        }
    }
    return ($lines -join "`n")
}

function Invoke-GoogleOcr([string]$path) {
    $key = ([string]$script:settings.GoogleKey).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'Google Cloud Vision API key is not set.' }
    $b64 = Get-ImageBase64 $path 2500 85
    $payload = @{
        requests = @(
            @{
                image    = @{ content = $b64 }
                features = @(@{ type = 'TEXT_DETECTION'; maxResults = 1 })
            }
        )
    } | ConvertTo-Json -Depth 8
    $uri = 'https://vision.googleapis.com/v1/images:annotate?key=' + [uri]::EscapeDataString($key)
    $r = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $payload -TimeoutSec 90
    $resp = @($r.responses)[0]
    if ($resp.error) { throw "Google Vision: $($resp.error.message)" }
    if ($resp.fullTextAnnotation -and $resp.fullTextAnnotation.text) { return [string]$resp.fullTextAnnotation.text }
    if ($resp.textAnnotations) { return [string]@($resp.textAnnotations)[0].description }
    return ''
}

function Get-OcrTextFromAny {
    param($o, [int]$depth = 0)
    if ($null -eq $o -or $depth -gt 9) { return '' }
    if ($o -is [string]) { return [string]$o }

    if ($o -is [System.Collections.IDictionary]) {
        foreach ($k in @('text', 'rec_text', 'content', 'description', 'ParsedText')) {
            if ($o.Contains($k) -and -not [string]::IsNullOrWhiteSpace([string]$o[$k])) { return [string]$o[$k] }
        }
        if ($o.Contains('rec_texts') -and $o['rec_texts']) { return (@($o['rec_texts']) -join "`n") }
        foreach ($k in @('results', 'result', 'res', 'data', 'lines', 'regions', 'words', 'ocr_result', 'ocrResults', 'prunedResult', 'texts', 'text_detections', 'text_prediction')) {
            if ($o.Contains($k) -and $null -ne $o[$k]) {
                $t = Get-OcrTextFromAny $o[$k] ($depth + 1)
                if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
            }
        }
        return ''
    }

    if ($o -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($i in $o) {
            $t = Get-OcrTextFromAny $i ($depth + 1)
            if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$parts.Add($t.Trim()) }
        }
        return ($parts -join "`n")
    }

    foreach ($name in @('text', 'rec_text', 'content', 'description', 'ParsedText', 'fullTextAnnotation')) {
        $prop = $o.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            if ($name -eq 'fullTextAnnotation') { return (Get-OcrTextFromAny $prop.Value ($depth + 1)) }
            return [string]$prop.Value
        }
    }
    $rt = $o.PSObject.Properties['rec_texts']
    if ($rt -and $rt.Value) { return (@($rt.Value) -join "`n") }
    foreach ($name in @('results', 'result', 'res', 'data', 'lines', 'regions', 'words', 'ocr_result', 'ocrResults', 'prunedResult', 'texts', 'text_detections', 'text_prediction')) {
        $prop = $o.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $t = Get-OcrTextFromAny $prop.Value ($depth + 1)
            if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
        }
    }
    return ''
}

function Invoke-PaddleMultipart([string]$Uri, [string]$Path, [hashtable]$Headers) {
    $bytes = [Convert]::FromBase64String((Get-ImageBase64 $Path 2500 88))
    $boundary = [guid]::NewGuid().ToString('N')
    $ms = New-Object System.IO.MemoryStream
    $enc = [System.Text.Encoding]::UTF8
    $head = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"image.jpg`"`r`nContent-Type: image/jpeg`r`n`r`n"
    $hb = $enc.GetBytes($head)
    $ms.Write($hb, 0, $hb.Length)
    $ms.Write($bytes, 0, $bytes.Length)
    $tail = "`r`n--$boundary--`r`n"
    $tb = $enc.GetBytes($tail)
    $ms.Write($tb, 0, $tb.Length)
    $body = $ms.ToArray()
    $ms.Dispose()
    $h = @{}
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    $h['Content-Type'] = "multipart/form-data; boundary=$boundary"
    return Invoke-RestMethod -Method Post -Uri $Uri -Headers $h -Body $body -TimeoutSec 120
}

function Get-GraviteeToken([string]$TokenUrl, [string]$ClientId, [string]$ClientSecret, [string]$Scope) {
    $cacheKey = $TokenUrl + '|' + $ClientId
    if ($script:oauthToken -and $script:oauthTokenKey -eq $cacheKey -and (Get-Date) -lt $script:oauthTokenExpiry) {
        return $script:oauthToken
    }
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
    }
    if (-not [string]::IsNullOrWhiteSpace($Scope)) { $body['scope'] = $Scope }
    $r = Invoke-RestMethod -Method Post -Uri $TokenUrl -Body $body -TimeoutSec 60
    if (-not $r.access_token) { throw 'Token endpoint returned no access_token.' }
    $script:oauthToken = [string]$r.access_token
    $script:oauthTokenKey = $cacheKey
    $exp = 300
    if ($r.expires_in) { try { $exp = [int]$r.expires_in } catch { } }
    if ($exp -lt 60) { $exp = 60 }
    $script:oauthTokenExpiry = (Get-Date).AddSeconds($exp - 30)
    return $script:oauthToken
}

function Invoke-PaddleOcr([string]$path) {
    $ep = ([string]$script:settings.PaddleEndpoint).Trim()
    if ([string]::IsNullOrWhiteSpace($ep)) { throw 'PaddleOCR endpoint URL is not set.' }

    $headers = @{}
    $tokenUrl     = ([string]$script:settings.PaddleTokenUrl).Trim()
    $clientId     = ([string]$script:settings.PaddleClientId).Trim()
    $clientSecret = ([string]$script:settings.PaddleClientSecret).Trim()
    if ($tokenUrl -and $clientId -and $clientSecret) {
        $token = Get-GraviteeToken -TokenUrl $tokenUrl -ClientId $clientId -ClientSecret $clientSecret -Scope ([string]$script:settings.PaddleScope).Trim()
        $headers['Authorization'] = 'Bearer ' + $token
    } else {
        $key = ([string]$script:settings.PaddleKey).Trim()
        if ($key) {
            $hname = ([string]$script:settings.PaddleKeyHeader).Trim()
            if ([string]::IsNullOrWhiteSpace($hname)) { $hname = 'Authorization' }
            if ($hname -ieq 'Authorization' -and $key -notmatch '(?i)^\s*(Bearer|Basic)\s') { $key = 'Bearer ' + $key }
            $headers[$hname] = $key
        }
    }

    $mode = [string]$script:settings.PaddleMode
    if ($mode -eq 'Multipart') {
        $r = Invoke-PaddleMultipart -Uri $ep -Path $path -Headers $headers
    } elseif ($mode -eq 'ImageUrl') {
        $b64 = Get-ImageBase64Png $path 2200
        $payload = @{
            input = @(
                @{
                    type = 'image_url'
                    url  = 'data:image/png;base64,' + $b64
                }
            )
        } | ConvertTo-Json -Depth 8
        $r = Invoke-RestMethod -Method Post -Uri $ep -Headers $headers -ContentType 'application/json' -Body $payload -TimeoutSec 120
    } else {
        $b64 = Get-ImageBase64 $path 2500 88
        $payload = @{ images = @($b64) } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod -Method Post -Uri $ep -Headers $headers -ContentType 'application/json' -Body $payload -TimeoutSec 120
    }

    $text = Get-OcrTextFromAny $r
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'PaddleOCR returned no text. Check the endpoint URL and response mode.' }
    return $text
}

function Get-ConfiguredCloudProvider {
    $p = [string]$script:settings.OcrProvider
    if ($p -eq 'OCRSpace' -or $p -eq 'Azure' -or $p -eq 'Google' -or $p -eq 'Paddle') { return $p }
    if ($p -eq 'Auto' -or [string]::IsNullOrWhiteSpace($p)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:settings.OcrSpaceKey)) { return 'OCRSpace' }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:settings.AzureKey) -and -not [string]::IsNullOrWhiteSpace([string]$script:settings.AzureEndpoint)) { return 'Azure' }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:settings.GoogleKey)) { return 'Google' }
        if (-not [string]::IsNullOrWhiteSpace([string]$script:settings.PaddleEndpoint)) { return 'Paddle' }
    }
    return ''
}

function Invoke-CloudOcr([string]$provider, [string]$path) {
    switch ($provider) {
        'OCRSpace' { return Invoke-OcrSpace $path }
        'Azure'    { return Invoke-AzureOcr $path }
        'Google'   { return Invoke-GoogleOcr $path }
        'Paddle'   { return Invoke-PaddleOcr $path }
        default    { throw "Unknown OCR provider '$provider'." }
    }
}

function Invoke-OcrText([string]$path) {
    $script:ocrNotice = ''
    $provider = Get-ConfiguredCloudProvider
    if ($provider) {
        try {
            $text = Invoke-CloudOcr $provider $path
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'The cloud OCR provider returned no text.' }
            return $text
        } catch {
            $script:ocrNotice = "Cloud OCR ($provider) failed: $($_.Exception.Message) - used Windows OCR instead."
        }
    }
    return (Get-OcrText $path)
}

function New-OcrTestImage {
    $bmp = New-Object System.Drawing.Bitmap(620, 200)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $f1 = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Regular)
        $f2 = New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)
        $g.DrawString('Clippr OCR key test', $f1, [System.Drawing.Brushes]::Black, 24, 28)
        $g.DrawString('Authenticate 12345', $f2, [System.Drawing.Brushes]::Black, 24, 80)
        $f1.Dispose(); $f2.Dispose(); $g.Dispose()
        $tmp = Join-Path $env:TEMP ('clippr-ocr-test-' + [guid]::NewGuid().ToString('N') + '.png')
        $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        return $tmp
    } finally { $bmp.Dispose() }
}

function Test-OcrProvider {
    $tmp = New-OcrTestImage
    try {
        $p = [string]$script:settings.OcrProvider
        if ($p -eq 'Windows') {
            $text = Get-OcrText $tmp
        } elseif ($p -eq 'Auto' -or [string]::IsNullOrWhiteSpace($p)) {
            $cp = Get-ConfiguredCloudProvider
            if ($cp) { $text = Invoke-CloudOcr $cp $tmp } else { $text = Get-OcrText $tmp }
        } else {
            $text = Invoke-CloudOcr $p $tmp
        }
        $text = ([string]$text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'No text was recognized in the test image.' }
        return $text
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Open-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Clippr - Settings / Store'
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 930)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $C_BG
    $dlg.ForeColor = $C_TEXT
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    try {
        $dlg.BackgroundImage = New-DialogBackground $dlg.ClientSize.Width $dlg.ClientSize.Height
        $dlg.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
    } catch { }

    function Add-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [single]$size = 9, [bool]$bold = $false, $color = $null) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $l.Font = New-Object System.Drawing.Font('Segoe UI', $size, $style)
        $l.ForeColor = if ($color) { $color } else { $C_TEXT }
        $l.BackColor = [System.Drawing.Color]::Transparent
        $dlg.Controls.Add($l)
        return $l
    }

    function Add-Text([string]$text, [int]$x, [int]$y, [int]$w, [bool]$secret = $false) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = $text
        $t.Location = New-Object System.Drawing.Point($x, $y)
        $t.Size = New-Object System.Drawing.Size($w, 26)
        $t.BackColor = $C_PANEL2
        $t.ForeColor = $C_TEXT
        $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $t.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        if ($secret) { $t.UseSystemPasswordChar = $true }
        $dlg.Controls.Add($t)
        return $t
    }

    [void](Add-Label 'SETTINGS / STORE' 22 14 300 30 16 $true)
    [void](Add-Label 'Bring your own OCR keys. Keys are stored only on this PC (settings.json) and never uploaded.' 24 46 590 20 8 $false $C_MUTED)

    [void](Add-Label 'THEME' 342 17 54 18 8 $true $C_MUTED)
    $cboTheme = New-Object System.Windows.Forms.ComboBox
    $cboTheme.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboTheme.Location = New-Object System.Drawing.Point(400, 10)
    $cboTheme.Size = New-Object System.Drawing.Size(216, 26)
    $cboTheme.BackColor = $C_PANEL2
    $cboTheme.ForeColor = $C_TEXT
    $cboTheme.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cboTheme.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    [void]$cboTheme.Items.AddRange(@('Swiss Paper', 'Midnight Brass', 'Neo-Brutalist', 'Calm Slate'))
    $themeValues = @('Swiss', 'Brass', 'Brutal', 'Calm')
    $ti = [Array]::IndexOf($themeValues, [string]$script:settings.Theme)
    if ($ti -lt 0) { $ti = 0 }
    $cboTheme.SelectedIndex = $ti
    $dlg.Controls.Add($cboTheme)

    [void](Add-Label 'OCR provider' 24 80 130 22 9 $true)
    $cboProv = New-Object System.Windows.Forms.ComboBox
    $cboProv.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboProv.Location = New-Object System.Drawing.Point(170, 76)
    $cboProv.Size = New-Object System.Drawing.Size(440, 26)
    $cboProv.BackColor = $C_PANEL2
    $cboProv.ForeColor = $C_TEXT
    $cboProv.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cboProv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    [void]$cboProv.Items.AddRange(@('Auto (cloud key if set, else Windows)', 'Windows OCR (built-in, no key)', 'OCR.space', 'Azure AI Vision', 'Google Cloud Vision', 'PaddleOCR (self-hosted)'))
    $provValues = @('Auto', 'Windows', 'OCRSpace', 'Azure', 'Google', 'Paddle')
    $idx = [Array]::IndexOf($provValues, [string]$script:settings.OcrProvider)
    if ($idx -lt 0) { $idx = 0 }
    $cboProv.SelectedIndex = $idx
    $dlg.Controls.Add($cboProv)

    [void](Add-Label 'OCR.space' 24 116 300 22 9 $true $C_ACCENT)
    [void](Add-Label 'API key' 24 148 130 22)
    $txtOsKey = Add-Text ([string]$script:settings.OcrSpaceKey) 170 144 440 $true
    [void](Add-Label 'Language' 24 184 130 22)
    $txtOsLang = Add-Text ([string]$script:settings.OcrSpaceLanguage) 170 180 120 $false
    [void](Add-Label 'e.g. eng, deu, hin' 300 184 200 20 8 $false $C_MUTED)

    [void](Add-Label 'Azure AI Vision' 24 216 300 22 9 $true $C_ACCENT)
    [void](Add-Label 'Endpoint' 24 248 130 22)
    $txtAzEp = Add-Text ([string]$script:settings.AzureEndpoint) 170 244 440 $false
    [void](Add-Label 'Key' 24 284 130 22)
    $txtAzKey = Add-Text ([string]$script:settings.AzureKey) 170 280 440 $true

    [void](Add-Label 'Google Cloud Vision' 24 316 300 22 9 $true $C_ACCENT)
    [void](Add-Label 'API key' 24 348 130 22)
    $txtGKey = Add-Text ([string]$script:settings.GoogleKey) 170 344 440 $true

    [void](Add-Label 'PaddleOCR (self-hosted)' 24 380 300 22 9 $true $C_ACCENT)
    [void](Add-Label 'Endpoint URL' 24 412 130 22)
    $txtPdEp = Add-Text ([string]$script:settings.PaddleEndpoint) 170 408 440 $false
    [void](Add-Label 'API key (optional)' 24 448 130 22)
    $txtPdKey = Add-Text ([string]$script:settings.PaddleKey) 170 444 440 $true
    [void](Add-Label 'Key header' 24 484 130 22)
    $txtPdHdr = Add-Text ([string]$script:settings.PaddleKeyHeader) 170 480 200 $false
    [void](Add-Label '(default: Authorization)' 384 484 220 20 8 $false $C_MUTED)
    [void](Add-Label 'Request mode' 24 520 130 22)
    $cboPdMode = New-Object System.Windows.Forms.ComboBox
    $cboPdMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cboPdMode.Location = New-Object System.Drawing.Point(170, 516)
    $cboPdMode.Size = New-Object System.Drawing.Size(300, 26)
    $cboPdMode.BackColor = $C_PANEL2
    $cboPdMode.ForeColor = $C_TEXT
    $cboPdMode.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cboPdMode.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $pdModes = @('Hub', 'Multipart', 'ImageUrl')
    [void]$cboPdMode.Items.AddRange(@('PaddleHub JSON (images[])', 'Multipart form (file)', 'Gravitee / image_url (input[])'))
    $mi = [Array]::IndexOf($pdModes, [string]$script:settings.PaddleMode)
    if ($mi -lt 0) { $mi = 0 }
    $cboPdMode.SelectedIndex = $mi
    $dlg.Controls.Add($cboPdMode)

    [void](Add-Label 'OAuth2 token URL' 24 556 130 22)
    $txtPdToken = Add-Text ([string]$script:settings.PaddleTokenUrl) 170 552 440 $false
    [void](Add-Label 'Client ID' 24 592 130 22)
    $txtPdCid = Add-Text ([string]$script:settings.PaddleClientId) 170 588 190 $false
    [void](Add-Label 'Client secret' 372 592 92 22)
    $txtPdCsec = Add-Text ([string]$script:settings.PaddleClientSecret) 468 588 142 $true
    [void](Add-Label 'Scope (optional)' 24 628 130 22)
    $txtPdScope = Add-Text ([string]$script:settings.PaddleScope) 170 624 200 $false
    [void](Add-Label 'OAuth2 overrides API key header.' 380 628 240 20 8 $false $C_MUTED)

    $chkShow = New-Object System.Windows.Forms.CheckBox
    $chkShow.Text = 'Show keys'
    $chkShow.Location = New-Object System.Drawing.Point(170, 664)
    $chkShow.AutoSize = $true
    $chkShow.ForeColor = $C_MUTED
    $chkShow.BackColor = [System.Drawing.Color]::Transparent
    $chkShow.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dlg.Controls.Add($chkShow)

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = 'Auto-name images with OCR'
    $chkAuto.Location = New-Object System.Drawing.Point(296, 664)
    $chkAuto.AutoSize = $true
    $chkAuto.ForeColor = $C_MUTED
    $chkAuto.BackColor = [System.Drawing.Color]::Transparent
    $chkAuto.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $chkAuto.Checked = ([string]$script:settings.AutoNameImages -eq 'True')
    $dlg.Controls.Add($chkAuto)
    $chkShow.Add_CheckedChanged({
        $txtOsKey.UseSystemPasswordChar = -not $chkShow.Checked
        $txtAzKey.UseSystemPasswordChar = -not $chkShow.Checked
        $txtGKey.UseSystemPasswordChar  = -not $chkShow.Checked
        $txtPdKey.UseSystemPasswordChar = -not $chkShow.Checked
        $txtPdCsec.UseSystemPasswordChar = -not $chkShow.Checked
    })

    $lblTest = Add-Label 'Providers are tried in order when set to Auto. If a key is missing or fails, Clippr falls back to Windows OCR.' 24 690 592 40 8 $false $C_MUTED

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = 'AUTHENTICATE'
    $btnTest.Size = New-Object System.Drawing.Size(150, 38)
    $btnTest.Location = New-Object System.Drawing.Point(24, 742)
    Style-Button $btnTest $false
    $btnTest.ForeColor = $C_ACCENT
    $dlg.Controls.Add($btnTest)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'SAVE'
    $btnSave.Size = New-Object System.Drawing.Size(110, 38)
    $btnSave.Location = New-Object System.Drawing.Point(404, 742)
    Style-Button $btnSave $true
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'CANCEL'
    $btnCancel.Size = New-Object System.Drawing.Size(110, 38)
    $btnCancel.Location = New-Object System.Drawing.Point(524, 742)
    Style-Button $btnCancel $false
    $dlg.Controls.Add($btnCancel)

    $help = Add-Label "Where to get keys:`n- OCR.space: ocr.space/ocrapi (free tier available)`n- Azure: Keys + endpoint from your Computer Vision resource`n- Google: enable the Cloud Vision API and create an API key`n- PaddleOCR: full URL of your server, optional API key + header (Gravitee API Key plan: X-Gravitee-Api-Key), or OAuth2 client credentials.`n`nRequest modes: PaddleHub JSON (images[]), Multipart (file), Gravitee image_url (input[]).`nThe Authenticate button runs the selected provider on a small test image. Keys stay local." 24 790 592 128 8 $false $C_MUTED

    $apply = {
        $script:settings.Theme            = $themeValues[$cboTheme.SelectedIndex]
        $script:settings.OcrProvider      = $provValues[$cboProv.SelectedIndex]
        $script:settings.OcrSpaceKey      = $txtOsKey.Text.Trim()
        $script:settings.OcrSpaceLanguage = $txtOsLang.Text.Trim()
        $script:settings.AzureEndpoint    = $txtAzEp.Text.Trim()
        $script:settings.AzureKey         = $txtAzKey.Text.Trim()
        $script:settings.GoogleKey        = $txtGKey.Text.Trim()
        $script:settings.PaddleEndpoint   = $txtPdEp.Text.Trim()
        $script:settings.PaddleKey        = $txtPdKey.Text.Trim()
        $script:settings.PaddleKeyHeader  = $txtPdHdr.Text.Trim()
        $script:settings.PaddleTokenUrl   = $txtPdToken.Text.Trim()
        $script:settings.PaddleClientId   = $txtPdCid.Text.Trim()
        $script:settings.PaddleClientSecret = $txtPdCsec.Text.Trim()
        $script:settings.PaddleScope      = $txtPdScope.Text.Trim()
        $script:settings.PaddleMode       = $pdModes[$cboPdMode.SelectedIndex]
        $script:settings.AutoNameImages   = [string]$chkAuto.Checked
        $script:oauthToken = ''
        $script:oauthTokenKey = ''
    }

    $btnSave.Add_Click({
        & $apply
        Save-Settings
        try { Apply-Theme $script:settings.Theme } catch { }
        if ($script:lblStatus) { $script:lblStatus.Text = 'Settings saved. Theme: ' + $script:Theme.Name + '   |   OCR provider: ' + $script:settings.OcrProvider }
        $dlg.Close()
    })

    $btnCancel.Add_Click({ $dlg.Close() })

    $btnTest.Add_Click({
        & $apply
        $btnTest.Enabled = $false
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblTest.ForeColor = $C_MUTED
        $lblTest.Text = 'Authenticating with the selected provider...'
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $text = Test-OcrProvider
            $flat = ($text -replace '\s+', ' ').Trim()
            if ($flat.Length -gt 70) { $flat = $flat.Substring(0, 70) + '...' }
            $lblTest.ForeColor = $C_ACCENT
            $lblTest.Text = "Authenticated. Test image recognized: $flat"
        } catch {
            $lblTest.ForeColor = [System.Drawing.Color]::FromArgb(255, 110, 110)
            $lblTest.Text = "Authentication failed: $($_.Exception.Message)"
        } finally {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnTest.Enabled = $true
        }
    })

    $dlg.Add_Shown({ Set-DarkTitleBar $dlg })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

function Run-Ocr {
    $sel = $script:histList.SelectedItem
    if (-not $sel) { return }
    if ($sel.Type -ne 'image') {
        [void][System.Windows.Forms.MessageBox]::Show('Select an image item first, then click OCR.', 'Clippr OCR')
        return
    }
    $path = Join-Path $script:ImagesDir $sel.ImageFile
    if (-not (Test-Path -LiteralPath $path)) {
        [void][System.Windows.Forms.MessageBox]::Show('The image file is missing.', 'Clippr OCR')
        return
    }
    $script:lblStatus.Text = 'Running OCR...'
    [System.Windows.Forms.Application]::DoEvents()
    $script:ocrNotice = ''
    try {
        $text = Invoke-OcrText $path
        $text = ($text -replace "`r", '').Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            [void][System.Windows.Forms.MessageBox]::Show('No readable text was found in that image.', 'Clippr OCR')
            $script:lblStatus.Text = 'OCR finished: no text found.'
            return
        }
        $text = ConvertTo-Crlf $text
        $added = Add-Clip $text
        [System.Windows.Forms.Clipboard]::SetText($text)
        $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
        if ($script:ocrNotice) {
            $script:lblStatus.Text = $script:ocrNotice
        } elseif ($added) {
            $script:lblStatus.Text = 'OCR text added to history and copied to clipboard.'
        } else {
            $script:lblStatus.Text = 'OCR text already in history. Copied to clipboard.'
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("OCR failed: $($_.Exception.Message)", 'Clippr OCR')
        $script:lblStatus.Text = 'OCR failed.'
    }
}

function Open-Preview($item) {
    if (-not $item) { return }
    $isImage = ([string]$item.Type -eq 'image')
    $imgPath = ''
    $bmp = $null
    $text = ''
    if ($isImage) {
        $imgPath = Join-Path $script:ImagesDir ([string]$item.ImageFile)
        if (-not (Test-Path -LiteralPath $imgPath)) {
            [void][System.Windows.Forms.MessageBox]::Show('The image file is missing.', 'Clippr Preview')
            return
        }
        try { $bmp = New-Object System.Drawing.Bitmap($imgPath) }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show("Could not open the image: $($_.Exception.Message)", 'Clippr Preview')
            return
        }
    } else {
        $text = [string]$item.Text
    }

    $pf = New-Object System.Windows.Forms.Form
    $pf.Text = if ($isImage) { 'Clippr Preview - Image' } else { 'Clippr Preview - Text' }
    $pf.Size = New-Object System.Drawing.Size(900, 700)
    $pf.MinimumSize = New-Object System.Drawing.Size(620, 440)
    $pf.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $pf.BackColor = $C_BG
    $pf.ForeColor = $C_TEXT
    $pf.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $pf.ShowInTaskbar = $false
    $pf.KeyPreview = $true
    if ($script:AppIcon) { $pf.Icon = $script:AppIcon }
    try {
        $pf.BackgroundImage = New-DialogBackground $pf.ClientSize.Width $pf.ClientSize.Height
        $pf.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
    } catch { }

    $cw = $pf.ClientSize.Width
    $ch = $pf.ClientSize.Height

    # ---- tab header ----
    $pvTop = New-Object System.Windows.Forms.Panel
    $pvTop.Location = New-Object System.Drawing.Point(0, 0)
    $pvTop.Size = New-Object System.Drawing.Size($cw, 54)
    $pvTop.Anchor = 'Top,Left,Right'
    $pvTop.BackColor = [System.Drawing.Color]::Transparent
    $pf.Controls.Add($pvTop)

    $btnTabPreview = New-Object System.Windows.Forms.Button
    $btnTabPreview.Text = if ($isImage) { 'IMAGE' } else { 'TEXT' }
    $btnTabPreview.Size = New-Object System.Drawing.Size(110, 32)
    $btnTabPreview.Location = New-Object System.Drawing.Point(14, 10)
    Style-Button $btnTabPreview $false
    $btnTabPreview.Margin = New-Object System.Windows.Forms.Padding(0)
    $pvTop.Controls.Add($btnTabPreview)

    $btnTabOcr = New-Object System.Windows.Forms.Button
    $btnTabOcr.Text = 'OCR TEXT'
    $btnTabOcr.Size = New-Object System.Drawing.Size(110, 32)
    $btnTabOcr.Location = New-Object System.Drawing.Point(130, 10)
    Style-Button $btnTabOcr $false
    $btnTabOcr.Margin = New-Object System.Windows.Forms.Padding(0)
    $pvTop.Controls.Add($btnTabOcr)

    $lblMeta = New-Object System.Windows.Forms.Label
    $lblMeta.AutoSize = $false
    $lblMeta.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblMeta.Anchor = 'Top,Right'
    $lblMeta.Location = New-Object System.Drawing.Point(($cw - 514), 12)
    $lblMeta.Size = New-Object System.Drawing.Size(500, 28)
    $lblMeta.ForeColor = $C_MUTED
    $lblMeta.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    if ($isImage) {
        $kb = ''
        try { $kb = ([math]::Round((Get-Item -LiteralPath $imgPath).Length / 1KB, 1)).ToString() + ' KB' } catch { }
        $lblMeta.Text = "IMAGE   $($bmp.Width) x $($bmp.Height) px   $kb   $($item.Time)"
    } else {
        $lines = @($text -split "`r?`n").Count
        $lblMeta.Text = "TEXT   $($text.Length) chars   $lines lines   $($item.Time)"
    }
    $pvTop.Controls.Add($lblMeta)

    # ---- content ----
    $pvHost = New-Object System.Windows.Forms.Panel
    $pvHost.Location = New-Object System.Drawing.Point(0, 54)
    $pvHost.Size = New-Object System.Drawing.Size($cw, ($ch - 54 - 62))
    $pvHost.Anchor = 'Top,Bottom,Left,Right'
    $pvHost.BackColor = $C_BG
    $pvHost.Padding = New-Object System.Windows.Forms.Padding(0)
    $pf.Controls.Add($pvHost)

    $panelPreview = New-Object System.Windows.Forms.Panel
    $panelPreview.Dock = 'Fill'
    $panelPreview.BackColor = $C_PANEL
    $panelPreview.Padding = New-Object System.Windows.Forms.Padding(10)
    $pvHost.Controls.Add($panelPreview)

    if ($isImage) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Dock = 'Fill'
        $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $pic.BackColor = $C_PANEL2
        $pic.Image = $bmp
        $panelPreview.Controls.Add($pic)
    } else {
        $txtPreview = New-Object System.Windows.Forms.TextBox
        $txtPreview.Multiline = $true
        $txtPreview.ReadOnly = $true
        $txtPreview.WordWrap = $true
        $txtPreview.ScrollBars = 'Vertical'
        $txtPreview.BorderStyle = 'None'
        $txtPreview.BackColor = $C_PANEL2
        $txtPreview.ForeColor = $C_TEXT
        $txtPreview.Font = New-Object System.Drawing.Font('Consolas', 10)
        $txtPreview.Dock = 'Fill'
        $txtPreview.Text = ConvertTo-Crlf $text
        $panelPreview.Controls.Add($txtPreview)
    }

    $panelOcr = New-Object System.Windows.Forms.Panel
    $panelOcr.Dock = 'Fill'
    $panelOcr.BackColor = $C_PANEL
    $panelOcr.Padding = New-Object System.Windows.Forms.Padding(10)
    $panelOcr.Visible = $false
    $pvHost.Controls.Add($panelOcr)

    $txtOcr = New-Object System.Windows.Forms.TextBox
    $txtOcr.Multiline = $true
    $txtOcr.ReadOnly = $true
    $txtOcr.WordWrap = $true
    $txtOcr.ScrollBars = 'Vertical'
    $txtOcr.BorderStyle = 'None'
    $txtOcr.BackColor = $C_PANEL2
    $txtOcr.ForeColor = $C_TEXT
    $txtOcr.Font = New-Object System.Drawing.Font('Consolas', 10)
    $txtOcr.Dock = 'Fill'
    $panelOcr.Controls.Add($txtOcr)

    # ---- footer ----
    $pvFooter = New-Object System.Windows.Forms.Panel
    $pvFooter.Location = New-Object System.Drawing.Point(0, ($ch - 62))
    $pvFooter.Size = New-Object System.Drawing.Size($cw, 62)
    $pvFooter.Anchor = 'Bottom,Left,Right'
    $pvFooter.BackColor = [System.Drawing.Color]::Transparent
    $pf.Controls.Add($pvFooter)

    $lblPvStatus = New-Object System.Windows.Forms.Label
    $lblPvStatus.AutoSize = $false
    $lblPvStatus.Location = New-Object System.Drawing.Point(14, 22)
    $lblPvStatus.Size = New-Object System.Drawing.Size(($cw - 420), 20)
    $lblPvStatus.Anchor = 'Bottom,Left,Right'
    $lblPvStatus.ForeColor = $C_MUTED
    $lblPvStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $pvFooter.Controls.Add($lblPvStatus)

    $btnPvClose = New-Object System.Windows.Forms.Button
    $btnPvClose.Text = 'CLOSE'
    $btnPvClose.Size = New-Object System.Drawing.Size(92, 34)
    $btnPvClose.Location = New-Object System.Drawing.Point(($cw - 14 - 92), 14)
    $btnPvClose.Anchor = 'Bottom,Right'
    Style-Button $btnPvClose $false
    $btnPvClose.Margin = New-Object System.Windows.Forms.Padding(0)
    $pvFooter.Controls.Add($btnPvClose)

    $btnPvOcr = New-Object System.Windows.Forms.Button
    $btnPvOcr.Text = 'OCR + COPY'
    $btnPvOcr.Size = New-Object System.Drawing.Size(104, 34)
    $btnPvOcr.Location = New-Object System.Drawing.Point(($btnPvClose.Left - 10 - 104), 14)
    $btnPvOcr.Anchor = 'Bottom,Right'
    Style-Button $btnPvOcr $false
    $btnPvOcr.Margin = New-Object System.Windows.Forms.Padding(0)
    if ($isImage) { $pvFooter.Controls.Add($btnPvOcr) }

    $btnPvCopy = New-Object System.Windows.Forms.Button
    $btnPvCopy.Text = 'COPY'
    $btnPvCopy.Size = New-Object System.Drawing.Size(92, 34)
    if ($isImage) {
        $btnPvCopy.Location = New-Object System.Drawing.Point(($btnPvOcr.Left - 10 - 92), 14)
    } else {
        $btnPvCopy.Location = New-Object System.Drawing.Point(($btnPvClose.Left - 10 - 92), 14)
    }
    $btnPvCopy.Anchor = 'Bottom,Right'
    Style-Button $btnPvCopy $true
    $btnPvCopy.Margin = New-Object System.Windows.Forms.Padding(0)
    $pvFooter.Controls.Add($btnPvCopy)

    if (-not $isImage) { $btnTabOcr.Visible = $false }

    # ---- tab switching ----
    $setTab = {
        param([string]$which)
        $ocrOn = ($which -eq 'ocr')
        $panelOcr.Visible = $ocrOn
        $panelPreview.Visible = (-not $ocrOn)
        if ($ocrOn) {
            $btnTabOcr.BackColor = $C_ACCENT
            $btnTabOcr.ForeColor = $script:Theme.AccentInk
            $btnTabPreview.BackColor = $C_PANEL2
            $btnTabPreview.ForeColor = $C_TEXT
        } else {
            $btnTabPreview.BackColor = $C_ACCENT
            $btnTabPreview.ForeColor = $script:Theme.AccentInk
            $btnTabOcr.BackColor = $C_PANEL2
            $btnTabOcr.ForeColor = $C_TEXT
        }
    }
    & $setTab 'preview'

    $btnTabPreview.Add_Click({ & $setTab 'preview' })
    $btnTabOcr.Add_Click({
        & $setTab 'ocr'
        if ($isImage -and [string]::IsNullOrWhiteSpace($txtOcr.Text)) {
            $lblPvStatus.Text = 'No OCR text yet - click RUN OCR to read this image.'
        }
    })

    # ---- actions ----
    $btnPvCopy.Add_Click({
        try {
            if ($panelOcr.Visible) {
                $t = [string]$txtOcr.Text
                if ([string]::IsNullOrWhiteSpace($t)) { $lblPvStatus.Text = 'Nothing to copy yet.'; return }
                $script:lastCaptured = $t
                [System.Windows.Forms.Clipboard]::SetText($t)
                $lblPvStatus.Text = 'OCR text copied to clipboard.'
            } elseif ($isImage) {
                $script:lastImageFingerprint = Get-ImageFingerprint $bmp
                [System.Windows.Forms.Clipboard]::SetImage($bmp)
                $lblPvStatus.Text = 'Image copied to clipboard.'
            } else {
                if ([string]::IsNullOrWhiteSpace($text)) { $lblPvStatus.Text = 'Nothing to copy.'; return }
                $t = ConvertTo-Crlf $text
                $script:lastCaptured = $t
                [System.Windows.Forms.Clipboard]::SetText($t)
                $lblPvStatus.Text = 'Text copied to clipboard.'
            }
            $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
        } catch {
            $lblPvStatus.Text = "Copy failed: $($_.Exception.Message)"
        }
    })

    $btnPvOcr.Add_Click({
        if (-not $isImage) { return }
        $btnPvOcr.Enabled = $false
        $lblPvStatus.Text = 'Running OCR...'
        [System.Windows.Forms.Application]::DoEvents()
        $script:ocrNotice = ''
        try {
            $ocr = Invoke-OcrText $imgPath
            $ocr = ($ocr -replace "`r", '').Trim()
            if ([string]::IsNullOrWhiteSpace($ocr)) {
                $lblPvStatus.Text = 'No readable text was found in this image.'
            } else {
                $ocrText = ConvertTo-Crlf $ocr
                $txtOcr.Text = $ocrText
                $script:lastCaptured = $ocrText
                [System.Windows.Forms.Clipboard]::SetText($ocrText)
                $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
                $added = Add-Clip $ocr
                & $setTab 'ocr'
                if ($script:ocrNotice) {
                    $lblPvStatus.Text = $script:ocrNotice + ' OCR text copied to clipboard.'
                } elseif ($added) {
                    $lblPvStatus.Text = "OCR text added to '$($script:captureTab)' and copied to clipboard."
                } else {
                    $lblPvStatus.Text = 'OCR text already at the top of history. Copied to clipboard.'
                }
            }
        } catch {
            $lblPvStatus.Text = "OCR failed: $($_.Exception.Message)"
        } finally {
            $btnPvOcr.Enabled = $true
        }
    })

    $btnPvClose.Add_Click({ $pf.Close() })
    $pf.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $pf.Close() } })
    $pf.Add_Shown({ Set-DarkTitleBar $pf })

    [void]$pf.ShowDialog($form)
    if ($bmp) { try { $bmp.Dispose() } catch { } }
}

function Start-ScreenCapture {
    $screen = $null
    $dim = $null
    $overlay = $null
    $script:capStart = $null
    $script:capActive = $false
    $script:capRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
    $script:capResult = $null

    try {
        $form.Hide()
        Start-Sleep -Milliseconds 220

        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $screen = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $g = [System.Drawing.Graphics]::FromImage($screen)
        $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $vs.Size)
        $g.Dispose()

        $dim = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
        $dg = [System.Drawing.Graphics]::FromImage($dim)
        $dg.DrawImage($screen, 0, 0)
        $shade = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 0, 0, 0))
        $dg.FillRectangle($shade, 0, 0, $vs.Width, $vs.Height)
        $dg.Dispose(); $shade.Dispose()

        $overlay = New-Object System.Windows.Forms.Form
        $overlay.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $overlay.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $overlay.Bounds = $vs
        $overlay.TopMost = $true
        $overlay.ShowInTaskbar = $false
        $overlay.BackgroundImage = $dim
        $overlay.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::None
        $overlay.Cursor = [System.Windows.Forms.Cursors]::Cross
        try {
            $p = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')
            $p.SetValue($overlay, $true, $null)
        } catch { }

        $overlay.Add_MouseDown({
            param($s, $e)
            $script:capStart = $e.Location
            $script:capActive = $true
            $script:capRect = New-Object System.Drawing.Rectangle($e.X, $e.Y, 0, 0)
            $overlay.Invalidate()
        })
        $overlay.Add_MouseMove({
            param($s, $e)
            if (-not $script:capActive) { return }
            $x = [Math]::Min($script:capStart.X, $e.X)
            $y = [Math]::Min($script:capStart.Y, $e.Y)
            $w = [Math]::Abs($e.X - $script:capStart.X)
            $h = [Math]::Abs($e.Y - $script:capStart.Y)
            $script:capRect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
            $overlay.Invalidate()
        })
        $overlay.Add_MouseUp({
            param($s, $e)
            $script:capActive = $false
            $r = $script:capRect
            if ($r.Width -ge 6 -and $r.Height -ge 6) {
                $crop = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
                $cg = [System.Drawing.Graphics]::FromImage($crop)
                $cg.DrawImage($screen, (New-Object System.Drawing.Rectangle(0, 0, $r.Width, $r.Height)), $r, [System.Drawing.GraphicsUnit]::Pixel)
                $cg.Dispose()
                $script:capResult = $crop
            }
            $overlay.Close()
        })
        $overlay.Add_Paint({
            param($s, $e)
            if ($script:capRect.Width -gt 0 -and $script:capRect.Height -gt 0) {
                $e.Graphics.DrawImage($screen, $script:capRect, $script:capRect, [System.Drawing.GraphicsUnit]::Pixel)
                $pen = New-Object System.Drawing.Pen($C_ACCENT, 2)
                $e.Graphics.DrawRectangle($pen, $script:capRect)
                $pen.Dispose()
            }
        })
        $overlay.Add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $overlay.Close() }
        })
        $overlay.Add_Shown({
            try { $overlay.Activate(); $overlay.Focus() } catch { }
        })

        [void]$overlay.ShowDialog()
    } catch {
        if ($script:lblStatus) {
            $script:lblStatus.Text = "Screen capture failed: $($_.Exception.Message)"
        }
    } finally {
        if ($overlay) { try { $overlay.Dispose() } catch { } }
        if ($dim) { try { $dim.Dispose() } catch { } }
        try { if (-not $form.Visible) { $form.Show(); $form.Activate() } } catch { }
    }

    if ($script:capResult) {
        $bmp = $script:capResult
        Add-Image $bmp ("Screenshot $($bmp.Width)x$($bmp.Height)")
        $bmp.Dispose()
        $script:capResult = $null
    }
    if ($screen) { try { $screen.Dispose() } catch { } }
}

function Copy-Selected {
    $sel = $script:histList.SelectedItem
    if (-not $sel) { return }
    if ($sel.Type -eq 'image') {
        $path = Join-Path $script:ImagesDir $sel.ImageFile
        if (Test-Path -LiteralPath $path) {
            try {
                $img = [System.Drawing.Image]::FromFile($path)
                $script:lastImageFingerprint = Get-ImageFingerprint $img
                [System.Windows.Forms.Clipboard]::SetImage($img)
                $img.Dispose()
                $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
                if ($script:lblStatus) { $script:lblStatus.Text = 'Image copied to clipboard.' }
            } catch {
                if ($script:lblStatus) { $script:lblStatus.Text = 'Could not copy the image.' }
            }
        }
    } else {
        $txt = ConvertTo-Crlf ([string]$sel.Text)
        $script:lastCaptured = $txt
        [System.Windows.Forms.Clipboard]::SetText($txt)
        $script:ignoreClipboardUntil = (Get-Date).AddSeconds(2)
        if ($script:lblStatus) { $script:lblStatus.Text = 'Copied to clipboard. Now press Ctrl+V anywhere.' }
    }
}

function Delete-Selected {
    $sel = $script:histList.SelectedItem
    if (-not $sel) { return }
    $tab = Find-ItemTab $sel
    if (-not $tab) { return }
    if ($sel.Type -eq 'image' -and $sel.ImageFile) {
        try { Remove-Item -LiteralPath (Join-Path $script:ImagesDir $sel.ImageFile) -Force -ErrorAction SilentlyContinue } catch { }
        if ($script:thumbCache.ContainsKey($sel.ImageFile)) {
            try { $script:thumbCache[$sel.ImageFile].Dispose() } catch { }
            $script:thumbCache.Remove($sel.ImageFile)
        }
    }
    $tab.Items = @($tab.Items | Where-Object { -not [object]::ReferenceEquals($_, $sel) })
    Save-State
    Refresh-Hist
}

function New-Tab {
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter a name for the new tab', 'New Tab', '')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()
    if (Test-ViewTab $name) {
        [void][System.Windows.Forms.MessageBox]::Show("'$name' is reserved for a built-in view.", 'Clippr')
        return
    }
    if ($script:tabs | Where-Object { $_.Name -eq $name }) {
        [void][System.Windows.Forms.MessageBox]::Show('A tab with that name already exists.', 'Clippr')
        return
    }
    $script:tabs += [pscustomobject]@{ Name = $name; Items = @() }
    $script:activeTab = $name
    $script:captureTab = $name
    Save-State
    Refresh-Tabs
    Refresh-Hist
}

function Rename-Tab {
    if (Test-ViewTab $script:activeTab) {
        [void][System.Windows.Forms.MessageBox]::Show('Built-in views cannot be renamed. Select a saved tab first.', 'Clippr')
        return
    }
    $tab = Get-ActiveTab
    if (-not $tab) { return }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Rename tab', 'Rename Tab', $tab.Name)
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()
    if (Test-ViewTab $name) {
        [void][System.Windows.Forms.MessageBox]::Show("'$name' is reserved for a built-in view.", 'Clippr')
        return
    }
    if ($script:tabs | Where-Object { $_.Name -eq $name -and $_.Name -ne $tab.Name }) {
        [void][System.Windows.Forms.MessageBox]::Show('A tab with that name already exists.', 'Clippr')
        return
    }
    $tab.Name = $name
    $script:activeTab = $name
    $script:captureTab = $name
    Save-State
    Refresh-Tabs
    Refresh-Hist
}

function Remove-Tab {
    if (Test-ViewTab $script:activeTab) {
        [void][System.Windows.Forms.MessageBox]::Show('Built-in views cannot be deleted. Select a saved tab first.', 'Clippr')
        return
    }
    if (@($script:tabs).Count -le 1) {
        [void][System.Windows.Forms.MessageBox]::Show('At least one tab is required.', 'Clippr')
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Delete tab '$($script:activeTab)' and all its items?", 'Delete Tab', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $script:tabs = @($script:tabs | Where-Object { $_.Name -ne $script:activeTab })
    $script:activeTab = @($script:tabs)[0].Name
    $script:captureTab = $script:activeTab
    Save-State
    Refresh-Tabs
    Refresh-Hist
}

function Set-DarkTitleBar($frm) {
    if (-not $frm) { return }
    try {
        [void]$frm.Handle
        $t = $script:Theme
        $dark = if ($t.DwmDark) { 1 } else { 0 }
        [ClipprNative]::DwmSetWindowAttribute($frm.Handle, 20, [ref]$dark, 4) | Out-Null
        [ClipprNative]::DwmSetWindowAttribute($frm.Handle, 19, [ref]$dark, 4) | Out-Null
        $caption = [int]$script:ThemeDwmCaption
        [ClipprNative]::DwmSetWindowAttribute($frm.Handle, 35, [ref]$caption, 4) | Out-Null
        $border = [int]$script:ThemeDwmBorder
        [ClipprNative]::DwmSetWindowAttribute($frm.Handle, 34, [ref]$border, 4) | Out-Null
    } catch { }
}

function Style-Button($b, [bool]$primary = $false) {
    if (-not $b) { return }
    $t = $script:Theme
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = $t.ButtonBorderWidth
    $b.Font = New-Object System.Drawing.Font($t.ButtonFont, $t.ButtonFontSize, [System.Drawing.FontStyle]::Bold)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    if ($primary) {
        $b.BackColor = $t.BtnPrimaryBg
        $b.ForeColor = $t.BtnPrimaryText
        $b.FlatAppearance.BorderColor = $t.BtnPrimaryBorder
        $b.FlatAppearance.MouseOverBackColor = $t.BtnPrimaryHover
        $b.FlatAppearance.MouseDownBackColor = $t.BtnPrimaryDown
    } else {
        $b.BackColor = $t.BtnSecondaryBg
        $b.ForeColor = $t.BtnSecondaryText
        $b.FlatAppearance.BorderColor = $t.BtnSecondaryBorder
        $b.FlatAppearance.MouseOverBackColor = $t.BtnSecondaryHover
        $b.FlatAppearance.MouseDownBackColor = $t.BtnSecondaryDown
    }
    Set-RoundedRegion $b $t.ButtonRadius
}

# ============================================================
#  LOAD DATA + BUILD UI
# ============================================================
Load-State
Load-Settings
Set-ThemePalette ([string]$script:settings.Theme)

# ============================================================
#  HEADLESS OCR WORKER
#  Spawned by the main app to name a freshly captured image
#  without blocking clipboard capture or the UI thread.
# ============================================================
if ($script:isOcrJob) {
    $jobImg = [string]$env:CLIPPR_OCR_IMAGE
    $jobOut = [string]$env:CLIPPR_OCR_OUT
    if (-not $jobOut) { exit }
    $jobTmp = [string]($jobOut + '.tmp')
    $jobText = ''
    try {
        if ($jobImg -and (Test-Path -LiteralPath $jobImg)) {
            $jobText = [string](Invoke-OcrText $jobImg)
        }
    } catch { }
    try {
        [System.IO.File]::WriteAllText($jobTmp, (ConvertTo-Crlf $jobText), (New-Object System.Text.UTF8Encoding($false)))
        if ($jobOut) { [System.IO.File]::Move($jobTmp, $jobOut) }
    } catch {
        try { if ($jobTmp) { Remove-Item -LiteralPath $jobTmp -Force -ErrorAction SilentlyContinue } } catch { }
    }
    exit
}

# avoid re-capturing whatever is still on the clipboard after a restart
$__items = @(Get-ViewItems 'All items')
$__recentText = @($__items | Where-Object { $_.Type -ne 'image' }) | Select-Object -First 1
if ($__recentText) { $script:lastCaptured = ConvertTo-Crlf ([string]$__recentText.Text) }
$__recentImg = @($__items | Where-Object { $_.Type -eq 'image' -and $_.ImageFile }) | Select-Object -First 1
if ($__recentImg) {
    $__p = Join-Path $script:ImagesDir $__recentImg.ImageFile
    if (Test-Path -LiteralPath $__p) {
        try {
            $__im = [System.Drawing.Image]::FromFile($__p)
            $script:lastImageFingerprint = Get-ImageFingerprint $__im
            $__im.Dispose()
        } catch { }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Clippr'
$form.Size = New-Object System.Drawing.Size(980, 660)
$form.MinimumSize = New-Object System.Drawing.Size(780, 500)
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon = [System.Drawing.SystemIcons]::Application
$script:AppIcon = $null
$script:IconPath = Join-Path $script:BaseDir 'clippr.ico'
if (Test-Path -LiteralPath $script:IconPath) {
    try {
        $script:AppIcon = New-Object System.Drawing.Icon($script:IconPath)
        $form.Icon = $script:AppIcon
    } catch { }
}
$script:BrandImage = $null
$__brandPath = Join-Path $script:BaseDir 'clippr.png'
if (Test-Path -LiteralPath $__brandPath) {
    try { $script:BrandImage = [System.Drawing.Image]::FromFile($__brandPath) } catch { }
}
try {
    $form.BackgroundImage = New-GlassBackground $form.ClientSize.Width $form.ClientSize.Height
    $form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
} catch { }

# ---------- MAIN AREA (added first so it fills last) ----------
$main = New-Object System.Windows.Forms.Panel
$main.Dock = 'Fill'
$main.BackColor = [System.Drawing.Color]::Transparent
$main.Padding = New-Object System.Windows.Forms.Padding(22, 10, 22, 14)
$form.Controls.Add($main)

# history list inside a glass frame
$listWrap = New-Object System.Windows.Forms.Panel
$listWrap.Dock = 'Fill'
$listWrap.BackColor = $script:Theme.ListBorder
$listWrap.Padding = New-Object System.Windows.Forms.Padding($script:Theme.ListBorderWidth, $script:Theme.ListBorderWidth, $script:Theme.ListBorderWidth, $script:Theme.ListBorderWidth)
$main.Controls.Add($listWrap)

$script:histList = New-Object FluidListBox
$script:histList.Dock = 'Fill'
$script:histList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:histList.BackColor = $script:Theme.ListBg
$script:histList.ForeColor = $C_TEXT
$script:histList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$script:histList.ItemHeight = 76
$script:histList.IntegralHeight = $false
$listWrap.Controls.Add($script:histList)
Set-DarkScrollBars $script:histList

# slim custom scrollbar drawn over the native (light) one
$script:histScroll = New-Object BufferedPanel
$script:histScroll.Width = 17
$script:histScroll.BackColor = $script:Theme.ListBg
$script:histScroll.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:histScroll.Visible = $false
$listWrap.Controls.Add($script:histScroll)
$script:histScroll.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $bmp = Get-GlassCrop $s
        if ($bmp) { $g.DrawImageUnscaled($bmp, 0, 0) } else { $g.Clear($C_PANEL2) }
        $m = Get-HistScrollMetrics
        if (-not $m -or $m.Total -le $m.Visible) { return }
        $t = $script:Theme
        $trackA = if ($t.IsLight) { 40 } else { 34 }
        $track = Get-RoundedPath 7 2 4 ([single][Math]::Max(4, $s.Height - 4)) 2
        $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($trackA, $t.Accent.R, $t.Accent.G, $t.Accent.B))
        $g.FillPath($tb, $track)
        $tb.Dispose(); $track.Dispose()
        $ty = [single]($m.ThumbY + 1)
        $th = [single][Math]::Max(10, $m.ThumbH - 2)
        $thumb = Get-RoundedPath 5.5 $ty 6 $th 3
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, $t.Accent.R, $t.Accent.G, $t.Accent.B))
        $g.FillPath($b, $thumb)
        $b.Dispose()
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, $t.Border.R, $t.Border.G, $t.Border.B), 1)
        $g.DrawPath($pen, $thumb)
        $pen.Dispose(); $thumb.Dispose()
    } catch { }
})
$script:histScroll.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $m = Get-HistScrollMetrics
    if (-not $m -or $m.MaxTop -le 0) { return }
    if ($e.Y -ge $m.ThumbY -and $e.Y -le ($m.ThumbY + $m.ThumbH)) {
        $script:scrollDrag = $true
        $script:scrollGrab = $e.Y - $m.ThumbY
        $s.Capture = $true
    } else {
        $span = [Math]::Max(1, $m.TrackH - $m.ThumbH)
        $ratio = ($e.Y - ($m.ThumbH / 2)) / [double]$span
        if ($ratio -lt 0) { $ratio = 0 }
        if ($ratio -gt 1) { $ratio = 1 }
        $script:histList.TopIndex = [int][Math]::Round($m.MaxTop * $ratio)
        Update-HistScroll
    }
})
$script:histScroll.Add_MouseMove({
    param($s, $e)
    if (-not $script:scrollDrag) { return }
    $m = Get-HistScrollMetrics
    if (-not $m -or $m.MaxTop -le 0) { return }
    $span = [Math]::Max(1, $m.TrackH - $m.ThumbH)
    $ratio = ($e.Y - $script:scrollGrab) / [double]$span
    if ($ratio -lt 0) { $ratio = 0 }
    if ($ratio -gt 1) { $ratio = 1 }
    $script:histList.TopIndex = [int][Math]::Round($m.MaxTop * $ratio)
    Update-HistScroll
})
$script:histScroll.Add_MouseUp({
    param($s, $e)
    $script:scrollDrag = $false
    $s.Capture = $false
    Update-HistScroll
})
$script:histScroll.Add_MouseWheel({
    param($s, $e)
    $m = Get-HistScrollMetrics
    if (-not $m) { return }
    $d = if ($e.Delta -gt 0) { -3 } else { 3 }
    $n = $script:histList.TopIndex + $d
    if ($n -lt 0) { $n = 0 }
    if ($n -gt $m.MaxTop) { $n = $m.MaxTop }
    $script:histList.TopIndex = $n
    Update-HistScroll
})
$script:histList.Add_TopIndexChanged({ Update-HistScroll })
$script:histList.Add_Resize({ Update-HistScroll })

Set-RoundedRegion $listWrap $script:Theme.PanelRadius
$listWrap.Add_Resize({ try { Set-RoundedRegion $this $script:Theme.PanelRadius } catch { }; Update-HistScroll })

# action bar (bottom)
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Dock = 'Bottom'
$actionBar.Height = 58
$actionBar.BackColor = [System.Drawing.Color]::Transparent
$main.Controls.Add($actionBar)

$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Fill'
$flow.BackColor = [System.Drawing.Color]::Transparent
$flow.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$flow.WrapContents = $false
$flow.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$actionBar.Controls.Add($flow)

$script:btnCopy = New-Object System.Windows.Forms.Button
$script:btnCopy.Text = 'COPY'
$script:btnCopy.Size = New-Object System.Drawing.Size(76, 36)
Style-Button $script:btnCopy $true
$flow.Controls.Add($script:btnCopy)

$script:btnView = New-Object System.Windows.Forms.Button
$script:btnView.Text = 'PREVIEW'
$script:btnView.Size = New-Object System.Drawing.Size(88, 36)
Style-Button $script:btnView $false
$script:btnView.Margin = New-Object System.Windows.Forms.Padding(0, 0, 6, 0)
$flow.Controls.Add($script:btnView)

$script:btnCapture = New-Object System.Windows.Forms.Button
$script:btnCapture.Text = 'CAPTURE'
$script:btnCapture.Size = New-Object System.Drawing.Size(96, 36)
Style-Button $script:btnCapture $false
$flow.Controls.Add($script:btnCapture)

$script:btnOcr = New-Object System.Windows.Forms.Button
$script:btnOcr.Text = 'OCR'
$script:btnOcr.Size = New-Object System.Drawing.Size(76, 36)
Style-Button $script:btnOcr $false
$flow.Controls.Add($script:btnOcr)

$script:btnDelete = New-Object System.Windows.Forms.Button
$script:btnDelete.Text = 'DELETE'
$script:btnDelete.Size = New-Object System.Drawing.Size(82, 36)
Style-Button $script:btnDelete $false
$flow.Controls.Add($script:btnDelete)

$script:btnClear = New-Object System.Windows.Forms.Button
$script:btnClear.Text = 'CLEAR'
$script:btnClear.Size = New-Object System.Drawing.Size(72, 36)
Style-Button $script:btnClear $false
$flow.Controls.Add($script:btnClear)

$script:chkStrip = New-Object System.Windows.Forms.CheckBox
$script:chkStrip.Text = 'Strip images (text only)'
$script:chkStrip.ForeColor = $script:Theme.Muted
$script:chkStrip.BackColor = [System.Drawing.Color]::Transparent
$script:chkStrip.AutoSize = $true
$script:chkStrip.Font = New-Object System.Drawing.Font($script:Theme.Font, 8.5)
$script:chkStrip.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:chkStrip.Checked = $script:stripImages
$script:chkStrip.Margin = New-Object System.Windows.Forms.Padding(6, 10, 0, 0)
$flow.Controls.Add($script:chkStrip)

# search row (top)
$searchRow = New-Object System.Windows.Forms.Panel
$searchRow.Dock = 'Top'
$searchRow.Height = 44
$searchRow.BackColor = [System.Drawing.Color]::Transparent
$main.Controls.Add($searchRow)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'SEARCH'
$lblSearch.ForeColor = $C_MUTED
$lblSearch.Font = New-Object System.Drawing.Font($script:Theme.LabelFont, 7.5, [System.Drawing.FontStyle]::Bold)
$lblSearch.AutoSize = $true
$lblSearch.Location = New-Object System.Drawing.Point(2, 14)
$searchRow.Controls.Add($lblSearch)

$searchBox = New-Object System.Windows.Forms.Panel
$searchBox.Location = New-Object System.Drawing.Point(70, 4)
$searchBox.Size = New-Object System.Drawing.Size(380, 34)
$searchBox.BackColor = $script:Theme.SearchBg
$searchRow.Controls.Add($searchBox)
Set-RoundedRegion $searchBox $script:Theme.SearchRadius
$searchBox.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $t = $script:Theme
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object System.Drawing.Pen($t.SearchBorder, $t.ButtonBorderWidth)
        $p = Get-RoundedPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) $t.SearchRadius
        $g.DrawPath($pen, $p)
        $pen.Dispose(); $p.Dispose()
        $mp = New-Object System.Drawing.Pen($t.Muted, 1.3)
        $mp.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $mp.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawEllipse($mp, 12, 11, 8.5, 8.5)
        $g.DrawLine($mp, 19.4, 18.4, 23, 22)
        $mp.Dispose()
    } catch { }
})

$script:txtSearch = New-Object System.Windows.Forms.TextBox
$script:txtSearch.Location = New-Object System.Drawing.Point(36, 5)
$script:txtSearch.Size = New-Object System.Drawing.Size(330, 24)
$script:txtSearch.BackColor = $script:Theme.SearchBg
$script:txtSearch.ForeColor = $script:Theme.Text
$script:txtSearch.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:txtSearch.Font = New-Object System.Drawing.Font($script:Theme.Font, 10)
$searchBox.Controls.Add($script:txtSearch)

# ---------- SIDEBAR ----------
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Left'
$sidebar.Width = 216
$sidebar.BackColor = [System.Drawing.Color]::Transparent
$sidebar.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 14)
$sidebar.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $t = $script:Theme
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $t.Sidebar, $t.Sidebar2, 90)
        $g.FillRectangle($lg, $rect)
        $lg.Dispose()
        $pen = New-Object System.Drawing.Pen($t.Border, $t.SidebarBorderWidth)
        $g.DrawLine($pen, ($s.Width - 1), 0, ($s.Width - 1), $s.Height)
        $pen.Dispose()
    } catch { }
})
$form.Controls.Add($sidebar)

$script:tabList = New-Object FluidListBox
$script:tabList.Dock = 'Fill'
$script:tabList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:tabList.BackColor = $script:Theme.Sidebar
$script:tabList.ForeColor = $C_TEXT
$script:tabList.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$script:tabList.ItemHeight = 44
$script:tabList.IntegralHeight = $false
$sidebar.Controls.Add($script:tabList)
Set-DarkScrollBars $script:tabList

$tabButtons = New-Object System.Windows.Forms.Panel
$tabButtons.Dock = 'Bottom'
$tabButtons.Height = 110
$tabButtons.BackColor = [System.Drawing.Color]::Transparent
$sidebar.Controls.Add($tabButtons)

$tabFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$tabFlow.Dock = 'Fill'
$tabFlow.BackColor = [System.Drawing.Color]::Transparent
$tabFlow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$tabFlow.WrapContents = $false
$tabFlow.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$tabButtons.Controls.Add($tabFlow)

$btnNewTab = New-Object System.Windows.Forms.Button
$btnNewTab.Text = '+  NEW TAB'
$btnNewTab.Size = New-Object System.Drawing.Size(188, 30)
Style-Button $btnNewTab $false
$btnNewTab.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$tabFlow.Controls.Add($btnNewTab)

$btnRenTab = New-Object System.Windows.Forms.Button
$btnRenTab.Text = 'RENAME TAB'
$btnRenTab.Size = New-Object System.Drawing.Size(188, 30)
Style-Button $btnRenTab $false
$btnRenTab.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$tabFlow.Controls.Add($btnRenTab)

$btnDelTab = New-Object System.Windows.Forms.Button
$btnDelTab.Text = 'DELETE TAB'
$btnDelTab.Size = New-Object System.Drawing.Size(188, 30)
Style-Button $btnDelTab $false
$btnDelTab.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$tabFlow.Controls.Add($btnDelTab)

$lblTabs = New-Object System.Windows.Forms.Label
$lblTabs.Text = 'VIEWS  &  TABS'
$lblTabs.UseMnemonic = $false
$lblTabs.Dock = 'Top'
$lblTabs.Height = 30
$lblTabs.ForeColor = $C_MUTED
$lblTabs.Font = New-Object System.Drawing.Font($script:Theme.LabelFont, 8, [System.Drawing.FontStyle]::Bold)
$lblTabs.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$sidebar.Controls.Add($lblTabs)

# status strip
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'
$statusBar.Height = 26
$statusBar.BackColor = $script:Theme.StatusBg
$form.Controls.Add($statusBar)

$statusLine = New-Object System.Windows.Forms.Panel
$statusLine.Dock = 'Top'
$statusLine.Height = $script:Theme.StatusLineWidth
$statusLine.BackColor = $script:Theme.StatusLine
$statusBar.Controls.Add($statusLine)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Dock = 'Fill'
$script:lblStatus.Text = ''
$script:lblStatus.ForeColor = $script:Theme.StatusText
$__statusFontSize = if ($script:Theme.Key -eq 'Brutal') { 7.0 } else { 8 }
$script:lblStatus.Font = New-Object System.Drawing.Font($script:Theme.MetaFont, $__statusFontSize)
$script:lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:lblStatus.AutoEllipsis = $true
$script:lblStatus.UseMnemonic = $false
$script:lblStatus.Padding = New-Object System.Windows.Forms.Padding(14, 0, 0, 0)
$statusBar.Controls.Add($script:lblStatus)

$lblCredit = New-Object System.Windows.Forms.Label
$lblCredit.Text = 'v1.1'
$lblCredit.Dock = 'Right'
$lblCredit.AutoSize = $true
$lblCredit.ForeColor = $script:Theme.StatusText
$lblCredit.Font = New-Object System.Drawing.Font($script:Theme.MetaFont, 8)
$lblCredit.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblCredit.Padding = New-Object System.Windows.Forms.Padding(0, 0, 14, 0)
$statusBar.Controls.Add($lblCredit)

# ---------- HEADER (added last so it docks first, full width) ----------
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 78
$header.BackColor = [System.Drawing.Color]::Transparent
$form.Controls.Add($header)

$brand = New-Object System.Windows.Forms.Panel
$brand.Location = New-Object System.Drawing.Point(18, 15)
$brand.Size = New-Object System.Drawing.Size(46, 46)
$brand.BackColor = [System.Drawing.Color]::Transparent
$brand.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $t = $script:Theme
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        if ($t.HardShadow) {
            $sh = Get-RoundedPath 3 3 46 46 2
            $sb = New-Object System.Drawing.SolidBrush($t.CardShadowColor)
            $g.FillPath($sb, $sh)
            $sb.Dispose(); $sh.Dispose()
        } else {
            Add-GlowBlob $g 23 23 30 30 $t.Accent.R $t.Accent.G $t.Accent.B 40
            Add-GlowBlob $g 27 19 23 23 $t.Accent2.R $t.Accent2.G $t.Accent2.B 28
        }
        if ($script:BrandImage) {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            if ($t.LogoMode -eq 'color') {
                $g.DrawImage($script:BrandImage, 0, 0, 46, 46)
            } else {
                $cm = New-Object System.Drawing.Imaging.ColorMatrix
                $cm.Matrix33 = 1.0; $cm.Matrix44 = 1.0
                if ($t.LogoMode -eq 'sepia') {
                    $cm.Matrix00 = 0.393; $cm.Matrix01 = 0.349; $cm.Matrix02 = 0.272
                    $cm.Matrix10 = 0.769; $cm.Matrix11 = 0.686; $cm.Matrix12 = 0.534
                    $cm.Matrix20 = 0.189; $cm.Matrix21 = 0.168; $cm.Matrix22 = 0.131
                } elseif ($t.LogoMode -eq 'contrast') {
                    $cm.Matrix00 = 0.374; $cm.Matrix01 = 0.374; $cm.Matrix02 = 0.374; $cm.Matrix03 = -0.12
                    $cm.Matrix10 = 0.734; $cm.Matrix11 = 0.734; $cm.Matrix12 = 0.734; $cm.Matrix13 = -0.12
                    $cm.Matrix20 = 0.143; $cm.Matrix21 = 0.143; $cm.Matrix22 = 0.143; $cm.Matrix23 = -0.12
                } else {
                    $cm.Matrix00 = 0.299; $cm.Matrix01 = 0.299; $cm.Matrix02 = 0.299
                    $cm.Matrix10 = 0.587; $cm.Matrix11 = 0.587; $cm.Matrix12 = 0.587
                    $cm.Matrix20 = 0.114; $cm.Matrix21 = 0.114; $cm.Matrix22 = 0.114
                }
                $ia = New-Object System.Drawing.Imaging.ImageAttributes
                $ia.SetColorMatrix($cm)
                $dest = New-Object System.Drawing.Rectangle(0, 0, 46, 46)
                $g.DrawImage($script:BrandImage, $dest, 0, 0, $script:BrandImage.Width, $script:BrandImage.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
                $ia.Dispose()
            }
            if ($t.HardShadow) {
                $bp = Get-RoundedPath 1 1 44 44 2
                $pen = New-Object System.Drawing.Pen($t.Border, 2)
                $g.DrawPath($pen, $bp)
                $pen.Dispose(); $bp.Dispose()
            }
            return
        }
        $cx = 23.0; $cy = 23.0
        $pts = New-Object 'System.Drawing.PointF[]' 20
        for ($i = 0; $i -lt 20; $i++) {
            $rad = if ($i % 2 -eq 0) { 22.0 } else { 15.5 }
            $ang = (-90 + $i * 18) * [Math]::PI / 180
            $pts[$i] = New-Object System.Drawing.PointF([single]($cx + $rad * [Math]::Cos($ang)), [single]($cy + $rad * [Math]::Sin($ang)))
        }
        $b = New-Object System.Drawing.SolidBrush($C_POP)
        $g.FillPolygon($b, $pts)
        $b.Dispose()
        $pen = New-Object System.Drawing.Pen($C_INK, 2.4)
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawPolygon($pen, $pts)
        $pen.Dispose()
        $inner = New-Object System.Drawing.SolidBrush($C_ACCENT)
        $g.FillEllipse($inner, 10, 10, 26, 26)
        $inner.Dispose()
        $f = New-Object System.Drawing.Font($C_FONT, 15, [System.Drawing.FontStyle]::Bold)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $ink = New-Object System.Drawing.SolidBrush($C_INK)
        $g.DrawString('C', $f, $ink, (New-Object System.Drawing.RectangleF(0, 0, 46, 45)), $sf)
        $ink.Dispose(); $sf.Dispose(); $f.Dispose()
    } catch { }
})
$header.Controls.Add($brand)

$header.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $t = $script:Theme
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $fam = New-Object System.Drawing.FontFamily($t.DisplayFont)
        $txt = if ($t.TitleUppercase) { 'CLIPPR' } else { 'Clippr' }
        $style = [int]$t.DisplayStyle
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddString($txt, $fam, $style, $t.DisplaySize, (New-Object System.Drawing.PointF(58, $t.TitleY)), [System.Drawing.StringFormat]::GenericDefault)

        if ($t.HardShadow) {
            $shadow = New-Object System.Drawing.Drawing2D.Matrix
            $shadow.Translate(2, 2)
            $sp = $p.Clone()
            $sp.Transform($shadow)
            $sb = New-Object System.Drawing.SolidBrush($t.CardShadowColor)
            $g.FillPath($sb, $sp)
            $sb.Dispose(); $sp.Dispose(); $shadow.Dispose()
        } elseif (-not $t.IsLight) {
            $shadow = New-Object System.Drawing.Drawing2D.Matrix
            $shadow.Translate(0, 1)
            $sp = $p.Clone()
            $sp.Transform($shadow)
            $sb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
            $g.FillPath($sb, $sp)
            $sb.Dispose(); $sp.Dispose(); $shadow.Dispose()
        }

        $br = New-Object System.Drawing.SolidBrush($t.DisplayColor)
        $g.FillPath($br, $p)
        $br.Dispose()
        $p.Dispose(); $fam.Dispose()
    } catch { }
})

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = $script:Theme.SubText
$lblSub.Font = New-Object System.Drawing.Font($script:Theme.SubFont, $script:Theme.SubSize, $script:Theme.SubStyle)
$lblSub.ForeColor = $script:Theme.Muted
$lblSub.BackColor = [System.Drawing.Color]::Transparent
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(59, 52)
$header.Controls.Add($lblSub)

$script:btnToggle = New-Object System.Windows.Forms.Button
$script:btnToggle.Text = 'CAPTURING'
$script:btnToggle.Size = New-Object System.Drawing.Size(168, 40)
$script:btnToggle.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 190), 20)
$script:btnToggle.Anchor = 'Top,Right'
$script:btnToggle.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:btnToggle.FlatAppearance.BorderSize = 1
$script:btnToggle.FlatAppearance.BorderColor = $script:Theme.ToggleOnBorder
$script:btnToggle.FlatAppearance.MouseOverBackColor = $script:Theme.BtnPrimaryHover
$script:btnToggle.Font = New-Object System.Drawing.Font($script:Theme.ButtonFont, 9.5, [System.Drawing.FontStyle]::Bold)
$script:btnToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnToggle.UseVisualStyleBackColor = $false
$header.Controls.Add($script:btnToggle)
Set-RoundedRegion $script:btnToggle $script:Theme.ButtonRadius

$script:btnSettings = New-Object System.Windows.Forms.Button
$script:btnSettings.Text = 'SETTINGS'
$script:btnSettings.Size = New-Object System.Drawing.Size(110, 40)
$script:btnSettings.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 310), 20)
$script:btnSettings.Anchor = 'Top,Right'
Style-Button $script:btnSettings $false
$script:btnSettings.Font = New-Object System.Drawing.Font($script:Theme.ButtonFont, 8.5, [System.Drawing.FontStyle]::Bold)
$header.Controls.Add($script:btnSettings)

$headerLine = New-Object System.Windows.Forms.Panel
$headerLine.Dock = 'Bottom'
$headerLine.Height = $script:Theme.HeaderLineWidth
$headerLine.BackColor = $script:Theme.Border
$header.Controls.Add($headerLine)
# ============================================================
#  DRAWING (owner-draw lists)
# ============================================================
$script:fHistItem = New-Object System.Drawing.Font($script:Theme.CardFont, $script:Theme.CardFontSize, $script:Theme.CardFontStyle)
$script:fHistMeta = New-Object System.Drawing.Font($script:Theme.MetaFont, $script:Theme.MetaFontSize)
$script:fTabView  = New-Object System.Drawing.Font($script:Theme.TabFont, $script:Theme.TabFontSize, [System.Drawing.FontStyle]::Bold)
$script:fTabItem  = New-Object System.Drawing.Font($script:Theme.TabFont, $script:Theme.TabFontSize, [System.Drawing.FontStyle]::Regular)
$script:histHover = -1
$script:tabHover  = -1

$script:histList.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $item = $sender.Items[$e.Index]
    $g = $e.Graphics
    $t = $script:Theme
    $isSel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $isHover = ($e.Index -eq $script:histHover)

    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $glass = Get-GlassCrop $sender
        if ($glass) {
            $gsrc = New-Object System.Drawing.Rectangle($e.Bounds.X, $e.Bounds.Y, $e.Bounds.Width, $e.Bounds.Height)
            $g.DrawImage($glass, $e.Bounds, $gsrc, [System.Drawing.GraphicsUnit]::Pixel)
        } else {
            $g.Clear($t.ListBg)
        }

        $card = New-Object System.Drawing.RectangleF(($e.Bounds.X + 2), ($e.Bounds.Y + 3), ($e.Bounds.Width - 16), ($e.Bounds.Height - 13))
        if ($card.Width -lt 8 -or $card.Height -lt 8) { return }

        if ($t.HardShadow) {
            $sc = if ($isSel) { $t.Accent } else { $t.CardShadowColor }
            $sp = Get-RoundedPath ($card.X + $t.CardShadowOffset) ($card.Y + $t.CardShadowOffset) $card.Width $card.Height $t.CardRadius
            $sbr = New-Object System.Drawing.SolidBrush($sc)
            $g.FillPath($sbr, $sp)
            $sbr.Dispose(); $sp.Dispose()
        } else {
            $sp = Get-RoundedPath ($card.X + 1) ($card.Y + 2) $card.Width $card.Height $t.CardRadius
            $sbr = New-Object System.Drawing.SolidBrush($t.CardShadowColor)
            $g.FillPath($sbr, $sp)
            $sbr.Dispose(); $sp.Dispose()
        }

        $path = Get-RoundedPath $card.X $card.Y $card.Width $card.Height $t.CardRadius
        $fill = if ($isSel) { $t.CardSel } elseif ($isHover) { $t.CardHi } else { $t.Card }
        $b = New-Object System.Drawing.SolidBrush($fill)
        $g.FillPath($b, $path)
        $b.Dispose()

        $borderCol = if ($isSel) { $t.CardSelBorder } elseif ($isHover) { $t.CardHoverBorder } else { $t.CardBorder }
        $pen = New-Object System.Drawing.Pen($borderCol, $t.CardBorderWidth)
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()

        if (-not $t.HardShadow) {
            $hi = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(30, 255, 255, 255), 1)
            $g.DrawLine($hi, [single]($card.X + 10), [single]($card.Y + 1), [single]($card.Right - 10), [single]($card.Y + 1))
            $hi.Dispose()
        }

        $spineBase = if ($item.Type -eq 'image') { $t.Accent2 } else { $t.Accent }
        $spineA = if ($isSel) { 255 } else { [int](255 * $t.CardBarOpacity) }
        $spineColor = [System.Drawing.Color]::FromArgb($spineA, $spineBase.R, $spineBase.G, $spineBase.B)
        $spine = Get-RoundedPath ($card.X + 3) ($card.Y + 10) $t.CardBarWidth ($card.Height - 20) ($t.CardBarWidth / 2)
        $spb = New-Object System.Drawing.SolidBrush($spineColor)
        $g.FillPath($spb, $spine)
        $spb.Dispose(); $spine.Dispose()

        $textLeft = [single]($card.X + 18)
        $meta = [string]$item.Time
        if ($item.Type -eq 'image') {
            $thumb = Get-Thumb $item.ImageFile
            if ($thumb) {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.DrawImage($thumb, [int]($card.X + 16), [int]($card.Y + 12), 46, 46)
                $ringCol = if ($isSel) { $t.Accent } else { $t.CardBorder }
                $ring = New-Object System.Drawing.Pen($ringCol, 1)
                $rp = Get-RoundedPath ($card.X + 16) ($card.Y + 12) 46 46 ([Math]::Max(0, $t.CardRadius - 1))
                $g.DrawPath($ring, $rp)
                $ring.Dispose(); $rp.Dispose()
            }
            $textLeft = [single]($card.X + 80)
            $preview = [string]$item.Text
            if ([string]::IsNullOrWhiteSpace($preview)) { $preview = 'Image' }
            $meta = "$($item.Time)   ·   $($item.W) x $($item.H) px"
        } else {
            $preview = [string]$item.Text
            $preview = $preview -replace "\r?\n", ' '
            $preview = $preview -replace "\t", ' '
            $preview = $preview.Trim()
        }

        $tb = New-Object System.Drawing.SolidBrush($t.Text)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
        $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $tw = [single]($card.Right - $textLeft - 26)
        if ($tw -lt 10) { $tw = 10 }
        $g.DrawString($preview, $script:fHistItem, $tb, (New-Object System.Drawing.RectangleF($textLeft, ($card.Y + 12), $tw, 22)), $sf)
        $mb = New-Object System.Drawing.SolidBrush($(if ($isSel) { $t.Text } else { $t.Muted }))
        $g.DrawString($meta, $script:fHistMeta, $mb, [single]$textLeft, [single]($card.Y + 43))
        $mb.Dispose(); $tb.Dispose(); $sf.Dispose()

        $tag = if ($item.Type -eq 'image') { 'IMG' } else { 'TXT' }
        $tagFont = New-Object System.Drawing.Font($t.Font, 7, [System.Drawing.FontStyle]::Bold)
        $tagW = [single]($g.MeasureString($tag, $tagFont).Width + 14)
        $tagRect = New-Object System.Drawing.RectangleF(($card.Right - $tagW - 12), ($card.Y + $card.Height - 25), $tagW, 16)
        $tagPath = Get-RoundedPath $tagRect.X $tagRect.Y $tagRect.Width $tagRect.Height $t.TagRadius
        $tagFill = New-Object System.Drawing.SolidBrush($t.TagBg)
        $tagPen = New-Object System.Drawing.Pen($t.TagBorder, $t.TagBorderWidth)
        $g.FillPath($tagFill, $tagPath)
        $g.DrawPath($tagPen, $tagPath)
        $tagFill.Dispose(); $tagPen.Dispose(); $tagPath.Dispose()
        $tfg = New-Object System.Drawing.SolidBrush($t.TagText)
        $tsf = New-Object System.Drawing.StringFormat
        $tsf.Alignment = [System.Drawing.StringAlignment]::Center
        $tsf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString($tag, $tagFont, $tfg, $tagRect, $tsf)
        $tfg.Dispose(); $tsf.Dispose(); $tagFont.Dispose()
    } catch { }
})
$script:tabList.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $g = $e.Graphics
    $t = $script:Theme
    $isSel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
    $isHover = ($e.Index -eq $script:tabHover)

    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $glass = Get-GlassCrop $sender
        if ($glass) {
            $gsrc = New-Object System.Drawing.Rectangle($e.Bounds.X, $e.Bounds.Y, $e.Bounds.Width, $e.Bounds.Height)
            $g.DrawImage($glass, $e.Bounds, $gsrc, [System.Drawing.GraphicsUnit]::Pixel)
        } else {
            $g.Clear($t.Sidebar)
        }
        $pill = New-Object System.Drawing.RectangleF(($e.Bounds.X + 1), ($e.Bounds.Y + 4), ($e.Bounds.Width - 8), ($e.Bounds.Height - 8))
        if ($pill.Width -lt 8 -or $pill.Height -lt 8) { return }

        if ($isSel -or $isHover) {
            if ($isSel -and $t.HardShadow) {
                $sp = Get-RoundedPath ($pill.X + 3) ($pill.Y + 3) $pill.Width $pill.Height $t.ButtonRadius
                $sb = New-Object System.Drawing.SolidBrush($t.Accent)
                $g.FillPath($sb, $sp)
                $sb.Dispose(); $sp.Dispose()
            }
            $p = Get-RoundedPath $pill.X $pill.Y $pill.Width $pill.Height $t.ButtonRadius
            $b = New-Object System.Drawing.SolidBrush($(if ($isSel) { $t.TabSelBg } else { $t.TabHoverBg }))
            $g.FillPath($b, $p)
            $b.Dispose()
            $bCol = if ($isSel) { $t.TabSelBorder } else { $t.Border }
            $pen = New-Object System.Drawing.Pen($bCol, $t.TabBorderWidth)
            $g.DrawPath($pen, $p)
            $pen.Dispose(); $p.Dispose()
        }

        $raw = [string]$sender.Items[$e.Index]
        $isView = Test-ViewTab $raw
        $txt = if ($t.TabUppercase) { $raw.ToUpper() } else { $raw }
        if ($e.Index -eq @($script:viewTabs).Count) {
            $dv = New-Object System.Drawing.Pen($t.Border, 1)
            $g.DrawLine($dv, $e.Bounds.X + 10, $e.Bounds.Y + 1, $e.Bounds.Right - 14, $e.Bounds.Y + 1)
            $dv.Dispose()
        }
        $f = if ($isView) { $script:fTabView } else { $script:fTabItem }
        $tColor = if ($isSel) { $t.TabSelText } else { $t.TabText }
        $dotX = [single]($pill.X + 13)
        $dotY = [single]($pill.Y + ($pill.Height - 5) / 2)
        if ($isSel) {
            $db = New-Object System.Drawing.SolidBrush($t.TabSelDot)
            $g.FillEllipse($db, $dotX, $dotY, 5, 5)
            $db.Dispose()
        } elseif ($isView) {
            $db = New-Object System.Drawing.SolidBrush($t.Accent)
            $g.FillEllipse($db, $dotX, $dotY, 5, 5)
            $db.Dispose()
        } else {
            $dp = New-Object System.Drawing.Pen($t.Muted, 1)
            $g.DrawEllipse($dp, $dotX, $dotY, 4, 4)
            $dp.Dispose()
        }
        $tb = New-Object System.Drawing.SolidBrush($tColor)
        $g.DrawString($txt, $f, $tb, [single]($pill.X + 27), [single]($pill.Y + ($pill.Height - 20) / 2))
        $tb.Dispose()
    } catch { }
})

# hover feedback makes the lists feel less rigid
$script:histList.Add_MouseMove({
    param($s, $e)
    try {
        $i = $s.IndexFromPoint($e.Location)
        if ($i -ne $script:histHover) {
            $old = $script:histHover
            $script:histHover = $i
            if ($old -ge 0 -and $old -lt $s.Items.Count) { $s.Invalidate($s.GetItemRectangle($old)) }
            if ($i -ge 0) { $s.Invalidate($s.GetItemRectangle($i)) }
        }
    } catch { }
})
$script:histList.Add_MouseLeave({
    param($s, $e)
    try {
        $old = $script:histHover
        $script:histHover = -1
        if ($old -ge 0 -and $old -lt $s.Items.Count) { $s.Invalidate($s.GetItemRectangle($old)) }
    } catch { }
})
$script:tabList.Add_MouseMove({
    param($s, $e)
    try {
        $i = $s.IndexFromPoint($e.Location)
        if ($i -ne $script:tabHover) {
            $old = $script:tabHover
            $script:tabHover = $i
            if ($old -ge 0 -and $old -lt $s.Items.Count) { $s.Invalidate($s.GetItemRectangle($old)) }
            if ($i -ge 0) { $s.Invalidate($s.GetItemRectangle($i)) }
        }
    } catch { }
})
$script:tabList.Add_MouseLeave({
    param($s, $e)
    try {
        $old = $script:tabHover
        $script:tabHover = -1
        if ($old -ge 0 -and $old -lt $s.Items.Count) { $s.Invalidate($s.GetItemRectangle($old)) }
    } catch { }
})

# ============================================================
#  EVENT WIRING
# ============================================================
$script:btnToggle.Add_Click({
    $script:capturing = -not $script:capturing
    Update-ToggleUI
    Save-State
})

$script:tabList.Add_SelectedIndexChanged({
    if ($script:tabList.SelectedItem) {
        $script:activeTab = [string]$script:tabList.SelectedItem
        if (-not (Test-ViewTab $script:activeTab)) { $script:captureTab = $script:activeTab }
        Refresh-Hist
        Save-State
    }
})

$script:txtSearch.Add_TextChanged({ Refresh-Hist })

$script:histList.Add_DoubleClick({ Copy-Selected })
$script:btnCopy.Add_Click({ Copy-Selected })
$script:btnView.Add_Click({
    $sel = $script:histList.SelectedItem
    if (-not $sel -and $script:histList.Items.Count -gt 0) {
        $script:histList.SelectedIndex = 0
        $sel = $script:histList.Items[0]
    }
    if (-not $sel) { return }
    Open-Preview $sel
})

$script:tip = New-Object System.Windows.Forms.ToolTip
$script:tip.AutoPopDelay = 8000
$script:tip.InitialDelay = 450
$script:tip.ReshowDelay = 150
$script:tip.SetToolTip($script:histList, 'Double-click a clip to copy it. Select a clip, then press PREVIEW or Enter to open the full item.')
$script:tip.SetToolTip($script:btnView, 'Open the selected clip in a preview window. Images get a big preview plus an OCR TEXT tab.')
$script:tip.SetToolTip($script:btnCopy, 'Copy the selected clip back to the clipboard.')
$script:tip.SetToolTip($script:btnCapture, 'Grab a region of the screen and save it as an image clip.')
$script:tip.SetToolTip($script:btnOcr, 'Read text from the selected image clip.')
$script:tip.SetToolTip($script:btnDelete, 'Delete the selected clip.')
$script:tip.SetToolTip($script:btnClear, 'Clear the current tab or view.')
$script:tip.SetToolTip($script:txtSearch, 'Filter clips. Press Esc to clear.')
$script:tip.SetToolTip($script:btnToggle, 'Turn clipboard capture on or off.')

$script:btnDelete.Add_Click({ Delete-Selected })
$script:btnCapture.Add_Click({ Start-ScreenCapture })
$script:btnOcr.Add_Click({ Run-Ocr })
$script:btnSettings.Add_Click({ Open-Settings })

$script:btnClear.Add_Click({
    if (Test-ViewTab $script:activeTab) {
        $filter = Get-ViewFilter $script:activeTab
        if (@(Get-ViewItems $script:activeTab).Count -eq 0) { return }
        $what = if ($filter -eq 'all') { 'ALL items from every saved tab' } elseif ($filter -eq 'text') { 'all TEXT items from every saved tab' } else { 'all IMAGE items from every saved tab' }
        $r = [System.Windows.Forms.MessageBox]::Show("Delete $what? This cannot be undone.", 'Clear View', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        foreach ($tab in @($script:tabs)) {
            $keep = @()
            foreach ($it in @($tab.Items)) {
                $match = ($filter -eq 'all') -or ([string]$it.Type -eq $filter)
                if ($match) {
                    if ($it.Type -eq 'image' -and $it.ImageFile) {
                        try { Remove-Item -LiteralPath (Join-Path $script:ImagesDir $it.ImageFile) -Force -ErrorAction SilentlyContinue } catch { }
                        if ($script:thumbCache.ContainsKey($it.ImageFile)) {
                            try { $script:thumbCache[$it.ImageFile].Dispose() } catch { }
                            $script:thumbCache.Remove($it.ImageFile)
                        }
                    }
                } else {
                    $keep += $it
                }
            }
            $tab.Items = @($keep)
        }
        Save-State
        Refresh-Hist
        return
    }
    $tab = Get-ActiveTab
    if (-not $tab -or @($tab.Items).Count -eq 0) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Clear all items in tab '$($script:activeTab)'?", 'Clear Tab', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        foreach ($it in @($tab.Items)) {
            if ($it.Type -eq 'image' -and $it.ImageFile) {
                try { Remove-Item -LiteralPath (Join-Path $script:ImagesDir $it.ImageFile) -Force -ErrorAction SilentlyContinue } catch { }
                if ($script:thumbCache.ContainsKey($it.ImageFile)) {
                    try { $script:thumbCache[$it.ImageFile].Dispose() } catch { }
                    $script:thumbCache.Remove($it.ImageFile)
                }
            }
        }
        $tab.Items = @()
        Save-State
        Refresh-Hist
    }
})

$script:chkStrip.Add_CheckedChanged({
    $script:stripImages = $script:chkStrip.Checked
    Save-State
})

$btnNewTab.Add_Click({ New-Tab })
$btnRenTab.Add_Click({ Rename-Tab })
$btnDelTab.Add_Click({ Remove-Tab })

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Tab) {
        $n = $script:tabList.Items.Count
        if ($n -gt 0) {
            $i = $script:tabList.SelectedIndex
            if ($i -lt 0) { $i = 0 }
            if ($e.Shift) { $i = ($i - 1 + $n) % $n } else { $i = ($i + 1) % $n }
            $script:tabList.SelectedIndex = $i
            try {
                $script:tabList.TopIndex = [Math]::Max(0, [Math]::Min($i - 2, [Math]::Max(0, $script:tabList.Items.Count - 1)))
            } catch { }
        }
        $e.SuppressKeyPress = $true
    }
    elseif ($e.Control -and $e.KeyCode -ge [System.Windows.Forms.Keys]::D1 -and $e.KeyCode -le [System.Windows.Forms.Keys]::D3) {
        $i = [int]$e.KeyCode - [int][System.Windows.Forms.Keys]::D1
        if ($i -lt $script:tabList.Items.Count) { $script:tabList.SelectedIndex = $i }
        $e.SuppressKeyPress = $true
    }
    elseif ($e.Control -and $e.Shift -and $e.KeyCode -eq [System.Windows.Forms.Keys]::S) {
        Start-ScreenCapture
        $e.SuppressKeyPress = $true
    }
    elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F) {
        $script:txtSearch.Focus()
        $e.SuppressKeyPress = $true
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        if ($script:txtSearch.Text.Length -gt 0) { $script:txtSearch.Text = '' }
    }
})

$script:histList.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $sel = $script:histList.SelectedItem
        if ($sel) { Open-Preview $sel }
        $e.SuppressKeyPress = $true
    }
})

# ============================================================
#  CLIPBOARD MONITOR
# ============================================================
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 400
$script:timer.Add_Tick({
    if (-not $script:capturing) { return }
    if ((Get-Date) -lt $script:ignoreClipboardUntil) { return }
    try {
        $hasText  = [System.Windows.Forms.Clipboard]::ContainsText()
        $hasImage = [System.Windows.Forms.Clipboard]::ContainsImage()

        if ($hasText) {
            $t = [System.Windows.Forms.Clipboard]::GetText()
            if ($t -ne $script:lastCaptured) { Add-Clip $t }
        }

        if ($hasImage) {
            if ($hasText -and $script:stripImages) {
                $tx = [System.Windows.Forms.Clipboard]::GetText()
                if (-not [string]::IsNullOrEmpty($tx)) { [System.Windows.Forms.Clipboard]::SetText($tx) }
            } else {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                if ($img) {
                    try {
                        $fp = Get-ImageFingerprint $img
                        if ($fp -ne $script:lastImageFingerprint) {
                            if (Add-Image $img ('Image ' + $img.Width + 'x' + $img.Height)) {
                                $script:lastImageFingerprint = $fp
                            }
                        }
                    } finally {
                        $img.Dispose()
                    }
                }
            }
        }
    } catch { }
})

# background image naming timer (runs OCR after an image has been captured)
$script:nameTimer = New-Object System.Windows.Forms.Timer
$script:nameTimer.Interval = 800
$script:nameTimer.Add_Tick({
    if ((-not $script:autoNameQueue -or $script:autoNameQueue.Count -eq 0) -and -not $script:autoNameProc) {
        $script:nameTimer.Stop()
        return
    }
    Invoke-AutoNameQueue
})

# ============================================================
#  TRAY + FORM LIFECYCLE
# ============================================================
$script:notify = New-Object System.Windows.Forms.NotifyIcon
if ($script:AppIcon) {
    try { $script:notify.Icon = New-Object System.Drawing.Icon($script:IconPath, 16, 16) } catch { $script:notify.Icon = [System.Drawing.SystemIcons]::Application }
} else {
    $script:notify.Icon = [System.Drawing.SystemIcons]::Application
}
$script:notify.Visible = $true
$script:notify.Text = 'Clippr'

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('Open Clippr')
$miCapture = New-Object System.Windows.Forms.ToolStripMenuItem('Capture screen region...')
$miPause = New-Object System.Windows.Forms.ToolStripMenuItem('Pause / Resume capture')
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem('OCR settings / store...')
$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem('About Clippr')
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
[void]$trayMenu.Items.Add($miOpen)
[void]$trayMenu.Items.Add($miCapture)
[void]$trayMenu.Items.Add($miPause)
[void]$trayMenu.Items.Add($miSettings)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($miAbout)
[void]$trayMenu.Items.Add($miExit)
$script:notify.ContextMenuStrip = $trayMenu

$miOpen.Add_Click({
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
    $form.Activate()
})
$miCapture.Add_Click({
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
    Start-ScreenCapture
})
$miSettings.Add_Click({
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
    Open-Settings
})
$miAbout.Add_Click({
    $msg = "Clippr  v1.1.0`n`nA friendly neighborhood clipboard manager with saved tabs, screen capture and OCR.`n`nStorage: $($script:DataFile)`nOCR keys: $($script:SettingsFile)`n`nBuilt with PowerShell + WinForms."
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'About Clippr', 'OK', 'Information')
})
$miPause.Add_Click({
    $script:capturing = -not $script:capturing
    Update-ToggleUI
    Save-State
})
$miExit.Add_Click({
    $script:exiting = $true
    Save-State
    $script:notify.Visible = $false
    $form.Close()
})
$script:notify.Add_DoubleClick({
    $form.Show()
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = 'Normal' }
    $form.Activate()
})

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.Hide(); return }
    try {
        foreach ($k in @($script:glassCache.Keys)) {
            $v = $script:glassCache[$k]
            if ($v -and $v.Bmp) { $v.Bmp.Dispose() }
        }
        $script:glassCache = @{}
        $form.Invalidate()
    } catch { }
})

$form.Add_Load({
    try {
        [ClipprNative]::ShowWindow($form.Handle, 5) | Out-Null
        [ClipprNative]::SetForegroundWindow($form.Handle) | Out-Null
        Set-DarkTitleBar $form
    } catch { }
})

$form.Add_Shown({
    Set-DarkScrollBars $script:histList
    Set-DarkScrollBars $script:tabList
})

$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:exiting) {
        $e.Cancel = $true
        Save-State
        $form.Hide()
        $script:notify.ShowBalloonTip(1500, 'Clippr', 'Still running in the tray.', [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Save-State
    }
})

$script:form = $form
$script:main = $main
$script:sidebar = $sidebar
$script:header = $header
$script:brand = $brand
$script:listWrap = $listWrap
$script:searchBox = $searchBox
$script:statusBar = $statusBar
$script:statusLine = $statusLine
$script:headerLine = $headerLine
$script:lblSearch = $lblSearch
$script:lblTabs = $lblTabs
$script:lblSub = $lblSub
$script:lblCredit = $lblCredit
$script:btnNewTab = $btnNewTab
$script:btnRenTab = $btnRenTab
$script:btnDelTab = $btnDelTab

function Apply-Theme([string]$key) {
    Set-ThemePalette $key
    $t = $script:Theme
    if ($script:settings) { $script:settings.Theme = $t.Key }

    try {
        foreach ($k in @($script:glassCache.Keys)) {
            $v = $script:glassCache[$k]
            if ($v -and $v.Bmp) { $v.Bmp.Dispose() }
        }
    } catch { }
    $script:glassCache = @{}

    try {
        if ($form.BackgroundImage) { $form.BackgroundImage.Dispose() }
        $form.BackgroundImage = New-GlassBackground $form.ClientSize.Width $form.ClientSize.Height
        $form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
        $form.BackColor = $t.Bg
        $form.ForeColor = $t.Text
        $form.Font = New-Object System.Drawing.Font($t.Font, 9)
    } catch { }

    if ($script:listWrap) {
        $script:listWrap.BackColor = $t.ListBorder
        $script:listWrap.Padding = New-Object System.Windows.Forms.Padding($t.ListBorderWidth, $t.ListBorderWidth, $t.ListBorderWidth, $t.ListBorderWidth)
        Set-RoundedRegion $script:listWrap $t.PanelRadius
    }
    if ($script:histList) {
        $script:histList.BackColor = $t.ListBg
        $script:histList.ForeColor = $t.Text
    }
    if ($script:histScroll) { $script:histScroll.BackColor = $t.ListBg }
    if ($script:tabList) {
        $script:tabList.BackColor = $t.Sidebar
        $script:tabList.ForeColor = $t.Text
    }

    if ($script:searchBox) {
        $script:searchBox.BackColor = $t.SearchBg
        Set-RoundedRegion $script:searchBox $t.SearchRadius
        $script:searchBox.Invalidate()
    }
    if ($script:txtSearch) {
        $script:txtSearch.BackColor = $t.SearchBg
        $script:txtSearch.ForeColor = $t.Text
        $script:txtSearch.Font = New-Object System.Drawing.Font($t.Font, 10)
    }
    if ($script:lblSearch) {
        $script:lblSearch.ForeColor = $t.Muted
        $script:lblSearch.Font = New-Object System.Drawing.Font($t.LabelFont, 7.5, [System.Drawing.FontStyle]::Bold)
    }
    if ($script:lblTabs) {
        $script:lblTabs.ForeColor = $t.Muted
        $script:lblTabs.Font = New-Object System.Drawing.Font($t.LabelFont, 8, [System.Drawing.FontStyle]::Bold)
    }

    if ($script:statusBar) { $script:statusBar.BackColor = $t.StatusBg }
    if ($script:statusLine) {
        $script:statusLine.Height = $t.StatusLineWidth
        $script:statusLine.BackColor = $t.StatusLine
    }
    if ($script:lblStatus) {
        $script:lblStatus.ForeColor = $t.StatusText
        $statusPx = if ($t.Key -eq 'Brutal') { 7.0 } else { 8 }
        $script:lblStatus.Font = New-Object System.Drawing.Font($t.MetaFont, $statusPx)
        $script:lblStatus.AutoEllipsis = $true
        $script:lblStatus.UseMnemonic = $false
    }
    if ($script:lblCredit) {
        $script:lblCredit.ForeColor = $t.StatusText
        $creditPx = if ($t.Key -eq 'Brutal') { 7.5 } else { 8 }
        $script:lblCredit.Font = New-Object System.Drawing.Font($t.MetaFont, $creditPx)
    }

    if ($script:headerLine) {
        $script:headerLine.Height = $t.HeaderLineWidth
        $script:headerLine.BackColor = $t.Border
    }
    if ($script:lblSub) {
        $script:lblSub.Text = $t.SubText
        $script:lblSub.Font = New-Object System.Drawing.Font($t.SubFont, $t.SubSize, $t.SubStyle)
        $script:lblSub.ForeColor = $t.Muted
    }

    $script:fHistItem = New-Object System.Drawing.Font($t.CardFont, $t.CardFontSize, $t.CardFontStyle)
    $script:fHistMeta = New-Object System.Drawing.Font($t.MetaFont, $t.MetaFontSize)
    $script:fTabView  = New-Object System.Drawing.Font($t.TabFont, $t.TabFontSize, [System.Drawing.FontStyle]::Bold)
    $script:fTabItem  = New-Object System.Drawing.Font($t.TabFont, $t.TabFontSize, [System.Drawing.FontStyle]::Regular)

    Style-Button $script:btnCopy $true
    Style-Button $script:btnView $false
    Style-Button $script:btnCapture $false
    Style-Button $script:btnOcr $false
    Style-Button $script:btnDelete $false
    Style-Button $script:btnClear $false
    Style-Button $script:btnSettings $false
    if ($script:btnNewTab) { Style-Button $script:btnNewTab $false }
    if ($script:btnRenTab) { Style-Button $script:btnRenTab $false }
    if ($script:btnDelTab) { Style-Button $script:btnDelTab $false }
    if ($script:btnSettings) { $script:btnSettings.Font = New-Object System.Drawing.Font($t.ButtonFont, 8.5, [System.Drawing.FontStyle]::Bold) }

    if ($script:chkStrip) {
        $script:chkStrip.ForeColor = $t.Muted
        $script:chkStrip.Font = New-Object System.Drawing.Font($t.Font, 8.5)
    }
    Update-ToggleUI

    try { $script:sidebar.Invalidate() } catch { }
    try { $script:header.Invalidate() } catch { }
    try { $script:brand.Invalidate() } catch { }
    try { $script:main.Invalidate() } catch { }
    try { $script:histList.Invalidate() } catch { }
    try { $script:tabList.Invalidate() } catch { }
    try { $script:form.Invalidate($true) } catch { }
    Set-DarkTitleBar $script:form
    Refresh-Hist
    try { $script:tabList.Invalidate() } catch { }
    try { Update-HistScroll } catch { }
}

# ============================================================
#  GO
# ============================================================
Update-ToggleUI
Refresh-Tabs
Refresh-Hist

[System.Windows.Forms.Application]::Run($form)

$script:timer.Stop()
if ($script:nameTimer) { try { $script:nameTimer.Stop(); $script:nameTimer.Dispose() } catch { } }
if ($script:autoNameProc) {
    try {
        if (-not $script:autoNameProc.HasExited) { $script:autoNameProc.Kill() }
        $script:autoNameProc.Dispose()
    } catch { }
}
if ($script:autoNameOut) { try { Remove-Item -LiteralPath $script:autoNameOut -Force -ErrorAction SilentlyContinue } catch { } }
try { foreach ($k in @($script:glassCache.Keys)) { $v = $script:glassCache[$k]; if ($v.Bmp) { $v.Bmp.Dispose() } } } catch { }
if ($script:BrandImage) { try { $script:BrandImage.Dispose() } catch { } }
if ($script:AppIcon) { try { $script:AppIcon.Dispose() } catch { } }
$script:notify.Visible = $false
$script:notify.Dispose()
