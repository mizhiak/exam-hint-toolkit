param(
  [Parameter(Mandatory=$true)][string]$Image,
  [string]$Lang = 'zh-Hans-CN',
  [string]$OutText,
  [int]$UpScale = 2
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($op, $type) {
    $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    return $t.Result
}

# 小字放大后再 OCR，中文识别率提升明显
$src = $Image
if ($UpScale -gt 1) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Image]::FromFile($Image)
    $nb = New-Object System.Drawing.Bitmap ([int]($bmp.Width * $UpScale)), ([int]($bmp.Height * $UpScale))
    $g = [System.Drawing.Graphics]::FromImage($nb)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($bmp, 0, 0, $nb.Width, $nb.Height)
    $g.Dispose(); $bmp.Dispose()
    $src = [System.IO.Path]::ChangeExtension($Image, ".up.png")
    $nb.Save($src, [System.Drawing.Imaging.ImageFormat]::Png)
    $nb.Dispose()
}

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

$file    = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path $src).Path)) ([Windows.Storage.StorageFile])
$stream  = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap  = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

$language = New-Object Windows.Globalization.Language($Lang)
$engine   = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
if ($null -eq $engine) { throw "OCR engine unavailable for $Lang" }

$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

$lines = foreach ($line in $result.Lines) { $line.Text }
$text = ($lines -join "`n")
# Windows OCR 会在汉字之间插空格，这里还原成连续中文
$text = $text -replace '(?<=[\u4e00-\u9fff])[ \t]+(?=[\u4e00-\u9fff])', ''
$text = $text -replace '(?<=[\u4e00-\u9fff])[ \t]+(?=[（）()，。、；：？！“”‘’《》])', ''
$text = $text -replace '(?<=[（）()，。、；：？！“”‘’《》])[ \t]+(?=[\u4e00-\u9fff])', ''
$text = $text -replace '(?<=\d)[ \t]+(?=\d)', ''
$text = $text -replace '[ \t]{2,}', ' '
# 拆字噪声还原（Windows OCR 对小字号汉字的常见误识别）
$fixes = [ordered]@{
  '氵去' = '法'; '扌丸' = '执'; '讠兑' = '说'; '讠正' = '证'; '纟合' = '给'
  '亻十' = '什'; '亻也' = '他'; '女也' = '她'; '木目' = '相'; '土也' = '地'
  '扌是' = '提'; '扌巴' = '把'; '扌居' = '据'; '纟冬' = '终'; '讠果' = '课'
}
foreach ($k in $fixes.Keys) { $text = $text.Replace($k, $fixes[$k]) }
# 选项字母被识别成符号：整行以 & / 8 / 6 开头且后面跟上选项内容 -> 还原成 B
$text = [regex]::Replace($text, '(?m)^[&8]\s*(?=[\u4e00-\u9fff A-Za-z])', 'B. ')
$text = [regex]::Replace($text, '(?m)^[6]\s*(?=[\u4e00-\u9fff A-Za-z])', 'G. ')

if ($OutText) { $text | Set-Content -LiteralPath $OutText -Encoding utf8 }
$text
