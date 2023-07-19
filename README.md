# About

This repository provides the scripts to:
- install a virtual 7.1 soundcard on Windows. This relies on a proprietary VAD driver provided by SteelSeries.
- select the playback device for the VAD (Virtual Audio Device) to route to.

A virtual 7.1 soundcard is useful for instances where a user does not have a physical soundcard which supports 5.1/7.1 channels.

The VAD itself does not perform HRTF / Virtual Surround Sound. Users should install [HeSuVi](https://sourceforge.net/p/hesuvi/) and use it together with the virtual 7.1 soundcard.

# Installation steps (Easy)

1. Download the latest zip from the releases page and extract it.
2. Navigate to `driver` folder and run `install.bat` as admin. (This installs VAD from GG V18.0.0)
3. That's it! Refer to [Usage](#usage) to learn how to use it.

# Installation steps (Advanced)

This step is for users who prefer to obtain the binaries themselves.

1. Checkout/download this repository.
2. Download [SoundVolumeView](https://www.nirsoft.net/utils/soundvolumeview-x64.zip) by NirSoft and extract the exe file into the current directory.
3. Download [SteelSeries GG V22.0.0](https://drivers.softpedia.com/get/KEYBOARD-and-MOUSE/Steelseries/SteelSeries-GG-Utility-22-0-0-64-bit.shtml). (Refer [here](#steelseries-gg-version-differences) for version differences)
4. Open `SteelSeriesGG22.0.0Setup.exe` as an archive using [7-zip](https://www.7-zip.org/download.html), extract the `sonar/driver` folder into the current directory.
5. Run `driver\install.bat` as admin to install the virtual audio driver.

# Usage

1. Install [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) if not already done.
2. Open `Configurator` that was installed with `EqualizerAPO`, tick `SteelSeries Sonar - Gaming`, tick `Troubleshooting Options`, select `Install as SFX/MFX` in the drop-down menu, click OK. Do not reboot when prompted.
3. Restart Windows Audio service. (You can do so using HeSuVi. From the menu toolbar, select Actions, Restart Audio Service)
4. Run `select_device.bat`, enter a number corresponding to your desired output device when prompted.

# Latency

The total latency was measured to be **27ms** using a [loop-back cable](https://manual.audacityteam.org/man/latency_test.html) by connecting the line input and line output on a computer and performing the latency test in Audacity.

Lower-latency alternatives such as [VB-Audio Cable / KSAudioStreamer]((https://sourceforge.net/p/hesuvi/wiki/Help/#71-virtualization)) tend to be unstable and/or causes crackling.

# SteelSeries GG version differences

| Version         | Bit depth | Sample rate (kHz) | Remarks                                                                                                    |
| --------------- | --------- | ----------------- | ---------------------------------------------------------------------------------------------------------- |
| 14.0.0 - 24.0.0 | 16        | 48                | Drivers can be found in `sonar/driver`. V18.0.0 is the last version that does not include machine learning DLL files. It is not required for this guide. |
| 19.0.0 - 41.0.0 | 24        | 96                | As of V28.0.0, drivers were moved to `apps/sonar/driver`. Installation scripts are still working.                                                    |

Users are suggested to use version 14.0.0 - 24.0.0 as HeSuVi already includes HRIR files for 48kHz and requires no additional effort by users to convert it to a different sample rate.

There are no latency differences between 48kHz and 96kHz, both were measured to be 27ms.

Later versions of GG (40+) includes multiple VAD sound outputs, some with 48kHz or 96kHz. It is conceivably possible to switch between the two sample rates but there are no plans to enhance the script at this time. (Pull requests are welcome)

Official GG changelog can be found [here](https://techblog.steelseries.com/).

# Credits

- SteelSeries - For creating the virtual audio device known as Sonar.
- NirSoft - SoundVolumeView for easily switching audio devices.
