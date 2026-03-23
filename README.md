
# Virtual Surround Sound

Scripts to install and use a virtual 7.1 soundcard on Windows, using the proprietary VAD (Virtual Audio Device) driver from SteelSeries Sonar.

A virtual 7.1 soundcard is useful when your audio device does not natively support multichannel output. Pair it with [HeSuVi](https://sourceforge.net/p/hesuvi/) for HRTF-based virtual surround sound — the VAD alone provides the 7.1 channels, not the spatial processing.

## Installation (Easy)

1. Download the latest zip from the [Releases](../../releases) page and extract it.
2. Run `driver\install.bat` as admin. (This installs the VAD from SteelSeries GG V18.0.0.)
3. Done. See [Usage](#usage) below.

## Installation (Advanced)

For users who prefer to obtain the binaries themselves:

1. Clone or download this repository.
2. Download [SoundVolumeView](https://www.nirsoft.net/utils/soundvolumeview-x64.zip) (NirSoft) and place the exe in the repository root.
3. Download [SteelSeries GG](https://drivers.softpedia.com/get/KEYBOARD-and-MOUSE/Steelseries/SteelSeries-GG-Utility-22-0-0-64-bit.shtml) (see [version notes](#steelseries-gg-version-differences) for which version to choose).
4. Open the installer with [7-Zip](https://www.7-zip.org/download.html), extract the `sonar/driver` folder into the repository root.
5. Run `driver\install.bat` as admin.

## Usage

### Initial setup

1. Install [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) if you haven't already.
2. Open the **Configurator** that ships with EqualizerAPO:
   - Tick **SteelSeries Sonar - Gaming**.
   - Tick **Troubleshooting Options** and select **Install as SFX/MFX**.
   - Click OK. **Do not reboot** when prompted.
3. Restart the Windows Audio service (HeSuVi can do this: *Actions > Restart Audio Service*).

### Selecting an output device

Run `select_device.bat`. It lists all render devices and lets you pick one by number. The script writes the routing directly to the Sonar APO registry keys and notifies the APO to reload — no need to disable or re-enable the VAD.

The selected device is also saved to the registry so the volume script can reference it.

### Volume control (AutoHotKey)

`volume_set.ahk` is an [AutoHotkey v2](https://www.autohotkey.com/) script that provides a minimal volume overlay for the routed output device. It is launched automatically by `select_device.bat`.

- **Volume Up / Volume Down** keys adjust volume in steps of 2.
- A dark-themed flyout appears near the bottom of the screen showing the current level.

> **Note:** The script reads the target device from the registry key written by `select_device.bat`. If you haven't run `select_device.bat` at least once, the script will exit with an error.

## Latency

Measured at **27 ms** round-trip using a [loopback cable test](https://manual.audacityteam.org/man/latency_test.html) in Audacity. No difference was observed between 48 kHz and 96 kHz sample rates.

Lower latency alternatives like [VB-Audio Cable / Audio Repeater KS](https://sourceforge.net/p/hesuvi/wiki/Help/#71-virtualization) could achieve 7ms but tend to be unstable or produce crackling.

## SteelSeries GG version differences

| Version | Bit depth | Sample rate | Remarks |
|---|---|---|---|
| 14.0.0 – 24.0.0 | 16-bit | 48 kHz | Driver in `sonar/driver`. V18.0.0 is the leanest — no bundled ML libraries. |
| 25.0.0 – 41.0.0 | 24-bit | 96 kHz | Driver path changed to `apps/sonar/driver` from V28.0.0 onward. Install scripts handle both. |

**Recommended:** V14–24 (48 kHz). HeSuVi ships with 48 kHz HRIR files out of the box — no sample-rate conversion needed.

Later GG versions (40+) expose multiple VAD outputs at different sample rates. Switching between them is possible but not yet scripted. Pull requests welcome.

Official GG changelog: [techblog.steelseries.com](https://techblog.steelseries.com/)

## Credits

- **SteelSeries** — Sonar virtual audio device.
- **NirSoft** — [SoundVolumeView](https://www.nirsoft.net/utils/sound_volume_view.html) for audio device management.
