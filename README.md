# Virtual Surround Sound

<img src="docs/volume-osd-icon.png" width="80" align="right">

Custom Windows APO that turns a VB-Cable virtual 7.1 endpoint into a headphone surround stack: apps play to the cable, HeSuVi (Equalizer APO) convolves 7.1 to binaural, and `vss_apo.dll` forwards the result to any physical output from inside the audio engine (~10ms added latency). Device switching is live, no audio restart.

Replaces the SteelSeries Sonar dependency this repo previously wrapped, no GG software needed.

## How it works

```
apps (7.1) -> CABLE Input (default device)
           -> EAPO SFX (pre-mix)
           -> EAPO MFX (HeSuVi 7.1 -> binaural)
           -> vss forwarder MFX -> physical device (WASAPI)
```

- forwarder passes audio through untouched and mirrors it to the target device via a lock-free ring + render thread
- target lives in `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId`, watched live by the APO
- plumbing details and Windows APO registration rules: [docs/apo-forwarder-internals.md](docs/apo-forwarder-internals.md)

## Prerequisites

- Windows 10/11
- [VB-Cable](https://vb-audio.com/Cable/) Pack45 or newer (older 2014-era driver blocks all endpoint effects)
- [Equalizer APO](https://sourceforge.net/projects/equalizerapo/) + [HeSuVi](https://sourceforge.net/projects/hesuvi/)
- [AutoHotkey v2](https://www.autohotkey.com/) (volume OSD and device switching)

## Install

1. Install VB-Cable, Equalizer APO (tick `CABLE Input` in its device selector), HeSuVi.
2. Download the [latest release](../../releases) (bundles `vss_apo.dll`), run `apo\install.bat` (admin). Registers the APO, deploys to Program Files, sets the composite FX chain on CABLE Input.
3. Set CABLE Input to 7.1 if not already (check speaker setup in mmsys.cpl).
4. Pick output device: `scripts\vss-device-select.bat`.
5. Optional: `tasks\import_tasks.bat` auto-routes on device plug/unplug. Task Scheduler points to this repo folder, do not move it after import.

Uninstall: `apo\uninstall.bat`.

Building from source (optional, needs VS Build Tools 2022): `apo\build.bat`. Release zips place the dll at `apo\build\vss_apo.dll`, where `install.ps1` expects it.

### Equalizer APO + HeSuVi notes

- EAPO device selector: ticking `CABLE Input` just registers the EAPO dll, slot mode does not matter, `apo\install.ps1` writes the final chain. Rerunning the selector on `CABLE Input` overwrites that chain, rerun `apo\install.ps1` after
- HeSuVi: pick an HRIR on the Virtualization tab. If virtualization seems off, recheck `On/Off`, `Auto-Deactivate for 2 OS Channels` latches it off when the cable was ever 2-channel
- verify: `debug\tone_channels.ps1` sweeps all 8 channels, rears should sound behind you

## Volume OSD

![Volume OSD](docs/volume-osd-overlay.png)

`scripts\vss-volume-osd.ahk` handles `Volume Up`/`Volume Down` and shows a volume overlay with the active device name.

![Tray Menu](docs/volume-osd-tray-menu.png)

Click or right-click the tray icon to switch output device or toggle the device OSD. Switching writes `TargetDeviceId`, the APO re-points its sink mid-stream.

- Scroll on the tray icon to adjust volume
- Only active when `CABLE Input` is the default device
- Ignores remote mouse focus from `PowerToys.MouseWithoutBordersHelper.exe`

## Repo layout

- `apo/` - APO source, build, install/uninstall
- `scripts/` - device picker (console) + volume OSD (AutoHotkey)
- `tasks/` - Task Scheduler auto-route on device changes
- `debug/` - diagnostic tools (direct-endpoint tone player, meters, FX slot dump, 7.1 format switch)
- `docs/` - forwarder internals, historical Sonar.APO analysis
- `tools/` - SoundVolumeView (see NIRSOFT_NOTICE.txt)

Credits:
- NirSoft, SoundVolumeView
- SteelSeries Sonar, forwarding mechanism blueprint ([docs/sonar-apo-internals.md](docs/sonar-apo-internals.md))
