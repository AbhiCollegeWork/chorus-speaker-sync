# master-volume.ps1 : always-on-top volume panel for the speaker setup.
# Master slider = all speakers together (VAIO strip).
# Individual sliders = A1 PartyPal / A2 Stone / A3 Tab bus faders.
# Run: right-click -> Run with PowerShell

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VMV {
    const string DLL = "C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll";
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Login();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Logout();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterFloat(string param, float value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterFloat(string param, ref float value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_IsParametersDirty();
}
'@

# wait up to 60s for Voicemeeter (it may still be starting after login)
$connected = $false
for ($try = 0; $try -lt 30 -and -not $connected; $try++) {
    if ([VMV]::VBVMR_Login() -ge 0) { $connected = $true } else { Start-Sleep -Seconds 2 }
}
if (-not $connected) { [System.Windows.Forms.MessageBox]::Show("Voicemeeter is not running.", "Speakers") | Out-Null; exit 1 }
Start-Sleep -Milliseconds 600
[VMV]::VBVMR_IsParametersDirty() | Out-Null

function Get-VMFloat($param) { $v = 0.0; [VMV]::VBVMR_GetParameterFloat($param, [ref]$v) | Out-Null; return $v }

$form = New-Object System.Windows.Forms.Form
$form.Text = "Speakers"
$form.TopMost = $true
$form.FormBorderStyle = "FixedSingle"
$form.MinimizeBox = $true
$form.MaximizeBox = $false
$form.ShowInTaskbar = $true
$form.ClientSize = New-Object System.Drawing.Size(470, 305)
$form.StartPosition = "Manual"
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($wa.Right - 490), ($wa.Bottom - 340))

$rows = @(
    @{ name = "ALL";      gainParam = "Strip[5].gain"; muteParam = "Strip[5].mute"; bold = $true  },
    @{ name = "PartyPal"; gainParam = "Bus[0].gain";   muteParam = "Bus[0].mute";   bold = $false },
    @{ name = "Stone";    gainParam = "Bus[1].gain";   muteParam = "Bus[1].mute";   bold = $false },
    @{ name = "Tab";      gainParam = "Bus[2].gain";   muteParam = "Bus[2].mute";   bold = $false }
)

$y = 12
foreach ($row in $rows) {
    $gainParam = $row.gainParam
    $muteParam = $row.muteParam

    $name = New-Object System.Windows.Forms.Label
    $name.Text = $row.name
    $style = if ($row.bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $name.Font = New-Object System.Drawing.Font("Segoe UI", 11, $style)
    $name.Size = New-Object System.Drawing.Size(85, 30)
    $name.Location = New-Object System.Drawing.Point(10, ($y + 8))
    $name.TextAlign = "MiddleLeft"

    $bar = New-Object System.Windows.Forms.TrackBar
    $bar.Minimum = -40
    $bar.Maximum = 6
    $bar.TickFrequency = 10
    $bar.SmallChange = 1
    $bar.LargeChange = 3
    $bar.AutoSize = $false
    $bar.Size = New-Object System.Drawing.Size(240, 40)
    $bar.Location = New-Object System.Drawing.Point(95, $y)
    $bar.Value = [Math]::Max(-40, [Math]::Min(6, [int][Math]::Round((Get-VMFloat $gainParam))))

    $db = New-Object System.Windows.Forms.Label
    $db.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $db.Size = New-Object System.Drawing.Size(60, 30)
    $db.Location = New-Object System.Drawing.Point(340, ($y + 8))
    $db.TextAlign = "MiddleCenter"
    $db.Text = "$($bar.Value) dB"

    $mute = New-Object System.Windows.Forms.CheckBox
    $mute.Appearance = "Button"
    $mute.Text = "M"
    $mute.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $mute.Size = New-Object System.Drawing.Size(45, 34)
    $mute.Location = New-Object System.Drawing.Point(408, ($y + 3))
    $mute.TextAlign = "MiddleCenter"
    $mute.Checked = ((Get-VMFloat $muteParam) -eq 1)
    if ($mute.Checked) { $mute.BackColor = [System.Drawing.Color]::IndianRed }

    $bar.add_ValueChanged({
        [VMV]::VBVMR_SetParameterFloat($gainParam, $bar.Value) | Out-Null
        $db.Text = "$($bar.Value) dB"
    }.GetNewClosure())
    $mute.add_CheckedChanged({
        [VMV]::VBVMR_SetParameterFloat($muteParam, $(if ($mute.Checked) { 1 } else { 0 })) | Out-Null
        $mute.BackColor = if ($mute.Checked) { [System.Drawing.Color]::IndianRed } else { [System.Drawing.SystemColors]::Control }
    }.GetNewClosure())

    $form.Controls.AddRange(@($name, $bar, $db, $mute))
    $y += 58

    if ($row.bold) {
        $sep = New-Object System.Windows.Forms.Label
        $sep.BorderStyle = "Fixed3D"
        $sep.Size = New-Object System.Drawing.Size(450, 2)
        $sep.Location = New-Object System.Drawing.Point(10, ($y - 8))
        $form.Controls.Add($sep)
        $y += 6
    }
}

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "M = mute. Tab row only works while the tablet is connected as display."
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.Size = New-Object System.Drawing.Size(450, 18)
$hint.Location = New-Object System.Drawing.Point(12, ($y - 4))
$form.Controls.Add($hint)

$form.add_FormClosed({ [VMV]::VBVMR_Logout() | Out-Null })
[System.Windows.Forms.Application]::Run($form)
