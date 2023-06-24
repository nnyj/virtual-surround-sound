# virtual-surround-sound

Install a virtual 7.1 soundcard on Windows 10+

- Pre-requisites:
  - [7-zip](https://www.7-zip.org/download.html)
  - [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/)
  - [HeSuVi](https://sourceforge.net/projects/hesuvi/)

- Steps:
  1. Checkout/download this repository.
  2. Download [SoundVolumeView](https://www.nirsoft.net/utils/soundvolumeview-x64.zip) by Nirsoft and extract the exe file into the current directory.
  3. Download an old version of [SteelSeries GG](https://drivers.softpedia.com/get/KEYBOARD-and-MOUSE/Steelseries/SteelSeries-GG-Utility-22-0-0-64-bit.shtml). It has been tested on V22.0. It does not work on the latest version (V40.0 as of writing).
  4. Open `SteelSeriesGG22.0.0Setup.exe` in 7-zip, extract the `sonar/driver` folder into the current directory.
  5. Run `driver\install.bat` as admin to install the virtual audio driver. (This step is not required if you have already installed SteelSeries GG V22.0.)
  6. Open `Configurator` that was installed with `EqualizerAPO`, tick `SteelSeries Sonar - Gaming`, tick `Troubleshooting Options`, select `Install as SFX/MFX` in the drop-down menu, click OK. Do not reboot when prompted.
  7. Restart Windows Audio service. (You can do so using HeSuVi. From the menu toolbar, select Actions, Restart Audio Service)
  8. Run `select_device.bat`, enter a number corresponding to your desired output device when prompted.
