// vss_apo.cpp
// Mode effect APO (composite MFX, after EqualizerAPO/HeSuVi) on a virtual render endpoint
// (VB-Cable "CABLE Input"). Taps the post-mix inside audiodg.exe and forwards it to a physical
// device via WASAPI. Mechanism + registration rules: docs/apo-forwarder-internals.md.
//
// Config: HKLM\SOFTWARE\VirtualSurroundSound
//   TargetDeviceId  REG_SZ  MMDevice endpoint ID, e.g. {0.0.0.00000000}.{guid}
// Read at LockForProcess and watched live (RegNotifyChangeKeyValue) for hot device switching.

#include <initguid.h>
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioenginebaseapo.h>
#include <ksmedia.h>
#include <avrt.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <new>

// {B2F007A1-EAD1-478B-9888-ABC593E55B5D} (regenerated: old {8A4F0C6D...} suspected quarantined by audiodg)
DEFINE_GUID(CLSID_VssForwarderAPO, 0xb2f007a1, 0xead1, 0x478b, 0x98, 0x88, 0xab, 0xc5, 0x93, 0xe5, 0x5b, 0x5d);

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

class RenderSink {
public:
  void Start(const wchar_t* device_id, UINT32 sample_rate) {
    Stop();
    wcsncpy_s(device_id_, device_id, _TRUNCATE);
    rate_ = sample_rate;
    ring_.read_pos.store(ring_.write_pos.load());
    stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    thread_ = CreateThread(nullptr, 0, ThreadProc, this, 0, nullptr);
    if (!thread_) dbg(L"CreateThread failed");
  }

  void Stop() {
    if (!thread_) return;
    SetEvent(stop_event_);
    WaitForSingleObject(thread_, 3000);
    CloseHandle(thread_);
    CloseHandle(stop_event_);
    thread_ = nullptr;
    stop_event_ = nullptr;
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

  void Run() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
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

      HANDLE waits[2] = { stop_event_, buffer_event };
      UINT32 max_fill = buffer_frames * 3;
      for (;;) {
        DWORD w = WaitForMultipleObjects(2, waits, FALSE, 500);
        if (w == WAIT_OBJECT_0) break;
        if (w == WAIT_FAILED) break;
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
    CoUninitialize();
  }

  StereoRing ring_;
  wchar_t device_id_[512] = {};
  UINT32 rate_ = 48000;
  HANDLE thread_ = nullptr;
  HANDLE stop_event_ = nullptr;
};

// ---------------------------------------------------------------------------
// APO COM object
// ---------------------------------------------------------------------------

class VssApo : public IAudioProcessingObject,
               public IAudioProcessingObjectRT,
               public IAudioProcessingObjectConfiguration,
               public IAudioSystemEffects {
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

  explicit VssApo(IUnknown* outer) {
    inner_.self = this;
    outer_ = outer ? outer : static_cast<IUnknown*>(&inner_);
    g_object_count++;
  }
  virtual ~VssApo() { sink_.Stop(); g_object_count--; }

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
    p->clsid = CLSID_VssForwarderAPO;
    p->Flags = (APO_FLAG)(APO_FLAG_INPLACE | APO_FLAG_DEFAULT);
    wcscpy_s(p->szFriendlyName, L"VSS Forwarder APO");
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
    return S_OK;
  }
  STDMETHODIMP IsInputFormatSupported(IAudioMediaType* pOppositeFormat, IAudioMediaType* pRequestedInputFormat,
                                      IAudioMediaType** ppSupportedInputFormat) override {
    return CheckFormat(pOppositeFormat, pRequestedInputFormat, ppSupportedInputFormat);
  }
  STDMETHODIMP IsOutputFormatSupported(IAudioMediaType* pOppositeFormat, IAudioMediaType* pRequestedOutputFormat,
                                       IAudioMediaType** ppSupportedOutputFormat) override {
    return CheckFormat(pOppositeFormat, pRequestedOutputFormat, ppSupportedOutputFormat);
  }
  STDMETHODIMP GetInputChannelCount(UINT32* pu32ChannelCount) override {
    if (!pu32ChannelCount) return E_POINTER;
    *pu32ChannelCount = channels_ ? channels_ : 2;
    return S_OK;
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
    locked_ = true;
    if (!discovery_only_ && default_mode_) {
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
    StopWatcher();
    sink_.Stop();
    locked_ = false;
    return S_OK;
  }

  // IAudioProcessingObjectRT - RT thread, no locks/allocs/COM here
  STDMETHODIMP_(void) APOProcess(UINT32 numIn, APO_CONNECTION_PROPERTY** in,
                                 UINT32 numOut, APO_CONNECTION_PROPERTY** out) override {
    if (numIn != 1 || numOut != 1) return;
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
      if (has && wcscmp(target_id, self->current_target_) != 0) {
        dbg(L"watcher: target changed, restarting sink");
        wcscpy_s(self->current_target_, target_id);
        self->sink_.Stop();
        self->sink_.Start(target_id, self->rate_);
      } else if (!has && self->current_target_[0]) {
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

public:
  LONG refs_ = 1;  // owned by Inner; public for Inner access
private:
  IUnknown* outer_ = nullptr;  // controlling unknown, not AddRef'd (outer outlives us)
  bool locked_ = false;
  bool discovery_only_ = false;
  bool default_mode_ = true;
  UINT32 channels_ = 0;
  UINT32 rate_ = 48000;
  wchar_t current_target_[512] = {};
  HANDLE watch_thread_ = nullptr;
  HANDLE watch_stop_ = nullptr;
  RenderSink sink_;
};

// ---------------------------------------------------------------------------
// Class factory + DLL plumbing
// ---------------------------------------------------------------------------

class VssApoFactory : public IClassFactory {
public:
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
    auto* apo = new (std::nothrow) VssApo(outer);
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
};

static VssApoFactory g_factory;

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
  if (rclsid != CLSID_VssForwarderAPO) return CLASS_E_CLASSNOTAVAILABLE;
  return g_factory.QueryInterface(riid, ppv);
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

static const wchar_t* CLSID_STR = L"{B2F007A1-EAD1-478B-9888-ABC593E55B5D}";

STDAPI DllRegisterServer() {
  wchar_t dll_path[MAX_PATH];
  GetModuleFileNameW(g_module, dll_path, MAX_PATH);
  wchar_t key[256];

  swprintf_s(key, L"CLSID\\%s", CLSID_STR);
  reg_set(HKEY_CLASSES_ROOT, key, nullptr, REG_SZ, L"VSS Forwarder APO", 36);
  swprintf_s(key, L"CLSID\\%s\\InprocServer32", CLSID_STR);
  reg_set(HKEY_CLASSES_ROOT, key, nullptr, REG_SZ, dll_path, (DWORD)(wcslen(dll_path) + 1) * 2);
  reg_set(HKEY_CLASSES_ROOT, key, L"ThreadingModel", REG_SZ, L"Both", 10);

  swprintf_s(key, L"AudioEngine\\AudioProcessingObjects\\%s", CLSID_STR);
  reg_set(HKEY_CLASSES_ROOT, key, L"FriendlyName", REG_SZ, L"VSS Forwarder APO", 36);
  reg_set(HKEY_CLASSES_ROOT, key, L"Copyright", REG_SZ, L"MIT", 8);
  DWORD v;
  v = 1; reg_set(HKEY_CLASSES_ROOT, key, L"MajorVersion", REG_DWORD, &v, 4);
  v = 0; reg_set(HKEY_CLASSES_ROOT, key, L"MinorVersion", REG_DWORD, &v, 4);
  // match EqualizerAPO: INPLACE + FPS/BPS match, NO samplesperframe-must-match
  v = APO_FLAG_INPLACE | APO_FLAG_FRAMESPERSECOND_MUST_MATCH | APO_FLAG_BITSPERSAMPLE_MUST_MATCH;
  reg_set(HKEY_CLASSES_ROOT, key, L"Flags", REG_DWORD, &v, 4);
  v = 1;
  reg_set(HKEY_CLASSES_ROOT, key, L"MinInputConnections", REG_DWORD, &v, 4);
  reg_set(HKEY_CLASSES_ROOT, key, L"MaxInputConnections", REG_DWORD, &v, 4);
  reg_set(HKEY_CLASSES_ROOT, key, L"MinOutputConnections", REG_DWORD, &v, 4);
  reg_set(HKEY_CLASSES_ROOT, key, L"MaxOutputConnections", REG_DWORD, &v, 4);
  v = 0xFFFFFFFF; reg_set(HKEY_CLASSES_ROOT, key, L"MaxInstances", REG_DWORD, &v, 4);
  v = 1; reg_set(HKEY_CLASSES_ROOT, key, L"NumAPOInterfaces", REG_DWORD, &v, 4);
  reg_set(HKEY_CLASSES_ROOT, key, L"APOInterface0", REG_SZ,
          L"{FD7F2B29-24D0-4B5C-B177-592C39F9CA10}", 78);
  return S_OK;
}

STDAPI DllUnregisterServer() {
  wchar_t key[256];
  swprintf_s(key, L"CLSID\\%s", CLSID_STR);
  RegDeleteTreeW(HKEY_CLASSES_ROOT, key);
  swprintf_s(key, L"AudioEngine\\AudioProcessingObjects\\%s", CLSID_STR);
  RegDeleteTreeW(HKEY_CLASSES_ROOT, key);
  return S_OK;
}
