# SteelSeries Sonar APO Device Redirection

Switch the physical output device that Sonar routes to, glitch-free.

## Why This Approach

- No SteelSeries GG running, no UI dependency
- No disable/enable endpoint cycling (causes audible pop/silence)
- Direct registry writes to the APO, same mechanism Sonar UI uses internally

## Architecture

```
App (Spotify, game, etc.)
  -> Sonar Virtual Audio Device (APO endpoint)
    -> Sonar.APO.dll (inside audiodg.exe)
      -> Physical audio device
```

- `Sonar.APO.dll` is an Audio Processing Object loaded by Windows into `audiodg.exe`
- DLL location: `C:\Program Files\SteelSeries\GG\sonar\driver\apoDriverPackage\Sonar.APO.dll`
- All IPC between SteelSeriesSonar.exe and the APO is through the registry (no HTTP, no pipes, no shared memory)

## Registry Layout

Base path: `HKLM\SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings\`

```
GlobalControl\
  Store\                          <- persistent keys (survive reboot)
    kSet_StreamRedirectionState      REG_DWORD   1 = enabled
    kSet_StreamRedirectionDeviceIdCount  REG_DWORD   56 (byte count of device ID)
    kSet_StreamRedirectionDeviceId   REG_BINARY  UTF-16LE + null terminator of device GUID
Streams\
  {streamId}\                     <- VOLATILE keys (created by audiodg per audio stream)
    kSet_StreamRedirectionState      same as above
    kSet_StreamRedirectionDeviceIdCount  same as above
    kSet_StreamRedirectionDeviceId   same as above
    ModifiedRender                   REG_BINARY  28-byte bitset (224 bits)
```

- Stream subkey names are volatile, change every session, exist only while audio is playing
- Device ID is the device ItemID encoded as UTF-16LE with null terminator, stored as REG_BINARY
- `kSet_StreamRedirectionDeviceIdCount` is always 56 (byte count, not char count)

## How the APO Reads Settings

1. APO polls `ModifiedRender` every ~30ms via `RegQueryValue`
2. `ModifiedRender` is a 28-byte bitset where each bit maps to a `kSet_*` setting
3. Non-zero bits trigger the APO to re-read corresponding `kSet_*` values from the stream key
4. After processing, APO resets `ModifiedRender` to all zeros
5. Runtime reads come from `Streams\{id}\` (volatile), NOT `GlobalControl\Store\`
6. `GlobalControl\Store\` is persistence only (loaded on boot)

## Solution

Write redirection values to both `GlobalControl\Store` (persistence) and every active `Streams\{id}` (live), then set all bits in `ModifiedRender` to signal the APO.

```batch
rem 1. Persist to GlobalControl\Store
reg add "HKLM\...\GlobalControl\Store" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f
reg add "HKLM\...\GlobalControl\Store" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d 56 /f
reg add "HKLM\...\GlobalControl\Store" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d %hex% /f

rem 2. Write to every active stream + signal ModifiedRender (volatile, .NET required)
powershell -NoProfile -Command "
  ... foreach stream:
    SetValue('kSet_StreamRedirectionState', 1, 'DWord')
    SetValue('ModifiedRender', [all 0xFF, 28 bytes], 'Binary')
    SetValue('kSet_StreamRedirectionDeviceIdCount', 56, 'DWord')
    SetValue('kSet_StreamRedirectionDeviceId', $bytes, 'Binary')
"

rem 3. Ensure Sonar is the default device
soundvolumeview /SetDefault "SteelSeries Sonar Virtual Audio Device\...\Render" 0
soundvolumeview /SetDefault "SteelSeries Sonar Virtual Audio Device\...\Render" 2
```

- `ModifiedRender` all-FF signals "settings changed, re-read everything"
- APO polls every ~30ms so all writes complete before it reads
- `reg.exe` cannot access volatile keys, must use .NET `[Microsoft.Win32.Registry]`
- `SetDefault` (both 0 and 2) ensures Windows routes audio through the Sonar endpoint

## Other Sonar Channels

Same pattern exists for other channels:
- `ChatRender\Settings\` - Chat
- `ChatCapture\Settings\` - Mic
- `Settings\` - Media (multi-channel mode)

Each has its own `GlobalControl\Store\`, `Streams\`, and `NotificationClients\`.

## Tools Required

- `soundvolumeview.exe` (NirSoft) for enumerating devices and setting defaults
- PowerShell with .NET (`[Microsoft.Win32.Registry]`) for volatile key access
- `reg.exe` for `GlobalControl\Store` (persistent keys) only
