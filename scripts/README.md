# Scripts

The working PowerShell tooling. These are what actually run today, as opposed to the `chorus` CLI described in the design documents, which is specified but not yet built.

All of them talk to Voicemeeter through `VoicemeeterRemote64.dll` and use the verify and retry pattern described in [Build Notes section 1.3](../docs/BUILD-NOTES.md), because the engine silently drops parameter writes made shortly after connecting.

| Script | Purpose |
|---|---|
| `fix-speakers.ps1` | Re-assign every output bus, restore routing, restart the engine. The fix for a speaker that has gone silent. |
| `master-volume.ps1` | Always on top volume panel: master plus per speaker sliders, mute buttons, live dB readout. |
| `speaker-mode.ps1` | Switch between the hub and any single output. |
| `tune-delay.ps1` | Apply a delay to one output bus, with verification and an engine restart. |

---

## fix-speakers.ps1

Run this whenever an output is silent, which most commonly happens after a reboot because Bluetooth reconnects more slowly than Voicemeeter starts.

```powershell
.\fix-speakers.ps1
```

It enumerates the available WDM outputs, assigns each configured device to its bus, verifies each write by reading it back, enables routing, and restarts the audio engine. Devices that are not currently present are reported and skipped rather than failing the run.

Edit the `$targets` block near the top to match your own speakers.

---

## master-volume.ps1

```powershell
.\master-volume.ps1
```

Opens a small always on top window with a master slider, one slider per output, mute buttons and live dB readouts.

This exists because **the Windows volume keys do not attenuate the Voicemeeter stream**, verified by measurement: dropping the Windows playback volume from 100 percent to 30 percent produced no change at the buses. Without this panel there is no convenient master control.

To start it with Windows:

```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "SpeakersPanel" -PropertyType String -Force `
  -Value 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\master-volume.ps1"'
```

The script waits up to 60 seconds for Voicemeeter to be reachable, so it survives being launched before the engine is ready at login.

---

## speaker-mode.ps1

```powershell
.\speaker-mode.ps1 theatre     # everything through the hub
.\speaker-mode.ps1 partypal    # one speaker directly
.\speaker-mode.ps1 stone       # the other speaker directly
.\speaker-mode.ps1 tab         # Miracast tablet, needs the screen share connected
.\speaker-mode.ps1 laptop      # built in speakers
```

Windows plays to exactly one default device at a time. The single output modes point that default straight at the device, bypassing Voicemeeter entirely, which is why they keep working when the engine is not running. Only `theatre` points Windows at the virtual input so the engine can fan the audio out.

If sound is coming from somewhere unexpected, this is almost always the reason.

---

## tune-delay.ps1

```powershell
.\tune-delay.ps1 A1 42    # 42 ms of delay on bus A1
.\tune-delay.ps1 A2 0     # clear bus A2
```

Add delay to whichever speaker you hear **first**. Delay can only be added, never removed, so the slowest speaker is the anchor and everything faster is held back to meet it.

Two things about this are easy to get wrong, both covered in [Build Notes section 1.5](../docs/BUILD-NOTES.md):

- The parameter that works is the System Settings per output delay, `Option.delay[i]`. The per channel EQ delay accepts a value, reads it back correctly, and has **no effect on the audio**.
- It does not apply until the audio engine restarts, which this script does for you. Expect a brief interruption.

The script verifies the value landed by saving the engine state and parsing it back, because the direct readback for this parameter always returns zero.

---

## Adapting these to your hardware

Device names are hard coded to the reference setup. Search for these strings and replace them with your own:

```
Headphones (PartyPal 185 Stereo)
Headphones (boAt Stone 1400 Stereo)
Digital Output (Abhishek's Tab S9 FE+)
```

List what your machine actually offers with:

```powershell
Import-Module AudioDeviceCmdlets
Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' } | Select-Object Name
```

**Always pick the "Stereo" entry, never "Hands-Free".** The hands free entry is the phone call profile: mono, roughly 8 kHz, and it sounds broken for music. Both entries appear for every Bluetooth speaker and the names are nearly identical.
