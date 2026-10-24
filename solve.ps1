param(
  [string]$TextFile,                # 题目文本文件（ocr.ps1 的输出）
  [string]$Text,                    # 或者直接传字符串
  [string]$Provider = 'deepseek',   # deepseek | ollama | echo
  [string]$Out = "$PSScriptRoot\answers.txt",
  [int]$Top = 0,                    # >0 时只处理前 N 行（题太多时）
  [switch]$Quiet,
  [switch]$Brief
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

if ($TextFile) { $q = (Get-Content -LiteralPath $TextFile -Raw -Encoding utf8) }
elseif ($Text) { $q = $Text }
else { throw 'need -TextFile or -Text' }

if ($Top -gt 0) { $q = (($q -split "`n") | Select-Object -First $Top) -join "`n" }

$system = @'
你是考场答题引擎。输入是从屏幕 OCR 出来的试题，可能有个别错别字或断行错误。
要求：
1. 按题号输出，一行一题，格式「题号. 答案」，例如：12. B
2. 多选题连写选项，例如：15. ABD
3. 判断题输出「题号. 对」或「题号. 错」
4. 单选/判断题只给选项字母，不解释
5. 简答/论述/方案类：给可直接抄写的内容，分 2~5 行，每行一个要点，不写「答：」，不解释理由
6. SQL 题：只输出 SQL 语句本身，每个子句单独一行（SELECT / FROM / WHERE / ORDER BY 各占一行），不加注释、不加代码块标记
7. 总长度不超过 400 字；能短则短，但要保证能直接交卷
8. 不要复述题目，不要加任何多余文字
9. OCR 噪声导致题意不清时，按最可能的原题作答
10. 常见 OCR 噪声请自行纠正：选项「&」「8」多为 B，「氵去」=法，「扌丸」=执，「讠兑」=说；数字题号与选项字母可能被拆开，按语义还原
11. 单选务必逐个选项核对，只选一个最符合题意的；不要因为 OCR 残缺就退回「看起来像常见答案」的选项
12. 输入里没有可识别试题时，只输出「无题目」三个字，绝不编造
'@

$user = "OCR 文本如下：`n`n$q"

function Get-Key {
    if ($env:DEEPSEEK_API_KEY) { return $env:DEEPSEEK_API_KEY }
    $cred = Join-Path $env:APPDATA 'dsh-desktop\harness\.credentials.yaml'
    if (Test-Path -LiteralPath $cred) {
        foreach ($line in Get-Content -LiteralPath $cred -Encoding utf8) {
            if ($line -match '^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)\s*$') { return $Matches[1] }
        }
    }
    return $null
}

$raw = $null
switch ($Provider) {
    'deepseek' {
        $key = Get-Key
        if (-not $key) { throw 'DEEPSEEK_API_KEY 未找到' }
        $body = @{
            model = 'deepseek-chat'
            temperature = 0
            max_tokens = 400
            messages = @(
                @{ role = 'system'; content = $system },
                @{ role = 'user';   content = $user }
            )
        } | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $r = Invoke-WebRequest -Uri 'https://api.deepseek.com/chat/completions' -Method Post `
            -Headers @{ Authorization = "Bearer $key" } `
            -ContentType 'application/json; charset=utf-8' -Body $bytes -UseBasicParsing -TimeoutSec 15
        # PS5.1 常把无 charset 的响应按 Latin-1 解，这里强制按 UTF-8 重新解码
        $ms = New-Object System.IO.MemoryStream
        $r.RawContentStream.Position = 0
        $r.RawContentStream.CopyTo($ms)
        $json = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $raw = ($json | ConvertFrom-Json).choices[0].message.content
    }
    'ollama' {
        $body = @{
            model = 'qwen2.5:7b-instruct'
            stream = $false
            options = @{ temperature = 0 }
            messages = @(
                @{ role = 'system'; content = $system },
                @{ role = 'user';   content = $user }
            )
        } | ConvertTo-Json -Depth 6 -Compress
        $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/chat' -Method Post `
            -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
        $raw = $resp.message.content
    }
    'echo' { $raw = "0. (echo provider)`n$system`n---`n$user" }
    default { throw "unknown provider: $Provider" }
}

$answers = ($raw -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$answers | Set-Content -LiteralPath $Out -Encoding utf8

if (-not $Quiet) { $answers -join "`n" }
