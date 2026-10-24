# snapshot-watch.ps1 — 从客户端 CEF 日志里还原"屏幕抓拍"的真实节奏
# 用法: powershell -ExecutionPolicy Bypass -File snapshot-watch.ps1 [-Root "D:\kaoshi\Exam_Client\[6.1.511.1150]"] [-Tail 40]
param(
  [string]$Root = 'D:\kaoshi\Exam_Client\[6.1.511.1150]',
  [int]$Tail = 40,
  [switch]$Live
)

function Parse-Logs([string]$logDir) {
    $out = @()
    foreach ($f in Get-ChildItem -LiteralPath $logDir -Filter '*_Cef.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime) {
        foreach ($line in Get-Content -LiteralPath $f.FullName -Encoding utf8 -ErrorAction SilentlyContinue) {
            if ($line -match 'offScreenCapture success') {
                if ($line -match '^\[(\d{4})/(\d{6})\.(\d{3})') {
                    $d = $Matches[1]; $t = $Matches[2]; $ms = $Matches[3]
                    $dt = [datetime]::ParseExact("2026$d$t", 'yyyyMMddHHmmss', $null).AddMilliseconds([int]$ms)
                    $out += $dt
                }
            }
        }
    }
    return $out
}

$logDir = Join-Path $Root '.log'
$stamps = Parse-Logs $logDir | Sort-Object -Unique

if ($stamps.Count -eq 0) {
    "没找到抓拍记录（日志里没有 offScreenCapture success）。等考试开始后再看。"
    return
}

"抓拍次数: $($stamps.Count)"
"首帧: $($stamps[0])   末帧: $($stamps[-1])"

$gaps = @()
for ($i = 1; $i -lt $stamps.Count; $i++) { $gaps += ($stamps[$i] - $stamps[$i-1]).TotalSeconds }

if ($gaps.Count -gt 0) {
    $stat = $gaps | Measure-Object -Average -Minimum -Maximum
    "间隔: 平均 {0:N1}s  最小 {1:N1}s  最大 {2:N1}s" -f $stat.Average, $stat.Minimum, $stat.Maximum
    ""
    "最近 $Tail 次抓拍时刻:"
    $stamps | Select-Object -Last $Tail | ForEach-Object { "  $($_.ToString('HH:mm:ss.fff'))" }
    ""
    "按平均间隔推算下一次抓拍: $(($stamps[-1].AddSeconds($stat.Average)).ToString('HH:mm:ss'))"
}

if ($Live) {
    ""
    "实时跟踪（Ctrl+C 结束）:"
    $seen = $stamps.Count
    while ($true) {
        Start-Sleep -Seconds 5
        $now = Parse-Logs $logDir | Sort-Object -Unique
        if ($now.Count -gt $seen) {
            for ($i = $seen; $i -lt $now.Count; $i++) { "  + $($now[$i].ToString('HH:mm:ss.fff'))" }
            $seen = $now.Count
        }
    }
}
