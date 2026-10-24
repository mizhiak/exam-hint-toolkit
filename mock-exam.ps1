param(
  [int]$Seconds = 45,
  [string]$Text = '',
  [string]$Image = '',
  [string]$TextFile = ''
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('MockExam' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;

public class MockExam : Form
{
    public MockExam(string body, string img)
    {
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        TopMost = true;
        ShowInTaskbar = true;
        BackColor = Color.White;

        var panel = new Panel();
        panel.Dock = DockStyle.Fill;
        panel.BackColor = Color.White;
        panel.AutoScroll = true;
        Controls.Add(panel);

        int y = 60;
        var head = new Label();
        head.Text = "在线笔试模拟页面    第 12 题 / 共 60 题    剩余 41:22";
        head.Font = new Font("Microsoft YaHei", 11f, FontStyle.Regular);
        head.ForeColor = Color.FromArgb(0x66, 0x66, 0x66);
        head.SetBounds(60, 20, 1300, 30);
        panel.Controls.Add(head);

        var q = new Label();
        q.Text = body;
        q.Font = new Font("Microsoft YaHei", 13f, FontStyle.Regular);
        q.ForeColor = Color.FromArgb(0x22, 0x22, 0x22);
        q.SetBounds(60, y, 1200, 260);
        panel.Controls.Add(q);
        y += 270;

        if (!string.IsNullOrEmpty(img) && System.IO.File.Exists(img))
        {
            var pic = new PictureBox();
            pic.Image = Image.FromFile(img);
            pic.SizeMode = PictureBoxSizeMode.Zoom;
            pic.SetBounds(60, y, 700, 360);
            panel.Controls.Add(pic);
        }
    }
}
'@
}

if ($TextFile -ne '' -and (Test-Path -LiteralPath $TextFile)) { $Text = (Get-Content -LiteralPath $TextFile -Raw -Encoding utf8) }`r`n`r`nif ([string]::IsNullOrWhiteSpace($Text)) {
    $Text = @"
某工程合同价款 1200 万元，工期 180 天。施工期间因发包人原因导致停工 30 天，
承包人按合同程序提出索赔。根据《建设工程施工合同（示范文本）》，
承包人应在索赔事件发生后（  ）天内向监理人递交索赔意向通知书。

A. 7 天
B. 14 天
C. 28 天
D. 56 天
"@
}

$f = New-Object MockExam($Text, $Image)
$t = New-Object System.Windows.Forms.Timer
$t.Interval = $Seconds * 1000
$t.Add_Tick({ $t.Stop(); $f.Close() })
$t.Start()
[System.Windows.Forms.Application]::Run($f)
