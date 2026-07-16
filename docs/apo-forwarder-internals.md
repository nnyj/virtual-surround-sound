# VSS Forwarder APO internals

How `apo/vss_apo.dll` replicates Sonar's redirection mechanism on a VB-Cable endpoint, and the Windows APO plumbing rules discovered while building it. Companion history: [sonar-apo-internals.md](sonar-apo-internals.md).

## Architecture

- CABLE Input (VB-Cable, 48kHz/8ch) is the default render endpoint, apps mix into it
- audiodg loads the FX chain registered on that endpoint:
  - SFX: EqualizerAPO pre-mix
  - MFX: EqualizerAPO post-mix (HeSuVi 7.1 to binaural convolution), then vss forwarder
- forwarder copies input to output untouched (INPLACE) and pushes frames into a lock-free SPSC ring
- render thread pops the ring and plays it on the physical device via WASAPI shared mode (IAudioClient3 min-period when available), ~10ms added latency
- target device comes from `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId`, read at LockForProcess and watched live (RegNotifyChangeKeyValue) so device switches re-point the sink without restarting audio

## COM rules audiodg enforces

- audiodg AGGREGATES APOs: `IClassFactory::CreateInstance` receives a non-null outer unknown. Returning `CLASS_E_NOAGGREGATION` makes the host silently abandon the APO after a factory probe (`DllGetClassObject` then QI then Release, never a visible CreateInstance), and it retries a few times per graph build
  - the APO must implement standard COM aggregation: inner non-delegating IUnknown owns identity and lifetime, all interface IUnknown methods delegate to the controlling unknown
  - symptom of missing support: endpoint FX graph fails, `IAudioClient::Initialize` on the endpoint returns `E_NOTIMPL`, and players silently fall back to other devices
- ThreadingModel `Both`, engine registration under `HKCR\AudioEngine\AudioProcessingObjects\{clsid}` with `APOInterface0` = IAudioProcessingObject

## Endpoint FX slot rules (Win11 24H2, VB-Cable Pack45)

- classic slots (`{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},N`): 5=SFX, 6=MFX, 7=EFX, one clsid each
  - MFX registered alone is silently ignored, needs SFX populated
  - EFX slot never loaded our APO on the cable endpoint
  - a failed SFX gets skipped, a failed MFX kills the whole endpoint graph
- composite slots (Win10 1803+): `,13` (SFX) and `,14` (MFX) are MULTI_SZ clsid lists, multiple APOs per position, executed in list order. This is how EAPO post-mix and the forwarder coexist in MFX
- `,0` association must be the null GUID, `{d3993a3f-99c2-4402-b5ec-a92a0367664b},5/,6` MULTI_SZ must contain the DEFAULT processing mode GUID or FX never attach to streams
- FxProperties key ACL denies KEY_WRITE to admins: open with exact `QueryValues|SetValue` rights (.NET `OpenSubKey`), `Set-ItemProperty`/`reg add` fail
- restart `AudioEndpointBuilder` + `audiosrv` after any FX registry change

## Config key

- `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId` = MMDevice endpoint ID string
- audiodg runs LPAC: the key needs read ACEs for `S-1-15-2-1` and `S-1-15-2-2` or the APO's read fails silently
- Users get `QueryValues|SetValue` so device-select scripts hot-switch without elevation (plain `reg add` still fails, it requests full KEY_WRITE)

## Endpoint format (7.1)

- `PKEY_AudioEngine_DeviceFormat` registry writes get reverted by AudioEndpointBuilder, and the stored value is a serialized PROPVARIANT (8-byte `41 00 00 00 01 00 00 00` header + WAVEFORMATEXTENSIBLE)
- the working method is `IPolicyConfig::SetDeviceFormat` (undocumented, same path as mmsys.cpl Configure), see `debug/set_71_policy.ps1`, takes effect without a service restart

## Debugging traps (cost days)

- broken APO = endpoint stream opens fail = players (SoundPlayer/waveOut especially) silently fall back to another device, so "audio plays" proves nothing about the endpoint under test. Use `debug/wasapi_tone.ps1`, it opens the endpoint by ID and surfaces the Initialize HRESULT
- per-app device pins (`HKCU\...\Audio\PolicyConfig\PropertyStore`) and device-change automation (vss-route task) both override or fight default-device switches during tests
- dbg tracing goes to OutputDebugString, capture with DebugView ("Capture Global Win32" needed for audiodg)
- driver reinstall (e.g. VB-Cable Pack43 to Pack45) regenerates endpoint GUIDs, all FxProperties registrations vanish with the old endpoint
- VB-Cable Pack43-era driver (1.0.3.5, 2014) blocks all endpoint FX, Pack45 (3.3.1.7, Oct 2024) required
