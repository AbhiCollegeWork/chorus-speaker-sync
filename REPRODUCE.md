# Reproducing Chorus End to End

This guide takes you from an empty machine to a working multi speaker audio hub, plus the full documentation set rendered to Word. Every step here has been run on real hardware. Where something has not been verified, it says so.

**Read [Honest status](#honest-status) first.** Part of this project is specified but not yet implemented, and this guide is careful about which is which.

---

## Contents

1. [Honest status](#honest-status)
2. [What you need](#what-you-need)
3. [Part A: the audio hub](#part-a-the-audio-hub)
4. [Part B: measuring speaker latency](#part-b-measuring-speaker-latency)
5. [Part C: building the documentation](#part-c-building-the-documentation)
6. [Verification checklist](#verification-checklist)
7. [If something breaks](#if-something-breaks)

---

## Honest status

| Component | State | Where |
|---|---|---|
| Audio routing to several outputs | **Working, verified** | Voicemeeter Potato plus `scripts/` |
| Mode switching, volume panel, repair | **Working, verified** | `scripts/*.ps1` |
| Persistence across reboot | **Working, verified** | Voicemeeter config file |
| Latency measurement by microphone | **Prototype, method proven** | Described in Part B |
| `chorus` CLI (`chorus setup`, `chorus calibrate`) | **Specified, NOT built** | Design lives in the docs |
| Documentation build to Word | **Working, verified** | `tools/` |

The `chorus` commands shown in the README and User Manual describe the target design. They do not exist yet. What exists today is a set of PowerShell scripts that do the routing, mode switching, volume control and repair, and a measurement method that has been demonstrated end to end but not yet packaged as a command.

This distinction matters. Do not file an issue that `chorus calibrate` is missing. It is on the roadmap.

---

## What you need

### Hardware

| Item | Notes |
|---|---|
| Windows 10 or 11 PC | Windows 10 Pro 19045 is the reference platform |
| Two or more audio outputs | Bluetooth speakers, a Miracast tablet, HDMI, or built in speakers |
| A microphone | The laptop's built in microphone is adequate for measurement |

**Before you plan for many Bluetooth speakers, read this.** Windows binds its Bluetooth stack to one radio at a time, and adding USB Bluetooth dongles does not raise that limit. Each stereo audio stream costs roughly 345 kbps of shared radio bandwidth. Two simultaneous Bluetooth speakers are verified working on the reference adapter (Intel Wireless-AC 8260). Three or more is untested. You can exceed two by mixing transports, for example two Bluetooth speakers plus a Miracast tablet plus HDMI, because those use different radios.

### Software

| Tool | Purpose | Needed for | Cost |
|---|---|---|---|
| [Voicemeeter Potato](https://vb-audio.com/Voicemeeter/potato.htm) | The audio engine with five output buses and per bus delay | Part A | Donationware, see below |
| PowerShell 5.1 | Ships with Windows | Parts A and B | Free |
| `AudioDeviceCmdlets` module | Switching the Windows default output device | Part A | Free |
| [pandoc](https://pandoc.org) 3.x | Markdown to Word conversion | Part C | Free |
| Node.js 18 or newer | Runs the Mermaid renderer | Part C | Free |
| Chrome or Edge | Driven headlessly to rasterise diagrams | Part C | Free |
| Python 3.9 or newer | `python-docx`, `pillow` | Part C | Free |

Get **Potato** specifically, not Voicemeeter Standard or Banana. Potato is the edition with five physical output buses and the per output delay this project depends on.

### A note on what Voicemeeter costs

Voicemeeter is **donationware**, and this guide should be upfront about that before you start.

From VB-Audio's own licence, in `readme.txt` inside the install folder:

> Voicemeeter8 Donationware Model allows you to install and use the application for free until you find it useful. Then you can pay a license price between 10 and 100 EUR/USD when you want, according to your means or usage.

What that means in practice:

- It is **not a subscription**. It is a one time payment, and you choose the amount within that range.
- Nothing is locked, crippled or time limited. Every feature this project uses works unlicensed, including the per output delay that the whole calibration depends on.
- Until you license it, Voicemeeter shows a periodic **"About / Registration info"** reminder dialog. It appears on a timer rather than at every launch, and you dismiss it with one click.

So you can build and run everything here without paying. If the project ends up being useful to you, the author is a single developer and the licence is bought at [shop.vb-audio.com](https://shop.vb-audio.com) using a challenge code from Voicemeeter's own About box.

This project is not affiliated with VB-Audio and earns nothing from that link.

---

## Part A: the audio hub

### A1. Install the audio engine

Download Voicemeeter Potato from the vendor and run the installer. Verify the download is signed before running it:

```powershell
Get-AuthenticodeSignature .\Voicemeeter8Setup.exe | Select-Object Status, SignerCertificate
```

Status should be `Valid`.

**Reboot after installing.** This is not optional. The virtual audio driver does not load correctly until you restart.

> The installer may return an unusual exit code even on success. Check whether `C:\Program Files (x86)\VB\Voicemeeter\` exists rather than trusting the exit code.

### A2. Launch the right edition

The installer often starts Voicemeeter Standard. Close it and launch Potato explicitly:

```powershell
Stop-Process -Name voicemeeter_x64 -Force -ErrorAction SilentlyContinue
Start-Process "C:\Program Files (x86)\VB\Voicemeeter\voicemeeter8x64.exe"
```

Confirm you have Potato: it shows five hardware output buttons (A1 through A5) at the top right. Standard shows three.

### A3. Pair your speakers in Windows first

Turn on each speaker and pair it through Windows Settings, Bluetooth and devices. Chorus does not implement pairing; the operating system flow is more reliable and already handles PINs and device quirks.

**A speaker must be powered on and showing Connected before the next step can see it.** Paired but switched off is not enough.

### A4. Assign speakers to output buses

In Voicemeeter, click each **A1**, **A2** and so on button at the top right and pick your speaker.

**Choose the entry named "Headphones (YourSpeaker Stereo)". Never pick "Headset (YourSpeaker Hands-Free AG Audio)".** The hands free entry is the telephone call profile: mono, roughly 8 kHz, and it sounds broken for music. The two entries look almost identical in the list.

Then on the Voicemeeter VAIO virtual input strip, enable the **A1** and **A2** buttons so the source feeds both buses.

To do this from a script instead, see `scripts/fix-speakers.ps1`, which assigns every bus and verifies each write.

### A5. Point Windows at the hub

Set **Voicemeeter Input (VB-Audio Voicemeeter VAIO)** as the Windows default playback device.

```powershell
Install-Module AudioDeviceCmdlets -Scope CurrentUser -Force
Import-Module AudioDeviceCmdlets
Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' -and $_.Name -match 'VAIO' }
```

You will see several identical looking VAIO entries. That is normal: the driver exposes eight pipes into the mixer. Any of them works. To pick deterministically, match on the driver instance path rather than the name or index:

```powershell
$guid = $dev.ID -replace '^\{0\.0\.0\.00000000\}\.', ''
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$guid\Properties").'{233164c8-1b2c-4c7d-bc68-b671687a2567},1'
```

The main input is the one ending `..._out1_wave_...`.

> `AudioDeviceCmdlets` renumbers its `Index` values between calls. Never store an index. Match on `ID` or the instance path.

### A6. Install the helper scripts

Copy `scripts/*.ps1` somewhere convenient and run them from PowerShell:

```powershell
.\speaker-mode.ps1 theatre     # all speakers through the hub
.\speaker-mode.ps1 partypal    # one speaker directly, hub bypassed
.\speaker-mode.ps1 laptop      # built in speakers
.\fix-speakers.ps1             # re-assign every bus and restart the engine
.\master-volume.ps1            # floating volume panel, master plus per speaker
```

`master-volume.ps1` is worth adding to startup. Windows volume keys do **not** attenuate the Voicemeeter stream, so without the panel you have no convenient master control.

```powershell
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
  -Name "SpeakersPanel" -PropertyType String -Force `
  -Value 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\master-volume.ps1"'
```

### A7. Harden the radio against dropouts

Bluetooth and 2.4 GHz Wi-Fi share the same band, and on most laptops the same antenna. Run elevated:

```powershell
# stop Windows powering down the wireless and USB hardware
foreach ($d in Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable) {
  if ($d.InstanceName -match "USB|BTH") { $d.Enable = $false; Set-CimInstance -CimInstance $d }
}
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT
```

**The single most effective fix is not a Windows setting.** If your router broadcasts only 2.4 GHz, enable its 5 GHz band and put the PC on it. That clears the air for Bluetooth. On the reference system, the entire dropout problem turned out to be a Miracast tablet session saturating 2.4 GHz. Disconnecting it fixed everything.

If dropouts persist, raise the engine buffer. In Voicemeeter, Menu, System Settings, set the WDM or MME buffer to 1024 or 2048. Larger buffers absorb radio contention at the cost of latency you will not notice for playback.

---

## Part B: measuring speaker latency

This is the part that makes the project worth existing. Every Bluetooth speaker adds 150 to 250 ms of latency and no two agree, so they arrive at different times and you hear an echo. The human ear cannot reliably tell you *which* speaker is early, which is why tuning by ear fails.

### B1. The method

1. Generate a click train: a 1 kHz sine burst, 8 ms long, with a linear decay envelope, repeating every 700 ms.
2. Play it through **one speaker at a time** by muting the others.
3. Record the room with a microphone.
4. Compute an amplitude envelope over 5 ms windows and detect onsets with an adaptive threshold and a 200 ms refractory period.
5. Take the median onset phase modulo the 700 ms repeat period. That is the speaker's latency.
6. Correct for microphone distance. Sound travels about 2.92 ms per metre.
7. Anchor on the **slowest** speaker and delay every faster one to match it. Delay can only be added, never removed.
8. Re-measure to verify. Target is a residual spread of 10 ms or less.

Full specification including aliasing constraints and precision limits is in [TRD section 6](docs/TRD.md).

### B2. Applying the delay

This is where most implementations go wrong, so be precise:

- The working parameter is the **System Settings per output delay**, reachable in the Voicemeeter API as `Option.delay[i]`, range 0 to 500 ms.
- It does **not** take effect until you restart the audio engine (`Command.Restart`).
- Restarting the engine **drops bus device assignments**, so re-assert them afterwards and confirm signal is present.
- The per channel EQ delay (`Bus[i].EQ.channel[j].delay`) **accepts a value, stores it, reads back correctly, and does nothing to the audio.** It was only caught by acoustic measurement. Do not use it.

`scripts/tune-delay.ps1` implements the correct path with verification:

```powershell
.\tune-delay.ps1 A1 42     # 42 ms on the PartyPal bus
.\tune-delay.ps1 A2 0      # clear the Stone bus
```

### B3. Verify acoustically, not through the API

The engine API will happily report success for a delay that has no audible effect. Any change to the delay path must be confirmed by measurement. A good keystone test: apply a known delay of 50 ms deliberately, run the measurement, and check it reads back as 50 ms plus or minus 10 ms. That single test would have caught the inert parameter immediately.

---

## Part C: building the documentation

The five design documents are Markdown with Mermaid diagrams. GitHub renders those natively. Word does not, so the build rasterises every diagram to PNG and embeds it.

### C1. Install the toolchain

```bash
# pandoc: https://pandoc.org/installing.html, then confirm
pandoc --version

# python packages
pip install python-docx pillow

# mermaid renderer, reusing your installed Chrome instead of downloading Chromium
cd tools
PUPPETEER_SKIP_DOWNLOAD=true npm install @mermaid-js/mermaid-cli
npm install mermaid@11 jsdom      # for the diagram validator
```

### C2. Point the renderer at your browser

Create `tools/puppeteer-config.json`:

```json
{
  "executablePath": "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "args": ["--no-sandbox", "--disable-setuid-sandbox"]
}
```

**Use forward slashes.** A Windows path with backslashes is not valid JSON escaping and the renderer fails with a confusing `Bad escaped character in JSON` error.

### C3. Validate the diagrams

```bash
node tools/validate-diagrams.mjs .
```

Every diagram should report PASS. A broken diagram renders as an error box on GitHub, so run this before pushing documentation changes.

### C4. Build

```bash
python tools/make-word-template.py    # once, creates the styled template
python tools/build-word-docs.py       # renders diagrams, produces docs/word/*.docx
```

The build does three non obvious things worth knowing about:

1. **It re-lays tall diagrams.** A top down flowchart with a dozen nodes, scaled to fit page height, leaves text at roughly 4pt and is unreadable. The script renders a left to right variant as well and keeps whichever displays larger.
2. **It disables syntax highlighting.** Highlighted code becomes one Word paragraph containing hundreds of separately styled runs. A 54 KB, 619 run paragraph hung Word indefinitely.
3. **It stamps DPI metadata on each PNG** so pandoc sizes images inside the page box instead of overflowing.

### C5. Populate the table of contents

Open each document, press `Ctrl+A` then `F9`, and choose to update the entire table. Pandoc emits the table of contents as a field that Word fills in on demand, so page numbers show as placeholders until you do this once.

---

## Verification checklist

Work through this to confirm a good build.

**Audio hub**

- [ ] Voicemeeter Potato is running and shows five output buses
- [ ] Each speaker is assigned to a bus using its **Stereo** endpoint, not Hands-Free
- [ ] The VAIO input strip has the relevant A buttons lit
- [ ] Windows default playback device is the Voicemeeter VAIO input
- [ ] Playing audio shows level on every assigned bus meter
- [ ] Sound is audible from every speaker at the same time
- [ ] Settings survive a reboot with no manual steps

**Measurement**

- [ ] A deliberately injected 50 ms delay is measured back as 50 ms plus or minus 10 ms
- [ ] After correction, the spread between speakers is 10 ms or less
- [ ] The result is confirmed by ear on percussive material, with no audible flam

**Documentation**

- [ ] `node tools/validate-diagrams.mjs .` reports all diagrams passing
- [ ] `docs/word/` contains five `.docx` files
- [ ] Each opens in Word and shows rendered diagrams, not code blocks
- [ ] The table of contents shows real page numbers after `Ctrl+A`, `F9`

---

## If something breaks

Symptoms and quick answers below. The full engineering log, with every problem hit during development and how each was diagnosed, is in [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md).

| Symptom | Most likely cause | Fix |
|---|---|---|
| One speaker silent after reboot | Bluetooth reconnects slower than Voicemeeter starts, so the bus lost its device | `.\fix-speakers.ps1` |
| Audio cuts out every minute or so | 2.4 GHz contention, most often a Miracast session | Disconnect the wireless display, move Wi-Fi to 5 GHz, raise the engine buffer |
| A speaker sounds like a telephone | The Hands-Free endpoint got selected | Reassign the bus to the Stereo endpoint |
| Delay setting has no audible effect | You used the inert per channel EQ delay, or did not restart the engine | Use `Option.delay[i]` and `Command.Restart` |
| No sound at all | Windows default device changed, or the engine is not running | `.\speaker-mode.ps1 theatre` |
| Word hangs opening a built document | Word blacklisted the path after an earlier hang | `.\tools\unblock-word-files.ps1 -Match chorus` |
| Diagrams show as code in Word | You opened the Markdown, not the file from `docs/word/` | Open the `.docx` |
| Mermaid renderer fails on JSON | Backslashes in `puppeteer-config.json` | Use forward slashes |

---

## Contributing measurements

The open question this project cares about most is how many concurrent Bluetooth audio streams real adapters actually sustain. Published answers are inconsistent, and most confuse *pairing* capacity, commonly quoted as seven devices, with *streaming* capacity, which is far lower and bandwidth bound.

If you reproduce this, please open an issue with your adapter model, how many speakers you got working simultaneously, and their transports. Confirm the transport from the device instance path rather than the friendly name:

| Transport | Instance path signature |
|---|---|
| Bluetooth stereo (A2DP) | `BTHENUM\{0000110B-...}` |
| Bluetooth hands free | `BTHENUM\{0000111E-...}` or `BTHHFENUM\` |
| Miracast | `SWD\WIFIDIRECT\...#MIRACAST` |

This matters more than it sounds. During development a setup that looked like three Bluetooth speakers working turned out to be two Bluetooth speakers plus a Miracast tablet, which is a completely different claim.
