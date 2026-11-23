# Cross-platform implementation

## Context

- Repository: `virtual-surround-sound`, branch `feature/cross-platform`.
- Issue: [Linux AND macOS support](https://github.com/nnyj/virtual-surround-sound/issues/2).
- Setup AND commands: [portable.md](portable.md).

## Verification

| Outcome                    | Evidence                                                                            |
| -------------------------- | ----------------------------------------------------------------------------------- |
| Linux DSP                  | Five cases pass with real CamillaDSP 4.1.3.                                         |
| Windows DSP                | Same five cases pass with native CamillaDSP 4.1.3.                                  |
| HeSuVi compatibility       | Eight inputs AND both ears match installed preset within one PCM16 output step.     |
| Default Linux 7.1 playback | Eight application links, eight capture links, two output links AND correct samples. |
| DSP crash                  | Service restarts AND routing recovers.                                              |
| Endpoint crash             | Endpoint restarts while DSP PID remains stable.                                     |
| Duplicate DSP guard        | Foreground run is rejected while DSP runs with its endpoint stopped.                |
| Output switching           | New target receives correct stereo audio.                                           |
| Output reconnect           | Restored target receives correct stereo audio.                                      |
| Invalid profile update     | Invalid HRIR leaves saved configuration AND active routing intact.                  |
| Uninstall                  | VSS units AND PipeWire client rule removed.                                         |
| Windows source integrity   | APO, scripts, tasks, debug tools AND release workflow match base commit.            |
| macOS hardware             | Unknown, no Mac available.                                                          |
| macOS startup simulation   | Updating a loaded service starts CamillaDSP once, with a valid LaunchAgent plist.   |

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

## Open

1. On desktop Linux, verify physical headphone output AND positional listening.
2. On macOS, verify BlackHole speaker assignments AND foreground audio input permission.
3. On macOS, verify LaunchAgent permission, unplug/replug AND sample-rate changes.
4. Measure live Windows latency AND device recovery before replacing the existing APO backend.
