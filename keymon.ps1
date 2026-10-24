param([int]$Seconds = 120)
$log = Join-Path $env:TEMP 'keymon.log'
Add-Type -ReferencedAssemblies 'System.Runtime.InteropServices' -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class KM {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static string Fg(){
    IntPtr h = GetForegroundWindow(); var t = new StringBuilder(200); GetWindowTextW(h,t,200);
    uint p; GetWindowThreadProcessId(h,out p); return "fg pid=" + p + " txt=" + t;
  }
}
'@
"START $(Get-Date -Format 'HH:mm:ss') $([KM]::Fg())" | Add-Content -LiteralPath $log -Encoding utf8
$prev = @{}
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    for ($vk = 1; $vk -lt 255; $vk++) {
        if (([KM]::GetAsyncKeyState($vk) -band 0x8000) -ne 0) {
            if (-not $prev.ContainsKey($vk)) {
                $prev[$vk] = 1
                $name = switch ($vk) {
                    0x70 {'F1'} 0x71 {'F2'} 0x72 {'F3'} 0x73 {'F4'} 0x74 {'F5'} 0x75 {'F6'} 0x76 {'F7'}
                    0x77 {'F8'} 0x78 {'F9'} 0x79 {'F10'} 0x7A {'F11'} 0x7B {'F12'} 0x20 {'SPACE'}
                    0x0D {'ENTER'} 0x11 {'CTRL'} 0x12 {'ALT'} 0x10 {'SHIFT'}
                    0xA0 {'LSHIFT'} 0xA1 {'RSHIFT'} 0xA2 {'LCTRL'} 0xA3 {'RCTRL'} 0xA4 {'LALT'} 0xA5 {'RALT'}
                    0xB0 {'MEDIA_NEXT'} 0xB1 {'MEDIA_PREV'} 0xB2 {'MEDIA_STOP'} 0xB3 {'MEDIA_PLAY'}
                    0xAD {'MUTE'} 0xAE {'VOL_DOWN'} 0xAF {'VOL_UP'} 0x2C {'PRTSC'}
                    0x5B {'LWIN'} 0x5C {'RWIN'} 0x2D {'INSERT'} 0x2E {'DELETE'} 0x24 {'HOME'} 0x23 {'END'}
                    default { '' }
                }
                $tag = if ($name) { "VK=0x{0:X2} $name" -f $vk } else { "VK=0x{0:X2} ({1})" -f $vk, [char]$vk }
                ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $tag) | Add-Content -LiteralPath $log -Encoding utf8
            }
        } else { $prev.Remove($vk) | Out-Null }
    }
    Start-Sleep -Milliseconds 30
}
"END $(Get-Date -Format 'HH:mm:ss')" | Add-Content -LiteralPath $log -Encoding utf8
