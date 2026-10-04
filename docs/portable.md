# Linux AND macOS surround

- Apps send 7.1 audio to a virtual output -> CamillaDSP applies HRIR filters -> physical headphones receive stereo.
- Python 3.10+ AND CamillaDSP 4.1.3 provide headless setup.
- Supply a legally obtained HeSuVi 7-channel OR 14-channel HRIR WAV.
- No HRIR files are bundled.
- Windows setup remains in [README.md](../README.md).

## Setup

### Linux

- Install PipeWire, WirePlumber AND PipeWire command-line tools through your distribution.
- Install `pipewire-pulse` for applications using the PulseAudio API.
- Download the `linux-pipewire` build from [CamillaDSP releases](https://github.com/HEnquist/camilladsp/releases/tag/v4.1.3).
- Put `camilladsp` on `PATH`, OR pass `--camilladsp /absolute/path/camilladsp` to `configure`.
- Run commands from the repository root as your desktop user.

```sh
python3 portable/vss.py devices
python3 portable/vss.py configure --hrir /path/to/hrir.wav --output YOUR_PIPEWIRE_NODE_NAME
python3 portable/vss.py install
python3 portable/vss.py status
```

- Select `Virtual Surround 7.1` as application output OR desktop default output.
- Configure the application for 7.1 audio.
- The service creates the virtual sink at login.
- A PipeWire loopback exposes eight named speaker channels AND feeds CamillaDSP without remixing.
- PipeWire handles output sample-rate conversion.
- WSL verifies processing AND graph behavior, physical headphone playback requires a desktop Linux audio device.

### macOS

- Install [BlackHole 16ch](https://github.com/ExistentialAudio/BlackHole) AND the matching CamillaDSP macOS build.
- Install Python 3.10+.
- Run `python3 portable/vss.py devices` to list exact CoreAudio output names.
- Configure with your HRIR AND physical output name.

```sh
python3 portable/vss.py configure --hrir /path/to/hrir.wav --output "MacBook Pro Speakers"
python3 portable/vss.py run
```

- In Audio MIDI Setup, select BlackHole 16ch AND set its rate to the HRIR rate.
- Configure BlackHole speakers as 7.1 surround.
- Assign channels 1 through 8 to FL, FR, center, LFE, rear left, rear right, side left, side right.
- Select BlackHole 16ch as the application OR system output.
- Channels 9 through 16 remain unused.
- Allow audio input access when macOS requests permission during foreground `run`.
- Verify sound in foreground, then press Ctrl+C AND run `install`.
- Verify sound again under LaunchAgent, permission behavior can differ from Terminal.
- A running process with silence can indicate missing macOS audio input permission.
- LaunchAgent starts CamillaDSP at user login.
- Native device opening, permissions AND reconnection require testing on a Mac.
- After a BlackHole sample-rate change, run `start` to reopen capture at the HRIR rate.

## Profiles

- `~/.config/vss/profile.json` stores HRIR, output AND processing choices.
- `~/.config/vss/config.json` contains generated CamillaDSP configuration, JSON is valid YAML.
- `XDG_CONFIG_HOME` OR global `--config-dir` changes profile storage.
- One VSS service instance runs per user.
- `configure` preserves omitted settings.
- `start` applies configured settings through a service restart.
- `check`, `run` AND `start` rebuild configuration from the profile before engine validation.
- Output switching briefly interrupts playback.

```sh
python3 portable/vss.py configure --output ANOTHER_OUTPUT
python3 portable/vss.py start
python3 portable/vss.py configure --preamp-db -18 --chunksize 512
python3 portable/vss.py start
```

| Setting              | Default          | Purpose                                           |
| -------------------- | ---------------- | ------------------------------------------------- |
| Preamp               | -12 dB           | Headroom before channel summing.                  |
| LFE gain             | +6.020599913 dB  | HeSuVi 200% bass relative to other channels.      |
| Chunk size at 48 kHz | 256 frames       | 5.333 ms per DSP block, excludes routing latency. |
| Sample rate          | HRIR sample rate | Preserve impulse timing without HRIR resampling.  |
| Headphone EQ         | None             | Optional stereo parametric filters.               |

- HRIR gain AND simultaneous channels can still clip, reduce preamp when needed.
- `--eq eq.json` loads a JSON array of peaking filters.
- `--clear-eq` removes headphone EQ.

```json
[{"type": "Peaking", "freq": 1000, "gain": -3, "q": 1}]
```

### Channel mapping

| Input      | HRIR left track | HRIR right track |
| ---------- | --------------- | ---------------- |
| FL         | 1               | 2                |
| FR         | 9               | 8                |
| Center     | 7               | 14               |
| LFE        | 7               | 14               |
| Rear left  | 5               | 6                |
| Rear right | 13              | 12               |
| Side left  | 3               | 4                |
| Side right | 11              | 10               |

- Track numbers start at 1.
- Seven-channel HRIRs use symmetric responses, tracks 8 through 14 repeat tracks 1 through 7.
- Mapping follows the [HeSuVi HRIR guide](https://sourceforge.net/p/hesuvi/wiki/How-To%20Record%20Impulse%20Responses%20Digitally/).
- LFE passes through a 111 Hz low-pass filter before the center responses AND configured bass gain.
- Seven speaker pairs AND LFE contributions sum into two ear channels.

## Verification AND operations

```sh
python3 portable/vss.py check
python3 portable/vss.py status
python3 portable/vss.py tones /tmp/vss_channels.wav
```

- `check` asks the local CamillaDSP engine to validate configuration AND HRIR loading.
- `status` reports service AND routing observations, sound quality remains a listening check.
- `tones` creates eight seconds of channel-isolated audio at -20 dBFS peak.
- Play the WAV through the virtual sink with a multichannel-capable player.
- Tone order: FL, FR, center, LFE, rear left, rear right, side left, side right.
- Each channel lasts one second including silence.
- Use headphones AND verify front, side, rear AND center positions.
- Generic HRIRs vary with listener anatomy.

```sh
python3 portable/vss.py stop
python3 portable/vss.py uninstall
```

- `stop` stops processing for this session.
- `uninstall` removes VSS service definitions while preserving profiles AND user HRIR files.
- Select a physical system output before uninstalling.
- Linux logs: `journalctl --user -u vss_dsp.service -u vss_endpoint.service`.
- macOS logs: `~/Library/Logs/virtual-surround-sound/`.

### Development

- `portable/dsp.py` owns HRIR validation AND shared channel processing.
- `portable/platforms.py` owns device APIs, routing AND native service managers.
- `portable/vss.py` owns CLI AND persistent profiles.
- Tests use generated synthetic responses without third-party datasets.
- Run `python3 portable/dsp_test.py --engine /path/to/camilladsp` for five offline checks.
- Set `VSS_ROUTING_TEST=1` AND `CAMILLADSP` to run `portable/routing_test.py` on an unused Linux VSS session.
- macOS AND Linux share the same convolution pipeline.
- Windows backend replacement requires live latency, reliability AND listening comparison against the APO.
- Measured results AND environment changes: [cross_platform_work.md](cross_platform_work.md).
