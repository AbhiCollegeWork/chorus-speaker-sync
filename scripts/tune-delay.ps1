# tune-delay.ps1 : set speaker sync delay (System Settings output delay).
#
# Usage:
#   .\tune-delay.ps1 A1 50    ->  50 ms delay on A1 (PartyPal 185)
#   .\tune-delay.ps1 A2 0     ->  clear delay on A2 (Stone 1400)
#
# Add delay to the speaker you hear FIRST. The script restarts the audio
# engine (brief dropout) because the delay only applies after a restart.

param(
    [Parameter(Mandatory = $true)] [ValidateSet("A1", "A2")] [string]$Bus,
    [Parameter(Mandatory = $true)] [ValidateRange(0, 500)] [int]$Delay
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VMT {
    const string DLL = "C:\\Program Files (x86)\\VB\\Voicemeeter\\VoicemeeterRemote64.dll";
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Login();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_Logout();
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterFloat(string param, float value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterStringA(string param, string value);
    [DllImport(DLL, CharSet = CharSet.Ansi)] public static extern int VBVMR_IsParametersDirty();
}
'@

if ([VMT]::VBVMR_Login() -lt 0) { Write-Host "Could not connect to Voicemeeter (is it running?)" -ForegroundColor Red; exit 1 }
Start-Sleep -Milliseconds 500
[VMT]::VBVMR_IsParametersDirty() | Out-Null

$idx = if ($Bus -eq "A1") { 0 } else { 1 }
$docs = [Environment]::GetFolderPath("MyDocuments") + "\Voicemeeter"
$check = "$docs\CheckState.xml"
$want = "msA$($idx + 1)='$Delay\.00'"

# set with verification via config save (direct readback of Option.* is unreliable)
$verified = $false
for ($try = 0; $try -lt 6 -and -not $verified; $try++) {
    [VMT]::VBVMR_SetParameterFloat("Option.delay[$idx]", $Delay) | Out-Null
    Start-Sleep -Milliseconds 700
    [VMT]::VBVMR_IsParametersDirty() | Out-Null
    [VMT]::VBVMR_SetParameterStringA("Command.Save", $check) | Out-Null
    Start-Sleep -Milliseconds 1200
    $line = (Select-String -Path $check -Pattern "OptionDev" | Select-Object -First 1).Line
    $verified = $line -match $want
}
if (-not $verified) { Write-Host "Failed to set delay after retries." -ForegroundColor Red; [VMT]::VBVMR_Logout() | Out-Null; exit 1 }

Write-Host "$Bus delay set to $Delay ms. Restarting audio engine (brief dropout)..."
[VMT]::VBVMR_SetParameterFloat("Command.Restart", 1) | Out-Null
Start-Sleep -Seconds 4
[VMT]::VBVMR_SetParameterStringA("Command.Save", "$docs\HomeTheatre.xml") | Out-Null
Start-Sleep -Seconds 1
Write-Host "Done. Config saved to $docs\HomeTheatre.xml" -ForegroundColor Green
[VMT]::VBVMR_Logout() | Out-Null
