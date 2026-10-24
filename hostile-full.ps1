param([int]$Seconds = 90)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('HostileFull' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing','System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class HostileFull : Form
{
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public Label Info;

    public HostileFull()
    {
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.White;

        Info = new Label();
        Info.Text = "HOSTILE FULLSCREEN  (模拟考试客户端：全屏 + 置顶 + 每 300ms 重新置顶)";
        Info.Font = new Font("Microsoft YaHei", 14f, FontStyle.Bold);
        Info.ForeColor = Color.FromArgb(0x88, 0, 0);
        Info.SetBounds(60, 60, 1300, 40);
        Controls.Add(Info);
    }

    public void KeepTop()
    {
        if (Handle != IntPtr.Zero)
            SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002);
    }
}
'@
}

$f = New-Object HostileFull
$t = New-Object System.Windows.Forms.Timer
$t.Interval = 300
$t.Add_Tick({ $f.KeepTop() })
$t.Start()

$end = New-Object System.Windows.Forms.Timer
$end.Interval = $Seconds * 1000
$end.Add_Tick({ $end.Stop(); $f.Close() })
$end.Start()

[System.Windows.Forms.Application]::Run($f)
