param([string]$id)
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
  int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object itf);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation {
  int GetPeakValue(out float peak);
}
public static class Meter {
  public static float Peak(string id) {
    var en = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorCom();
    IMMDevice dev;
    en.GetDevice(id, out dev);
    var iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
    object o;
    dev.Activate(ref iid, 23, IntPtr.Zero, out o);
    float p;
    ((IAudioMeterInformation)o).GetPeakValue(out p);
    return p;
  }
}
"@
$max = 0.0
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 100
  $p = [Meter]::Peak($id)
  if ($p -gt $max) { $max = $p }
}
Write-Output "max peak: $max"
