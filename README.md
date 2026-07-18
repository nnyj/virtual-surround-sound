# virtual-surround-sound

<div align="center">

[![Stars](https://img.shields.io/github/stars/nnyj/virtual-surround-sound?style=for-the-badge&labelColor=555&color=e3b341)](https://github.com/nnyj/virtual-surround-sound/stargazers)
[![Downloads](https://img.shields.io/github/downloads/nnyj/virtual-surround-sound/total?style=for-the-badge&labelColor=555&color=2ea44f)](https://github.com/nnyj/virtual-surround-sound/releases)
[![Latest Release](https://img.shields.io/github/v/release/nnyj/virtual-surround-sound?style=for-the-badge&label=Latest%20Release&labelColor=555&color=3572d6)](https://github.com/nnyj/virtual-surround-sound/releases/latest)

</div>

<img src="docs/volume-osd-icon.png" width="80" align="right">

Custom Windows APO that turns a VB-Cable virtual 7.1 endpoint into a headphone surround stack: apps play to the cable, HeSuVi (Equalizer APO) convolves 7.1 to binaural, and `vss_apo.dll` forwards the result to any physical output from inside the audio engine. Device switching is live, no audio restart.

Replaces the SteelSeries Sonar dependency this repo previously wrapped, no GG software needed.

## Features

- Inline APO forwarding with ~10ms added latency, runs inside Windows Audio Engine on the RT thread
- Lock-free SPSC ring buffer bridging the DSP thread and a dedicated WASAPI render thread
- Live output device switching without audio restart, target stored in registry and watched via `RegNotifyChangeKeyValue`
- `IAudioClient3` low-latency path where available, 20ms shared mode fallback
- Volume OSD (AutoHotkey) with tray device picker and scrollable volume
- Auto-route on device plug/unplug via Task Scheduler

## How it works

```
apps (7.1) -> CABLE Input (default device)
           -> EAPO SFX (pre-mix)
           -> EAPO MFX (HeSuVi 7.1 -> binaural)
           -> vss forwarder MFX -> physical device (WASAPI)
```

The forwarder passes audio through untouched and mirrors it to the target device via a lock-free ring plus a dedicated render thread. Target device ID lives in `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId`, watched live by the APO so device switches take effect mid-stream.

Plumbing details and Windows APO registration rules: [docs/apo-forwarder-internals.md](docs/apo-forwarder-internals.md)

## Install

Prerequisites:

- Windows 10/11
- [VB-Cable](https://vb-audio.com/Cable/) Pack45 or newer (older 2014-era driver blocks all endpoint effects)
- [Equalizer APO](https://sourceforge.net/projects/equalizerapo/) + [HeSuVi](https://sourceforge.net/projects/hesuvi/)
- [AutoHotkey v2](https://www.autohotkey.com/) (volume OSD and device switching)

> [!WARNING]
> The Equalizer APO device selector overwrites the EAPO chain on CABLE Input when you re-run it. If that happens, re-run `apo\install.ps1` to restore the chain.

Steps:

1. Install VB-Cable, Equalizer APO (tick `CABLE Input` in its device selector), HeSuVi
2. Download the [latest release](../../releases), run `apo\install.bat` as admin (registers the APO, deploys to Program Files, writes the composite FX chain on CABLE Input)
3. Set CABLE Input to 7.1 in mmsys.cpl if not already
4. Pick output device: `scripts\vss-device-select.bat`
5. Optional: `tasks\import_tasks.bat` imports Task Scheduler tasks for auto-route on device plug/unplug (do not move the repo folder after import)

Uninstall: `apo\uninstall.bat`

### Building from source

Requires VS Build Tools 2022 (x64). All dependencies are Windows SDK.

```sh
cd apo
build.bat
```

Output: `apo\build\vss_apo.dll`, which is where `install.ps1` expects it.

### HeSuVi notes

- Pick an HRIR on the Virtualization tab
- If virtualization seems off, recheck `On/Off` and `Auto-Deactivate for 2 OS Channels` (latches off if CABLE was ever 2-channel)
- Verify channel routing: `debug\tone_channels.ps1` sweeps all 8 channels, rears should sound behind you

## Volume OSD

![Volume OSD](docs/volume-osd-overlay.png)

`scripts\vss-volume-osd.ahk` handles `Volume Up`/`Volume Down` and shows an overlay with the active device name.

![Tray Menu](docs/volume-osd-tray-menu.png)

- Click or right-click the tray icon to switch output device or toggle the OSD
- Scroll on the tray icon to adjust volume
- Active only when `CABLE Input` is the default device
- Ignores remote mouse focus from `PowerToys.MouseWithoutBordersHelper.exe`

## Repo layout

- `apo/` - APO source, build script, install/uninstall
- `scripts/` - device picker (console) + volume OSD (AutoHotkey)
- `tasks/` - Task Scheduler auto-route on device changes
- `debug/` - diagnostic tools (tone player, meters, FX slot dump, 7.1 format switch)
- `docs/` - forwarder internals, historical Sonar.APO analysis
- `tools/` - SoundVolumeView (see NIRSOFT_NOTICE.txt)

## Credits

- [NirSoft SoundVolumeView](https://www.nirsoft.net/utils/sound_volume_view.html): device enumeration utility
- [SteelSeries Sonar](docs/sonar-apo-internals.md): forwarding mechanism blueprint

## License

[GPL-3.0](LICENSE)
