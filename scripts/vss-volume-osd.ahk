#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode("Input")
SetWorkingDir(A_ScriptDir)
CoordMode("Mouse", "Screen")
CoordMode("Menu", "Screen")

ShowTrayIcon := true
AlwaysShowDevice := true

RegKey := "HKCU\SOFTWARE\VirtualSurroundSound\AHK"
SoundCli := A_ScriptDir "\..\tools\soundvolumeview.exe"
if !FileExist(SoundCli)
  SoundCli := "soundvolumeview.exe"
CableFilter := "VB-Audio Virtual Cable"
CableRender := "VB-Audio Virtual Cable\Device\CABLE Input\Render"

AudioDevice := ""
try AudioDevice := RegRead(RegKey, "AudioDevice")

IsDefaultDevice() {
  return InStr(SoundGetName(), "CABLE Input")
}

GetDevice() {
  global AudioDevice
  try
    AudioDevice := RegRead(RegKey, "AudioDevice")
  return AudioDevice
}

GetVolPercent() {
  try return Round(SoundGetVolume(, GetDevice()))
  try return Round(SoundGetVolume())
  return 0
}

IsMouseLocal() {
  try return WinGetProcessName("A") != "PowerToys.MouseWithoutBordersHelper.exe"
  return true
}

Volume(Offset) {
  if !IsDefaultDevice()
    return
  dev := GetDevice()
  try {
    SoundSetVolume Format("{:+d}", Offset), , dev
    UpdateTrayIcon(Round(SoundGetVolume(, dev)))
    if AlwaysShowDevice
      ShowDeviceOsd(dev)
    else
      ShowVolOsd()
  }
}

; --- Device management ---

EnumerateDevices() {
  devices := []
  ; unique per process: SingleInstance Force kills old script but not its soundvolumeview child, which may still hold shared file
  tmpFile := A_Temp "\vss_devices_" DllCall("GetCurrentProcessId") ".csv"
  loop files A_Temp "\vss_devices*.csv"
    try FileDelete(A_LoopFileFullPath)
  try {
    RunWait('"' SoundCli '" /scomma "' tmpFile '" /Columns "Name,Type,Direction,DeviceName,ItemID"', , "Hide")
    output := FileRead(tmpFile)
    FileDelete(tmpFile)
  } catch
    return devices
  loop parse output, "`n", "`r" {
    if A_Index = 1
      continue
    if !A_LoopField
      continue
    parts := StrSplit(A_LoopField, ",")
    if parts.Length < 5
      continue
    if parts[2] = "Device" && parts[3] = "Render" && parts[4] != CableFilter
      devices.Push({name: parts[1], deviceName: parts[4], id: parts[5], label: parts[1] " (" parts[4] ")"})
  }
  return devices
}

RouteDevice(name, deviceName, deviceId) {
  ; vss_apo.dll watches TargetDeviceId (RegNotifyChangeKeyValue) and re-points its sink live.
  ; reg add requests KEY_WRITE and gets denied for non-admin; .NET open with exact rights works
  ; (apo\install.ps1 grants Users QueryValues+SetValue on the key).
  RunWait('powershell -NoProfile -Command "'
    . "$k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\VirtualSurroundSound',"
    . "[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,"
    . "[System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue);"
    . "$k.SetValue('TargetDeviceId','" deviceId "','String');$k.Close()"
    . '"', , "Hide")

  RunWait(A_ComSpec ' /c "' SoundCli '" /Enable "' CableRender '"', , "Hide")
  loop 3
    RunWait(A_ComSpec ' /c "' SoundCli '" /SetDefault "' CableRender '" ' (A_Index - 1), , "Hide")

  label := name " (" deviceName ")"
  RegWrite(label, "REG_SZ", RegKey, "AudioDevice")
  RegWrite(deviceId, "REG_SZ", RegKey, "AudioDeviceId")
}

; --- Tray menu ---

BuildTrayMenu() {
  A_TrayMenu.Delete()
  A_TrayMenu.Add("Show device OSD", ToggleShowDevice)
  if AlwaysShowDevice
    A_TrayMenu.Check("Show device OSD")
  A_TrayMenu.Add()
  devices := EnumerateDevices()
  if devices.Length {
    for dev in devices {
      A_TrayMenu.Add(dev.label, SwitchDevice.Bind(dev))
      if dev.label = AudioDevice
        A_TrayMenu.Check(dev.label)
    }
  } else {
    A_TrayMenu.Add("(no devices found)", (*) => 0)
    A_TrayMenu.Disable("(no devices found)")
  }
  A_TrayMenu.Add()
  A_TrayMenu.Add("Sound control panel", (*) => Run("mmsys.cpl"))
  A_TrayMenu.Add("Volume mixer", (*) => Run("sndvol.exe"))
  A_TrayMenu.Add()
  A_TrayMenu.Add("Exit", (*) => ExitApp())
}

RefreshTray(*) {
  BuildTrayMenu()
  UpdateTrayIcon(GetVolPercent())
}

; vss-device-select.bat auto-route writes registry from scheduled task; watcher replaces relaunching script
WatchDevice(*) {
  prev := AudioDevice
  if GetDevice() != prev {
    RefreshTray()
    ShowDeviceOsd(AudioDevice)
  }
  ArmRegWatch()
}

ArmRegWatch() {
  ; single-shot per call, re-arm after each notification; 0x4 = REG_NOTIFY_CHANGE_LAST_SET, 0x10000000 = THREAD_AGNOSTIC
  DllCall("advapi32\RegNotifyChangeKeyValue", "Ptr", hRegKey, "Int", 0, "UInt", 0x4 | 0x10000000, "Ptr", hRegEvent, "Int", 1)
}

; runs on threadpool thread: GUI/registry work unsafe here, hand off to main thread
OnRegSignal(*) {
  DllCall("PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x8001, "Ptr", 0, "Ptr", 0)
}

ToggleShowDevice(name, pos, menu) {
  global AlwaysShowDevice
  AlwaysShowDevice := !AlwaysShowDevice
  if AlwaysShowDevice
    menu.Check(name)
  else
    menu.Uncheck(name)
}

SwitchDevice(dev, *) {
  global AudioDevice
  RouteDevice(dev.name, dev.deviceName, dev.id)
  AudioDevice := dev.label
  BuildTrayMenu()
  ShowDeviceOsd(AudioDevice)
}

; --- GUI ---

GuiStyle := "-Caption +AlwaysOnTop +ToolWindow +E0x08000000 -DPIScale"

; -DPIScale keeps layout in physical pixels, but point-sized fonts still track DPI; scale layout to match
S(n) {
  return Round(n * A_ScreenDPI / 96)
}

; rebuild OSD guis lazily on next show
EnsureOsdGuis() {
  if BuiltDpi = A_ScreenDPI
    return
  for g in [VolGui, DevGui]
    try g.Destroy()
  BuildOsdGuis()
}

; DWM-rounded corners are GPU-antialiased; SetWindowRgn regions are 1-bit masks and always jagged
RoundCorners(guiObj) {
  DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd, "UInt", 33, "UInt*", 2, "UInt", 4)  ; DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND
  DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", guiObj.Hwnd, "UInt", 34, "UInt*", 0x222222, "UInt", 4)  ; DWMWA_BORDER_COLOR, DWM draws antialiased 1px outline
}

VolIcon(vol) {
  if vol <= 0
    return Chr(0xE74F)
  if vol <= 33
    return Chr(0xE993)
  if vol <= 66
    return Chr(0xE994)
  return Chr(0xE995)
}

UpdateVolControls(vol) {
  VolGui["IconText"].Text := VolIcon(vol)
  VolGui["VolumeBar"].Value := vol
  VolGui["VolText"].Text := vol
}

BuildOsdGuis() {
  global

  ; Volume OSD
  VolW := S(192)
  VolH := S(48)

  VolGui := Gui(GuiStyle)
  VolGui.BackColor := "2b2b2b"
  VolGui.SetFont("s12", "Segoe MDL2 Assets")
  VolGui.MarginX := 0
  VolGui.MarginY := 0
  VolGui.Add("Text", "vIconText cFFFFFF x" S(12) " w" S(28) " h" VolH " Center +0x200 Section", Chr(0xE995))
  VolGui.SetFont("s9", "Segoe UI")
  VolGui.Add("Progress", "vVolumeBar w" S(102) " h" S(6) " c5294E2 Background505050 Range0-100 ys+" S(20) " x+" S(4), 0)
  VolGui.SetFont("s11", "Segoe UI Variable Display")
  VolGui.Add("Text", "vVolText cFFFFFF w" S(32) " h" VolH " Right +0x200 ys x+0", "100")

  ; Device OSD
  DevW := S(280)
  DevH := S(40)
  DevGap := S(8)

  DevGui := Gui(GuiStyle)
  DevGui.BackColor := "2b2b2b"
  DevGui.MarginX := 0
  DevGui.MarginY := 0
  DevGui.SetFont("s12", "Segoe MDL2 Assets")
  DevGui.Add("Text", "cFFFFFF x" S(12) " w" S(28) " h" DevH " Center +0x200 Section", Chr(0xE7F5))
  DevGui.SetFont("s11", "Segoe UI Variable Display")
  DevGui.Add("Text", "vDevName cFFFFFF w" (DevW - S(54)) " h" DevH " +0x200 ys x+" S(4), "")

  for g in [VolGui, DevGui]
    RoundCorners(g)

  BuiltDpi := A_ScreenDPI
}
BuildOsdGuis()

HideAll(*) {
  DevGui.Hide()
  VolGui.Hide()
}

ShowVolOsd() {
  EnsureOsdGuis()
  UpdateVolControls(GetVolPercent())
  VolGui.Show("NoActivate w" VolW " h" VolH " x" (A_ScreenWidth // 2 - VolW // 2) " y" (A_ScreenHeight - S(110)))
  SetTimer(HideAll, -2500)
}

ShowDeviceOsd(name) {
  ShowVolOsd()
  DevGui["DevName"].Text := name
  DevGui.Show("NoActivate w" DevW " h" DevH " x" (A_ScreenWidth // 2 - DevW // 2) " y" (A_ScreenHeight - S(110) - DevH - DevGap))
}

; --- Startup ---

UpdateTrayIcon(vol) {
  static hMod := DllCall("LoadLibraryEx", "Str", A_WinDir "\System32\SndVolSSO.dll", "Ptr", 0, "UInt", 0x02, "Ptr")
  resId := vol <= 0 ? 120 : vol <= 33 ? 122 : vol <= 66 ? 123 : 124
  hIcon := DllCall("LoadImage", "Ptr", hMod, "Ptr", resId, "UInt", 1, "Int", 16, "Int", 16, "UInt", 0, "Ptr")
  if hIcon
    TraySetIcon("HICON:" hIcon)
}

ShowTrayMenu() {
  MouseGetPos(&mx, &my)
  rect := Buffer(16, 0)
  DllCall("SystemParametersInfo", "UInt", 0x0030, "UInt", 0, "Ptr", rect, "UInt", 0)
  mx := Max(NumGet(rect, 0, "Int"), Min(mx, NumGet(rect, 8, "Int")))
  my := Max(NumGet(rect, 4, "Int"), Min(my, NumGet(rect, 12, "Int")))
  DllCall("SetForegroundWindow", "Ptr", A_ScriptHwnd)
  A_TrayMenu.Show(mx, my)
  DllCall("PostMessage", "Ptr", A_ScriptHwnd, "UInt", 0, "Ptr", 0, "Ptr", 0)
}

MouseOnIcon := false

CheckIconHover() {
  global MouseOnIcon
  MouseGetPos(, , &win)
  try
    if WinGetClass("ahk_id " win) ~= "^(Shell_TrayWnd|Shell_SecondaryTrayWnd|NotifyIconOverflowWindow)$"
      return
  MouseOnIcon := false
  SetTimer(CheckIconHover, 0)
}

OnTrayClick(wParam, lParam, msg, hwnd) {
  global MouseOnIcon
  if lParam = 0x202 || lParam = 0x205 {
    ShowTrayMenu()
    return 1
  } else if lParam = 0x200 && !MouseOnIcon {
    MouseOnIcon := true
    SetTimer(CheckIconHover, 100)
  }
}
OnMessage(0x404, OnTrayClick)

if !ShowTrayIcon
  A_IconHidden := true
else {
  RefreshTray()
  ; WM_DEVICECHANGE: rebuild device menu + icon, debounced (same func = timer reset)
  OnMessage(0x219, (*) => SetTimer(RefreshTray, -2000))
}

if AudioDevice != ""
  ShowDeviceOsd(AudioDevice)

; event-driven registry watch: auto-reset event signals threadpool wait, callback marshals to main thread
hRegKey := 0
DllCall("advapi32\RegOpenKeyExW", "Ptr", 0x80000001, "WStr", StrReplace(RegKey, "HKCU\"), "UInt", 0, "UInt", 0x0010, "Ptr*", &hRegKey)  ; HKCU, KEY_NOTIFY
if hRegKey {
  hRegEvent := DllCall("CreateEventW", "Ptr", 0, "Int", 0, "Int", 0, "Ptr", 0, "Ptr")
  ScriptHwnd := A_ScriptHwnd
  OnMessage(0x8001, WatchDevice)
  ArmRegWatch()
  hRegWait := 0
  DllCall("RegisterWaitForSingleObject", "Ptr*", &hRegWait, "Ptr", hRegEvent, "Ptr", CallbackCreate(OnRegSignal, , 2), "Ptr", 0, "UInt", 0xFFFFFFFF, "UInt", 0)
}

#HotIf IsMouseLocal() && IsDefaultDevice()
$Volume_Up::Volume(2)
$Volume_Down::Volume(-2)
#HotIf

#HotIf MouseOnIcon && IsDefaultDevice()
WheelUp::Volume(2)
WheelDown::Volume(-2)
#HotIf
