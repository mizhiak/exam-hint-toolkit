param(
  [switch]$NoNet,
  [string]$Img = "$env:TEMP\selftest.png"
)
$ErrorActionPreference = 'Continue'
$kit = $PSScriptRoot
$fail = 0
function Line($ok, $name, $detail) {
    $mark = if ($ok) { 'PASS' } else { 'FAIL'; $script:fail++ }
    "{0}  {1,-26} {2}" -f $mark, $name, $detail
}

# 1) 系统版本（WDA_EXCLUDEFROMCAPTURE 需要 19041+）
$build = [Environment]::OSVersion.Version.Build
Line ($build -ge 19041) 'OS build' "build=$build (>=19041 才能防截屏)"

# 2) OCR 引擎 + 中文
try {
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $langs = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }
    Line ($langs -contains 'zh-Hans-CN') 'OCR zh-Hans-CN' ($langs -join ',')
} catch { Line $false 'OCR engine' $_.Exception.Message }

# 3) 截图
try {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 200, 100
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size 200, 100))
    $g.Dispose(); $bmp.Save($Img, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Line (Test-Path $Img) 'capture' "$Img"
} catch { Line $false 'capture' $_.Exception.Message }

# 4) API key
$key = $env:DEEPSEEK_API_KEY
if (-not $key) {
    $cred = Join-Path $env:APPDATA 'dsh-desktop\harness\.credentials.yaml'
    if (Test-Path $cred) {
        foreach ($l in Get-Content $cred -Encoding utf8) { if ($l -match '^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)') { $key = $Matches[1] } }
    }
}
Line ([bool]$key) 'api key' $(if ($key) { 'found (sk-...' + $key.Substring([Math]::Max(0,$key.Length-6)) + ')' } else { 'missing' })

# 5) answers.txt
$ans = Join-Path $kit 'answers.txt'
Line (Test-Path $ans) 'answers.txt' $ans

# 6) 脚本齐备
foreach ($f in 'capture.ps1','ocr.ps1','solve.ps1','exam-live.ps1','start-live.vbs') {
    Line (Test-Path (Join-Path $kit $f)) "file $f" ''
}

# 7) 网络 / 答题往返
if (-not $NoNet) {
    $q = "$env:TEMP\selftest-q.txt"
    '1. 判断题：1+1=2。A 正确 B 错误' | Set-Content -LiteralPath $q -Encoding utf8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'solve.ps1') -TextFile $q -Provider deepseek -Out "$env:TEMP\selftest-a.txt" -Quiet 2>&1
    $a = Get-Content "$env:TEMP\selftest-a.txt" -Encoding utf8 -ErrorAction SilentlyContinue
    $ok = ($a -and ($a -join '') -notmatch '出错|失败')
    Line $ok 'deepseek round-trip' ("{0:N1}s -> {1}" -f $sw.Elapsed.TotalSeconds, ($a -join ' / '))
}

# 8) 相位
$snap = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'exam-live.ps1') -SnapInfo 2>&1
"INFO  抓拍相位: " + (($snap | Where-Object { $_ -match 'period|last|next|距离' }) -join ' | ')

""
if ($fail -eq 0) { "SELFTEST OK（可以进考场了）" } else { "SELFTEST 有 $fail 项失败，先修再进考场" }
