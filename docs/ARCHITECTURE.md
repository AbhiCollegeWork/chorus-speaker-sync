# How Chorus Works: A Visual Guide

This document explains the system in diagrams, starting from the problem and working down to the mechanism. It is written for someone meeting the project for the first time, so it assumes no prior knowledge of Bluetooth audio, Voicemeeter, or signal processing.

If you only read one section, read [the problem in one picture](#1-the-problem-in-one-picture). Everything else follows from it.

---

## Contents

1. [The problem in one picture](#1-the-problem-in-one-picture)
2. [What calibration actually changes](#2-what-calibration-actually-changes)
3. [The system stack](#3-the-system-stack)
4. [Where the milliseconds go](#4-where-the-milliseconds-go)
5. [The signal path in detail](#5-the-signal-path-in-detail)
6. [Why only two Bluetooth speakers](#6-why-only-two-bluetooth-speakers)
7. [The radio contention problem](#7-the-radio-contention-problem)
8. [Choosing a transport](#8-choosing-a-transport)
9. [How the measurement works](#9-how-the-measurement-works)
10. [Solving for the delays](#10-solving-for-the-delays)
11. [The full calibration sequence](#11-the-full-calibration-sequence)
12. [What can go wrong at runtime](#12-what-can-go-wrong-at-runtime)
13. [Troubleshooting as a decision tree](#13-troubleshooting-as-a-decision-tree)

---

## 1. The problem in one picture

You press play. Both speakers receive the same audio at the same instant. They do **not** produce sound at the same instant.

```mermaid
gantt
    title Uncalibrated: one drum hit, two arrival times
    dateFormat SSS
    axisFormat %L ms
    todayMarker off

    section PC
    Audio sample leaves the PC        :milestone, src, 000, 0ms

    section PartyPal 185
    Encode, transmit, decode, amplify  :done, pp, 000, 176ms
    SOUND ARRIVES                      :milestone, crit, ppa, 176, 0ms

    section Stone 1400
    Encode, transmit, decode, amplify  :active, st, 000, 218ms
    SOUND ARRIVES                      :milestone, crit, sta, 218, 0ms
```

The two speakers are **42 ms apart**. That gap is what you hear as a doubled attack on drums, or a hollow echo on dialogue.

Why does it happen? Each speaker runs its own encoder, its own radio buffer, its own decoder, and its own amplifier. None of that is synchronised between manufacturers, or even between two models from the same manufacturer. The delay is a property of the specific speaker, and there is no standard that makes them agree.

| Gap between speakers | What you hear |
|---|---|
| 0 to 10 ms | One sound. Correct. |
| 10 to 25 ms | Slightly wider, mild hollowness. Usually fine. |
| 25 to 50 ms | A distinct doubled hit on percussion. This example sits here. |
| Over 50 ms | Obvious echo. Unusable. |

**The cruel part:** your ear can tell that something is wrong, but it cannot tell you *which speaker is early*. Below about 30 ms, human hearing fuses the two sounds and discards the ordering. That is why dragging a delay slider by ear turns into blind guesswork, and it is the reason this project exists.

---

## 2. What calibration actually changes

Chorus measures both arrival times, then holds the faster speaker back so both land together.

```mermaid
gantt
    title Calibrated: the fast speaker is delayed to meet the slow one
    dateFormat SSS
    axisFormat %L ms
    todayMarker off

    section PC
    Audio sample leaves the PC         :milestone, src2, 000, 0ms

    section PartyPal 185
    Chorus holds it back 42 ms         :crit, hold, 000, 42ms
    Encode, transmit, decode, amplify  :done, pp2, 042, 176ms
    SOUND ARRIVES                      :milestone, crit, ppa2, 218, 0ms

    section Stone 1400
    Encode, transmit, decode, amplify  :active, st2, 000, 218ms
    SOUND ARRIVES                      :milestone, crit, sta2, 218, 0ms
```

Both now arrive at 218 ms. The echo is gone.

Two things follow from this picture, and they are the most commonly misunderstood parts of the project:

**Chorus does not make Bluetooth faster.** Everything still arrives 218 ms late. Absolute latency is a property of the transport and cannot be removed. What matters perceptually is only the *difference* between speakers, and that is what gets fixed.

**Delay can only be added, never removed.** There is no way to make the Stone arrive sooner, so the slowest speaker sets the pace and everything faster is held back to meet it. The slowest output always receives a delay of zero. This is why calibration appears to "only change one speaker".

---

## 3. The system stack

Audio does not go from your player to your speaker directly. It passes through five layers, and Chorus operates at exactly one of them.

```mermaid
block-beta
  columns 5

  app["Spotify / VLC / Netflix<br/><i>any application</i>"]:5

  space:5

  win["Windows audio stack<br/>default output device points at the virtual input"]:5

  space:5

  vaio["Voicemeeter virtual input (VAIO)<br/><i>a sound card that exists only in software</i>"]:5

  space:5

  eng["Voicemeeter Potato engine<br/>per output: gain, mute, DELAY"]:5

  space:5

  a1["Bus A1<br/>Bluetooth"] a2["Bus A2<br/>Bluetooth"] a3["Bus A3<br/>Miracast"] a4["Bus A4<br/>HDMI"] a5["Bus A5<br/>Analog"]

  space:5

  s1["Speaker 1"] s2["Speaker 2"] s3["Tablet"] s4["TV / AVR"] s5["Laptop"]

  app --> win
  win --> vaio
  vaio --> eng
  eng --> a1
  eng --> a2
  eng --> a3
  eng --> a4
  eng --> a5
  a1 --> s1
  a2 --> s2
  a3 --> s3
  a4 --> s4
  a5 --> s5

  style eng fill:#1e3a5f,color:#fff
  style vaio fill:#2c5282,color:#fff
```

The key idea is the **virtual input**. Voicemeeter installs a device that Windows believes is a sound card. Applications play to it normally, with no special support required. Instead of driving a physical speaker, that device hands the audio to the Voicemeeter engine, which can then copy it to five real outputs at once and apply an independent delay to each.

Chorus is the control layer that drives the engine, measures the result, and computes the delays. It is not itself in the audio path.

---

## 4. Where the milliseconds go

The 218 ms is not one thing. It accumulates across the whole chain.

```mermaid
xychart-beta
    title "Latency contribution by stage, Bluetooth path"
    x-axis ["App buffer", "Windows mixer", "Virtual device", "Engine buffer", "Bluetooth transport"]
    y-axis "milliseconds" 0 --> 200
    bar [25, 10, 5, 21, 150]
```

| Stage | Typical | Can Chorus change it? |
|---|---|---|
| Application buffer | 10 to 40 ms | No |
| Windows shared mixer | about 10 ms | No |
| Virtual device to engine | about 5 ms | No |
| Engine output buffer | 11, 21 or 43 ms | **Yes**, this is the buffer size setting |
| Bluetooth encode, transmit, decode, amplify | 100 to 200 ms | No |

Only one bar is under our control, and increasing it is often the right move. A larger buffer holds more audio in reserve, which lets playback ride through brief radio interference instead of dropping out.

```mermaid
xychart-beta
    title "Engine buffer: latency cost against dropout resilience"
    x-axis ["512 samples", "1024 samples", "2048 samples"]
    y-axis "milliseconds added" 0 --> 50
    bar [11, 21, 43]
    line [11, 21, 43]
```

Because Chorus equalises the *relative* timing afterwards, the extra latency from a big buffer costs you nothing perceptually for music and film. It would matter for gaming or live monitoring, which this project explicitly does not target.

---

## 5. The signal path in detail

The same journey, with the mechanism at each hop rather than just the timing.

```mermaid
flowchart TB
    subgraph SW["Software, on the PC"]
        direction TB
        A["Application produces PCM samples"]
        B["Windows shared mixer<br/>resamples and mixes all apps"]
        C["Virtual audio device<br/>presents as a sound card"]
        D["Engine input strip<br/>the single source everything is copied from"]
    end

    subgraph BUS["Per output processing, independent for each bus"]
        direction TB
        E1["Gain<br/>balance a loud speaker against a quiet one"]
        E2["Mute"]
        E3["DELAY LINE<br/>0 to 500 ms, this is what calibration sets"]
        E4["Output buffer<br/>WDM or MME, absorbs interference"]
    end

    subgraph TX["Transport, outside our control"]
        direction TB
        F["Codec encode<br/>SBC, about 345 kbps"]
        G["2.4 GHz radio<br/>shared with Wi-Fi"]
        H["Speaker: decode, DAC, amplifier"]
    end

    I(("Sound in<br/>the room"))
    MIC["Microphone"]
    CAL["Chorus calibration engine"]

    A --> B --> C --> D
    D -->|"copied to every enabled bus"| E1
    E1 --> E2 --> E3 --> E4
    E4 --> F --> G --> H --> I
    I -.->|"measure what actually arrived"| MIC
    MIC -.-> CAL
    CAL -.->|"set delay, verify, restart engine"| E3

    style E3 fill:#1e3a5f,color:#fff
    style CAL fill:#2c5282,color:#fff
    style I fill:#4a5568,color:#fff
```

The dotted path is the entire point of the project. Every other tool in this space stops at the solid arrows, leaving the delay line to be set by hand. Chorus closes the loop through the room itself, which is the only way to learn the true arrival time of a specific speaker in a specific place.

---

## 6. Why only two Bluetooth speakers

This is the question everyone asks, and the answer is a hard limit rather than a missing feature.

```mermaid
flowchart TB
    subgraph WIN["Windows"]
        STACK["Bluetooth stack"]
        R1["Built in adapter<br/>ACTIVE"]
        R2["USB dongle 2<br/>IDLE, cannot be used at the same time"]
        R3["USB dongle 3<br/>IDLE, cannot be used at the same time"]
        STACK --> R1
        STACK -.->|"not usable concurrently"| R2
        STACK -.->|"not usable concurrently"| R3
    end

    subgraph BW["That one radio's audio budget"]
        S1["Stream 1<br/>about 345 kbps"]
        S2["Stream 2<br/>about 345 kbps"]
        S3["Stream 3<br/>UNVERIFIED"]
    end

    R1 --> S1
    R1 --> S2
    R1 -.->|"untested territory"| S3

    subgraph LIN["Linux with BlueZ, for comparison"]
        BZ["BlueZ"]
        H0["hci0 ACTIVE"]
        H1["hci1 ACTIVE"]
        H2["hci2 ACTIVE"]
        BZ --> H0
        BZ --> H1
        BZ --> H2
    end

    style R2 fill:#742a2a,color:#fff
    style R3 fill:#742a2a,color:#fff
    style S3 fill:#744210,color:#fff
    style H1 fill:#22543d,color:#fff
    style H2 fill:#22543d,color:#fff
```

Three separate facts stack up here:

**Windows uses one Bluetooth radio at a time.** Buying USB dongles does not help. The additional adapters do not become usable alongside the built in one, and the vendor guidance is to disable the internal adapter before using an external one.

**Each stereo audio stream costs roughly 345 kbps** of that single radio's shared bandwidth, plus its own scheduling slots.

**Two streams are verified working** on the reference adapter, an Intel Wireless-AC 8260. Three or more has not been tested, so the project does not claim it. If you try it, the documentation asks you to report what happened.

Beware the widely repeated claim that Bluetooth supports seven devices. That figure is about *pairing* capacity. Audio *streaming* is bandwidth bound and the real limit is far lower. Confusing the two is the single most common error in community write ups on this subject.

To go beyond the ceiling you either mix transports, which is what the five buses are for, or move to Linux where BlueZ can drive several adapters independently.

---

## 7. The radio contention problem

Almost every dropout report traces back to this diagram.

```mermaid
flowchart LR
    subgraph BAND["The 2.4 GHz band, one shared antenna on most laptops"]
        direction TB
        WIFI["Wi-Fi to your router<br/>bursty, high bandwidth"]
        MIRA["Miracast to a tablet<br/>CONTINUOUS VIDEO, the worst offender"]
        BT1["Bluetooth speaker 1"]
        BT2["Bluetooth speaker 2"]
        OTHER["Idle earbuds, smartwatch,<br/>game controller"]
    end

    COLLIDE{{"Collisions and retransmissions"}}
    DROP["Audio dropout<br/>you hear a gap"]

    WIFI --> COLLIDE
    MIRA --> COLLIDE
    BT1 --> COLLIDE
    BT2 --> COLLIDE
    OTHER --> COLLIDE
    COLLIDE --> DROP

    FIX1["Move Wi-Fi to 5 GHz<br/>THE REAL FIX"]
    FIX2["Disconnect Miracast"]
    FIX3["Raise the engine buffer"]
    FIX4["Turn off idle BT gadgets"]

    DROP -.-> FIX1
    DROP -.-> FIX2
    DROP -.-> FIX3
    DROP -.-> FIX4

    style MIRA fill:#742a2a,color:#fff
    style FIX1 fill:#22543d,color:#fff
    style DROP fill:#744210,color:#fff
```

During development, dropouts every 40 to 80 seconds were chased through adapter power settings, USB selective suspend, Wi-Fi roaming aggressiveness, and three different buffer sizes. Each change helped a little. The actual cause was a Miracast session to a tablet, streaming video over Wi-Fi Direct on the same band. Disconnecting it stopped the dropouts completely.

**A two minute test that settles it.** Play a locally stored track, then turn Wi-Fi off entirely and listen. If the dropouts stop, it is band contention, and no audio setting will fully fix it. Moving your router and PC to 5 GHz is the real answer.

---

## 8. Choosing a transport

Chorus supports five outputs, but they are not interchangeable. This is how to pick.

```mermaid
flowchart TD
    START(["I want to add an output"]) --> Q1{"Does it need<br/>to be wireless?"}

    Q1 -->|No| WIRED{"Is a cable<br/>practical?"}
    WIRED -->|Yes, to a TV or receiver| HDMI["HDMI<br/>under 10 ms, up to 8 channels<br/>BEST QUALITY AND TIMING"]
    WIRED -->|Yes, to powered speakers| ANALOG["Analog jack<br/>under 10 ms"]

    Q1 -->|Yes| Q2{"How many Bluetooth<br/>outputs already?"}
    Q2 -->|"0 or 1"| BT["Bluetooth A2DP<br/>150 to 250 ms, needs calibration<br/>SAFE"]
    Q2 -->|"2"| WARN["Bluetooth A2DP<br/>PAST THE VERIFIED CEILING<br/>expect dropouts, please report results"]
    Q2 -->|"Need another wireless output"| Q3{"Is it a tablet<br/>or a TV?"}

    Q3 -->|Yes| MIRA["Miracast<br/>200 to 500 ms<br/>WARNING: saturates 2.4 GHz<br/>and will hurt your Bluetooth audio"]
    Q3 -->|No| STUCK["No good option<br/>consider the Linux path"]

    HDMI --> CAL(["Run calibration"])
    ANALOG --> CAL
    BT --> CAL
    WARN --> CAL
    MIRA --> CAL

    style HDMI fill:#22543d,color:#fff
    style BT fill:#2c5282,color:#fff
    style WARN fill:#744210,color:#fff
    style MIRA fill:#742a2a,color:#fff
```

A detail that matters more than it sounds: **always identify a device by its Windows instance path, not its friendly name.**

| Transport | Instance path signature |
|---|---|
| Bluetooth stereo, what you want | `BTHENUM\{0000110B-...}` |
| Bluetooth hands free, avoid for music | `BTHENUM\{0000111E-...}` or `BTHHFENUM\` |
| Miracast | `SWD\WIFIDIRECT\...#MIRACAST` |

Every Bluetooth speaker appears twice in Windows, once as "Headphones (Name Stereo)" and once as "Headset (Name Hands-Free AG Audio)". The second is the telephone call profile: mono, roughly 8 kHz, and it sounds broken for music. The names are nearly identical and the wrong one is easy to pick.

During development, a setup that appeared to prove three simultaneous Bluetooth speakers turned out, on inspecting the instance paths, to be two Bluetooth speakers plus a Miracast tablet. Friendly names hid the difference.

---

## 9. How the measurement works

To learn a speaker's true latency you have to hear it. Chorus plays a test sound through one speaker at a time and records the room.

```mermaid
flowchart LR
    subgraph GEN["1. Generate"]
        G1["1 kHz sine burst<br/>8 ms long"]
        G2["Linear decay envelope<br/>sharp attack, no ringing tail"]
        G3["Repeat every 700 ms<br/>8 or more times"]
        G1 --> G2 --> G3
    end

    subgraph PLAY["2. Isolate"]
        P1["Mute every other output"]
        P2["Wait 1.5 s for the<br/>transport to settle"]
        P1 --> P2
    end

    subgraph CAP["3. Capture"]
        C1["Record via microphone<br/>22.05 kHz mono"]
        C2["Amplitude envelope<br/>5 ms windows, peak value"]
        C1 --> C2
    end

    subgraph DET["4. Detect"]
        D1["Adaptive threshold<br/>max(noise x 3, peak x 0.10)"]
        D2["200 ms refractory period<br/>ignores room reflections"]
        D3["Median phase across all clicks<br/>rejects a dropped packet"]
        D1 --> D2 --> D3
    end

    GEN --> PLAY --> CAP --> DET
    DET --> OUT["latency for this speaker"]

    style OUT fill:#1e3a5f,color:#fff
```

Each design choice has a reason:

| Choice | Why |
|---|---|
| 1 kHz tone | Sits inside both speaker output range and microphone sensitivity, and avoids low frequency room resonance that smears the start of the sound |
| 8 ms burst | Long enough to detect reliably, short enough to pin down exactly when it began |
| Linear decay | A sharp attack with no ringing tail, so reflections do not look like new clicks |
| 700 ms spacing | Longer than the room's echo, short enough to collect many samples quickly |
| Median, not average | One dropped Bluetooth packet cannot skew the result |
| Refractory period | A wall reflection arriving 30 ms later is not counted as a second click |

The microphone should sit roughly equidistant from your speakers. Sound travels about **2.92 ms per metre**, so a microphone one metre closer to one speaker makes that speaker look 3 ms faster than it is.

---

## 10. Solving for the delays

Once every speaker has a measured latency, the arithmetic is short.

```mermaid
flowchart TB
    M["Measured latencies<br/>PartyPal 176 ms<br/>Stone 218 ms<br/>HDMI 8 ms"]

    M --> DIST["Subtract microphone distance<br/>distance in metres / 343 x 1000"]

    DIST --> ANCHOR["Find the SLOWEST output<br/>anchor = max(latency) = 218 ms<br/><i>because delay can only be added</i>"]

    ANCHOR --> SOLVE["For each output:<br/>delay = anchor - its latency"]

    SOLVE --> R1["PartyPal: 218 - 176 = <b>42 ms</b>"]
    SOLVE --> R2["Stone: 218 - 218 = <b>0 ms</b><br/><i>the anchor, never delayed</i>"]
    SOLVE --> R3["HDMI: 218 - 8 = <b>210 ms</b>"]

    R1 --> APPLY["Write all delays<br/>restart the engine ONCE<br/>re-assert the outputs"]
    R2 --> APPLY
    R3 --> APPLY

    APPLY --> VERIFY["Measure everything again"]

    VERIFY --> CHECK{"spread =<br/>max - min"}
    CHECK -->|"10 ms or less"| PASS["PASS, save the profile"]
    CHECK -->|"10 to 25 ms"| MARG["MARGINAL, save with a warning"]
    CHECK -->|"over 25 ms"| FAIL["FAIL, change nothing<br/>report which output and why"]

    style ANCHOR fill:#1e3a5f,color:#fff
    style PASS fill:#22543d,color:#fff
    style FAIL fill:#742a2a,color:#fff
```

Note the last branch. **A failed calibration must leave the system exactly as it was.** Half applied delays would leave you worse off than before while appearing configured, so the profile is only written once a verification pass confirms the result.

The verification pass is not ceremony. The engine will happily report success for a delay that has no audible effect, which is exactly what happened during development with a parameter that accepted values, stored them, read them back correctly, and did nothing at all. Only re-measuring caught it.

---

## 11. The full calibration sequence

Putting sections 9 and 10 together, with the awkward engine behaviour that the implementation has to work around.

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as Chorus
    participant E as Audio engine
    participant S as Speakers
    participant M as Microphone

    U->>C: run calibration
    C->>C: check mic present and not clipping
    C->>C: check at least two outputs connected
    C->>C: synthesise the click train

    loop for each connected output
        C->>E: mute every other output
        Note over C,E: every write is read back and retried,<br/>the engine silently drops about a third<br/>of writes made just after connecting
        C->>C: wait 1.5 s for the transport to settle
        C->>S: play the click train on this output only
        S-->>M: sound travels through the room
        M->>C: recorded audio
        C->>C: envelope, onset detection, median phase
    end

    C->>C: correct for microphone distance
    C->>C: anchor on the slowest, solve the delays

    rect rgb(240, 240, 245)
        Note over C,E: applying delays, the fragile part
        C->>E: write every delay (verified individually)
        Note over C,E: readback for this parameter always returns zero,<br/>so verification saves engine state to disk<br/>and parses the value back
        C->>E: restart the engine ONCE
        Note over E,S: a restart silently drops bus device assignments,<br/>which is the most common cause of<br/>"one speaker stopped working"
        C->>E: re-assert every bus device
        C->>E: confirm signal present on each bus
    end

    C->>S: verification pass, measure again
    S-->>M: sound
    M->>C: recorded audio

    alt spread within 10 ms
        C->>U: PASS, synced within N ms, profile saved
    else spread too large
        C->>U: FAIL, nothing changed, here is which output and why
    end
```

The grey block is where the implementation earns its keep. Three separate engine quirks live in that short stretch, all discovered the hard way and all documented in [BUILD-NOTES](BUILD-NOTES.md).

---

## 12. What can go wrong at runtime

Wireless outputs disappear routinely. That is the medium, not a bug, so the system treats it as an expected state rather than an error.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Unassigned

    Unassigned --> Assigned: pick a device

    state Assigned {
        direction LR
        [*] --> Silent
        Silent --> Live: enable routing
        Live --> Silent: mute or disable
        Live --> Measuring: calibration solos it
        Measuring --> Live: pass complete
    }

    Assigned --> Orphaned: speaker powered off,<br/>out of range,<br/>or the engine restarted
    Orphaned --> Assigned: repair, device is back
    Orphaned --> Unassigned: clear the assignment
    Assigned --> Unassigned: clear
```

**Orphaned is the state that matters.** When a speaker switches off, or the audio engine restarts, the bus keeps its configuration but loses its actual device. The engine reports no error. Nothing appears in a log. The only symptom is one silent speaker.

Detecting and naming this state is what makes a one command repair possible, and it is why the level meters in the control panel exist. A meter is the only thing that distinguishes "the software believes this output is fine" from "sound is genuinely reaching the device".

---

## 13. Troubleshooting as a decision tree

```mermaid
flowchart TD
    START(["Something is wrong"]) --> Q0{"Any sound<br/>at all?"}

    Q0 -->|"No sound anywhere"| N1{"Is the engine<br/>running?"}
    N1 -->|No| N2["Start Voicemeeter Potato<br/>and check it is the Potato edition"]
    N1 -->|Yes| N3{"Is Windows output<br/>set to the virtual input?"}
    N3 -->|No| N4["speaker-mode.ps1 theatre"]
    N3 -->|Yes| N5["fix-speakers.ps1"]

    Q0 -->|"One speaker silent"| S1{"Does Windows show it<br/>as Connected?"}
    S1 -->|No| S2["Power cycle the speaker,<br/>wait for it to reconnect"]
    S1 -->|Yes| S3["fix-speakers.ps1<br/><i>the bus lost its device,<br/>see section 12</i>"]

    Q0 -->|"Sound cuts out repeatedly"| D1{"Is a tablet or TV<br/>connected as a<br/>wireless display?"}
    D1 -->|Yes| D2["Disconnect it and retest<br/>THIS IS USUALLY THE CAUSE"]
    D1 -->|No| D3{"Is your Wi-Fi<br/>on 2.4 GHz?"}
    D3 -->|Yes| D4["Move the router and PC to 5 GHz<br/>THE REAL FIX"]
    D3 -->|No| D5["Raise the engine buffer to 2048,<br/>switch WDM to MME,<br/>move speakers closer"]

    Q0 -->|"Echo or doubled hits"| E1{"Has calibration<br/>ever been run?"}
    E1 -->|No| E2["Run calibration"]
    E1 -->|Yes| E3{"Did anything change?<br/>new speaker, buffer size,<br/>codec after a firmware update"}
    E3 -->|Yes| E2
    E3 -->|No| E4["Re-run calibration,<br/>check the microphone is<br/>equidistant from the speakers"]

    Q0 -->|"Telephone quality audio"| H1["The hands free endpoint got picked.<br/>Reassign the bus to the<br/>Stereo endpoint, see section 8"]

    Q0 -->|"Delay setting does nothing"| P1["You used the per channel EQ delay.<br/>Use the System Settings output delay<br/>and restart the engine"]

    style D2 fill:#742a2a,color:#fff
    style D4 fill:#22543d,color:#fff
    style S3 fill:#2c5282,color:#fff
```

---

## Where to go next

| You want to | Read |
|---|---|
| Build this yourself, step by step | [REPRODUCE.md](../REPRODUCE.md) |
| Understand a specific problem in depth | [BUILD-NOTES.md](BUILD-NOTES.md) |
| Use the system day to day | [USER-MANUAL.md](USER-MANUAL.md) |
| See the full engineering specification | [TRD.md](TRD.md) |
| Understand the design intent and scope | [PRD.md](PRD.md) |
