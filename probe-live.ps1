param(
  [int]$MaxSeconds = 900,
  [int]$IntervalMs = 2000,
  [string]$Log = "$PSScriptRoot\probe.log"
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies 'System.Drawing','System.Windows.Forms','System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class W
{
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint aff);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80,
              WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;

    public static List<string> Windows()
    {
        var list = new List<string>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(512); GetWindowText(h, t, t.Capacity);
            var c = new StringBuilder(256); GetClassName(h, c, c.Capacity);
            var title = t.ToString();
            if (title.Length == 0) return true;
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            uint aff = 99; GetWindowDisplayAffinity(h, out aff);
            RECT r; GetWindowRect(h, out r);
            list.Add(string.Format("hwnd=0x{0:X} class={1} topmost={2} layered={3} toolwin={4} noact={5} trans={6} affinity={7} rect={8},{9},{10},{11} title={12}",
                h.ToInt64(), c, (ex & WS_EX_TOPMOST) != 0, (ex & WS_EX_LAYERED) != 0,
                (ex & WS_EX_TOOLWINDOW) != 0, (ex & WS_EX_NOACTIVATE) != 0, (ex & WS_EX_TRANSPARENT) != 0,
                aff, r.L, r.T, r.R, r.B, title));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // 截取窗口区域并统计"非黑像素比例"，用来判断是否被 SetWindowDisplayAffinity 保护
    public static string CaptureStats(IntPtr h)
    {
        RECT r; if (!GetWindowRect(h, out r)) return "rect-fail";
        int w = r.R - r.L, hh = r.B - r.T;
        if (w <= 0 || hh <= 0) return "bad-rect";
        using (var bmp = new Bitmap(w, hh))
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(r.L, r.T, 0, 0, new Size(w, hh), CopyPixelOperation.SourceCopy);
            int sampled = 0, nonblack = 0, distinct = 0;
            var set = new HashSet<int>();
            for (int y = 0; y < hh; y += Math.Max(1, hh / 40))
              for (int x = 0; x < w; x += Math.Max(1, w / 40))
              {
                  Color c = bmp.GetPixel(x, y); sampled++;
                  if (c.R + c.G + c.B > 24) nonblack++;
                  set.Add((c.R << 16) | (c.G << 8) | c.B);
              }
            distinct = set.Count;
            return string.Format("size={0}x{1} sampled={2} nonblack={3:F1}% distinctColors={4}",
                w, hh, sampled, (100.0 * nonblack / Math.Max(1, sampled)), distinct);
        }
    }
}
'@

function Now { Get-Date -Format 'HH:mm:ss.fff' }
function Emit([string]$tag, [string]$msg) {
    $line = "{0}`t{1}`t{2}" -f (Now), $tag, $msg
    Add-Content -LiteralPath $Log -Value $line -Encoding utf8
}

Emit 'START' "max=${MaxSeconds}s interval=${IntervalMs}ms"

$procsOfInterest = @('Exam_Client','packet_divert','screen_locker','display_util','blue_util_x64','image_check')
$seenProc = @{}
$lastWinSig = ''
$lastDrv = ''
$lastNet = ''
$deadline = (Get-Date).AddSeconds($MaxSeconds)
$tick = 0

while ((Get-Date) -lt $deadline) {
    $tick++

    # --- 进程 ---
    foreach ($n in $procsOfInterest) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) {
            $ids = ($p | ForEach-Object { $_.Id }) -join ','
            if ($seenProc[$n] -ne $ids) {
                $seenProc[$n] = $ids
                $cmd = ''
                try { $cmd = (Get-CimInstance Win32_Process -Filter "Name='$n.exe'" | Select-Object -First 1).CommandLine } catch {}
                $par = ''
                try { $par = (Get-CimInstance Win32_Process -Filter "Name='$n.exe'" | Select-Object -First 1).ParentProcessId } catch {}
                Emit 'PROC+' "$n pid=$ids ppid=$par cmd=$cmd"
            }
        } elseif ($seenProc[$n]) {
            Emit 'PROC-' "$n (gone)"
            $seenProc[$n] = $null
        }
    }

    # --- WinDivert 驱动 ---
    $drv = ''
    try {
        $d = Get-CimInstance Win32_SystemDriver -Filter "Name like 'WinDivert%'" -ErrorAction SilentlyContinue
        if ($d) { $drv = ($d | ForEach-Object { "$($_.Name):$($_.State)" }) -join ',' }
    } catch {}
    $drvFile = (Test-Path 'C:\Windows\System32\drivers\WinDivert.sys') -or (Test-Path 'C:\Windows\System32\drivers\WinDivert64.sys')
    $sig = "$drv|file=$drvFile"
    if ($sig -ne $lastDrv) {
        $lastDrv = $sig
        Emit 'DRV' ("drivers=" + $(if ($drv) { $drv } else { 'none' }) + " sysFile=$drvFile")
    }

    # --- 网络连通性（每 5 个 tick 一次）---
    if ($tick % 5 -eq 1) {
        $r = @()
        foreach ($h in @('api.deepseek.com','www.baidu.com','exam.weicewang.com')) {
            $ok = 'fail'
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $ar = $c.BeginConnect($h, 443, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2500) -and $c.Connected) { $ok = 'open' }
                $c.Close()
            } catch {}
            $r += "$h=$ok"
        }
        $s = $r -join ' '
        if ($s -ne $lastNet) { $lastNet = $s; Emit 'NET' $s }
    }

    # --- 窗口 ---
    $wins = [W]::Windows()
    $sig = ($wins -join '||')
    if ($sig -ne $lastWinSig) {
        $lastWinSig = $sig
        foreach ($w in $wins) {
            if ($w -match 'title=(.+)$') {
                $t = $Matches[1]
                if ($t -match '考试|Exam|答题|ATS|DSH|DeepSeek') { Emit 'WIN' $w }
            }
        }
    }

    # --- 抓屏保护检测：找到考试窗口后每 15 tick 测一次 ---
    if ($tick % 15 -eq 3) {
        $target = $null
        foreach ($w in [W]::Windows()) {
            if ($w -match 'title=(.*考试.*|.*Exam.*)$') { $target = $w; break }
        }
        if ($target -and $target -match 'hwnd=0x([0-9A-F]+)') {
            $hv = [IntPtr][Convert]::ToInt64($Matches[1], 16)
            $stats = [W]::CaptureStats($hv)
            Emit 'CAPTURE' "$stats | $($target.Substring(0, [Math]::Min(140, $target.Length)))"
        }
    }

    Start-Sleep -Milliseconds $IntervalMs
}

Emit 'END' "ticks=$tick"
