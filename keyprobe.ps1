param([int]$Seconds = 30)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -ReferencedAssemblies 'System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KP {
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    public static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
}
'@

$names = @{
  0x13='Pause/Break'; 0x14='CapsLock'; 0x2C='PrintScreen'; 0x91='ScrollLock'; 0x90='NumLock'
  0x09='Tab'; 0x1B='Esc'; 0x20='Space'; 0x0D='Enter'; 0x10='Shift'; 0x11='Ctrl'; 0x12='Alt'; 0x5B='Win'
  0x21='PageUp'; 0x22='PageDown'; 0x23='End'; 0x24='Home'; 0x2D='Insert'; 0x2E='Delete'
  0x25='Left'; 0x26='Up'; 0x27='Right'; 0x28='Down'
  0x60='Num0'; 0x61='Num1'; 0x62='Num2'; 0x63='Num3'; 0x64='Num4'; 0x65='Num5'; 0x66='Num6'
  0x67='Num7'; 0x68='Num8'; 0x69='Num9'; 0x6A='Num*'; 0x6B='Num+'; 0x6D='Num-'; 0x6E='Num.'; 0x6F='Num/'
}
$fkeys = @{ 0x70='F1';0x71='F2';0x72='F3';0x73='F4';0x74='F5';0x75='F6';0x76='F7';0x77='F8';0x78='F9';0x79='F10';0x7A='F11';0x7B='F12' }
foreach ($k in $fkeys.Keys) { $names[$k] = $fkeys[$k] }
foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') { $names[[int][char]$c] = "$c" }
foreach ($d in [char[]]'0123456789') { $names[[int][char]$d] = "$d" }

"按任意键看键名与 VK 码；$Seconds 秒后自动结束。"
"（想找可用的单键热键，就挨个按：ScrollLock / Pause / F9 / 小键盘 * ）"
""
$deadline = (Get-Date).AddSeconds($Seconds)
$prev = @{}
while ((Get-Date) -lt $deadline) {
    for ($vk = 3; $vk -lt 255; $vk++) {   # 跳过 1/2（鼠标左右键），免得点鼠标也算
        $d = [KP]::Down($vk)
        if ($d -and -not $prev.ContainsKey($vk)) {
            $prev[$vk] = $true
            $nm = if ($names.ContainsKey($vk)) { $names[$vk] } else { "(未知)" }
            "  按下: {0,-12} VK=0x{1:X2} ({1})" -f $nm, $vk
        } elseif (-not $d -and $prev.ContainsKey($vk)) {
            $prev.Remove($vk)
        }
    }
    Start-Sleep -Milliseconds 20
}
"结束。"
