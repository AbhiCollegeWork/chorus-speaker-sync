# fix-speakers.ps1 : one-click repair if a speaker is silent.
# Reassigns all outputs, restores routing, restarts the audio engine.
# Make sure both boAt speakers are powered on first.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class VMF {
    const string DLL = "C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll";
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Login();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Logout();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterFloat(string param, float value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterFloat(string param, ref float value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterStringA(string param, string value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterStringA(string param, StringBuilder value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_IsParametersDirty();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Output_GetDeviceNumber();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Output_GetDeviceDescA(int index, ref int type, StringBuilder name, StringBuilder hardwareId);
}
'@

if ([VMF]::VBVMR_Login() -lt 0) {
    Start-Process "C:\Program Files (x86)\VB\Voicemeeter\voicemeeter8x64.exe"
    Start-Sleep -Seconds 6
    if ([VMF]::VBVMR_Login() -lt 0) { Write-Host "Cannot reach Voicemeeter." -ForegroundColor Red; exit 1 }
}
Start-Sleep -Milliseconds 800
[VMF]::VBVMR_IsParametersDirty() | Out-Null

function Get-VMString($param) {
    $sb = New-Object System.Text.StringBuilder 512
    [VMF]::VBVMR_GetParameterStringA($param, $sb) | Out-Null
    return $sb.ToString()
}

# available WDM devices right now
$avail = @()
$n = [VMF]::VBVMR_Output_GetDeviceNumber()
for ($i = 0; $i -lt $n; $i++) {
    $t = 0
    $nm = New-Object System.Text.StringBuilder 256
    $hw = New-Object System.Text.StringBuilder 256
    [VMF]::VBVMR_Output_GetDeviceDescA($i, [ref]$t, $nm, $hw) | Out-Null
    if ($t -eq 3) { $avail += $nm.ToString() }
}

$targets = @(
    @{ bus = 0; strip = "Strip[5].A1"; dev = "Headphones (PartyPal 185 Stereo)";     label = "A1 PartyPal 185" },
    @{ bus = 1; strip = "Strip[5].A2"; dev = "Headphones (boAt Stone 1400 Stereo)";  label = "A2 Stone 1400" },
    @{ bus = 2; strip = "Strip[5].A3"; dev = "Digital Output (Abhishek's Tab S9 FE+)"; label = "A3 Tab S9 (optional)" }
)

foreach ($tg in $targets) {
    if ($avail -notcontains $tg.dev) {
        Write-Host "$($tg.label): device not available (speaker off / not connected) - skipped" -ForegroundColor Yellow
        continue
    }
    $ok = $false
    for ($try = 0; $try -lt 6 -and -not $ok; $try++) {
        if ((Get-VMString "Bus[$($tg.bus)].device.name") -ne $tg.dev) {
            [VMF]::VBVMR_SetParameterStringA("Bus[$($tg.bus)].device.wdm", $tg.dev) | Out-Null
            Start-Sleep -Seconds 2
        }
        [VMF]::VBVMR_SetParameterFloat($tg.strip, 1) | Out-Null
        Start-Sleep -Milliseconds 500
        [VMF]::VBVMR_IsParametersDirty() | Out-Null
        $v = 0.0; [VMF]::VBVMR_GetParameterFloat($tg.strip, [ref]$v) | Out-Null
        $ok = ((Get-VMString "Bus[$($tg.bus)].device.name") -eq $tg.dev) -and ($v -eq 1)
    }
    if ($ok) { Write-Host "$($tg.label): OK" -ForegroundColor Green } else { Write-Host "$($tg.label): FAILED" -ForegroundColor Red }
}

[VMF]::VBVMR_SetParameterFloat("Command.Restart", 1) | Out-Null
Start-Sleep -Seconds 4
Write-Host "Audio engine restarted. Play something to test." -ForegroundColor Cyan
[VMF]::VBVMR_Logout() | Out-Null
