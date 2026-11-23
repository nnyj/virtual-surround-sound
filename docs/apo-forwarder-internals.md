# Forwarder internals

How the forwarder in `vss_apo.dll` copies the audio of a VB-Cable endpoint to a real output device, and the Windows APO rules found while building the forwarder. The forwarder follows the redirection that Sonar uses: [sonar-apo-internals.md](sonar-apo-internals.md). Bluetooth sync fix: [native-route-internals.md](native-route-internals.md).

## Overview

- ✅ The forwarder plays the cable audio on any output device, from inside the Windows audio engine.
- ✅ A device switch works live, Windows audio does not restart.
- ❌ Bluetooth headsets play late against video on this route, the native route fixes that.

## How it runs

```yml
apps: play 7.1 to CABLE Input, the default device (VB-Cable, 48 kHz, 8 ch)
stream effect (SFX): Equalizer APO pre-mix
mode effect (MFX): Equalizer APO post-mix (HeSuVi, 7.1 to headphone stereo) ➜ forwarder
forwarder: passes the audio on unchanged ➜ pushes each frame into a ring buffer
render thread: reads the ring buffer ➜ plays on the target device (WASAPI shared mode)
target device: HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId, read at LockForProcess and watched for changes
```

## Terms

- **APO:** audio processing object, an effect that `audiodg` loads into the audio engine.
- **`audiodg`:** the Windows process that runs the audio engine and all APOs.
- **Slot:** registry value in the endpoint key `FxProperties` that names the APO for one position.
- **Target device:** the real output device the forwarder plays on.

| Slot value `{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},N` | Position                 | Holds         |
| ----------------------------------------------------- | ------------------------ | ------------- |
| `,5`                                                  | Stream effect (SFX)      | One class id  |
| `,6`                                                  | Mode effect (MFX)        | One class id  |
| `,7`                                                  | Endpoint effect (EFX)    | One class id  |
| `,13`                                                 | Stream effect, composite | Class id list |
| `,14`                                                 | Mode effect, composite   | Class id list |

## Forwarder

- **In place:** the forwarder copies input to output unchanged.
- **Ring buffer:** lock-free, one writer (engine thread) and one reader (render thread).
- **Render thread:** plays through `IAudioClient3` with the minimum period when the device supports that, else through a 20 ms shared mode buffer.
- **Added latency:** ~10 ms.
- **Device switch:** the forwarder watches the config key with `RegNotifyChangeKeyValue` and restarts its stream on each write.

## COM rules of audiodg

- **Aggregation is required:** `audiodg` passes an outer unknown to `IClassFactory::CreateInstance`.
  - The APO needs an inner non-delegating `IUnknown` that owns identity and lifetime.
  - All other `IUnknown` methods delegate to the outer unknown.

- **Without aggregation:**
  - `audiodg` probes the factory (`DllGetClassObject`, `QueryInterface`, `Release`) and drops the APO without an error.
  - `audiodg` retries a few times per graph build.
  - The effect graph of the endpoint fails, `IAudioClient::Initialize` returns `E_NOTIMPL`.
  - Players then switch to another device without an error.

- **Registration:**
  - `ThreadingModel` is `Both`.
  - `HKCR\AudioEngine\AudioProcessingObjects\{clsid}` with `APOInterface0` set to `IAudioProcessingObject`.

## Slot rules

Seen on Windows 11 24H2 with VB-Cable Pack45.

- **Classic slots `,5` `,6` `,7`:**
  - A mode effect without a stream effect is ignored without an error.
  - The endpoint effect slot never loaded the forwarder on the cable endpoint.
  - A stream effect that fails is skipped. A mode effect that fails breaks the whole endpoint.

- **Composite slots `,13` `,14`:** Windows 10 1803 and later.
  - Each holds a list of class ids, Windows runs the list in order.
  - Equalizer APO post-mix and the forwarder share `,14` this way.

- **Other values the effects need:**
  - `,0` holds the null GUID.
  - `{d3993a3f-99c2-4402-b5ec-a92a0367664b},5` and `,6` hold the default processing mode GUID. Without them the effects never attach to a stream.

- **Writing `FxProperties`:** the key denies `KEY_WRITE` to admins.
  - `Set-ItemProperty` and `reg add` fail.
  - .NET `OpenSubKey` with exactly `QueryValues` and `SetValue` rights works.

- **After each change:** restart `AudioEndpointBuilder` and `audiosrv`.

## Config key

- **Value:** `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId` holds the device id of the target device.
- **Read rights:** `audiodg` runs in a restricted token. The key needs read rights for `S-1-15-2-1` and `S-1-15-2-2`, else the forwarder cannot read the key and reports no error.
- **Write rights:** Users get `QueryValues` and `SetValue`, so the route script switches devices without admin rights.
  - Plain `reg add` still fails, because `reg add` asks for full `KEY_WRITE`.

## Endpoint format, 7.1

- **Registry write fails:** `AudioEndpointBuilder` reverts a write to `PKEY_AudioEngine_DeviceFormat`.
  - The stored value is a serialized `PROPVARIANT`: 8 bytes `41 00 00 00 01 00 00 00`, then a `WAVEFORMATEXTENSIBLE`.

- **Working way:** `IPolicyConfig::SetDeviceFormat`, undocumented, the same call the Windows sound panel uses.
  - `apo/format_policy.ps1 -mode cable` makes that call.
  - The format applies without a service restart.

## Debugging traps

- **Sound plays, but the endpoint is broken:**
  - A broken APO fails the stream open. Players then switch to another device without an error.
  - `debug/tone_play.ps1` opens the endpoint by id and shows the error code.

- **Default device changes back during a test:**
  - Per-app device pins in `HKCU\...\Audio\PolicyConfig\PropertyStore` override a switch.
  - The `vss-route` task also switches devices on each device event.

- **Debug lines are missing:** the APO writes to `OutputDebugString` inside `audiodg`. DebugView shows the lines only with `Capture Global Win32`.
- **Effects are gone after a driver install:** a reinstall, for example VB-Cable Pack43 to Pack45, creates new endpoint GUIDs. The `FxProperties` values of the old endpoint are lost.
- **Effects never load:** the VB-Cable Pack43 driver (1.0.3.5, 2014) blocks all endpoint effects. Pack45 (3.3.1.7, October 2024) is required.
