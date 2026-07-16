# step 440Hz tone through each channel of the endpoint mix format (7.1 positional test)
# order at 8ch: FL FR C LFE RL RR SL SR
param(
  [string]$target = '{0.0.0.00000000}.{df289d1a-058d-406c-a321-e1a0a6011984}',
  [double]$secs_per_ch = 1.5
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
public static class ChanTone {
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
  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  struct WaveFormatEx {
    public ushort wFormatTag, nChannels;
    public uint nSamplesPerSec, nAvgBytesPerSec;
    public ushort nBlockAlign, wBitsPerSample, cbSize;
  }
  public static void Play(string id, double secsPerCh) {
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
    int rate = (int)fmt.nSamplesPerSec, ch = fmt.nChannels;
    string[] names = { "FL","FR","C","LFE","RL","RR","SL","SR" };
    Console.WriteLine("mix: " + ch + "ch " + rate + "Hz");
    Marshal.ThrowExceptionForHR(ac.Initialize(0, 0, 10000000, 0, pFmt, IntPtr.Zero));
    uint bufFrames;
    Marshal.ThrowExceptionForHR(ac.GetBufferSize(out bufFrames));
    var iidRc = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
    IntPtr pRc;
    Marshal.ThrowExceptionForHR(ac.GetService(ref iidRc, out pRc));
    var rc = (IAudioRenderClient)Marshal.GetObjectForIUnknown(pRc);
    Marshal.ThrowExceptionForHR(ac.Start());
    long framesPerCh = (long)(rate * secsPerCh);
    double phase = 0, step = 2 * Math.PI * 440.0 / rate;
    for (int c = 0; c < ch; c++) {
      Console.WriteLine("channel " + c + (c < names.Length ? " (" + names[c] + ")" : ""));
      long done = 0;
      while (done < framesPerCh) {
        uint padding;
        Marshal.ThrowExceptionForHR(ac.GetCurrentPadding(out padding));
        uint avail = bufFrames - padding;
        if (avail == 0) { System.Threading.Thread.Sleep(5); continue; }
        if (avail > framesPerCh - done) avail = (uint)(framesPerCh - done);
        IntPtr data;
        Marshal.ThrowExceptionForHR(rc.GetBuffer(avail, out data));
        unsafe {
          float* p = (float*)data;
          for (uint i = 0; i < avail; i++) {
            // 100ms fade-gap between channels to make transitions obvious
            double t = (double)(done + i) / framesPerCh;
            float s = t > 0.93 ? 0f : (float)(0.4 * Math.Sin(phase));
            phase += step;
            for (int k = 0; k < ch; k++) *p++ = (k == c) ? s : 0f;
          }
        }
        Marshal.ThrowExceptionForHR(rc.ReleaseBuffer(avail, 0));
        done += avail;
      }
    }
    System.Threading.Thread.Sleep(300);
    ac.Stop();
  }
}
"@ -CompilerParameters (New-Object System.CodeDom.Compiler.CompilerParameters -Property @{ CompilerOptions = '/unsafe' })

[ChanTone]::Play($target, $secs_per_ch)
Write-Output 'done'
