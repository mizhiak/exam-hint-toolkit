param([switch]$Check)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ("Overlay" -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing','System.Runtime.InteropServices' -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class Overlay : Form
{
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    const int WS_EX_TRANSPARENT = 0x20;
    const int WS_EX_LAYERED = 0x80000;
    const int WS_EX_TOOLWINDOW = 0x80;
    const int WS_EX_NOACTIVATE = 0x8000000;
    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public Label Txt;

    public Overlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        Opacity = 0.90;
        BackColor = Color.Black;
        Width = 720; Height = 260;
        var wa = Screen.PrimaryScreen.WorkingArea;
        Left = Math.Max(10, wa.Right - Width - 40);
        Top = 60;

        Txt = new Label();
        Txt.Dock = DockStyle.Fill;
        Txt.ForeColor = Color.White;
        Txt.BackColor = Color.Black;
        Txt.TextAlign = ContentAlignment.MiddleCenter;
        Txt.Font = new Font("Microsoft YaHei", 26f, FontStyle.Bold);
        Txt.Padding = new Padding(12);
        Controls.Add(Txt);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    public void Raise()
    {
        if (Handle != IntPtr.Zero) SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, 0x0001 | 0x0002);
    }

    public void SetWidth(int w)
    {
        Width = Math.Max(240, w);
        var wa = Screen.PrimaryScreen.WorkingArea;
        if (Left + Width > wa.Right) Left = Math.Max(0, wa.Right - Width - 10);
    }
}
'@
}

if (-not ("KeyPoll" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KeyPoll
{
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    public static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
    public static bool CtrlAlt { get { return Down(0x11) && Down(0x12); } }
}
'@
}

if ($Check) { "compile ok"; exit 0 }

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ansFile = Join-Path $root 'answers.txt'
if (-not (Test-Path -LiteralPath $ansFile)) {
    @('1. A','2. B','3. C','4. D','5. 寰呭畾') | Set-Content -LiteralPath $ansFile -Encoding utf8
}

$form = New-Object Overlay
$script:shown    = $false
$script:held     = $false
$script:fontSize = 26.0

function Get-Answers {
    try {
        $lines = @(Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'answers.txt') -Encoding utf8 -ErrorAction Stop |
                   Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { return '(answers.txt 涓虹┖)' }
        return ($lines -join "`n")
    } catch { return "(璇诲彇澶辫触: $($_.Exception.Message))" }
}

$form.Txt.Text = (Get-Content -LiteralPath $ansFile -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"

$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 50
$poll.Add_Tick({
    if (-not [KeyPoll]::CtrlAlt) { $script:held = $false; return }
    if ($script:held) { return }
    $script:held = $true

    if ([KeyPoll]::Down(0x51)) {                                   # Q 鍒囨崲
        if ($script:shown) { $form.Hide(); $script:shown = $false }
        else {
            $form.Txt.Text = (Get-Content -LiteralPath $ansFile -Encoding utf8 | Where-Object { $_.Trim() -ne '' }) -join "`n"
            $form.Show(); $form.Raise(); $script:shown = $true
        }
    }
    elseif ([KeyPoll]::Down(0x5A)) { $form.Hide(); $script:shown = $false }   # Z 绱ф€ラ殣钘?    elseif ([KeyPoll]::Down(0x26)) { $form.Top  = [Math]::Max(0, $form.Top - 20); $form.Raise() }
    elseif ([KeyPoll]::Down(0x28)) { $form.Top  = $form.Top + 20;                 $form.Raise() }
    elseif ([KeyPoll]::Down(0x25)) { $form.Left = [Math]::Max(0, $form.Left - 20) }
    elseif ([KeyPoll]::Down(0x27)) { $form.Left = $form.Left + 20 }
    elseif ([KeyPoll]::Down(0xBB)) {
        $script:fontSize = [Math]::Min(64, $script:fontSize + 2)
        $form.Txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', $script:fontSize, [System.Drawing.FontStyle]::Bold)
    }
    elseif ([KeyPoll]::Down(0xBD)) {
        $script:fontSize = [Math]::Max(10, $script:fontSize - 2)
        $form.Txt.Font = New-Object System.Drawing.Font('Microsoft YaHei', $script:fontSize, [System.Drawing.FontStyle]::Bold)
    }
    elseif ([KeyPoll]::Down(0x57)) { $form.SetWidth($form.Width + 80) }
    elseif ([KeyPoll]::Down(0x53)) { $form.SetWidth($form.Width - 80) }
})
$poll.Start()
[System.Windows.Forms.Application]::Run()

