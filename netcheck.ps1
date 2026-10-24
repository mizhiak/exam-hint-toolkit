param(
  [string[]]$Hosts = @('example.com','cdn.example.com','api.deepseek.com','www.baidu.com','agora.io'),
  [int]$Port = 443,
  [string]$Out = "$PSScriptRoot\netcheck.txt"
)
$ErrorActionPreference = 'Continue'
$lines = @()
function W($s) { $script:lines += $s }

W ("== {0} ==" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ""
W "-- 本机 DNS 服务器 --"
(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } |
    ForEach-Object { "  {0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ', ') }) | ForEach-Object { W $_ }
W ""
W "-- 默认路由 --"
(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    ForEach-Object { "  ifIndex={0} nexthop={1} metric={2}" -f $_.ifIndex, $_.NextHop, $_.RouteMetric }) | ForEach-Object { W $_ }
W ""
W "-- WinDivert / packet_divert 状态 --"
$svc = Get-Service -Name 'WinDivert*' -ErrorAction SilentlyContinue
if ($svc) { $svc | ForEach-Object { W ("  service {0}: {1}" -f $_.Name, $_.Status) } } else { W '  WinDivert 服务: 未安装/未运行' }
$drv = Get-ChildItem 'C:\Windows\System32\drivers\WinDivert*.sys' -ErrorAction SilentlyContinue
if ($drv) { $drv | ForEach-Object { W ("  driver file: {0} ({1} B)" -f $_.Name, $_.Length) } } else { W '  driver file: 无' }
$pd = Get-Process -Name 'packet_divert' -ErrorAction SilentlyContinue
if ($pd) { foreach ($p in $pd) { W ("  packet_divert.exe pid={0}" -f $p.Id) } } else { W '  packet_divert.exe: 未运行' }
$ec = Get-Process -Name 'Exam_Client' -ErrorAction SilentlyContinue
if ($ec) { foreach ($p in $ec) { W ("  Exam_Client.exe pid={0}" -f $p.Id) } } else { W '  Exam_Client.exe: 未运行' }
W ""
W ("-- DNS + TCP {0} --" -f $Port)
foreach ($h in $Hosts) {
    $ip = ''
    try { $ip = (Resolve-DnsName -Name $h -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress } catch { $ip = "解析失败: $($_.Exception.Message.Split([char]10)[0])" }
    $tcp = 'n/a'
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $t = $c.BeginConnect($h, $Port, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne(3000) -and $c.Connected) { $tcp = 'open' } else { $tcp = 'fail' }
        $c.Close()
    } catch { $tcp = 'fail' }
    W ("  {0,-32} dns={1,-40} tcp{2}={3}" -f $h, $ip, $Port, $tcp)
}
W ""
W "-- 出站连接速览（非本机/非环回，前 15 条）--"
(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' } |
    Sort-Object RemoteAddress -Unique | Select-Object -First 15 |
    ForEach-Object { "  {0}:{1} pid={2}" -f $_.RemoteAddress, $_.RemotePort, $_.OwningProcess }) | ForEach-Object { W $_ }

$lines | Set-Content -LiteralPath $Out -Encoding utf8
$lines
