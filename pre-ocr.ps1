param([string]$Image, [string]$OutDir = "$env:TEMP")
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile($Image)
$w = $src.Width; $h = $src.Height
function Save($bmp, [string]$name) {
  $p = Join-Path $OutDir $name
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return $p
}
# 灰度
$gray = New-Object System.Drawing.Bitmap $w,$h
$gg = [System.Drawing.Graphics]::FromImage($gray)
$ia = New-Object System.Drawing.Imaging.ImageAttributes
$cm = New-Object System.Drawing.Imaging.ColorMatrix
$cm.Matrix00 = 0.299; $cm.Matrix01 = 0.299; $cm.Matrix02 = 0.299
$cm.Matrix10 = 0.587; $cm.Matrix11 = 0.587; $cm.Matrix12 = 0.587
$cm.Matrix20 = 0.114; $cm.Matrix21 = 0.114; $cm.Matrix22 = 0.114
$cm.Matrix33 = 1.0; $cm.Matrix44 = 1.0
$ia.SetColorMatrix($cm)
$gg.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,$w,$h), 0,0,$w,$h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
$gg.Dispose()
$pGray = Save (New-Object System.Drawing.Bitmap $gray) 'pre-gray.png'
"gray = $pGray"

# 灰度 + 阈值(二分增强)
$th = New-Object System.Drawing.Bitmap $w,$h
for($y=0; $y -lt $h; $y++){
  for($x=0; $x -lt $w; $x++){
    $c = $gray.GetPixel($x,$y)
    $v = [int](($c.R * 0.299) + ($c.G * 0.587) + ($c.B * 0.114))
    $v = if ($v -lt 150) { 0 } else { 255 }
    $th.SetPixel($x,$y,[System.Drawing.Color]::FromArgb(255,$v,$v,$v))
  }
}
$pTh = Save $th 'pre-th.png'
"threshold = $pTh"
$gray.Dispose()
$src.Dispose()
