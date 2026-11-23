// vss_apo.cpp
// Mode effect APO (composite MFX, after EqualizerAPO/HeSuVi) on a virtual render endpoint
// (VB-Cable "CABLE Input"). Taps the post-mix inside audiodg.exe and forwards it to a physical
// device via WASAPI. Mechanism + registration rules: docs/apo-forwarder-internals.md.
//
// Config: HKLM\SOFTWARE\VirtualSurroundSound
//   TargetDeviceId  REG_SZ  MMDevice endpoint ID, e.g. {0.0.0.00000000}.{guid}
// Read at LockForProcess and watched live (RegNotifyChangeKeyValue) for hot device switching.
//
// Second class, native APO: stream effect on a headset endpoint, 7.1 in, stereo out. Hosts the
// Equalizer APO pre-mix and post-mix classes (HeSuVi) at 8 ch and passes their FL/FR on, without sink or watcher.

#include <initguid.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioenginebaseapo.h>
#include <audioengineextensionapo.h>
#include <ksmedia.h>
#include <avrt.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <new>

// {B2F007A1-EAD1-478B-9888-ABC593E55B5D} (regenerated: old {8A4F0C6D...} suspected quarantined by audiodg)
DEFINE_GUID(CLSID_VssForwarderAPO, 0xb2f007a1, 0xead1, 0x478b, 0x98, 0x88, 0xab, 0xc5, 0x93, 0xe5, 0x5b, 0x5d);
// {7C1E5A42-5D0B-4E0C-9B7A-6F3B2D9E8A11}
DEFINE_GUID(CLSID_VssNativeAPO, 0x7c1e5a42, 0x5d0b, 0x4e0c, 0x9b, 0x7a, 0x6f, 0x3b, 0x2d, 0x9e, 0x8a, 0x11);

static std::atomic<LONG> g_object_count{0};
static HMODULE g_module = nullptr;

// capture with DebugView/dbgview (needs "Capture Global Win32" for audiodg)
static void dbg(const wchar_t* msg, HRESULT hr = S_OK) {
  wchar_t line[320];
  swprintf_s(line, L"[VssAPO pid=%lu] %s (hr=0x%08X)\r\n", GetCurrentProcessId(), msg, (unsigned)hr);
  OutputDebugStringW(line);
}

// ---------------------------------------------------------------------------
// Lock-free SPSC ring buffer, stereo float32 frames.
// Writer: APOProcess (RT thread inside audiodg). Reader: render thread.
// ---------------------------------------------------------------------------

struct StereoRing {
  static const UINT32 CAP = 1u << 15;  // 32768 frames (~683ms @48k), power of 2
  float data[CAP * 2];
  std::atomic<UINT32> write_pos{0};
  std::atomic<UINT32> read_pos{0};

  UINT32 fill() const { return write_pos.load(std::memory_order_acquire) - read_pos.load(std::memory_order_acquire); }

  // extract ch0/ch1 from interleaved src with src_channels stride, drop excess when full
  void push(const float* src, UINT32 src_channels, UINT32 frames) {
    UINT32 w = write_pos.load(std::memory_order_relaxed);
    UINT32 space = CAP - (w - read_pos.load(std::memory_order_acquire));
    if (frames > space) frames = space;
    for (UINT32 i = 0; i < frames; i++) {
      UINT32 slot = ((w + i) & (CAP - 1)) * 2;
      data[slot] = src[i * src_channels];
      data[slot + 1] = src_channels > 1 ? src[i * src_channels + 1] : src[i * src_channels];
    }
    write_pos.store(w + frames, std::memory_order_release);
  }

  UINT32 pop(float* dst, UINT32 frames) {
    UINT32 r = read_pos.load(std::memory_order_relaxed);
    UINT32 avail = write_pos.load(std::memory_order_acquire) - r;
    if (frames > avail) frames = avail;
    for (UINT32 i = 0; i < frames; i++) {
      UINT32 slot = ((r + i) & (CAP - 1)) * 2;
      dst[i * 2] = data[slot];
      dst[i * 2 + 1] = data[slot + 1];
    }
    read_pos.store(r + frames, std::memory_order_release);
    return frames;
  }

  // reader-side latency clamp: device clock drift slowly grows fill, cap it
  void drop_to(UINT32 max_fill) {
    UINT32 r = read_pos.load(std::memory_order_relaxed);
    UINT32 avail = write_pos.load(std::memory_order_acquire) - r;
    if (avail > max_fill) read_pos.store(r + (avail - max_fill), std::memory_order_release);
  }
};

// ---------------------------------------------------------------------------
// RenderSink: owns render thread driving WASAPI on the physical device.
// All COM/WASAPI happens on the thread, APO threads only touch ring + events.
// ---------------------------------------------------------------------------

// wakes the render thread when the target endpoint goes ACTIVE, so reopening needs no polling
class DeviceWatch : public IMMNotificationClient {
public:
  HANDLE signal = nullptr;
  const wchar_t* target = nullptr;
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
      *ppv = static_cast<IMMNotificationClient*>(this);
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return 2; }  // owned by RenderSink, outlives registration
  STDMETHODIMP_(ULONG) Release() override { return 1; }
  // MMDevice worker thread: signal only, no blocking or WASAPI calls here
  STDMETHODIMP OnDeviceStateChanged(LPCWSTR id, DWORD state) override {
    if (state == DEVICE_STATE_ACTIVE && target && id && !wcscmp(id, target)) SetEvent(signal);
    return S_OK;
  }
  STDMETHODIMP OnDeviceAdded(LPCWSTR) override { return S_OK; }
  STDMETHODIMP OnDeviceRemoved(LPCWSTR) override { return S_OK; }
  STDMETHODIMP OnDefaultDeviceChanged(EDataFlow, ERole, LPCWSTR) override { return S_OK; }
  STDMETHODIMP OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }
};

class RenderSink {
public:
  void Start(const wchar_t* device_id, UINT32 sample_rate) {
    Stop();
    wcsncpy_s(device_id_, device_id, _TRUNCATE);
    rate_ = sample_rate;
    ring_.read_pos.store(ring_.write_pos.load());
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    device_event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    thread_ = CreateThread(nullptr, 0, ThreadProc, this, 0, nullptr);
    if (!thread_) dbg(L"CreateThread failed");
  }

  void Stop() {
    if (!thread_) return;
    SetEvent(stop_event_);
    WaitForSingleObject(thread_, 3000);
    CloseHandle(thread_);
    CloseHandle(stop_event_);
    CloseHandle(device_event_);
    thread_ = nullptr;
    stop_event_ = nullptr;
    device_event_ = nullptr;
  }

  void PushFrames(const float* buf, UINT32 channels, UINT32 frames) {
    if (thread_) ring_.push(buf, channels, frames);
  }

private:
  static DWORD WINAPI ThreadProc(LPVOID ctx) {
    ((RenderSink*)ctx)->Run();
    return 0;
  }

  static bool is_float32(const WAVEFORMATEX* wf) {
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return wf->wBitsPerSample == 32;
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* ext = (const WAVEFORMATEXTENSIBLE*)wf;
      return IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) && wf->wBitsPerSample == 32;
    }
    return false;
  }

  // a failed open must not end the thread, reopening is what recovers the sink
  void Run() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* notify_enum = nullptr;
    watch_.signal = device_event_;
    watch_.target = device_id_;
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&notify_enum))))
      notify_enum->RegisterEndpointNotificationCallback(&watch_);
    HANDLE waits[2] = { stop_event_, device_event_ };
    for (;;) {
      RunSession();
      // endpoint going ACTIVE wakes this at once; the timeout only covers a dropped callback
      if (WaitForMultipleObjects(2, waits, FALSE, REOPEN_BACKSTOP_MS) == WAIT_OBJECT_0) break;
    }
    if (notify_enum) {
      notify_enum->UnregisterEndpointNotificationCallback(&watch_);
      notify_enum->Release();
    }
    CoUninitialize();
  }

  // one open/pump/teardown cycle
  void RunSession() {
    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioClient3* client3 = nullptr;
    IAudioRenderClient* render = nullptr;
    WAVEFORMATEX* mix = nullptr;
    HANDLE buffer_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HANDLE mmcss = nullptr;
    bool started = false;
    HRESULT hr;

    do {
      hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
      if (FAILED(hr)) { dbg(L"MMDeviceEnumerator failed", hr); break; }
      hr = enumerator->GetDevice(device_id_, &device);
      if (FAILED(hr)) { dbg(L"GetDevice failed, check TargetDeviceId", hr); break; }
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&client);
      if (FAILED(hr)) { dbg(L"IAudioClient Activate failed", hr); break; }
      client->GetMixFormat(&mix);

      // fast path: IAudioClient3 minimum shared period (~2.7ms), needs exact mix format match
      bool low_latency = false;
      if (mix && mix->nSamplesPerSec == rate_ && mix->nChannels == 2 && is_float32(mix) &&
          SUCCEEDED(client->QueryInterface(IID_PPV_ARGS(&client3)))) {
        UINT32 def_p, fund_p, min_p, max_p;
        if (SUCCEEDED(client3->GetSharedModeEnginePeriod(mix, &def_p, &fund_p, &min_p, &max_p)) &&
            SUCCEEDED(client3->InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, min_p, mix, nullptr))) {
          low_latency = true;
          dbg(L"IAudioClient3 low-latency path active");
        }
      }
      if (!low_latency) {
        WAVEFORMATEX want = {};
        want.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        want.nChannels = 2;
        want.nSamplesPerSec = rate_;
        want.wBitsPerSample = 32;
        want.nBlockAlign = 8;
        want.nAvgBytesPerSec = rate_ * 8;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            200000, 0, &want, nullptr);  // 20ms buffer
        if (FAILED(hr)) { dbg(L"IAudioClient Initialize failed", hr); break; }
        dbg(L"fallback shared 10ms path active");
      }

      client->SetEventHandle(buffer_event);
      UINT32 buffer_frames = 0;
      client->GetBufferSize(&buffer_frames);
      hr = client->GetService(IID_PPV_ARGS(&render));
      if (FAILED(hr)) { dbg(L"GetService IAudioRenderClient failed", hr); break; }

      DWORD task_index = 0;
      mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
      hr = client->Start();
      if (FAILED(hr)) { dbg(L"client Start failed", hr); break; }
      started = true;
      ring_.read_pos.store(ring_.write_pos.load(std::memory_order_acquire), std::memory_order_release);

      HANDLE waits[2] = { stop_event_, buffer_event };
      UINT32 max_fill = buffer_frames * 3;
      int idle = 0;
      for (;;) {
        DWORD w = WaitForMultipleObjects(2, waits, FALSE, 500);
        if (w == WAIT_OBJECT_0 || w == WAIT_FAILED) break;
        // A live stream signals every device period. BT reconnect keeps the endpoint ID but
        // replaces the device, leaving a stream that never faults and never clocks; silence
        // here is the only symptom, so treat it as dead and reopen.
        if (w == WAIT_TIMEOUT) {
          if (++idle < STALL_TICKS) continue;
          dbg(L"sink stalled, reopening");
          break;
        }
        idle = 0;
        ring_.drop_to(max_fill);
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) break;
        UINT32 want_frames = buffer_frames - padding;
        if (!want_frames) continue;
        BYTE* pb = nullptr;
        if (FAILED(render->GetBuffer(want_frames, &pb))) break;
        UINT32 got = ring_.pop((float*)pb, want_frames);
        if (got < want_frames) memset(pb + (size_t)got * 8, 0, ((size_t)want_frames - got) * 8);
        render->ReleaseBuffer(want_frames, 0);
      }
    } while (false);

    if (started) client->Stop();
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    if (mix) CoTaskMemFree(mix);
    if (render) render->Release();
    if (client3) client3->Release();
    if (client) client->Release();
    if (device) device->Release();
    if (enumerator) enumerator->Release();
    CloseHandle(buffer_event);
  }

  static const DWORD REOPEN_BACKSTOP_MS = 30000;
  static const int STALL_TICKS = 4;  // x 500ms wait

  StereoRing ring_;
  DeviceWatch watch_;
  wchar_t device_id_[512] = {};
  UINT32 rate_ = 48000;
  HANDLE thread_ = nullptr;
  HANDLE stop_event_ = nullptr;
  HANDLE device_event_ = nullptr;
};

// minimal IAudioMediaType, used to suggest a format to the engine
class SuggestedType : public IAudioMediaType {
public:
  SuggestedType(UINT32 channels, DWORD mask, UINT32 rate) {
    fmt_.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    fmt_.Format.nChannels = (WORD)channels;
    fmt_.Format.nSamplesPerSec = rate;
    fmt_.Format.wBitsPerSample = 32;
    fmt_.Format.nBlockAlign = (WORD)(channels * 4);
    fmt_.Format.nAvgBytesPerSec = rate * channels * 4;
    fmt_.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    fmt_.Samples.wValidBitsPerSample = 32;
    fmt_.dwChannelMask = mask;
    fmt_.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
  }
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IAudioMediaType)) {
      *ppv = static_cast<IAudioMediaType*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&refs_); }
  STDMETHODIMP_(ULONG) Release() override {
    ULONG n = (ULONG)InterlockedDecrement(&refs_);
    if (!n) delete this;
    return n;
  }
  STDMETHODIMP IsCompressedFormat(BOOL* compressed) override {
    if (!compressed) return E_POINTER;
    *compressed = FALSE;
    return S_OK;
  }
  STDMETHODIMP IsEqual(IAudioMediaType* other, DWORD* flags) override {
    if (!other || !flags) return E_POINTER;
    const WAVEFORMATEX* o = other->GetAudioFormat();
    bool same = o && o->nChannels == fmt_.Format.nChannels && o->nSamplesPerSec == fmt_.Format.nSamplesPerSec &&
                o->wBitsPerSample == 32;
    *flags = same ? (AUDIOMEDIATYPE_EQUAL_FORMAT_TYPES | AUDIOMEDIATYPE_EQUAL_FORMAT_DATA) : 0;
    return same ? S_OK : S_FALSE;
  }
  STDMETHODIMP_(const WAVEFORMATEX*) GetAudioFormat() override { return &fmt_.Format; }
  STDMETHODIMP GetUncompressedAudioFormat(UNCOMPRESSEDAUDIOFORMAT* out) override {
    if (!out) return E_POINTER;
    out->guidFormatType = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    out->dwSamplesPerFrame = fmt_.Format.nChannels;
    out->dwBytesPerSampleContainer = 4;
    out->dwValidBitsPerSample = 32;
    out->fFramesPerSecond = (FLOAT)fmt_.Format.nSamplesPerSec;
    out->dwChannelMask = fmt_.dwChannelMask;
    return S_OK;
  }
private:
  LONG refs_ = 1;
  WAVEFORMATEXTENSIBLE fmt_ = {};
};

// one Equalizer APO stage hosted inside the native APO, writes 8 ch into its own buffer
struct HostedStage {
  IAudioProcessingObject* apo = nullptr;
  IAudioProcessingObjectRT* rt = nullptr;
  IAudioProcessingObjectConfiguration* cfg = nullptr;
  float* buffer = nullptr;
  bool locked = false;

  // Equalizer APO takes exactly this struct and picks its stage from the class id inside
  void Create(const wchar_t* clsid, APOInitSystemEffects init) {
    if (apo) return;
    CLSIDFromString(clsid, &init.APOInit.clsid);
    HRESULT hr = CoCreateInstance(init.APOInit.clsid, nullptr, CLSCTX_INPROC_SERVER, __uuidof(IAudioProcessingObject),
                                  (void**)&apo);
    if (SUCCEEDED(hr)) hr = apo->Initialize(sizeof(init), (BYTE*)&init);
    if (SUCCEEDED(hr)) hr = apo->QueryInterface(__uuidof(IAudioProcessingObjectRT), (void**)&rt);
    if (SUCCEEDED(hr)) hr = apo->QueryInterface(__uuidof(IAudioProcessingObjectConfiguration), (void**)&cfg);
    dbg(L"hosted Equalizer APO stage created", hr);
    if (FAILED(hr)) Release();
  }
  // connection: output of the previous stage, or the stream. A locked stage replaces it with its own 8 ch output
  void Lock(APO_CONNECTION_DESCRIPTOR* connection, IAudioMediaType* type_8ch) {
    if (!cfg) return;
    buffer = (float*)_aligned_malloc((size_t)connection->u32MaxFrameCount * 8 * sizeof(float), 32);
    APO_CONNECTION_DESCRIPTOR output = *connection;
    output.Type = APO_CONNECTION_BUFFER_TYPE_EXTERNAL;
    output.pBuffer = (UINT_PTR)buffer;
    output.pFormat = type_8ch;
    APO_CONNECTION_DESCRIPTOR* output_list = &output;
    HRESULT hr = buffer ? cfg->LockForProcess(1, &connection, 1, &output_list) : E_OUTOFMEMORY;
    dbg(L"hosted Equalizer APO stage lock", hr);
    locked = SUCCEEDED(hr);
    if (locked) *connection = output;
  }
  void Unlock() {
    if (locked) cfg->UnlockForProcess();
    locked = false;
    if (buffer) _aligned_free(buffer);
    buffer = nullptr;
  }
  void Release() {
    if (rt) rt->Release();
    if (cfg) cfg->Release();
    if (apo) apo->Release();
    rt = nullptr;
    cfg = nullptr;
    apo = nullptr;
  }
  // RT thread, same connection rule as Lock
  void Process(APO_CONNECTION_PROPERTY* connection) {
    if (!locked) return;
    APO_CONNECTION_PROPERTY output = *connection;
    output.pBuffer = (UINT_PTR)buffer;
    output.u32ValidFrameCount = 0;
    output.u32BufferFlags = BUFFER_INVALID;
    APO_CONNECTION_PROPERTY* output_list = &output;
    rt->APOProcess(1, &connection, 1, &output_list);
    *connection = output;
  }
};

// ---------------------------------------------------------------------------
// APO COM object
// ---------------------------------------------------------------------------

class VssApo : public IAudioProcessingObject,
               public IAudioProcessingObjectRT,
               public IAudioProcessingObjectConfiguration,
               public IAudioSystemEffects,
               public IAudioProcessingObjectPreferredFormatSupport {
public:
  // audiodg aggregates APOs: inner non-delegating IUnknown owns identity + lifetime,
  // outer-facing IUnknown on all interfaces delegates to the controlling unknown
  class Inner : public IUnknown {
  public:
    VssApo* self = nullptr;
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
      if (!ppv) return E_POINTER;
      if (riid == __uuidof(IUnknown))
        *ppv = static_cast<IUnknown*>(this);
      else if (riid == __uuidof(IAudioProcessingObject))
        *ppv = static_cast<IAudioProcessingObject*>(self);
      else if (riid == __uuidof(IAudioProcessingObjectRT))
        *ppv = static_cast<IAudioProcessingObjectRT*>(self);
      else if (riid == __uuidof(IAudioProcessingObjectConfiguration))
        *ppv = static_cast<IAudioProcessingObjectConfiguration*>(self);
      else if (riid == __uuidof(IAudioSystemEffects))
        *ppv = static_cast<IAudioSystemEffects*>(self);
      else if (self->native_ && riid == __uuidof(IAudioProcessingObjectPreferredFormatSupport))
        *ppv = static_cast<IAudioProcessingObjectPreferredFormatSupport*>(self);
      else {
        wchar_t iid_str[64];
        StringFromGUID2(riid, iid_str, 64);
        dbg(L"apo QI miss", 0);
        dbg(iid_str);
        *ppv = nullptr;
        return E_NOINTERFACE;
      }
      ((IUnknown*)*ppv)->AddRef();  // delegates to outer for interface pointers, per COM rules
      return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&self->refs_); }
    STDMETHODIMP_(ULONG) Release() override {
      ULONG n = (ULONG)InterlockedDecrement(&self->refs_);
      if (!n) delete self;
      return n;
    }
  };

  VssApo(IUnknown* outer, bool native) : native_(native) {
    inner_.self = this;
    outer_ = outer ? outer : static_cast<IUnknown*>(&inner_);
    g_object_count++;
  }
  virtual ~VssApo() { sink_.Stop(); pre_mix_.Release(); post_mix_.Release(); g_object_count--; }

  // IUnknown on all APO interfaces: delegate to controlling unknown
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override { return outer_->QueryInterface(riid, ppv); }
  STDMETHODIMP_(ULONG) AddRef() override { return outer_->AddRef(); }
  STDMETHODIMP_(ULONG) Release() override { return outer_->Release(); }

  Inner inner_;

  // IAudioProcessingObject
  STDMETHODIMP Reset() override { return S_OK; }
  STDMETHODIMP GetLatency(HNSTIME* pTime) override {
    if (!pTime) return E_POINTER;
    *pTime = 0;
    return S_OK;
  }
  STDMETHODIMP GetRegistrationProperties(APO_REG_PROPERTIES** ppRegProps) override {
    dbg(L"GetRegistrationProperties");
    if (!ppRegProps) return E_POINTER;
    auto* p = (APO_REG_PROPERTIES*)CoTaskMemAlloc(sizeof(APO_REG_PROPERTIES));
    if (!p) return E_OUTOFMEMORY;
    memset(p, 0, sizeof(*p));
    if (native_) {
      p->clsid = CLSID_VssNativeAPO;
      p->Flags = (APO_FLAG)(APO_FLAG_FRAMESPERSECOND_MUST_MATCH | APO_FLAG_BITSPERSAMPLE_MUST_MATCH);
      wcscpy_s(p->szFriendlyName, L"VSS Native APO");
    } else {
      p->clsid = CLSID_VssForwarderAPO;
      p->Flags = (APO_FLAG)(APO_FLAG_INPLACE | APO_FLAG_DEFAULT);
      wcscpy_s(p->szFriendlyName, L"VSS Forwarder APO");
    }
    wcscpy_s(p->szCopyrightInfo, L"MIT");
    p->u32MajorVersion = 1;
    p->u32MinInputConnections = 1;
    p->u32MaxInputConnections = 1;
    p->u32MinOutputConnections = 1;
    p->u32MaxOutputConnections = 1;
    p->u32MaxInstances = 0xFFFFFFFF;
    p->u32NumAPOInterfaces = 1;
    p->iidAPOInterfaceList[0] = __uuidof(IAudioProcessingObject);
    *ppRegProps = p;
    return S_OK;
  }
  STDMETHODIMP Initialize(UINT32 cbDataSize, BYTE* pbyData) override {
    dbg(L"Initialize", cbDataSize);
    if (cbDataSize >= sizeof(APOInitSystemEffects2) && pbyData) {
      auto* init = (APOInitSystemEffects2*)pbyData;
      discovery_only_ = init->InitializeForDiscoveryOnly != FALSE;
      default_mode_ = IsEqualGUID(init->AudioProcessingMode, AUDIO_SIGNALPROCESSINGMODE_DEFAULT) != FALSE;
    }
    if (native_ && cbDataSize == sizeof(APOInitSystemEffects) && pbyData) {
      // pre-mix holds the HeSuVi stereo upmix, post-mix the HRIR convolution
      pre_mix_.Create(L"{EACD2258-FCAC-4FF4-B36D-419E924A6D79}", *(APOInitSystemEffects*)pbyData);
      post_mix_.Create(L"{EC1CC9CE-FAED-4822-828A-82A81A6F018F}", *(APOInitSystemEffects*)pbyData);
    }
    return S_OK;
  }
  STDMETHODIMP IsInputFormatSupported(IAudioMediaType* pOppositeFormat, IAudioMediaType* pRequestedInputFormat,
                                      IAudioMediaType** ppSupportedInputFormat) override {
    if (native_)
      return CheckSide(pOppositeFormat, pRequestedInputFormat, ppSupportedInputFormat, 8, KSAUDIO_SPEAKER_7POINT1_SURROUND);
    return CheckFormat(pOppositeFormat, pRequestedInputFormat, ppSupportedInputFormat);
  }
  STDMETHODIMP IsOutputFormatSupported(IAudioMediaType* pOppositeFormat, IAudioMediaType* pRequestedOutputFormat,
                                       IAudioMediaType** ppSupportedOutputFormat) override {
    if (native_)
      return CheckSide(pOppositeFormat, pRequestedOutputFormat, ppSupportedOutputFormat, 2, KSAUDIO_SPEAKER_STEREO);
    return CheckFormat(pOppositeFormat, pRequestedOutputFormat, ppSupportedOutputFormat);
  }
  STDMETHODIMP GetInputChannelCount(UINT32* pu32ChannelCount) override {
    if (!pu32ChannelCount) return E_POINTER;
    *pu32ChannelCount = native_ ? 8 : (channels_ ? channels_ : 2);
    return S_OK;
  }

  // IAudioProcessingObjectPreferredFormatSupport, native only: the engine reports the input format as the mix format
  STDMETHODIMP GetPreferredInputFormat(IAudioMediaType* outputFormat, IAudioMediaType** preferredFormat) override {
    return MakeFloatType(8, KSAUDIO_SPEAKER_7POINT1_SURROUND, outputFormat, preferredFormat);
  }
  STDMETHODIMP GetPreferredOutputFormat(IAudioMediaType* inputFormat, IAudioMediaType** preferredFormat) override {
    return MakeFloatType(2, KSAUDIO_SPEAKER_STEREO, inputFormat, preferredFormat);
  }

  // IAudioProcessingObjectConfiguration
  STDMETHODIMP LockForProcess(UINT32 numIn, APO_CONNECTION_DESCRIPTOR** in,
                              UINT32 numOut, APO_CONNECTION_DESCRIPTOR** out) override {
    dbg(L"LockForProcess");
    if (numIn != 1 || numOut != 1 || !in || !out) return APOERR_NUM_CONNECTIONS_INVALID;
    const WAVEFORMATEX* wf = in[0]->pFormat->GetAudioFormat();
    if (!wf) return APOERR_INVALID_CONNECTION_FORMAT;
    channels_ = wf->nChannels;
    rate_ = wf->nSamplesPerSec;
    if (native_) {
      mid_type_ = new (std::nothrow) SuggestedType(8, KSAUDIO_SPEAKER_7POINT1_SURROUND, rate_);
      mid_frames_ = in[0]->u32MaxFrameCount;
      APO_CONNECTION_DESCRIPTOR connection = *in[0];
      if (mid_type_) {
        pre_mix_.Lock(&connection, mid_type_);
        post_mix_.Lock(&connection, mid_type_);
      }
    }
    locked_ = true;
    if (!native_ && !discovery_only_ && default_mode_) {
      wchar_t target_id[512];
      if (ReadTargetId(target_id)) {
        wcscpy_s(current_target_, target_id);
        sink_.Start(target_id, rate_);
        dbg(L"sink started");
      } else {
        current_target_[0] = 0;
        dbg(L"no TargetDeviceId, passthrough only");
      }
      StartWatcher();  // hot device switch: re-point sink when TargetDeviceId changes
    }
    return S_OK;
  }
  STDMETHODIMP UnlockForProcess() override {
    pre_mix_.Unlock();
    post_mix_.Unlock();
    if (mid_type_) mid_type_->Release();
    mid_type_ = nullptr;
    StopWatcher();
    sink_.Stop();
    locked_ = false;
    return S_OK;
  }

  // IAudioProcessingObjectRT - RT thread, no locks/allocs/COM here
  STDMETHODIMP_(void) APOProcess(UINT32 numIn, APO_CONNECTION_PROPERTY** in,
                                 UINT32 numOut, APO_CONNECTION_PROPERTY** out) override {
    if (numIn != 1 || numOut != 1) return;
    if (native_) {
      ProcessNative(in, out[0]);
      return;
    }
    APO_CONNECTION_PROPERTY* cin = in[0];
    APO_CONNECTION_PROPERTY* cout = out[0];
    UINT32 frames = cin->u32ValidFrameCount;
    auto* src = (const float*)cin->pBuffer;
    auto* dst = (float*)cout->pBuffer;
    if (cin->u32BufferFlags == BUFFER_VALID && frames) {
      if (dst != src) memcpy(dst, src, (size_t)frames * channels_ * sizeof(float));
      sink_.PushFrames(src, channels_, frames);
    }
    cout->u32ValidFrameCount = frames;
    cout->u32BufferFlags = cin->u32BufferFlags;
  }
  STDMETHODIMP_(UINT32) CalcInputFrames(UINT32 outputFrames) override { return outputFrames; }
  STDMETHODIMP_(UINT32) CalcOutputFrames(UINT32 inputFrames) override { return inputFrames; }

private:
  static bool ReadTargetId(wchar_t (&target_id)[512]) {
    DWORD size = sizeof(target_id);
    return RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtualSurroundSound", L"TargetDeviceId",
                        RRF_RT_REG_SZ, nullptr, target_id, &size) == ERROR_SUCCESS && target_id[0];
  }

  void StartWatcher() {
    if (watch_thread_) return;
    watch_stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    watch_thread_ = CreateThread(nullptr, 0, WatchProc, this, 0, nullptr);
  }

  void StopWatcher() {
    if (!watch_thread_) return;
    SetEvent(watch_stop_);
    WaitForSingleObject(watch_thread_, 3000);
    CloseHandle(watch_thread_);
    CloseHandle(watch_stop_);
    watch_thread_ = nullptr;
    watch_stop_ = nullptr;
  }

  static DWORD WINAPI WatchProc(LPVOID param) {
    auto* self = (VssApo*)param;
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\VirtualSurroundSound", 0,
                      KEY_NOTIFY | KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
      dbg(L"watcher: config key open failed");
      return 0;
    }
    HANDLE change = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    for (;;) {
      if (RegNotifyChangeKeyValue(key, FALSE, REG_NOTIFY_CHANGE_LAST_SET, change, TRUE) != ERROR_SUCCESS) break;
      HANDLE waits[2] = { self->watch_stop_, change };
      if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) != WAIT_OBJECT_0 + 1) break;  // stop or error
      wchar_t target_id[512];
      bool has = ReadTargetId(target_id);
      // restart on any write, unchanged value included: reconnect rewrites the same id and the
      // sink may be holding a stream bound to the device instance that went away
      if (has) {
        dbg(L"watcher: target written, restarting sink");
        wcscpy_s(self->current_target_, target_id);
        self->sink_.Stop();
        self->sink_.Start(target_id, self->rate_);
      } else if (self->current_target_[0]) {
        dbg(L"watcher: target cleared, stopping sink");
        self->current_target_[0] = 0;
        self->sink_.Stop();
      }
    }
    CloseHandle(change);
    RegCloseKey(key);
    return 0;
  }

  static bool IsFloat32Type(IAudioMediaType* type) {
    const WAVEFORMATEX* wf = type->GetAudioFormat();
    if (!wf) return false;
    if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
      return IsEqualGUID(((const WAVEFORMATEXTENSIBLE*)wf)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != FALSE;
    return false;
  }

  // pass-through APO: accept float32, force in/out format identical
  static HRESULT CheckFormat(IAudioMediaType* opposite, IAudioMediaType* requested, IAudioMediaType** supported) {
    if (!requested || !supported) return E_POINTER;
    const WAVEFORMATEX* rq = requested->GetAudioFormat();
    if (rq) dbg(L"CheckFormat", MAKELONG((WORD)rq->nChannels, (WORD)(rq->nSamplesPerSec / 100)));
    *supported = nullptr;
    if (opposite) {
      const WAVEFORMATEX* a = opposite->GetAudioFormat();
      const WAVEFORMATEX* b = requested->GetAudioFormat();
      if (a && b && (a->nChannels != b->nChannels || a->nSamplesPerSec != b->nSamplesPerSec ||
                     a->wBitsPerSample != b->wBitsPerSample)) {
        *supported = opposite;
        opposite->AddRef();
        return S_FALSE;
      }
    }
    if (!IsFloat32Type(requested)) return APOERR_FORMAT_NOT_SUPPORTED;
    *supported = requested;
    requested->AddRef();
    return S_OK;
  }

  // one side of the native APO: input 8 ch float32 preferred, output 2 ch float32, rate follows the other side
  static HRESULT CheckSide(IAudioMediaType* opposite, IAudioMediaType* requested, IAudioMediaType** supported,
                           UINT32 channels, DWORD mask) {
    if (!requested || !supported) return E_POINTER;
    *supported = nullptr;
    const WAVEFORMATEX* rq = requested->GetAudioFormat();
    if (!rq) return APOERR_FORMAT_NOT_SUPPORTED;
    UINT32 rate = rq->nSamplesPerSec;
    if (opposite && opposite->GetAudioFormat()) rate = opposite->GetAudioFormat()->nSamplesPerSec;
    // apps also open 1, 2 and 6 ch streams on the endpoint, the native APO takes them as they are
    bool count_ok = rq->nChannels == channels ||
                    (channels == 8 && (rq->nChannels == 1 || rq->nChannels == 2 || rq->nChannels == 6));
    if (IsFloat32Type(requested) && rq->wBitsPerSample == 32 && count_ok && rq->nSamplesPerSec == rate) {
      *supported = requested;
      requested->AddRef();
      return S_OK;
    }
    *supported = new (std::nothrow) SuggestedType(channels, mask, rate);
    dbg(L"CheckSide suggested other format");
    return *supported ? S_FALSE : E_OUTOFMEMORY;
  }

  static HRESULT MakeFloatType(UINT32 channels, DWORD mask, IAudioMediaType* other, IAudioMediaType** preferred) {
    if (!preferred) return E_POINTER;
    const WAVEFORMATEX* of = other ? other->GetAudioFormat() : nullptr;
    *preferred = new (std::nothrow) SuggestedType(channels, mask, of ? of->nSamplesPerSec : 48000);
    return *preferred ? S_OK : E_OUTOFMEMORY;
  }

  // RT thread. Hosted Equalizer APO (HeSuVi) writes the binaural result to FL/FR and zeroes the rest,
  // without it the native APO is a plain downmix
  void ProcessNative(APO_CONNECTION_PROPERTY** in, APO_CONNECTION_PROPERTY* cout) {
    APO_CONNECTION_PROPERTY* cin = in[0];
    UINT32 frames = cin->u32ValidFrameCount;
    auto* dst = (float*)cout->pBuffer;
    APO_CONNECTION_PROPERTY connection = *cin;
    bool in_range = frames <= mid_frames_;
    if (in_range) {
      pre_mix_.Process(&connection);
      post_mix_.Process(&connection);
    }
    bool hosted = in_range && post_mix_.locked;
    UINT32 src_channels = in_range && (pre_mix_.locked || post_mix_.locked) ? 8 : channels_;
    auto* src = (const float*)connection.pBuffer;
    APO_BUFFER_FLAGS flags = (APO_BUFFER_FLAGS)connection.u32BufferFlags;
    if (flags == BUFFER_VALID && frames) {
      for (UINT32 i = 0; i < frames; i++) {
        const float* f = src + (size_t)i * src_channels;
        float left = f[0];
        float right = src_channels > 1 ? f[1] : f[0];
        if (!hosted && src_channels >= 6) {
          left += 0.7f * (f[2] + f[4]);
          right += 0.7f * (f[2] + f[5]);
        }
        if (!hosted && src_channels == 8) {
          left += 0.7f * f[6];
          right += 0.7f * f[7];
        }
        dst[i * 2] = left;
        dst[i * 2 + 1] = right;
      }
    }
    cout->u32ValidFrameCount = frames;
    cout->u32BufferFlags = flags;
  }

public:
  LONG refs_ = 1;  // owned by Inner; public for Inner access
private:
  IUnknown* outer_ = nullptr;  // controlling unknown, not AddRef'd (outer outlives us)
  bool native_ = false;  // set by the CLSID: native APO, otherwise forwarder
  bool locked_ = false;
  bool discovery_only_ = false;
  bool default_mode_ = true;
  UINT32 channels_ = 0;
  UINT32 rate_ = 48000;
  wchar_t current_target_[512] = {};
  HANDLE watch_thread_ = nullptr;
  HANDLE watch_stop_ = nullptr;
  RenderSink sink_;
  HostedStage pre_mix_;
  HostedStage post_mix_;
  IAudioMediaType* mid_type_ = nullptr;  // 8 ch format between the hosted stages and the downmix
  UINT32 mid_frames_ = 0;  // buffer size of the hosted stages
};

// ---------------------------------------------------------------------------
// Class factory + DLL plumbing
// ---------------------------------------------------------------------------

class VssApoFactory : public IClassFactory {
public:
  explicit VssApoFactory(bool native) : native_(native) {}
  STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    wchar_t iid_str[64];
    StringFromGUID2(riid, iid_str, 64);
    dbg(iid_str);
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IClassFactory)) {
      *ppv = static_cast<IClassFactory*>(this);
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { dbg(L"factory AddRef"); return 2; }   // static lifetime
  STDMETHODIMP_(ULONG) Release() override { dbg(L"factory Release"); return 1; }
  STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
    dbg(outer ? L"CreateInstance aggregated" : L"CreateInstance standalone");
    if (!ppv) return E_POINTER;
    if (outer && riid != __uuidof(IUnknown)) return CLASS_E_NOAGGREGATION;  // aggregation must ask IUnknown
    auto* apo = new (std::nothrow) VssApo(outer, native_);
    if (!apo) return E_OUTOFMEMORY;
    HRESULT hr = apo->inner_.QueryInterface(riid, ppv);  // non-delegating identity
    apo->inner_.Release();
    return hr;
  }
  STDMETHODIMP LockServer(BOOL lock) override {
    dbg(L"LockServer", lock);
    if (lock) g_object_count++; else g_object_count--;
    return S_OK;
  }
private:
  bool native_;
};

static VssApoFactory g_forwarder_factory(false);
static VssApoFactory g_native_factory(true);

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    g_module = (HMODULE)instance;
    DisableThreadLibraryCalls(instance);
    wchar_t host[MAX_PATH];
    GetModuleFileNameW(nullptr, host, MAX_PATH);
    dbg(host);
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
  dbg(L"DllGetClassObject");
  if (rclsid == CLSID_VssForwarderAPO) return g_forwarder_factory.QueryInterface(riid, ppv);
  if (rclsid == CLSID_VssNativeAPO) return g_native_factory.QueryInterface(riid, ppv);
  return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow() {
  dbg(L"DllCanUnloadNow");
  return g_object_count.load() > 0 ? S_FALSE : S_OK;
}

static LONG reg_set(HKEY root, const wchar_t* key, const wchar_t* name, DWORD type, const void* value, DWORD size) {
  HKEY h;
  LONG rc = RegCreateKeyExW(root, key, 0, nullptr, 0, KEY_WRITE, nullptr, &h, nullptr);
  if (rc == ERROR_SUCCESS) {
    rc = RegSetValueExW(h, name, 0, type, (const BYTE*)value, size);
    RegCloseKey(h);
  }
  return rc;
}

struct ApoClass {
  const wchar_t* clsid;
  const wchar_t* name;
  DWORD flags;
};

static const ApoClass APO_CLASSES[] = {
  // match EqualizerAPO: INPLACE + FPS/BPS match, NO samplesperframe-must-match
  { L"{B2F007A1-EAD1-478B-9888-ABC593E55B5D}", L"VSS Forwarder APO",
    APO_FLAG_INPLACE | APO_FLAG_FRAMESPERSECOND_MUST_MATCH | APO_FLAG_BITSPERSAMPLE_MUST_MATCH },
  // channel count changes, so not in place
  { L"{7C1E5A42-5D0B-4E0C-9B7A-6F3B2D9E8A11}", L"VSS Native APO",
    APO_FLAG_FRAMESPERSECOND_MUST_MATCH | APO_FLAG_BITSPERSAMPLE_MUST_MATCH },
};

STDAPI DllRegisterServer() {
  wchar_t dll_path[MAX_PATH];
  GetModuleFileNameW(g_module, dll_path, MAX_PATH);
  wchar_t key[256];

  for (const ApoClass& apo : APO_CLASSES) {
    DWORD name_size = (DWORD)(wcslen(apo.name) + 1) * 2;
    swprintf_s(key, L"CLSID\\%s", apo.clsid);
    reg_set(HKEY_CLASSES_ROOT, key, nullptr, REG_SZ, apo.name, name_size);
    swprintf_s(key, L"CLSID\\%s\\InprocServer32", apo.clsid);
    reg_set(HKEY_CLASSES_ROOT, key, nullptr, REG_SZ, dll_path, (DWORD)(wcslen(dll_path) + 1) * 2);
    reg_set(HKEY_CLASSES_ROOT, key, L"ThreadingModel", REG_SZ, L"Both", 10);

    swprintf_s(key, L"AudioEngine\\AudioProcessingObjects\\%s", apo.clsid);
    reg_set(HKEY_CLASSES_ROOT, key, L"FriendlyName", REG_SZ, apo.name, name_size);
    reg_set(HKEY_CLASSES_ROOT, key, L"Copyright", REG_SZ, L"MIT", 8);
    DWORD v;
    v = 1; reg_set(HKEY_CLASSES_ROOT, key, L"MajorVersion", REG_DWORD, &v, 4);
    v = 0; reg_set(HKEY_CLASSES_ROOT, key, L"MinorVersion", REG_DWORD, &v, 4);
    reg_set(HKEY_CLASSES_ROOT, key, L"Flags", REG_DWORD, &apo.flags, 4);
    v = 1;
    reg_set(HKEY_CLASSES_ROOT, key, L"MinInputConnections", REG_DWORD, &v, 4);
    reg_set(HKEY_CLASSES_ROOT, key, L"MaxInputConnections", REG_DWORD, &v, 4);
    reg_set(HKEY_CLASSES_ROOT, key, L"MinOutputConnections", REG_DWORD, &v, 4);
    reg_set(HKEY_CLASSES_ROOT, key, L"MaxOutputConnections", REG_DWORD, &v, 4);
    v = 0xFFFFFFFF; reg_set(HKEY_CLASSES_ROOT, key, L"MaxInstances", REG_DWORD, &v, 4);
    v = 1; reg_set(HKEY_CLASSES_ROOT, key, L"NumAPOInterfaces", REG_DWORD, &v, 4);
    reg_set(HKEY_CLASSES_ROOT, key, L"APOInterface0", REG_SZ,
            L"{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}", 78);
  }
  return S_OK;
}

STDAPI DllUnregisterServer() {
  wchar_t key[256];
  for (const ApoClass& apo : APO_CLASSES) {
    swprintf_s(key, L"CLSID\\%s", apo.clsid);
    RegDeleteTreeW(HKEY_CLASSES_ROOT, key);
    swprintf_s(key, L"AudioEngine\\AudioProcessingObjects\\%s", apo.clsid);
    RegDeleteTreeW(HKEY_CLASSES_ROOT, key);
  }
  return S_OK;
}
