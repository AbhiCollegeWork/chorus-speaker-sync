# speaker-mode.ps1 : switch between home-theatre mode and single-speaker mode.
#
#   .\speaker-mode.ps1 theatre    -> both speakers via Voicemeeter (movie mode)
#   .\speaker-mode.ps1 partypal   -> Windows plays directly to PartyPal only
#   .\speaker-mode.ps1 stone      -> Windows plays directly to Stone only
#   .\speaker-mode.ps1 laptop     -> Windows plays on the laptop's own speakers
#
# Single/laptop modes work even with Voicemeeter closed.

param(
    [Parameter(Mandatory = $true)] [ValidateSet("theatre", "partypal", "stone", "laptop", "tab")] [string]$Mode
)

Import-Module AudioDeviceCmdlets -ErrorAction Stop

function Set-DefaultByName([string]$pattern) {
    $dev = Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' -and $_.Name -match $pattern } | Select-Object -First 1
    if (-not $dev) { Write-Host "Device matching '$pattern' not found (speaker off?)" -ForegroundColor Red; exit 1 }
    Set-AudioDevice -ID $dev.ID | Out-Null
    Write-Host "Default output -> $($dev.Name)" -ForegroundColor Green
}

switch ($Mode) {
    "theatre" {
        if (-not (Get-Process voicemeeter8x64 -ErrorAction SilentlyContinue)) {
            Start-Process "C:\Program Files (x86)\VB\Voicemeeter\voicemeeter8x64.exe"
            Write-Host "Starting Voicemeeter..."
            Start-Sleep -Seconds 6
        }
        Set-DefaultByName "VAIO"
        Write-Host "Theatre mode: both speakers active. If one is silent, run fix-speakers.ps1" -ForegroundColor Cyan
    }
    "partypal" { Set-DefaultByName "PartyPal 185 Stereo" }
    "stone"    { Set-DefaultByName "boAt Stone 1400 Stereo" }
    "laptop"   { Set-DefaultByName "Realtek" }
    "tab"      { Set-DefaultByName "Tab S9" }   # tablet must be connected as wireless display first
}
