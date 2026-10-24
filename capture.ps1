param(
  [string]$Out = "$PSScriptRoot\shot.png",
  [string]$Title,                       # 可选：只截某个窗口（按标题模糊匹配）
  [double]$Scale = 1.0,                 # 放大倍数，小字建议 2
  [switch]$FullScreen,
  [string]$Crop = '',
  [switch]$Silent
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class Shot
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static IntPtr FindByTitle(string part)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new System.Text.StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            var t = sb.ToString();
            if (t.Length > 0 && t.IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Grab([IntPtr]$hWnd) {
    $r = New-Object Shot+RECT
    if (-not [Shot]::GetWindowRect($hWnd, [ref]$r)) { throw "GetWindowRect failed" }
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "bad window rect ${w}x${h}" }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()
    return $bmp
}

if ($FullScreen) {
    Add-Type -AssemblyName System.Windows.Forms
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()
    if ($Crop -ne '') {
        $a = $Crop -split ','
        $r2 = New-Object System.Drawing.Rectangle ([int]$a[0]), ([int]$a[1]), ([int]$a[2]), ([int]$a[3])
        $c = $bmp.Clone($r2, $bmp.PixelFormat)
        $bmp.Dispose(); $bmp = $c
    }
    if ($Scale -ne 1.0) {
        $nb0 = New-Object System.Drawing.Bitmap ([int]($bmp.Width * $Scale)), ([int]($bmp.Height * $Scale))
        $g0 = [System.Drawing.Graphics]::FromImage($nb0)
        $g0.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g0.DrawImage($bmp, 0, 0, $nb0.Width, $nb0.Height)
        $g0.Dispose(); $bmp.Dispose(); $bmp = $nb0
    }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $w0 = $bmp.Width; $h0 = $bmp.Height; $bmp.Dispose()
    if (-not $Silent) { "saved $Out (${w0}x${h0})" }
    exit 0
}

if ($Title) {
    $h = [Shot]::FindByTitle($Title)
    if ($h -eq [IntPtr]::Zero) { throw "window not found: $Title" }
} else {
    $h = [Shot]::GetForegroundWindow()
}

$bmp = Grab $h
if ($Scale -ne 1.0) {
    $nb = New-Object System.Drawing.Bitmap ([int]($bmp.Width * $Scale)), ([int]($bmp.Height * $Scale))
    $g2 = [System.Drawing.Graphics]::FromImage($nb)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($bmp, 0, 0, $nb.Width, $nb.Height)
    $g2.Dispose(); $bmp.Dispose(); $bmp = $nb
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$w = $bmp.Width; $h2 = $bmp.Height; $bmp.Dispose()
if (-not $Silent) { "saved $Out (${w}x${h2})" }
