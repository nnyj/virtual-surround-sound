# play 440Hz tone DIRECTLY to an endpoint via WASAPI shared mode (bypasses default-device routing entirely)
# usage: wasapi_tone.ps1 [-target <endpoint_id>] [-secs 3]
param(
  [string]$target = '{0.0.0.00000000}.{df289d1a-058d-406c-a321-e1a0a6011984}',
  [int]$secs = 3
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
  int GetDevice(string id, out IMMDevice device);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr itf);
}
public static class TonePlayer {
  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  struct WaveFormatEx {
    public ushort wFormatTag, nChannels;
    public uint nSamplesPerSec, nAvgBytesPerSec;
    public ushort nBlockAlign, wBitsPerSample, cbSize;
  }
  [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioClient {
    int Initialize(int shareMode, uint flags, long duration, long periodicity, IntPtr format, IntPtr sessionGuid);
    int GetBufferSize(out uint frames);
    int GetStreamLatency(out long latency);
    int GetCurrentPadding(out uint padding);
    int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    int GetMixFormat(out IntPtr format);
    int GetDevicePeriod(out long def, out long min);
    int Start();
    int Stop();
    int Reset();
    int SetEventHandle(IntPtr handle);
    int GetService(ref Guid iid, out IntPtr svc);
  }
  [Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioRenderClient {
    int GetBuffer(uint frames, out IntPtr data);
    int ReleaseBuffer(uint frames, uint flags);
  }
  public static void Play(string id, int secs) {
    var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorCom();
    IMMDevice dev;
    Marshal.ThrowExceptionForHR(en.GetDevice(id, out dev));
    var iidAc = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    IntPtr pAc;
    Marshal.ThrowExceptionForHR(dev.Activate(ref iidAc, 23, IntPtr.Zero, out pAc));
    var ac = (IAudioClient)Marshal.GetObjectForIUnknown(pAc);
    IntPtr pFmt;
    Marshal.ThrowExceptionForHR(ac.GetMixFormat(out pFmt));
    var fmt = (WaveFormatEx)Marshal.PtrToStructure(pFmt, typeof(WaveFormatEx));
    Console.WriteLine("mix format: " + fmt.nChannels + "ch " + fmt.nSamplesPerSec + "Hz " + fmt.wBitsPerSample + "bit tag=" + fmt.wFormatTag);
    Marshal.ThrowExceptionForHR(ac.Initialize(0, 0, 10000000, 0, pFmt, IntPtr.Zero));
    uint bufFrames;
    Marshal.ThrowExceptionForHR(ac.GetBufferSize(out bufFrames));
    var iidRc = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
    IntPtr pRc;
    Marshal.ThrowExceptionForHR(ac.GetService(ref iidRc, out pRc));
    var rc = (IAudioRenderClient)Marshal.GetObjectForIUnknown(pRc);
    int rate = (int)fmt.nSamplesPerSec, ch = fmt.nChannels;
    bool floatFmt = fmt.wFormatTag == 3 || (fmt.wFormatTag == 0xFFFE && fmt.wBitsPerSample == 32);
    long total = (long)rate * secs, done = 0;
    double phase = 0, step = 2 * Math.PI * 440.0 / rate;
    Marshal.ThrowExceptionForHR(ac.Start());
    while (done < total) {
      uint padding;
      Marshal.ThrowExceptionForHR(ac.GetCurrentPadding(out padding));
      uint avail = bufFrames - padding;
      if (avail == 0) { System.Threading.Thread.Sleep(5); continue; }
      IntPtr data;
      Marshal.ThrowExceptionForHR(rc.GetBuffer(avail, out data));
      unsafe {
        if (floatFmt) {
          float* p = (float*)data;
          for (uint i = 0; i < avail; i++) {
            float s = (float)(0.366 * Math.Sin(phase)); phase += step;
            for (int c = 0; c < ch; c++) *p++ = s;
          }
        } else {
          short* p = (short*)data;
          for (uint i = 0; i < avail; i++) {
            short s = (short)(12000 * Math.Sin(phase)); phase += step;
            for (int c = 0; c < ch; c++) *p++ = s;
          }
        }
      }
      Marshal.ThrowExceptionForHR(rc.ReleaseBuffer(avail, 0));
      done += avail;
    }
    System.Threading.Thread.Sleep(300);
    ac.Stop();
  }
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters -Property @{ CompilerOptions = '/unsafe' })

[TonePlayer]::Play($target, $secs)
Write-Output "played $secs s tone to $target"
