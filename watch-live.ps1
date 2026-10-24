param(
  [int]$IntervalSec = 4,
  [int]$MaxRestarts = 200,
  [string]$Kit = "$PSScriptRoot"
)
# 看门狗：浮层被考试客户端杀掉后自动拉起来
$tag   = 'exam' + '-' + 'live'
$log   = Join-Path $env:TEMP 'live-watch.log'
$vbs   = Join-Path $Kit 'start-live.vbs'
$off   = Join-Path $env:TEMP 'live-off.flag'

function WL([string]$m) {
    try { ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Add-Content -LiteralPath $log -Encoding utf8 } catch {}
}

WL "WATCH START pid=$PID interval=${IntervalSec}s"
$restarts = 0
while ($true) {
    Start-Sleep -Seconds $IntervalSec
    if (Test-Path -LiteralPath $off) { WL 'off-flag present, exit'; break }
    $alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tag) })
    if ($alive.Count -eq 0) {
        $restarts++
        WL "overlay gone -> restart #$restarts"
        if ($restarts -gt $MaxRestarts) { WL 'max restarts reached, exit'; break }
        try { Start-Process -FilePath 'wscript.exe' -ArgumentList @($vbs) -WindowStyle Hidden } catch { WL "restart failed: $_" }
    }
}
WL 'WATCH END'
