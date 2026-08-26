# Build Notes: Every Problem and How It Was Solved

This is the engineering log. It records every non obvious problem hit while building Chorus, what the symptom looked like, how it was diagnosed, and what actually fixed it.

It exists because most of these cost hours to work out and almost none of them are documented anywhere else. If you are reproducing this project, or building anything on Voicemeeter, Bluetooth audio on Windows, or pandoc to Word conversion, read the relevant section before you start rather than after you are stuck.

Entries are marked with how the conclusion was reached:

- **Measured** means confirmed on hardware, usually acoustically or with signal meters.
- **Observed** means reproduced reliably but not instrumented.
- **Cited** means taken from vendor documentation.

Reference platform: Windows 10 Pro 19045, Intel Dual Band Wireless-AC 8260, Voicemeeter Potato 3.1.2.2, pandoc 3.10.2, Node 22, Python 3.11.

---

## Contents

1. [Voicemeeter engine and Remote API](#1-voicemeeter-engine-and-remote-api)
2. [Bluetooth, transports and radio](#2-bluetooth-transports-and-radio)
3. [Acoustic measurement](#3-acoustic-measurement)
4. [Windows audio device handling](#4-windows-audio-device-handling)
5. [Diagrams](#5-diagrams)
6. [Word export](#6-word-export)
7. [Writing style](#7-writing-style)
8. [Debugging traps](#8-debugging-traps)
9. [A note on how this was built](#9-a-note-on-how-this-was-built)

---

## 1. Voicemeeter engine and Remote API

### 1.1 The installer reports failure on success

**Symptom.** The Potato installer returned exit code `-805306369`, which reads as a crash.

**Reality.** The install had completed correctly. The exit code is not a reliable success signal.

**Fix.** Verify by checking the filesystem and the audio endpoints, not the exit code:

```powershell
Test-Path "C:\Program Files (x86)\VB\Voicemeeter"
Get-PnpDevice | Where-Object { $_.FriendlyName -match "Voicemeeter|VB-Audio" }
```

### 1.2 The installer launches the wrong edition

**Symptom.** After installing Potato, the running application had only three output buses. The Remote API reported `VoicemeeterType = 1`, which is Standard.

**Cause.** The installer package contains all three editions and starts Standard by default.

**Fix.** Launch Potato explicitly. `voicemeeter8x64.exe` is Potato; `voicemeeter_x64.exe` is Standard. Confirm through the API, where type `3` is Potato.

### 1.3 Parameter writes fail silently right after connecting

**Symptom.** `VBVMR_SetParameterFloat` returned `0` for success, but the value never applied. Roughly a third to a half of writes issued shortly after `VBVMR_Login` were lost.

**Diagnosis.** Reading the parameter back immediately after writing showed the old value. Retrying the same call succeeded.

**Fix.** Never trust the return code. Every mutating call goes through a verify and retry loop:

```powershell
$ok = $false
for ($try = 0; $try -lt 6 -and -not $ok; $try++) {
    [VM]::VBVMR_SetParameterFloat("Strip[5].A2", 1) | Out-Null
    Start-Sleep -Milliseconds 600
    [VM]::VBVMR_IsParametersDirty() | Out-Null
    $ok = (VM-GetFloat "Strip[5].A2") -eq 1
}
```

This single pattern is responsible for most of the reliability in the scripts. It is not defensive paranoia; without it the system is genuinely unreliable.

### 1.4 System option parameters always read back as zero

**Symptom.** `VBVMR_GetParameterFloat("Option.delay[0]", ...)` returned `0` no matter what had been written, so the verify loop in 1.3 could never succeed.

**Fix.** Verify by writing the engine state to file and parsing the persisted value:

```powershell
[VM]::VBVMR_SetParameterStringA("Command.Save", "$docs\CheckState.xml") | Out-Null
Start-Sleep -Milliseconds 1200
$line = (Select-String -Path "$docs\CheckState.xml" -Pattern "OptionDev" | Select-Object -First 1).Line
$verified = $line -match "msA1='300\.00'"
```

The `OptionDev` element carries `msA1` through `msA5`, which are the per output delays in milliseconds.

### 1.5 The obvious delay parameter does nothing

**This was the most expensive bug in the project.**

**Symptom.** Setting `Bus[i].EQ.channel[j].delay` succeeded, read back correctly, persisted to the config file, and had **no audible effect whatsoever**. Three hundred milliseconds of delay produced no change.

**How it was caught.** Not through the API, which reported everything as fine. It was caught by recording the speakers with a microphone and measuring click arrival times. The measured offset did not move.

**Root cause.** That parameter belongs to the bus EQ section and is inert for output timing on this build.

**Fix.** The working parameter is the System Settings per output delay, exposed as `Option.delay[i]`, range 0 to 500 ms. It requires an engine restart to take effect.

**Lesson worth generalising.** An API that accepts a write, stores it, and reads it back correctly can still be doing nothing. For anything whose effect is physical, verify physically. The keystone test is to inject a known delay and confirm the measurement recovers it.

### 1.6 Delay requires an engine restart

**Behaviour.** `Option.delay[i]` does not apply until `Command.Restart` runs. The restart causes a brief audio interruption.

**Consequence for design.** Batch all delay writes, restart once, then re-assert bus assignments (see 1.7), then verify. Do not restart per output.

### 1.7 Engine restart drops bus device assignments

**Symptom.** After `Command.Restart`, or after restarting the Voicemeeter application, one or more buses went silent. `Bus[i].device.name` returned an empty string. Nothing reported an error anywhere.

**Impact.** This is the single most common day to day failure. It presents to the user as "one speaker stopped working" with no diagnostic.

**Fix.** After every engine restart, re-assert each bus device and confirm signal is present on the meters. This is what `scripts/fix-speakers.ps1` does.

### 1.8 Loading a saved config does not restore devices

**Symptom.** `Command.Load` restored faders and routing but left buses unassigned.

**Cause.** The device configuration section of the XML, `OutputDev` and `OptionDev`, is not applied by a config load.

**Fix.** Always explicitly set `Bus[i].device.wdm` or `.mme` after loading. Never rely on load alone.

### 1.9 MME buffers more deeply than WDM

**Measured.** Switching output buses from WDM to MME improved tolerance of radio interference. In the saved config the interface shows as `type='1'` for MME.

**Trade off.** More latency, which does not matter here because calibration equalises relative timing anyway. Buffer sizes and their latency cost:

| Buffer (samples) | Added latency at 48 kHz | Dropout resilience |
|---|---|---|
| 512 | about 11 ms | poor under contention |
| 1024 | about 21 ms | moderate |
| 2048 | about 43 ms | best available |

---

## 2. Bluetooth, transports and radio

### 2.1 Windows uses one Bluetooth adapter at a time

**Cited.** Windows binds its Bluetooth stack to a single radio. Adding USB Bluetooth dongles does not increase capacity, and vendor guidance is to disable the built in adapter before using an external one.

**Consequence.** The number of simultaneous Bluetooth speakers is capped by one radio's bandwidth. There is no software route around this on Windows. Linux with BlueZ addresses adapters independently as `hci0`, `hci1` and so on, which is the actual path to more speakers and is why the roadmap mentions it.

### 2.2 Streaming capacity is far lower than pairing capacity

**Cited and measured.** The widely quoted "seven Bluetooth devices" figure refers to ACL link capacity, which is about pairing. Audio streaming is bandwidth bound at roughly 345 kbps per stereo stream. Two simultaneous streams are measured working on the Intel 8260. Three or more is untested.

Conflating these two numbers is the most common error in community writeups on this topic, and it is why the README publishes only what has been measured.

### 2.3 A "three speaker" success was actually two transports

**Symptom.** A setup with three outputs playing simultaneously looked like proof that three Bluetooth speakers work.

**Diagnosis.** Checking the device instance paths showed otherwise:

```
PartyPal 185 Stereo     BTHENUM\{0000110B-...}        Bluetooth A2DP
boAt Stone 1400 Stereo  BTHENUM\{0000110B-...}        Bluetooth A2DP
Tab S9 FE+              SWD\WIFIDIRECT\...#MIRACAST   Wi-Fi Direct
```

The third output was a Miracast tablet, not Bluetooth at all. The real result was two Bluetooth streams plus one Wi-Fi stream.

**Rule that came out of it.** Always determine transport from the PnP instance path, never from the friendly name. Friendly names are ambiguous; a Miracast tablet and a Bluetooth speaker can both present as "Digital Output" or "Headphones".

| Transport | Signature |
|---|---|
| Bluetooth stereo (A2DP) | `BTHENUM\{0000110B-...}` |
| Bluetooth hands free (HFP) | `BTHENUM\{0000111E-...}`, `BTHHFENUM\` |
| Miracast | `SWD\WIFIDIRECT\...#MIRACAST`, device class `Miracast` |

### 2.4 Hands free endpoints must be excluded

**Symptom.** Every Bluetooth speaker appears twice in the output list, as "Headphones (X Stereo)" and "Headset (X Hands-Free AG Audio)". Selecting the wrong one gives mono, roughly 8 kHz, telephone quality audio.

**Additional problem.** A video call application can grab the hands free profile on its own, which both degrades quality and can use a speaker across the room as the microphone.

**Fix.** Exclude hands free endpoints from the assignable list. To stop applications grabbing them, disable the components (elevated):

```powershell
Get-PnpDevice | Where-Object { $_.InstanceId -like "BTHHFENUM*" } | Disable-PnpDevice -Confirm:$false
```

### 2.5 The dropout mystery: Miracast was eating the band

**Symptom.** Audio dropped out briefly every 40 to 80 seconds, on both speakers, with no fixed pattern.

**What was tried and did not fully fix it.** Disabling adapter power management, disabling USB selective suspend, lowering Wi-Fi roaming aggressiveness, raising the engine buffer to 1024 then 2048, switching WDM to MME. Each helped and lengthened the interval, but none eliminated it.

**Root cause, measured.** An active Miracast session to a tablet. Miracast is a continuous video stream over Wi-Fi Direct on the same 2.4 GHz band, sharing the antenna with Bluetooth. Disconnecting the tablet stopped the dropouts completely.

**Ranked mitigations.**

1. Move the host Wi-Fi to 5 GHz. This is the real fix and clears the band.
2. Do not run Miracast at the same time as Bluetooth audio.
3. Raise the engine buffer to absorb brief contention.
4. Disable radio power management.
5. Reduce Wi-Fi roaming scans.

**Diagnostic that settles it in two minutes.** Play a locally stored track, turn Wi-Fi off entirely, and listen. If the dropouts stop, it is band contention and no amount of audio configuration will fully fix it.

### 2.6 Radio power management settings

Applied elevated. `MSPower_DeviceEnable` covers the wireless card, the Wi-Fi Direct virtual adapters and, importantly, **the USB hub the Bluetooth radio sits on**, which a first pass missed.

```powershell
foreach ($d in Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable) {
  if ($d.InstanceName -match "USB|BTH") { $d.Enable = $false; Set-CimInstance -CimInstance $d }
}
```

`RoamAggressiveness = 1` on the Intel adapter reduces periodic off channel scanning, and takes effect after a reboot.

---

## 3. Acoustic measurement

### 3.1 Why measurement rather than tuning by ear

Human hearing fuses sounds below roughly 30 ms, the precedence effect, and gives almost no reliable cue about which of two identical broadband transients came first. Users can hear that something is wrong but not what to change, so tuning by ear is blind search. This was confirmed directly: the user could hear a clear doubled tick but could not tell which speaker led.

### 3.2 Stimulus design

| Parameter | Value | Reason |
|---|---|---|
| Waveform | 1 kHz sine burst | inside both speaker passband and microphone sensitivity, avoids low frequency room modes that smear onsets |
| Duration | 8 ms | long enough to detect, short enough to localise the attack |
| Envelope | linear decay | sharp attack, no ringing tail to trigger false onsets |
| Period | 700 ms | longer than room reverberation, short enough for many samples |
| Repeats | 8 or more | enables median statistics against Bluetooth jitter |

### 3.3 Latency computation

The recorder does not know when the generator emitted each click, so measurement is relative, using the repeat period as a shared time base.

```
phase_i = median over onsets of ((t_k - T0) mod P)
```

The median rejects outliers from a dropped packet or a stray room noise. Pairwise offset is the circular difference, giving an unambiguous range of plus or minus half the period, which is plus or minus 350 ms at P = 700 ms. Bluetooth spread is far smaller than that, so the period is safe.

### 3.4 Distance compensation

Sound travels about 343 m/s, so one metre of extra distance adds about 2.92 ms of apparent latency. Either place the microphone equidistant from all speakers, which is the default guidance, or declare per output distances and subtract them.

### 3.5 Anchor on the slowest output

Delay can only be added, never removed, so the slowest speaker sets the pace:

```
anchor  = max over i of latency_i
delay_i = round(anchor - latency_i)
```

The slowest output gets zero delay. This is worth surfacing in any user interface, because otherwise "why did it only change one speaker?" is the obvious question.

### 3.6 Practical measurement gotchas

**MCI cannot save to a long path.** `mciSendString("save rec ...")` fails with error 304, "The filename is invalid", on long paths with spaces. Record to a short path such as `C:\Users\<name>\AppData\Local\Temp\rec.wav` and move the file afterwards.

**PowerShell has no `short` type accelerator.** `New-Object short[]` fails. Use `New-Object 'System.Int16[]'` and `[Int16]` casts when synthesising audio buffers.

**Bluetooth settle time.** After muting or unmuting an output, wait about 1.5 seconds before measuring. The transport takes time to stabilise and early samples are unreliable.

**Onset detection needs both an adaptive threshold and a refractory period.** Threshold `max(noise_floor * 3, peak * 0.10)` adapts to quiet rooms and loud speakers. A 200 ms refractory period suppresses double triggering on reflections.

---

## 4. Windows audio device handling

### 4.1 AudioDeviceCmdlets indices are not stable

**Symptom.** Device `Index` values change between calls, so a stored index selects the wrong device later.

**Fix.** Match on `ID`, or better, on the driver instance path from the registry:

```powershell
$guid = $dev.ID -replace '^\{0\.0\.0\.00000000\}\.', ''
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$guid\Properties").'{233164c8-1b2c-4c7d-bc68-b671687a2567},1'
```

The Voicemeeter virtual inputs are distinguishable only this way; all eight share the friendly name "Speakers (VB-Audio Voicemeeter VAIO)". The main input ends `..._out1_wave_...`.

### 4.2 Windows volume keys do not affect the virtual stream

**Measured.** Setting the Windows playback volume from 100 percent to 30 percent produced no change in the level arriving at the Voicemeeter buses (0.267 against 0.271 peak).

**Consequence.** A master volume control has to be built. It maps to the input strip gain, `Strip[5].gain`, which is what `scripts/master-volume.ps1` provides.

### 4.3 Windows plays to exactly one default device

Obvious in hindsight, and a recurring source of confusion in use. Single speaker modes point the Windows default straight at that device, bypassing the engine entirely, which is why they keep working when Voicemeeter is closed. Only the hub mode points Windows at the virtual input.

Whenever sound comes from an unexpected place, the default device is the first thing to check.

---

## 5. Diagrams

### 5.1 Mermaid, not generated images

Diagrams are Mermaid fenced blocks in Markdown. GitHub renders them natively, they diff cleanly in version control, and they do not rot the way checked in PNGs do.

### 5.2 Validate before publishing

A malformed diagram renders as an error box on GitHub. `tools/validate-diagrams.mjs` parses every diagram with the real Mermaid parser and exits non zero on failure.

**Gotcha.** Mermaid needs a DOM, so the validator sets up jsdom first. On newer Node versions `global.navigator` is a getter only property and plain assignment throws. Use:

```js
Object.defineProperty(global, "navigator", { value: dom.window.navigator, configurable: true });
```

### 5.3 Tall diagrams become unreadable in print

**Symptom.** A top down flowchart with a dozen nodes has an aspect ratio around 1:7. Scaled to fit page height it becomes about 2.3 inches wide, putting label text at roughly 4pt.

**Fix.** For any diagram taller than 1.5 times its width, the build also renders a left to right variant and keeps whichever displays larger on the page. Four of seventeen diagrams were re-laid this way. Layout direction is presentation, not meaning, so the Markdown source keeps the natural top down form for GitHub.

---

## 6. Word export

### 6.1 Toolchain

Mermaid to PNG through mermaid-cli driving headless Chrome, then Markdown to docx through pandoc with a styled reference template.

**Reuse the installed browser.** `PUPPETEER_SKIP_DOWNLOAD=true` during install, then point at Chrome with a config file, avoiding a 150 MB Chromium download.

**Use forward slashes in `puppeteer-config.json`.** A Windows path with backslashes is invalid JSON escaping and produces `Bad escaped character in JSON at position 26`, which does not obviously point at the path.

### 6.2 Word ignores fonts set on styles

**Symptom.** Setting heading fonts with python-docx had no effect in Word, although the file looked correct when inspected.

**Cause.** Word resolves `w:asciiTheme` in preference to `w:ascii`. A style that carries a theme font reference ignores the explicit font.

**Fix.** Both patch the document theme and strip the theme attributes from `styles.xml`:

```python
xml = re.sub(r'(<a:latin typeface=")[^"]*(")', r'\1' + BODY_FONT + r'\2', xml)   # theme1.xml
xml = re.sub(r'\s+w:(ascii|hAnsi|cs|eastAsia)Theme="[^"]*"', "", xml)           # styles.xml
```

### 6.3 Syntax highlighting can hang Word

**Symptom.** One document out of five hung Word indefinitely on open. The others were fine.

**Diagnosis.** Comparing the internal XML showed the failing document had a `document.xml` of 230 KB against about 112 KB for a larger document, despite fewer tables and images. Inspecting paragraph sizes found the cause: pandoc emits each highlighted code block as a **single paragraph containing hundreds of separately styled runs**. The largest was 54 KB with 619 runs and 60 line breaks. That document had four large JSON blocks; the others had small ones.

**Fix.** `--syntax-highlighting=none`. Code renders as plain monospace, which is arguably better for print anyway, and the document XML halved.

### 6.4 Word blacklists files that once hung it

**This was the real cause of "the files will not open", and it is self reinforcing.**

**Symptom.** A document hung on open. After the underlying problem in 6.3 was fixed and the file rebuilt, it still hung. Then other documents that had opened fine started hanging too.

**Diagnosis.** A byte identical copy of the failing file opened instantly under a different filename, in the same folder. That rules out the content entirely and points at the path.

**Root cause.** When Word hangs or is force closed on a document, it records that exact path in the registry:

```
HKCU\Software\Microsoft\Office\<version>\Word\Resiliency\DisabledItems
```

From then on Word hangs or refuses on that path regardless of how healthy the file is.

**Why it spreads.** Force closing Word to escape the hang is itself recorded as a crash on that document, which adds another entry. Repeated testing therefore blacklisted three of the five files.

**Fix.** Remove the matching values. `tools/unblock-word-files.ps1 -List` shows what is listed, `-Match chorus` removes only those entries and leaves add ins and unrelated documents alone.

**Diagnostic tell worth remembering.** If a file fails to open but a copy of it under a different name opens fine, the problem is not the file.

### 6.5 Things that looked like defects but were not

**Compatibility Mode.** Pandoc output opens with `[Compatibility Mode]` in the title bar and reports `CompatibilityMode = 12`, which is Word 2007 mode. This is normal for pandoc and harmless.

**Table of contents shows placeholders.** Pandoc writes the table of contents as a field marked dirty. Word fills it in on demand. Press `Ctrl+A` then `F9` once per document.

**Image DPI.** Images are stamped with computed DPI metadata so pandoc sizes them within the page box. The values are non integer, for example 356.36 DPI, which is valid and works correctly.

---

## 7. Writing style

### 7.1 No em dashes or en dashes

House rule for this project. All source documents and the generated Word output are verified at zero of both characters.

### 7.2 Do not remove them with find and replace

**What went wrong.** A scripted character swap across 131 em dashes and 23 en dashes produced:

- Comma splices, for example "Play one audio source at once. And actually get them in sync".
- Eight broken table cells, where an em dash had meant "not applicable" and became a stray comma, leaving `|, |`.
- Five mangled document titles, "Backend Schema. Chorus".
- Changed character widths in ASCII art boxes, which relies on exact alignment.

Forty eight places had to be repaired by hand afterwards.

**Correct approach.** Write the sentence without one in the first place. When removing existing ones, choose per context: a comma for an aside, a colon before an expansion, a full stop between independent clauses, plain hyphens for ranges such as `150-250 ms`. Then verify:

```bash
grep -oP '\x{2014}|\x{2013}' README.md docs/*.md | wc -l   # must print 0
```

Check inside generated Word files too, not just the Markdown, since the build can reintroduce them from script constants.

---

## 8. Debugging traps

Honest notes on methodology failures during this build. These cost more time than any of the actual bugs.

### 8.1 Do not force kill the application you are testing

The Word blacklist loop in 6.4 was created by the test harness itself. Each timeout triggered a force kill, which Word recorded as a crash against that document, which caused the next open to hang. The result was an alternating pass and fail pattern across the file list that looked like a property of the files and was not.

**Rule.** Let the application quit gracefully. If you must kill it, wait for the process to actually exit before starting another instance, and check whether the application keeps crash state that needs clearing.

### 8.2 Beware verification that is weaker than the real use

Opening documents through COM automation with `Visible = false` skips full pagination and rendering. Files verified that way were reported as working, then failed when actually opened. The verification was real but not equivalent to the user's path.

**Rule.** Verify through the same path the user takes, or state plainly which path was tested.

### 8.3 An API reporting success is not evidence of effect

Covered in 1.5. The inert delay parameter accepted writes, read back correctly and persisted to disk. Only acoustic measurement revealed it did nothing.

**Rule.** For anything with a physical effect, close the loop with a measurement. Build a keystone test that injects a known value and confirms it is recovered.

### 8.4 A false confirmation is worse than no confirmation

At one point the syntax highlighting fix appeared confirmed because a rebuilt file opened successfully. It was coincidence; the blacklist state had changed between runs. Comparing the two files showed them to be byte equivalent in every measured respect, which is what exposed the false conclusion.

**Rule.** When a fix appears to work, check that the mechanism actually explains the result. If a supposedly fixed file and an unfixed file are identical, the fix is not what changed the outcome.

### 8.5 Shell state does not persist between separate invocations

Types added with `Add-Type` and variables set in one PowerShell invocation are gone in the next. Long debugging sessions need a helper script that is dot sourced each time rather than assuming a persistent session.

---

## 9. A note on how this was built

This project, including the audio setup, the diagnostic scripts, the measurement method and all documentation, was built collaboratively with Claude Code across a series of working sessions on the actual hardware.

That is worth stating for two reasons.

**It shapes what the documentation contains.** Nearly every entry above records something discovered by running a command and reading real output: device instance paths, bus level meters, recorded audio, registry contents, document XML internals. The findings are specific to observed behaviour rather than general advice, which is what makes them useful and also what bounds them. Figures marked *measured* were measured on one reference platform. They may differ on yours, and the project explicitly asks for reports from other hardware.

**It shaped the failures too.** Several entries in section 8 are methodology mistakes: verifying through a weaker path than real use, accepting a coincidental confirmation, and building a self reinforcing failure loop with an over aggressive test harness. They are recorded because a reproduction guide that lists only the successes is misleading about how much of this work was diagnosis rather than construction.

If you reproduce this, the most valuable thing you can contribute back is measurement from different hardware, particularly the concurrent Bluetooth stream ceiling on adapters other than the Intel 8260. See the contributing section in [REPRODUCE.md](../REPRODUCE.md).
