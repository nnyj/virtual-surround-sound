# set CABLE Input to 48kHz 8ch via IPolicyConfig::SetDeviceFormat (same path as mmsys.cpl Configure)
$cable_id = '{0.0.0.00000000}.{df289d1a-058d-406c-a321-e1a0a6011984}'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigClientCom {}
[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
  [PreserveSig] int GetMixFormat(string deviceId, out IntPtr format);
  [PreserveSig] int GetDeviceFormat(string deviceId, int def, out IntPtr format);
  [PreserveSig] int ResetDeviceFormat(string deviceId);
  [PreserveSig] int SetDeviceFormat(string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
  [PreserveSig] int GetProcessingPeriod(string deviceId, int def, out long defPeriod, out long minPeriod);
  [PreserveSig] int SetProcessingPeriod(string deviceId, ref long period);
  [PreserveSig] int GetShareMode(string deviceId, IntPtr mode);
  [PreserveSig] int SetShareMode(string deviceId, IntPtr mode);
  [PreserveSig] int GetPropertyValue(string deviceId, int bFxStore, IntPtr key, IntPtr value);
  [PreserveSig] int SetPropertyValue(string deviceId, int bFxStore, IntPtr key, IntPtr value);
  [PreserveSig] int SetDefaultEndpoint(string deviceId, int role);
  [PreserveSig] int SetEndpointVisibility(string deviceId, int visible);
}
public static class Fmt {
  public static int Set(string id, ushort ch, uint rate, ushort bits, uint mask) {
    ushort block = (ushort)(ch * bits / 8);
    IntPtr p = Marshal.AllocCoTaskMem(40);
    Marshal.WriteInt16(p, 0, unchecked((short)0xFFFE));
    Marshal.WriteInt16(p, 2, (short)ch);
    Marshal.WriteInt32(p, 4, (int)rate);
    Marshal.WriteInt32(p, 8, (int)(rate * block));
    Marshal.WriteInt16(p, 12, (short)block);
    Marshal.WriteInt16(p, 14, (short)bits);
    Marshal.WriteInt16(p, 16, 22);
    Marshal.WriteInt16(p, 18, (short)bits);
    Marshal.WriteInt32(p, 20, (int)mask);
    byte[] pcm = { 0x01,0,0,0, 0,0, 0x10,0, 0x80,0,0,0xAA, 0,0x38,0x9B,0x71 };
    Marshal.Copy(pcm, 0, new IntPtr(p.ToInt64() + 24), 16);
    var pc = (IPolicyConfig)(object)new PolicyConfigClientCom();
    int hr = pc.SetDeviceFormat(id, p, p);
    Marshal.FreeCoTaskMem(p);
    return hr;
  }
}
"@

$hr = [Fmt]::Set($cable_id, 8, 48000, 24, 0xFF)
Write-Output ("SetDeviceFormat hr=0x{0:X8}" -f $hr)
