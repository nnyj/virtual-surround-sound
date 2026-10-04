# Cross-platform implementation

## Context

- Repository: `virtual-surround-sound`, branch `feature/cross-platform`.
- Issue: [Linux AND macOS support](https://github.com/nnyj/virtual-surround-sound/issues/2).
- Setup AND commands: [portable.md](portable.md).
- Existing Windows APO remains the production backend.

## Structure

| File                             | Responsibility                                                            |
| -------------------------------- | ------------------------------------------------------------------------- |
| `portable/dsp.py`                | Shared HRIR validation, channel mapping, bass filtering AND headphone EQ. |
| `portable/platforms.py`          | Device enumeration, PipeWire routing AND native service management.       |
| `portable/vss.py`                | CLI AND persistent profiles.                                              |
| `portable/dsp_test.py`           | Five cases, including real numerical DSP output.                          |
| `portable/routing_test.py`       | One opt-in Linux lifecycle test with real audio.                          |
| `.github/workflows/portable.yml` | Pinned Windows, Linux AND macOS DSP checks.                               |

- Runtime Python dependencies: standard library only.
- CamillaDSP version: 4.1.3.
- Linux uses an eight-channel PipeWire loopback sink feeding native CamillaDSP capture.
- CamillaDSP capture exposes unpositioned ports, direct virtual-sink use causes ordinary clients to downmix.
- The loopback gives applications named speaker channels AND disables remixing only on the internal bridge.
- Native systemd user services supervise both processes.
- DSP remains running while a failed endpoint restarts.
- macOS uses BlackHole 16ch capture, CoreAudio output AND launchd.
- Shared processing reads the first eight capture channels in canonical speaker order.
- User-supplied seven-channel AND fourteen-channel HeSuVi WAVs are supported.
- LFE uses a 111 Hz low-pass filter, center responses AND 200% default gain.
- Filtered LFE joins center before fourteen convolution passes.
- Profiles are the source of truth, runtime configuration rebuilds before startup.
- No third-party HRIR files are bundled.

## Verification

| Outcome                    | Evidence                                                                            |
| -------------------------- | ----------------------------------------------------------------------------------- |
| Linux DSP                  | Five cases pass with real CamillaDSP 4.1.3.                                         |
| Windows DSP                | Same five cases pass with native CamillaDSP 4.1.3.                                  |
| HeSuVi compatibility       | Eight inputs AND both ears match installed preset within one PCM16 output step.     |
| Default Linux 7.1 playback | Eight application links, eight capture links, two output links AND correct samples. |
| DSP crash                  | Service restarts AND routing recovers.                                              |
| Endpoint crash             | Endpoint restarts while DSP PID remains stable.                                     |
| Output switching           | New target receives correct stereo audio.                                           |
| Output reconnect           | Restored target receives correct stereo audio.                                      |
| Invalid profile update     | Invalid HRIR leaves saved configuration AND active routing intact.                  |
| Uninstall                  | VSS units AND PipeWire client rule removed.                                         |
| Windows source integrity   | APO, scripts, tasks, debug tools AND release workflow match base commit.            |
| macOS hardware             | Unknown, no Mac available.                                                          |
| Hosted CI                  | Prepared, not executed in this worktree session.                                    |

- HeSuVi comparison uses the installed `sonic-.wav` preset AND unchanged Equalizer APO configuration.
- Maximum measured absolute error is below `1/32768`, the Benchmark PCM16 quantization step.
- This comparison establishes processing compatibility for that preset AND configuration.
- Physical latency, CPU use under game load AND subjective positional quality remain unmeasured.
- WSL routing tests use temporary virtual outputs, physical Linux output remains a listening check.

## Environment changes

| Location                    | Change                                                                   |
| --------------------------- | ------------------------------------------------------------------------ |
| WSL Ubuntu                  | PipeWire 1.6.2, WirePlumber 0.5.13 AND 29 supporting packages installed. |
| WSL user session            | PipeWire AND WirePlumber running.                                        |
| WSL `/tmp/vss_tools`        | CamillaDSP 4.1.3 native PipeWire binary retained for reruns.             |
| Windows temporary directory | CamillaDSP 4.1.3 in `vss_camilladsp-win`, no system installation.        |
| Windows audio setup         | No configuration OR registry edits.                                      |
| Test audio services         | Removed after each lifecycle test.                                       |

## Reproduce

```sh
python3 portable/dsp_test.py --engine /path/to/camilladsp
```

- Expected: five tests pass with no skipped audio checks.
- The Linux lifecycle test requires a running PipeWire AND WirePlumber session.
- The lifecycle test refuses to overwrite existing VSS services OR client rules.

```sh
VSS_ROUTING_TEST=1 CAMILLADSP=/path/to/camilladsp python3 portable/routing_test.py
```

- Expected: one test passes AND temporary audio services disappear.

## Open

1. On desktop Linux, verify physical headphone output AND positional listening.
2. On macOS, verify BlackHole speaker assignments AND foreground audio input permission.
3. On macOS, verify LaunchAgent permission, unplug/replug AND sample-rate changes.
4. Measure live Windows latency AND device recovery before replacing the existing APO backend.
