param(
  [int]$MaxSeconds = 3600,
  [int]$IntervalMs = 1000,
  [string]$Log = "$PSScriptRoot\probe2.log"
)
$ErrorActionPreference = 'Continue'

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class D {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EP cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

  public static List<string> Top(uint pidFilter, bool anyPid) {
    var o = new List<string>();
    EnumWindows((h,l)=>{
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!anyPid && pid != pidFilter) return true;
      if (!IsWindowVisible(h)) return true;
      var t=new StringBuilder(512); GetWindowText(h,t,t.Capacity);
      var c=new StringBuilder(256); GetClassName(h,c,c.Capacity);
      RECT r; GetWindowRect(h,out r);
      int ex=GetWindowLong(h,-20); uint a=99; GetWindowDisplayAffinity(h,out a);
      o.Add(string.Format("hwnd=0x{0:X} pid={1} cls={2} top={3} aff={4} rect={5},{6},{7},{8} title={9}",
        h.ToInt64(), pid, c, (ex&0x8)!=0, a, r.L,r.T,r.R,r.B,
        t.ToString().Replace("\t"," ")));
      return true; }, IntPtr.Zero);
    return o;
  }

  public static List<string> Children(IntPtr parent) {
    var o = new List<string>();
    EnumChildWindows(parent, (h,l)=>{
      var c=new StringBuilder(256); GetClassName(h,c,c.Capacity);
      var t=new StringBuilder(256); GetWindowText(h,t,t.Capacity);
      RECT r; GetWindowRect(h,out r);
      uint a=99; GetWindowDisplayAffinity(h,out a);
      int ex=GetWindowLong(h,-20);
      o.Add(string.Format("child=0x{0:X} cls={1} vis={2} top={3} aff={4} rect={5},{6},{7},{8} title={9}",
        h.ToInt64(), c, IsWindowVisible(h), (ex&0x8)!=0, a, r.L,r.T,r.R,r.B, t.ToString()));
      return true; }, IntPtr.Zero);
    return o;
  }
}
'@

function Now { Get-Date -Format 'HH:mm:ss.fff' }
function Emit([string]$tag, [string]$msg) {
    Add-Content -LiteralPath $Log -Value ("{0}`t{1}`t{2}" -f (Now), $tag, $msg) -Encoding utf8
}

Emit 'START' "deep probe max=${MaxSeconds}s interval=${IntervalMs}ms"
$names = @('Exam_Client','packet_divert','screen_locker','display_util','blue_util_x64','image_check','elevate')
$seen = @{}
$lastTop = ''
$lastNet = ''
$lastDrv = ''
$lastTcp = ''
$deadline = (Get-Date).AddSeconds($MaxSeconds)
$tick = 0
$cpuPrev = @{}

while ((Get-Date) -lt $deadline) {
    $tick++

    foreach ($n in $names) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) {
            $ids = ($p | ForEach-Object { $_.Id }) -join ','
            if ($seen[$n] -ne $ids) {
                $seen[$n] = $ids
                $info = Get-CimInstance Win32_Process -Filter "Name='$n.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
                Emit 'PROC+' ("{0} pid={1} ppid={2} cmd={3}" -f $n, $ids, $info.ParentProcessId, $info.CommandLine)
            }
        } elseif ($seen[$n]) {
            Emit 'PROC-' "$n gone"
            $seen[$n] = $null
        }
    }

    # Exam_Client CPU 增量（判断是否在上传/解码视频）
    $ec = Get-Process -Name Exam_Client -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ec) {
        $c = $ec.TotalProcessorTime.TotalSeconds
        if ($cpuPrev.ContainsKey($ec.Id)) {
            $d = [math]::Round(($c - $cpuPrev[$ec.Id]) / ([double]$IntervalMs / 1000) * 100, 0)
            if ($d -gt 60 -and ($tick % 10 -eq 0)) { Emit 'CPU' "Exam_Client cpu=${d}% ws=$([math]::Round($ec.WorkingSet64/1MB))MB" }
        }
        $cpuPrev[$ec.Id] = $c
    }

    if ($tick % 3 -eq 0) {
        $drv = ''
        try { $d2 = Get-CimInstance Win32_SystemDriver -Filter "Name like 'WinDivert%'" -ErrorAction SilentlyContinue
              if ($d2) { $drv = ($d2 | ForEach-Object { "$($_.Name):$($_.State)" }) -join ',' } } catch {}
        $sys1 = Test-Path 'C:\Windows\System32\drivers\WinDivert.sys'
        $sys2 = Test-Path 'C:\Windows\System32\drivers\WinDivert64.sys'
        $sig = "$drv|$sys1|$sys2"
        if ($sig -ne $lastDrv) { $lastDrv = $sig; Emit 'DRV' "drivers=$drv sys=$sys1/$sys2" }
    }

    if ($tick % 5 -eq 1) {
        $r = @()
        foreach ($h in @('api.deepseek.com','www.baidu.com')) {
            $ok = 'fail'
            try { $c2 = New-Object System.Net.Sockets.TcpClient
                  $ar = $c2.BeginConnect($h, 443, $null, $null)
                  if ($ar.AsyncWaitHandle.WaitOne(2000) -and $c2.Connected) { $ok = 'open' }
                  $c2.Close() } catch {}
            $r += "$h=$ok"
        }
        $s = $r -join ' '
        if ($s -ne $lastNet) { $lastNet = $s; Emit 'NET' $s }
    }

    # 顶层窗口变化（含 affinity / topmost）
    $pid0 = 0
    if ($ec) { $pid0 = $ec.Id }
    $tops = [D]::Top([uint32]$pid0, $false)
    $sig = ($tops -join '||')
    if ($sig -ne $lastTop) {
        $lastTop = $sig
        foreach ($w in $tops) { Emit 'WIN' $w }
        if ($pid0 -ne 0) {
            $hwnd = 0
            foreach ($w in $tops) { if ($w -match 'hwnd=0x([0-9A-F]+)') { $hwnd = [Convert]::ToInt64($Matches[1],16); break } }
            if ($hwnd -ne 0) {
                foreach ($cw in [D]::Children([IntPtr]$hwnd)) { Emit 'CHILD' $cw }
            }
        }
    }

    # 全屏置顶窗口（锁屏器）
    if ($tick % 5 -eq 3) {
        foreach ($w in [D]::Top([uint32]0, $true)) {
            if ($w -match 'rect=(\-?\d+),(\-?\d+),(\-?\d+),(\-?\d+)') {
                $rw = [int]$Matches[3] - [int]$Matches[1]
                $rh = [int]$Matches[4] - [int]$Matches[2]
                if ($rw -ge 1500 -and $rh -ge 900 -and $w -match 'top=True') { Emit 'FULLTOP' $w }
            }
        }
    }

    # 考试进程的出站连接
    if ($tick % 10 -eq 7) {
        $ids = @()
        foreach ($n in @('Exam_Client','packet_divert','screen_locker')) {
            $pp = Get-Process -Name $n -ErrorAction SilentlyContinue
            if ($pp) { $ids += $pp.Id }
        }
        if ($ids.Count -gt 0) {
            $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess }
            $s = ($conns | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" } | Sort-Object -Unique) -join ','
            if ($s -ne $lastTcp) { $lastTcp = $s; Emit 'TCP' "pids=$($ids -join ',') remote=$s" }
        }
    }

    if ($tick % 60 -eq 0) { Emit 'BEAT' "tick=$tick procs=$($seen.Keys -join ',')" }

    Start-Sleep -Milliseconds $IntervalMs
}
Emit 'END' "ticks=$tick"
