# Show or set the device format and mix format of one render endpoint via IPolicyConfig::SetDeviceFormat (same path as mmsys.cpl Configure).
# usage: format_policy.ps1 -endpoint '{guid}' [-mode show|cable|native]
# cable: device and mix 48 kHz 8 ch 24-bit PCM, for CABLE Input.
# native: re-applies the current device format with a 2 ch float mix. This makes the engine ask the stream effect
#   for its preferred format again: 8 ch with the native APO installed, 2 ch after removal.
param([Parameter(Mandatory)][ValidatePattern('^\{[0-9a-fA-F-]{36}\}$')][string]$endpoint,
  [ValidateSet('show', 'cable', 'native')][string]$mode = 'show')
$device_id = "{0.0.0.00000000}.$endpoint"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClientCom {}
[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
  [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
  [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int def, out IntPtr format);
  [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
  [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
}
public static class Policy {
  static IPolicyConfig Open() { return (IPolicyConfig)(object)new PolicyConfigClientCom(); }
  static string Describe(IntPtr p) {
    if (p == IntPtr.Zero) return "null";
    ushort tag = (ushort)Marshal.ReadInt16(p, 0);
    string text = string.Format("tag=0x{0:X} ch={1} rate={2} bits={3}",
      tag, Marshal.ReadInt16(p, 2), Marshal.ReadInt32(p, 4), Marshal.ReadInt16(p, 14));
    if (tag != 0xFFFE) return text;
    return text + string.Format(" mask=0x{0:X} sub={1:X}", Marshal.ReadInt32(p, 20), (ushort)Marshal.ReadInt16(p, 24));
  }
  public static string Show(string id) {
    IntPtr mix, device, deviceDefault;
    int a = Open().GetMixFormat(id, out mix);
    int b = Open().GetDeviceFormat(id, 0, out device);
    int c = Open().GetDeviceFormat(id, 1, out deviceDefault);
    return string.Format("mix hr=0x{0:X8} {1}\ndevice hr=0x{2:X8} {3}\ndevice default hr=0x{4:X8} {5}",
      a, Describe(mix), b, Describe(device), c, Describe(deviceDefault));
  }
  static IntPtr Make(ushort channels, uint rate, ushort bits, uint mask, bool isFloat) {
    ushort block = (ushort)(channels * bits / 8);
    IntPtr p = Marshal.AllocCoTaskMem(40);
    Marshal.WriteInt16(p, 0, unchecked((short)0xFFFE));
    Marshal.WriteInt16(p, 2, (short)channels);
    Marshal.WriteInt32(p, 4, (int)rate);
    Marshal.WriteInt32(p, 8, (int)(rate * block));
    Marshal.WriteInt16(p, 12, (short)block);
    Marshal.WriteInt16(p, 14, (short)bits);
    Marshal.WriteInt16(p, 16, 22);
    Marshal.WriteInt16(p, 18, (short)bits);
    Marshal.WriteInt32(p, 20, (int)mask);
    byte[] sub = { (byte)(isFloat ? 3 : 1),0,0,0, 0,0, 0x10,0, 0x80,0,0,0xAA, 0,0x38,0x9B,0x71 };
    Marshal.Copy(sub, 0, new IntPtr(p.ToInt64() + 24), 16);
    return p;
  }
  public static int SetCable(string id) {
    IntPtr format = Make(8, 48000, 24, 0xFF, false);
    int hr = Open().SetDeviceFormat(id, format, format);
    Marshal.FreeCoTaskMem(format);
    return hr;
  }
  public static int SetNative(string id) {
    IntPtr device;
    if (Open().GetDeviceFormat(id, 0, out device) < 0 || device == IntPtr.Zero) device = Make(2, 48000, 16, 0x3, false);
    IntPtr mix = Make(2, (uint)Marshal.ReadInt32(device, 4), 32, 0x3, true);
    int hr = Open().SetDeviceFormat(id, device, mix);
    Marshal.FreeCoTaskMem(device);
    Marshal.FreeCoTaskMem(mix);
    return hr;
  }
}
"@

if ($mode -eq 'cable') { Write-Output ("SetDeviceFormat hr=0x{0:X8}" -f [Policy]::SetCable($device_id)) }
if ($mode -eq 'native') { Write-Output ("SetDeviceFormat hr=0x{0:X8}" -f [Policy]::SetNative($device_id)) }
Write-Output ([Policy]::Show($device_id))
