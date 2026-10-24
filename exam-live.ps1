param(
  [string]$Provider    = 'deepseek',
  [string]$Hotkey      = 'f9',
  [double]$Scale       = 1.5,
  [string]$Crop        = '',
  [string]$Theme       = 'white',
  [double]$FontSize    = 11,
  [int]$MaxWidth     = 420,
  [int]$Preview      = 0,
  [int]$AutoHideSec    = 3,
  [double]$PeriodSec   = 66.9,
  [double]$GuardSec    = 4,
  [switch]$Hold,
  [switch]$Check,
  [switch]$Once,
  [switch]$SnapInfo,
  [switch]$Demo,
  [switch]$NoWDA,
  [switch]$Brief,
  [int]$MaxChars    = 0,
  [int]$PageChars   = 60,
  [int]$FullWidth   = 460,
  [int]$FullSeconds = 9,
  [int]$InlineMax   = 220,
  [switch]$ForceChild,
  [switch]$NoChild,
  [switch]$AllowMulti,
  [int]$Auto = 0,
  [string]$TextColor   = 'dark'
)
$ErrorActionPreference = 'Stop'
$kit    = $PSScriptRoot
$shot   = Join-Path $env:TEMP 'exam-shot.png'
$qtxt   = Join-Path $env:TEMP 'exam-q.txt'
$ans    = Join-Path $kit 'answers.txt'
$logDir = 'C:\ProgramData\ExamClient\.log'
$runLog = Join-Path $env:TEMP 'live-run.log'

function RL([string]$m) {
    try { ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Add-Content -LiteralPath $runLog -Encoding utf8 } catch {}
}

# 单实例：已有浮层在跑就自己退出，避免 F9 触发两次
$script:mtx = $null
if (-not $AllowMulti -and -not $Check -and -not $Demo -and -not $Preview) {
    $created = $false
    try { $script:mtx = New-Object System.Threading.Mutex($true, 'Local\exam-live-overlay', [ref]$created) } catch { $created = $true }
    if (-not $created) { RL 'DUP exit (mutex held)'; exit 0 }
}

# ---------------- 抓拍相位 ----------------
$script:snapCache = @{ at = [datetime]::MinValue; next = $null; last = $null; period = $PeriodSec; samples = 0 }

function Get-SnapshotState {
    if (((Get-Date) - $script:snapCache.at).TotalSeconds -lt 3) { return $script:snapCache }
    $st = @{ at = Get-Date; next = $null; last = $null; period = $PeriodSec; samples = 0 }
    try {
        $f = Get-ChildItem -LiteralPath $logDir -File -ErrorAction Stop |
             Where-Object { $_.Name -like '*_Cef.log' } | Sort-Object LastWriteTime | Select-Object -Last 1
        if ($f) {
            $stamps = New-Object System.Collections.ArrayList
            $year = (Get-Date).Year
            foreach ($line in Get-Content -LiteralPath $f.FullName -Encoding utf8 -ErrorAction SilentlyContinue) {
                if ($line -notmatch 'offScreenCapture success') { continue }
                if ($line -match '^\[(\d{2})(\d{2})/(\d{6})\.(\d{3})') {
                    try {
                        $dt = [datetime]::new($year, [int]$Matches[1], [int]$Matches[2],
                                [int]$Matches[3].Substring(0,2), [int]$Matches[3].Substring(2,2),
                                [int]$Matches[3].Substring(4,2), [int]$Matches[4])
                        if ($dt -gt (Get-Date).AddHours(-8)) { [void]$stamps.Add($dt) }
                    } catch {}
                }
            }
            if ($stamps.Count -gt 0) {
                $st.last = $stamps[$stamps.Count - 1]
                $st.samples = $stamps.Count
                if ($stamps.Count -ge 2) {
                    $d = @()
                    for ($i = 1; $i -lt $stamps.Count; $i++) {
                        $x = ($stamps[$i] - $stamps[$i-1]).TotalSeconds
                        if ($x -gt 10 -and $x -lt 600) { $d += $x }
                    }
                    if ($d.Count -gt 0) { $s = $d | Sort-Object; $st.period = [double]$s[[int][math]::Floor($s.Count/2)] }
                }
                if (((Get-Date) - $st.last).TotalSeconds -le ($st.period * 3)) {
                    $nx = $st.last.AddSeconds($st.period)
                    while ($nx -lt (Get-Date)) { $nx = $nx.AddSeconds($st.period) }
                    $st.next = $nx
                }
            }
        }
    } catch {}
    $script:snapCache = $st
    return $st
}

function TimeToNextSnap {
    $s = Get-SnapshotState
    if (-not $s.next) { return 9999.0 }
    return ($s.next - (Get-Date)).TotalSeconds
}

if ($SnapInfo) {
    $s = Get-SnapshotState
    'last snapshot : {0}' -f $(if ($s.last) { $s.last.ToString('HH:mm:ss.fff') } else { '未找到' })
    'next snapshot : {0}' -f $(if ($s.next) { $s.next.ToString('HH:mm:ss.fff') } else { '推算不出' })
    'period        : {0:N1}s (样本 {1})' -f $s.period, $s.samples
    'now           : {0}' -f (Get-Date -Format 'HH:mm:ss.fff')
    '距离下次      : {0:N1}s' -f (TimeToNextSnap)
    exit 0
}

# ---------------- 取题流水线 ----------------
function Invoke-Child {
    # 起子进程 + 硬超时；超时就杀掉并抛错，绝不让 UI 线程无限等
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 15)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -PassThru -WindowStyle Hidden
    try { $p | Wait-Process -Timeout $TimeoutSec -ErrorAction Stop }
    catch {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        RL ("  TIMEOUT after {0}s: {1}" -f $TimeoutSec, (Split-Path -Leaf $ArgList[3]))
        throw ("超时 {0}s" -f $TimeoutSec)
    }
    RL ('  {0} {1:N1}s' -f (Split-Path -Leaf $ArgList[3]), $sw.Elapsed.TotalSeconds)
    return $p.ExitCode
}

function Invoke-Pipeline {
    param([string]$UseProvider = '')
    $prov = if ($UseProvider) { $UseProvider } else { $Provider }
    $ps = 'powershell.exe'
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $cap = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $kit 'capture.ps1'),
             '-Out',$shot,'-FullScreen','-Scale',"$Scale",'-Silent')
    if ($Crop -ne '') { $cap += @('-Crop', $Crop) }
    [void](Invoke-Child -Exe $ps -ArgList $cap -TimeoutSec 12)
    if (-not (Test-Path $shot)) { throw 'capture failed' }

    [void](Invoke-Child -Exe $ps -TimeoutSec 15 -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
        (Join-Path $kit 'ocr.ps1'),'-Image',$shot,'-UpScale','2','-OutText',$qtxt))
    if (-not (Test-Path $qtxt)) { throw 'ocr failed' }

    $briefArg = if ($Brief) { @('-Brief') } else { @() }
    [void](Invoke-Child -Exe $ps -TimeoutSec 15 -ArgList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',
        (Join-Path $kit 'solve.ps1'),'-TextFile',$qtxt,'-Out',$ans,'-Provider',$prov,'-Quiet') + $briefArg))
    if (-not (Test-Path $shot)) { throw 'capture failed' }
    RL ('  capture {0:N1}s' -f $sw.Elapsed.TotalSeconds); $sw.Restart()

    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'ocr.ps1') -Image $shot -UpScale 2 -OutText $qtxt | Out-Null
    if (-not (Test-Path $qtxt)) { throw 'ocr failed' }
    RL ('  ocr {0:N1}s' -f $sw.Elapsed.TotalSeconds); $sw.Restart()

    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'solve.ps1') -TextFile $qtxt -Out $ans -Provider $prov -Quiet $(if ($Brief) { '-Brief' }) | Out-Null
    RL ('  solve {0:N1}s provider={1}' -f $sw.Elapsed.TotalSeconds, $prov)
    return (Get-Content -LiteralPath $ans -Encoding utf8) -join "`n"
}

if ($Once) {
    '== 抓屏 → OCR → 答题 =='
    Invoke-Pipeline | Out-Null
    Get-Content -LiteralPath $ans -Encoding utf8
    exit 0
}

RL "START pid=$PID hotkey=$Hotkey provider=$Provider"
trap { RL "TRAP: $_"; break }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('ManualInput' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing','System.Runtime.InteropServices' -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class ManualInput : Form
{
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    const int WS_EX_TOOLWINDOW = 0x80;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public TextBox Box;
    public ManualInput()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true; ShowInTaskbar = false; Opacity = 0.95;
        BackColor = Color.White;
        Width = 380; Height = 108;
        var wa = Screen.PrimaryScreen.WorkingArea;
        Left = Math.Max(10, wa.Right - Width - 24); Top = 96;
        var box = new TextBox();
        box.Multiline = true; box.BorderStyle = BorderStyle.None;
        box.Font = new Font("Microsoft YaHei", 10f);
        box.ForeColor = Color.FromArgb(0x22,0x22,0x22);
        box.SetBounds(8, 6, 364, 74);
        Box = box;
        var hint = new Label();
        hint.Text = "Enter 提交    Esc 取消";
        hint.Font = new Font("Microsoft YaHei", 7.5f);
        hint.ForeColor = Color.FromArgb(0x99,0x99,0x99);
        hint.SetBounds(8, 84, 200, 18);
        Controls.Add(box); Controls.Add(hint);
    }
    protected override CreateParams CreateParams
    { get { var cp = base.CreateParams; cp.ExStyle |= WS_EX_TOOLWINDOW; return cp; } }
    protected override void OnShown(EventArgs e)
    { base.OnShown(e); SetWindowPos(Handle, HWND_TOPMOST, 0,0,0,0, 0x0001|0x0002); SetWindowDisplayAffinity(Handle, 0x11u); Box.Focus(); }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Enter) { DialogResult = DialogResult.OK; Close(); return true; }
        if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}
"@
}
if (-not ('Overlay' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing','System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class Overlay : Form
{
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr c, IntPtr p);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint c);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern IntPtr SetWindowLong(IntPtr h, int i, IntPtr v);
    static IntPtr SetPtr(IntPtr h, int idx, IntPtr v)
    {
        return IntPtr.Size == 8 ? SetWindowLongPtr(h, idx, v) : SetWindowLong(h, idx, v);
    }
    const int GWLP_HWNDPARENT = -8;
    const uint GW_OWNER = 4;
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    const int WS_EX_TRANSPARENT = 0x20, WS_EX_LAYERED = 0x80000, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x8000000;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public Label Txt;
    public bool ExcludeFromCapture = true;
    public bool White = true;
    public int RightMargin = 24;
    public int TopMargin = 96;
    public int MaxWidth = 420;
    public int ScreenX = 400;
    public int ScreenY = 96;
    public IntPtr ParentHwnd = IntPtr.Zero;
    public bool AutoAttach = true;

    public Overlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true; ShowInTaskbar = false;
        BackColor = Color.White; Opacity = 0.94;
        Width = 120; Height = 36;
        var wa = Screen.PrimaryScreen.WorkingArea;
        ScreenX = Math.Max(10, wa.Right - Width - RightMargin); ScreenY = TopMargin;
        Txt = new Label();
        Txt.Dock = DockStyle.Fill;
        Txt.TextAlign = ContentAlignment.MiddleCenter;
        Txt.Font = new Font("Microsoft YaHei", 14f, FontStyle.Bold);
        Txt.Padding = new Padding(3);
        Controls.Add(Txt);
        ApplyTheme();
    }

    protected override CreateParams CreateParams
    {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    public void ApplyTheme()
    {
        if (White) {
            BackColor = Color.White; Txt.BackColor = Color.White;
            Txt.ForeColor = Color.FromArgb(0x33, 0x33, 0x33);
            Opacity = 0.94;
        } else {
            BackColor = Color.Black; Txt.BackColor = Color.Black;
            Txt.ForeColor = Color.White;
            Opacity = 0.92;
        }
        var wa = Screen.PrimaryScreen.WorkingArea;
        ScreenX = Math.Max(0, wa.Right - Width - RightMargin);
        ScreenY = TopMargin;
        Invalidate();
        ApplyPos();
    }

    public void AutoFit()
    {
        int cap = MaxWidth > 80 ? MaxWidth : 420;
        var sz = TextRenderer.MeasureText(Txt.Text, Txt.Font, new Size(cap - 14, 2000), TextFormatFlags.WordBreak);
        Width = Math.Min(cap, Math.Max(46, sz.Width + 14));
        Height = Math.Max(22, sz.Height + 8);
        var wa = Screen.PrimaryScreen.WorkingArea;
        ScreenX = Math.Max(0, wa.Right - Width - RightMargin);
        ApplyPos();
    }

    public void ApplyPos()
    {
        var wa = Screen.PrimaryScreen.WorkingArea;
        if (ScreenX < 0) ScreenX = 0;
        if (ScreenY < TopMargin) ScreenY = TopMargin;
        if (ScreenY + Height > wa.Bottom) ScreenY = Math.Max(0, wa.Bottom - Height - 20);
        Location = new Point(ScreenX, ScreenY);
    }

    // 宿主窗口没了就自动解除附属关系，免得浮层跟着一起消失
    public void EnsureOwner()
    {
        if (ParentHwnd != IntPtr.Zero && !IsWindow(ParentHwnd)) Detach();
    }

    public void Nudge(int dx, int dy)
    {
        ScreenX = Math.Max(0, ScreenX + dx);
        ScreenY = Math.Max(0, ScreenY + dy);
        ApplyPos();
        Raise();
    }

    public string AttachErr = "";
    public bool Attach()
    {
        AttachErr = "";
        if (Handle == IntPtr.Zero) { AttachErr = "handle0"; return false; }
        // 1) 先取浮层正下方那个窗口（WS_EX_TRANSPARENT 会被 WindowFromPoint 跳过）
        POINT cp = new POINT();
        cp.X = ScreenX + Width / 2; cp.Y = ScreenY + Math.Min(Height / 2, 12);
        IntPtr target = WindowFromPoint(cp);
        if (target == Handle || target == IntPtr.Zero) target = GetForegroundWindow();
        if (target == IntPtr.Zero) { AttachErr = "target0"; return false; }
        IntPtr root = GetAncestor(target, 2);   // GA_ROOT
        if (root == IntPtr.Zero) root = target;
        if (root == Handle) { AttachErr = "targetIsSelf"; return false; }
        if (root == GetDesktopWindow() || root == GetShellWindow()) { AttachErr = "desktop"; return false; }
        if (ParentHwnd == root) { Raise(); ApplyPos(); return true; }
        if (ParentHwnd != IntPtr.Zero) Detach();
        // 2) 把浮层挂成该窗口的“附属窗口”（owned window）：附属窗口永远画在宿主之上
        SetPtr(Handle, GWLP_HWNDPARENT, root);
        IntPtr got = GetWindow(Handle, GW_OWNER);
        if (got != root) { AttachErr = "owner_fail tgt=" + target + " root=" + root + " got=" + got; Detach(); return false; }
        ParentHwnd = root;
        SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040);
        SetWindowDisplayAffinity(Handle, ExcludeFromCapture ? 0x11u : 0x00u);
        ApplyPos();
        return true;
    }

    public void Detach()
    {
        if (ParentHwnd == IntPtr.Zero) return;
        SetPtr(Handle, GWLP_HWNDPARENT, IntPtr.Zero);
        ParentHwnd = IntPtr.Zero;
        SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002);
        SetWindowDisplayAffinity(Handle, ExcludeFromCapture ? 0x11u : 0x00u);
        ApplyPos();
    }

    // 本窗口是否已经被前台窗口压住（EnumWindows 顺序：0 为最上）
    public bool BelowForeground()
    {
        if (!Visible) return false;
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero || fg == Handle) return false;
        IntPtr me = Handle;
        int mi = -1, fi = -1, n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            if (h == me) mi = n;
            if (h == fg) fi = n;
            n++;
            return true;
        }, IntPtr.Zero);
        if (mi < 0 || fi < 0) return false;
        return mi > fi;
    }

    public void Raise()
    {
        if (Handle == IntPtr.Zero) return;
        if (AutoAttach) Attach();
        EnsureOwner();
        SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002);
        SetWindowDisplayAffinity(Handle, ExcludeFromCapture ? 0x11u : 0x00u);
    }

    public void SetWidth(int w) { Width = Math.Max(60, w); AutoFit(); }
}
'@
}

if (-not ('KeyPoll' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KeyPoll
{
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    public static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
    public static bool CtrlAlt { get { return Down(0x11) && Down(0x12); } }
}
'@
}
if (-not ('WinInfo' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WinInfo
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string Fg()
    {
        IntPtr h = GetForegroundWindow();
        var c = new StringBuilder(160); GetClassNameW(h, c, 160);
        var t = new StringBuilder(160); GetWindowTextW(h, t, 160);
        uint p; GetWindowThreadProcessId(h, out p);
        return h + " pid=" + p + " cls=" + c + " txt=" + t;
    }
}
'@
}

if ($Check) { "compile ok (hotkey=$Hotkey theme=$Theme autohide=${AutoHideSec}s guard=${GuardSec}s hold=$Hold child=$ForceChild)"; exit 0 }

$HK = @{
  ctrlaltg = @{ vk = 0x47; mod = $true }; scrolllock = @{ vk = 0x91; mod = $false }
  pause = @{ vk = 0x13; mod = $false }; capslock = @{ vk = 0x14; mod = $false }
  f8 = @{ vk = 0x77; mod = $false }; f9 = @{ vk = 0x78; mod = $false }
  f10 = @{ vk = 0x7A; mod = $false }; f11 = @{ vk = 0x7B; mod = $false }
  f12 = @{ vk = 0x7C; mod = $false }; insert = @{ vk = 0x2D; mod = $false }
  backquote = @{ vk = 0xC0; mod = $false }; rctrl = @{ vk = 0xA3; mod = $false }
}
if (-not $HK.ContainsKey($Hotkey)) { throw "unknown -Hotkey: $Hotkey" }

$form = New-Object Overlay
$form.White = ($Theme -ne 'dark')
$form.Txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', $FontSize, [System.Drawing.FontStyle]::Bold)
$script:fontSize = $FontSize
$form.ExcludeFromCapture = (-not $NoWDA)
$form.AutoAttach = (-not $NoChild)
$form.MaxWidth = $MaxWidth
if ($TextColor -eq 'gray') { $form.Txt.ForeColor = [System.Drawing.Color]::FromArgb(0x80,0x80,0x80) }
$form.ApplyTheme()

$script:shown = $false; $script:held = $false; $script:trigHeld = $false
$script:lastCalc = [datetime]::MinValue; $script:hideAt = [datetime]::MaxValue
$script:lastRaise = [datetime]::MinValue; $script:showAt = [datetime]::MinValue; $script:full = $null; $script:page = 0; $script:pages = 0; $script:fullHeld = $false; $script:f8Held = $false; $script:f7Held = $false; $script:fullAt = [datetime]::MinValue
$script:hb = 0
$script:mbHeld = $false; $script:mouseEdge = $false; $script:lastAns = $null; $script:autoFire = $false
$script:zLow = 0

$script:vk = $HK[$Hotkey].vk; $script:mod = $HK[$Hotkey].mod

$form.Txt.Text = "按 $Hotkey 取题"

function Split-Pages {
    param([string]$Text, [int]$Size)
    if (-not $Text) { return @('') }
    $out = @(); $rest = $Text
    while ($rest.Length -gt 0) {
        if ($rest.Length -le $Size) { $out += $rest; break }
        $cut = $Size
        $nl = $rest.LastIndexOf("`n", [Math]::Min($Size, $rest.Length - 1))
        if ($nl -gt 20) { $cut = $nl }
        $out += $rest.Substring(0, $cut).TrimEnd()
        $rest = $rest.Substring([Math]::Min($cut + 1, $rest.Length)).TrimStart()
    }
    return $out
}

$archDir = Join-Path $kit 'archive'
function Archive-Item {
    param([string]$Q, [string]$A)
    if (-not $Q -and -not $A) { return }
    try {
        if (-not (Test-Path -LiteralPath $archDir)) { New-Item -ItemType Directory -Path $archDir -Force | Out-Null }
        $f = Join-Path $archDir ((Get-Date -Format 'yyyy-MM-dd') + '.txt')
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('======== ' + (Get-Date -Format 'HH:mm:ss') + ' ========')
        [void]$sb.AppendLine('[题]')
        foreach ($ln in ($Q -split "`r?`n")) { if ($ln.Trim()) { [void]$sb.AppendLine('  ' + $ln.Trim()) } }
        [void]$sb.AppendLine('[答]')
        foreach ($ln in ($A -split "`r?`n")) { if ($ln.Trim()) { [void]$sb.AppendLine('  ' + $ln.Trim()) } }
        [void]$sb.AppendLine('')
        [System.IO.File]::AppendAllText($f, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    } catch { }
}

function Show-Full {
    # 一次显示整段答案（复杂简答/SQL 用），按 Z 或 9 秒后自动收
    # 始终读最新的 answers.txt，避免用到上一次的旧分页
    $text = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
    $old = $form.MaxWidth
    $form.MaxWidth = $FullWidth
    $form.Txt.Text = $text
    $form.AutoFit(); $form.Show(); $form.Raise()
    $form.MaxWidth = $old
    $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
    $script:hideAt = (Get-Date).AddSeconds($FullSeconds)
    RL "FULL shown chars=$($text.Length)"
}

function Invoke-Manual {
    $dlg = New-Object ManualInput
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $q = $dlg.Box.Text.Trim()
    $dlg.Dispose()
    if (-not $q) { return }
    RL "MANUAL chars=$($q.Length)"
    $dlgTxt = Join-Path $env:TEMP 'exam-manual.txt'
    $q | Set-Content -LiteralPath $dlgTxt -Encoding utf8
    $txt = $null
    try {
        $ps = 'powershell.exe'
        $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $kit 'solve.ps1'),
                  '-TextFile',$dlgTxt,'-Out',$ans,'-Provider',$Provider,'-Quiet')
        if ($Brief) { $argl += '-Brief' }
        [void](Invoke-Child -Exe $ps -ArgList $argl -TimeoutSec 20)
        $txt = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
    } catch { $txt = "出错: $($_.Exception.Message)" }
    $script:full = @($txt); $script:pages = 1; $script:page = 0; $script:fullAt = Get-Date
    $keep = $form.MaxWidth; $form.MaxWidth = $FullWidth
    $form.Txt.Text = $txt
    $form.AutoFit(); $form.Show(); $form.Raise()
    $form.MaxWidth = $keep
    $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
    $script:hideAt = (Get-Date).AddSeconds($FullSeconds)
    RL "MANUAL shown chars=$($txt.Length)"
    try { Archive-Item -Q $q -A $txt } catch { }
}

function Show-Answer {
    $form.Txt.Text = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
    $form.AutoFit(); $form.Show(); $form.Raise()
    $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
    $script:hideAt = (Get-Date).AddSeconds($AutoHideSec)
}
function Hide-Answer { if ($form.ParentHwnd -ne [IntPtr]::Zero) { $form.Detach() }; $form.Hide(); $script:shown = $false; $script:zLow = 0
}

if ($Preview -gt 0) {
    $form.Txt.Text = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
    $form.AutoFit(); $form.Show(); $form.Raise()
    if ($ForceChild) { $okp = $form.Attach(); RL ("PREVIEW child={0} err={1}" -f $okp, $form.AttachErr) }
    RL "PREVIEW ${Preview}s size=$($form.Width)x$($form.Height)"
    Start-Sleep -Seconds $Preview
    $form.Hide()
    exit 0
}

if ($Demo) {
    $form.Txt.Text = '12. B'
    $form.AutoFit(); $form.Show(); $form.Raise()
    if ($ForceChild) { $okc = $form.Attach(); RL ("DEMO child={0} err={1} fg=[{2}] own={3} below={4}" -f $okc, $form.AttachErr, [WinInfo]::Fg(), $form.Handle, $form.BelowForeground()) }
    RL 'DEMO shown'
    $dt = New-Object System.Windows.Forms.Timer
    $dt.Interval = 9000
    $dt.Add_Tick({ $dt.Stop(); $form.Close() })
    $dt.Start()
    [System.Windows.Forms.Application]::Run()
    RL 'DEMO exit'
    exit 0
}

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 40
$poll.Add_Tick({
    try {
        $now = Get-Date
        $ttn = TimeToNextSnap

        if ($script:shown) {
            if ($script:ForceChild -and $form.ParentHwnd -eq [IntPtr]::Zero) { if ($form.Attach()) { RL 'CHILD forced' } }
            if ($Hold -and [KeyPoll]::Down($script:vk)) { $script:hideAt = $now.AddMilliseconds(400) }
            if ($ttn -le $GuardSec -or $now -gt $script:hideAt) { Hide-Answer }
            elseif (($now - $script:lastRaise).TotalMilliseconds -gt 120) {
                $form.Raise(); $script:lastRaise = $now
                if (-not $script:ForceChild -and $form.ParentHwnd -eq [IntPtr]::Zero -and $form.BelowForeground()) {
                    $script:zLow++
                    if ($script:zLow -ge 3) {
                        $ok = $form.Attach()
                        RL "CHILD auto=$ok n=$($script:zLow)"
                        if ($ok) { $script:zLow = 0
}
                    }
                } elseif ($script:zLow -ne 0) { $script:zLow = 0
}
            }
        }

        $modOk = (-not $script:mod) -or [KeyPoll]::CtrlAlt
        $down  = [KeyPoll]::Down($script:vk)

        $script:hb = ($script:hb + 1) % 250
        if ($script:hb -eq 0) { RL "beat vk=$($script:vk) down=$down shown=$($script:shown)" }

        # 自动模式：每 $Auto 秒自己抓一次，完全不依赖按键
        $script:autoFire = $false
        if ($Auto -gt 0 -and -not $script:shown -and ((Get-Date) - $script:lastCalc).TotalSeconds -ge $Auto) { $script:autoFire = $true }
        # 鼠标兜底：滚轮中键按下 = 触发（考试客户端可能把 F9 吃掉）
        $mbNow = [KeyPoll]::Down(0x04)
        $script:mouseEdge = ($mbNow -and (-not $script:mbHeld))
        $script:mbHeld = $mbNow
        if ((($modOk -and $down) -or $script:mouseEdge -or $script:autoFire)) {
            if (-not $script:trigHeld) {
                $script:trigHeld = $true
                RL "TRIGGER src=$($(if ($script:autoFire) { 'auto' } elseif ($script:mouseEdge) { 'mouse' } else { 'key' })) vk=$($script:vk) ttn=$([math]::Round($ttn,1)) fg=[$([WinInfo]::Fg())]"
                $wait = (TimeToNextSnap - $GuardSec)
                if ($wait -gt 0 -and $wait -lt $GuardSec) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
                if ($script:shown) { Hide-Answer }
                # 已有答案且还有下一页 -> 直接翻页，不重算
                if ($script:full -and $script:page -lt ($script:pages - 1) -and $script:fullAt -and ((Get-Date) - $script:fullAt).TotalSeconds -lt 30) {
                    $script:page++
                    $pTxt = $script:full[$script:page]
                    $form.Txt.Text = $pTxt + "  " + ($script:page + 1) + "/" + $script:pages
                    $form.AutoFit(); $form.Show(); $form.Raise()
                    $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
                    $script:hideAt = (Get-Date).AddSeconds($AutoHideSec)
                    RL "PAGE $($script:page + 1)/$($script:pages)"
                    return
                }

                $txt = $null
                if ($script:lastCalc -and ((Get-Date) - $script:lastCalc).TotalSeconds -lt 3 -and (Test-Path $ans)) {
                    $txt = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
                } else {
                    try { $txt = Invoke-Pipeline }
                    catch {
                        $e1 = $_.Exception.Message
                        RL "PIPE-ERR $e1"
                        if ($Provider -ne 'ollama') {
                            try { $txt = Invoke-Pipeline -UseProvider 'ollama' }
                            catch { $txt = "云端失败($e1)；本地也失败($($_.Exception.Message))" }
                        } else { $txt = "出错: $e1" }
                    }
                    $script:lastCalc = Get-Date
                }
                # 没读到题 / 和上次答案一样 -> 不弹框（避免自动模式下瞎闪）
                if ($txt -match '无题目' -or $txt.Trim().Length -lt 3) { $script:lastCalc = Get-Date; RL "SKIP noshow len=$($txt.Length)"; return }
                if ($script:lastAns -and $txt -eq $script:lastAns -and $script:autoFire) { $script:lastCalc = Get-Date; RL 'SKIP same answer'; return }
                $script:lastAns = $txt
                try { Archive-Item -Q (Get-Content -LiteralPath $qtxt -Raw -Encoding utf8) -A $txt } catch { }
                if ($MaxChars -gt 0 -and $txt.Length -gt $MaxChars) { $txt = $txt.Substring(0, $MaxChars) + '…' }
                # 短答案（含多数简答/SQL）：一次显示整段，不做分页
                if ($txt.Length -le $InlineMax) {
                    $script:full = @($txt); $script:pages = 1; $script:page = 0; $script:fullAt = Get-Date
                    $keep = $form.MaxWidth
                    $form.MaxWidth = $FullWidth
                    $form.Txt.Text = $txt
                    $form.AutoFit(); $form.Show(); $form.Raise()
                    $form.MaxWidth = $keep
                } else {
                    $script:full  = Split-Pages -Text $txt -Size $PageChars
                    $script:pages = $script:full.Count
                    $script:page  = 0; $script:fullAt = Get-Date
                    $showTxt = $script:full[0] + "  " + 1 + "/" + $script:pages
                    $form.Txt.Text = $showTxt
                    $form.AutoFit(); $form.Show(); $form.Raise()
                }
                $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
                $script:hideAt = (Get-Date).AddSeconds($AutoHideSec)
                RL "SHOWN bytes=$($txt.Length) pages=$($script:pages)"
            }
        } else {
            $script:trigHeld = $false
        }

        # F7：直接读剪贴板当题目（你在卷面上选中复制后按它，不弹输入框）
        if ([KeyPoll]::Down(0x76)) {
            if (-not $script:f7Held) {
                $script:f7Held = $true
                try {
                    $clip = Get-Clipboard -Raw -ErrorAction Stop
                    if ($clip -and $clip.Trim().Length -ge 4) {
                        Hide-Answer
                        $cf = Join-Path $env:TEMP 'exam-clip.txt'
                        $clip.Trim() | Set-Content -LiteralPath $cf -Encoding utf8
                        RL "CLIP chars=$($clip.Trim().Length)"
                        [void](Invoke-Child -Exe 'powershell.exe' -TimeoutSec 20 -ArgList (@('-NoProfile','-ExecutionPolicy','Bypass','-File',
                            (Join-Path $kit 'solve.ps1'),'-TextFile',$cf,'-Out',$ans,'-Provider',$Provider,'-Quiet') + $(if ($Brief) { @('-Brief') } else { @() })))
                        $ctxt = (Get-Content -LiteralPath $ans -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
                        $script:full = @($ctxt); $script:pages = 1; $script:page = 0; $script:fullAt = Get-Date
                        $keep2 = $form.MaxWidth; $form.MaxWidth = $FullWidth
                        $form.Txt.Text = $ctxt
                        $form.AutoFit(); $form.Show(); $form.Raise()
                        $form.MaxWidth = $keep2
                        $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
                        $script:hideAt = (Get-Date).AddSeconds($FullSeconds)
                        RL "CLIP shown chars=$($ctxt.Length)"
                        try { Archive-Item -Q $clip.Trim() -A $ctxt } catch { }
                    }
                } catch { RL "CLIP-ERR $($_.Exception.Message)" }
            }
        } else { $script:f7Held = $false }

        # F8：手动输入题目（OCR 失败时用）
        if ([KeyPoll]::Down(0x77)) {
            if (-not $script:f8Held) { $script:f8Held = $true; Hide-Answer; Invoke-Manual }
        } else { $script:f8Held = $false }

        # F10：整段面板（复杂简答用）
        if ([KeyPoll]::Down(0x79)) {
            if (-not $script:fullHeld) {
                $script:fullHeld = $true
                if ($script:shown) { Hide-Answer } else { Show-Full }
            }
        } else { $script:fullHeld = $false }

        if ([KeyPoll]::CtrlAlt) {
            if ($script:held) { return }
            $script:held = $true
            if ([KeyPoll]::Down(0x51)) { if ($script:shown) { Hide-Answer } else { Show-Answer } }
            elseif ([KeyPoll]::Down(0x49)) { Hide-Answer; Invoke-Manual }
            elseif ([KeyPoll]::Down(0x56)) {
                $ocrTxt = Join-Path $env:TEMP 'exam-q.txt'
                if (Test-Path $ocrTxt) {
                    $o = (Get-Content -LiteralPath $ocrTxt -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
                    $script:full = Split-Pages -Text $o -Size $PageChars
                    $script:pages = $script:full.Count; $script:page = 0; $script:fullAt = Get-Date
                    $form.Txt.Text = $script:full[0] + "  OCR 1/" + $script:pages
                    $form.AutoFit(); $form.Show(); $form.Raise()
                    $script:shown = $true; $script:lastRaise = Get-Date; $script:showAt = Get-Date
                    $script:hideAt = (Get-Date).AddSeconds(6)
                }
            }
            elseif ([KeyPoll]::Down(0x5A)) { Hide-Answer }
            elseif ([KeyPoll]::Down(0x26)) { $form.Nudge(0, -20) }
            elseif ([KeyPoll]::Down(0x28)) { $form.Nudge(0, 20) }
            elseif ([KeyPoll]::Down(0x25)) { $form.Nudge(-20, 0) }
            elseif ([KeyPoll]::Down(0x27)) { $form.Nudge(20, 0) }
            elseif ([KeyPoll]::Down(0xBB)) { $script:fontSize = [Math]::Min(40, $script:fontSize + 2)
                $form.Txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', $script:fontSize, [System.Drawing.FontStyle]::Bold); $form.AutoFit() }
            elseif ([KeyPoll]::Down(0xBD)) { $script:fontSize = [Math]::Max(8, $script:fontSize - 2)
                $form.Txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', $script:fontSize, [System.Drawing.FontStyle]::Bold); $form.AutoFit() }
            elseif ([KeyPoll]::Down(0x57)) { $form.SetWidth($form.Width + 40) }
            elseif ([KeyPoll]::Down(0x53)) { $form.SetWidth($form.Width - 40) }
        } else { $script:held = $false }
    } catch {
        RL "TICK-ERR $($_.Exception.Message)"
    }
})
$poll.Start()
RL 'RUN enter'
[System.Windows.Forms.Application]::Run()
RL 'RUN exit'
