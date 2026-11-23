# Native route internals

How `Bluetooth sync fix` keeps video in sync on Bluetooth headsets. Forwarder and effect slot basics: [apo-forwarder-internals.md](apo-forwarder-internals.md).

## Overview

- ✅ Video is in sync on Bluetooth headsets, because apps play to the headset itself.
- ✅ 7.1 and HeSuVi still work, because the native APO runs HeSuVi on the headset.
- ❌ Tested with Microsoft Bluetooth and USB audio drivers only.

## How it runs

```yml
cable route: app ➜ CABLE Input (default device) ➜ HeSuVi ➜ forwarder ➜ target device
native route: app ➜ headset (default device) ➜ native APO (HeSuVi inside) ➜ Windows mix ➜ headset driver
route choice: native route when the headset has the native APO, else cable route
turn on: tray item Bluetooth sync fix ➜ vss-device-select.bat native on "<device id>" ➜ install.ps1 -endpoint {guid} ➜ route again
turn off: tray item ➜ vss-device-select.bat native off "<device id>" ➜ install.ps1 -endpoint {guid} -remove ➜ route again
dry run: vss-device-select.bat auto "" "" "" dry-run prints device, route and Bluetooth flag, writes nothing
```

## Terms

- **Native APO:** second class in `vss_apo.dll`. Takes 1 to 8 ch in, gives 2 ch out.
- **Forwarder:** first class in `vss_apo.dll`. Sits on `CABLE Input`, copies the cable audio to the target device.
- **Stream effect slot:** registry value of one endpoint. Windows runs the effect in this slot once per app stream, before Windows mixes the apps.
- **Audio clock lag:** frames an app wrote, minus the position the driver reports (`IAudioClock::GetPosition`).

| Thing                  | Id                                                            |
| ---------------------- | ------------------------------------------------------------- |
| Native APO class       | `{7C1E5A42-5D0B-4E0C-9B7A-6F3B2D9E8A11}`                      |
| Stream effect slot     | `{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5` in `FxProperties`  |
| Equalizer APO pre-mix  | `{EACD2258-FCAC-4FF4-B36D-419E924A6D79}`                      |
| Equalizer APO post-mix | `{EC1CC9CE-FAED-4822-828A-82A81A6F018F}`                      |
| Bluetooth test         | `{b3f8fa53-0004-438e-9003-51a46e139bfc},2` contains `BTHENUM` |

## Why the cable route is late on Bluetooth

- Players delay the video by the audio clock lag.
- The lag comes from the driver of the device the app opened.
  | App opens     | Lag holds the headset delay | Result                                |
  | ------------- | --------------------------- | ------------------------------------- |
  | Headset       | ✅                          | In sync                               |
  | `CABLE Input` | ❌                          | Video runs ahead by the headset delay |

- The forwarder plays a second stream on the headset. Windows does not link the clock of that stream to the cable clock.
- **The cable cannot report the delay:**
  - The value an APO returns from `GetLatency` does not reach `GetPosition` or `GetStreamLatency`.
  - The VB-Cable latency setting does not move the cable clock.
  - Other virtual cables lack a setting for a reported delay.
  - Only an own signed kernel driver could report a late position.

## Native APO

- **Place:** stream effect slot of the headset. Each app stream gets its own copy, with its own HeSuVi.
- **Flags:** not in-place, because the channel count changes from input to output.
- **7.1 for apps:**
  - The native APO tells Windows that the native APO prefers 8 ch input (`IAudioProcessingObjectPreferredFormatSupport`).
  - Windows then shows the headset to apps as an 8 ch device (`IAudioClient::GetMixFormat`).
  - Windows asks for the preferred format only when the device format is set. `format_policy.ps1 -mode native` sets the current device format again.
  - `IPolicyConfig::GetMixFormat` still shows 2 ch after that call.

- **Input:** 1, 2, 6 or 8 ch float32. With 8 ch only, Firefox retries every second and stays silent.
- **Output:** 2 ch float32 only.
- **HeSuVi inside:**
  - The native APO creates two Equalizer APO classes itself: pre-mix (HeSuVi stereo upmix), then post-mix (HeSuVi HRIR).
  - Each stage gets a copy of the init data of the native APO, with the class id replaced.
  - Equalizer APO picks its stage from that class id, so the HeSuVi config applies unchanged.
  - Windows must pass init data of exactly `sizeof(APOInitSystemEffects)`, else the native APO does not create the stages.
  - Each stage writes 8 ch into its own buffer. A stage that fails is skipped.
  - The native APO outputs FL and FR of the last buffer. HeSuVi writes the headphone result to FL and FR.

- **Fallback:** plain downmix, fronts plus 0.7 × centre, back and side channels. LFE is dropped.
  - Used when the post-mix stage is not locked.
  - Used when one period holds more frames than the stage buffers.

## Routes

| Route  | Default device | `TargetDeviceId` | Forwarder               |
| ------ | -------------- | ---------------- | ----------------------- |
| Cable  | `CABLE Input`  | Target device id | Plays to the target     |
| Native | The headset    | Empty            | Stops its second stream |

- A headset with the native APO never takes the cable route. The forwarder stream would run through the native APO and HeSuVi a second time.

## Install

- **On:** `install.ps1 -endpoint '{guid}'`, needs admin.
  - Fails when the native APO class is not registered. `install.ps1` without arguments registers both classes.
  - Saves the old slot value in `HKLM\SOFTWARE\VirtualSurroundSound\NativeSaved`. An empty value means the slot was absent.
  - Writes the native APO class into the slot.
  - Restarts Windows audio, then runs `format_policy.ps1 -mode native`.

- **Off:** `install.ps1 -endpoint '{guid}' -remove` writes the saved value back, or deletes the slot.
- **Uninstall:** `uninstall.ps1` does the same for every headset, then removes both classes, the config key and the dll.
- **Format call:** without `format_policy.ps1 -mode native` the headset stays at 2 ch after install and at 8 ch after removal.
- **`NativeSaved` rights:** only admins write. A normal user must not choose the class that an admin restores later.
- **Elevation:** only the tray click elevates. The scheduled task runs without admin rights and uses mode `auto` only.

## Dead ends

| Tried                                                    | Result                                                                |
| -------------------------------------------------------- | --------------------------------------------------------------------- |
| Native APO in mode effect slot `,6`                      | `IAudioClient::Initialize` fails with `0x887C001E`, Bluetooth and USB |
| Native APO in endpoint effect slot `,7`                  | Windows does not create the APO on the A2DP + Hands-Free endpoint     |
| Equalizer APO as own entry before the native APO (`,13`) | Windows asks the native APO for 2 ch input, drops the 8 ch suggestion |
| `IAudioSystemEffectsCustomFormats`                       | Windows does not call `GetFormatCount` in `,6`                        |
| `SetDeviceFormat` with an 8 ch device format             | Fails with `0x88890008`                                               |
| `ResetDeviceFormat` after removal                        | Leaves an 8 ch mix format, use `format_policy.ps1 -mode native`       |
| `New-Item -Force` on an existing registry key            | Deletes the values and subkeys of the key                             |

## Measured

Sony Bluetooth earbuds, Microsoft Bluetooth driver, release dll.

| Measurement, ms                                | Result    |
| ---------------------------------------------- | --------- |
| Real delay of the earbuds                      | 258       |
| Audio clock lag of the earbuds                 | 249       |
| Firefox offset, earbuds without the native APO | 99 to 112 |
| Firefox offset, native route                   | 99, 109   |
| Vivaldi offset, native route                   | 109, 110  |

- **Offset:** browser media time when the microphone hears a click, minus the media time of the click. The same offset as without the native APO means in sync.
- **Other devices:** a Sony over-ear Bluetooth headset works by ear. The fallback downmix works on a USB audio codec.

## Check a headset

`debug/channel_check.ps1 -id '{0.0.0.00000000}.{guid}'` plays a tone on each of the 8 channels and prints the headset peak per channel. `debug/endpoint_list.ps1` prints the guids. A microphone is not needed.

| Peaks                                    | Meaning                            |
| ---------------------------------------- | ---------------------------------- |
| Centre and surround above 0, LFE above 0 | HeSuVi runs, seen on the earbuds   |
| Centre and surround above 0, LFE 0       | Fallback downmix                   |
| Centre and surround 0                    | Equalizer APO runs with HeSuVi off |

- **Proof that the stages run:** debug lines `hosted Equalizer APO stage created` and `hosted Equalizer APO stage lock` with `hr=0x00000000`, read with DebugView.
