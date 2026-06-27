#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode("Input")
SetWorkingDir(A_ScriptDir)
CoordMode("Mouse", "Screen")
CoordMode("Menu", "Screen")

ShowTrayIcon := true
AlwaysShowDevice := true
SndVolDll := A_WinDir "\System32\SndVolSSO.dll"

RegKey := "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK"
SoundCli := A_ScriptDir "\..\tools\soundvolumeview.exe"
if !FileExist(SoundCli)
  SoundCli := "soundvolumeview.exe"
SonarFilter := "SteelSeries Sonar Virtual Audio Device"
ApoBase := "SOFTWARE\SteelSeries ApS\Sonar.APO\Game\Settings"
SonarRender := "SteelSeries Sonar Virtual Audio Device\Device\SteelSeries Sonar - Gaming\Render"

AudioDevice := ""
try AudioDevice := RegRead(RegKey, "AudioDevice")

IsDefaultDevice() {
  return InStr(SoundGetName(), "SteelSeries Sonar - Gaming")
}

GetDevice() {
  global AudioDevice, RegKey
  try
    AudioDevice := RegRead(RegKey, "AudioDevice")
  return AudioDevice
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
    vol := Round(SoundGetVolume(, dev))
    UpdateTrayIcon(vol)
    if AlwaysShowDevice
      ShowDeviceOsd(dev)
    else
      ShowVolOsd()
  }
}

; --- Device management ---

EnumerateDevices() {
  global SoundCli, SonarFilter
  devices := []
  tmpFile := A_Temp "\vss_devices.csv"
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
    if parts[2] = "Device" && parts[3] = "Render" && parts[4] != SonarFilter
      devices.Push({name: parts[1], deviceName: parts[4], id: parts[5], label: parts[1] " (" parts[4] ")"})
  }
  return devices
}

DeviceIdToHex(id) {
  charCount := StrLen(id) + 1
  byteCount := charCount * 2
  buf := Buffer(byteCount, 0)
  StrPut(id, buf, charCount, "UTF-16")
  hex := ""
  loop byteCount
    hex .= Format("{:02X}", NumGet(buf, A_Index - 1, "UChar"))
  return {hex: hex, count: charCount}
}

RouteDevice(name, deviceName, deviceId) {
  global ApoBase, SonarRender, SoundCli, RegKey

  result := DeviceIdToHex(deviceId)
  hex := result.hex, count := result.count
  persistStore := "HKLM\" ApoBase "\GlobalControl\Store"

  RunWait(A_ComSpec ' /c '
    . 'reg add "' persistStore '" /v kSet_StreamRedirectionState /t REG_DWORD /d 1 /f >nul 2>nul'
    . ' & reg add "' persistStore '" /v kSet_StreamRedirectionDeviceIdCount /t REG_DWORD /d ' count ' /f >nul 2>nul'
    . ' & reg add "' persistStore '" /v kSet_StreamRedirectionDeviceId /t REG_BINARY /d ' hex ' /f >nul 2>nul'
    . ' & reg add "' persistStore '" /v kSet_RenderState /t REG_DWORD /d 1 /f >nul 2>nul'
    . ' & reg add "' persistStore '" /v kSet_StreamRedirectionGainLin /t REG_DWORD /d 1065353216 /f >nul 2>nul'
    . ' & reg add "' persistStore '" /v kSet_StreamRedirectionMute /t REG_DWORD /d 0 /f >nul 2>nul'
    , , "Hide")

  streamsPath := ApoBase "\Streams"
  RunWait('powershell -NoProfile -Command "'
    . "$hklm=[Microsoft.Win32.Registry]::LocalMachine;"
    . "$hex='" hex "';"
    . "[byte[]]$bytes=for($i=0;$i -lt $hex.Length;$i+=2){[convert]::ToByte($hex.Substring($i,2),16)};"
    . "if($root=$hklm.OpenSubKey('" streamsPath "')){"
    . "$root.GetSubKeyNames()|ForEach-Object{"
    . "if($key=$hklm.OpenSubKey('" streamsPath "\'+$_,$true)){"
    . "$key.SetValue('ModifiedRender',[byte[]](@(0xFF)*28),'Binary');"
    . "$key.SetValue('kSet_StreamRedirectionDeviceId',$bytes,'Binary');"
    . "@{kSet_StreamRedirectionState=1;kSet_StreamRedirectionDeviceIdCount=" count ";kSet_RenderState=1;kSet_StreamRedirectionGainLin=1065353216;kSet_StreamRedirectionMute=0}.GetEnumerator()|ForEach-Object{$key.SetValue($_.Key,$_.Value,'DWord')};"
    . "$key.Close()}};$root.Close()}"
    . '"', , "Hide")

  RunWait(A_ComSpec ' /c "' SoundCli '" /Enable "' SonarRender '"', , "Hide")
  RunWait(A_ComSpec ' /c "' SoundCli '" /SetDefault "' SonarRender '" 0', , "Hide")
  RunWait(A_ComSpec ' /c "' SoundCli '" /SetDefault "' SonarRender '" 2', , "Hide")

  label := name " (" deviceName ")"
  RegWrite(label, "REG_SZ", RegKey, "AudioDevice")
  RegWrite(deviceId, "REG_SZ", RegKey, "AudioDeviceId")
}

; --- Tray menu ---

BuildTrayMenu() {
  global AudioDevice
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
  A_TrayMenu.Add("Exit", (*) => ExitApp())
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

RoundCorners(guiObj, w, h, r) {
  hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r)
  DllCall("SetWindowRgn", "Ptr", guiObj.Hwnd, "Ptr", hRgn, "Int", true)
}

ShowOsdPair(border, flyout, bw, bh, br, bx, by) {
  border.Show("NoActivate w" bw " h" bh " x" bx " y" by)
  RoundCorners(border, bw, bh, br)
  flyout.Show("NoActivate w" (bw - 2) " h" (bh - 2) " x" (bx + 1) " y" (by + 1))
  RoundCorners(flyout, bw - 2, bh - 2, br - 1)
  WinSetAlwaysOnTop(1, border)
  WinSetAlwaysOnTop(1, flyout)
}

VolIcon(vol) {
  if (vol <= 0)
    return Chr(0xE74F)
  if (vol <= 33)
    return Chr(0xE993)
  if (vol <= 66)
    return Chr(0xE994)
  return Chr(0xE995)
}

UpdateVolControls(gui, vol) {
  gui["IconText"].Text := VolIcon(vol)
  gui["VolumeBar"].Value := vol
  gui["VolText"].Text := vol
}

; Volume OSD
BorderW := 192
BorderH := 48
BorderR := 16

BorderGui := Gui(GuiStyle)
BorderGui.BackColor := "222222"

FlyoutGui := Gui(GuiStyle " +Owner" BorderGui.Hwnd)
FlyoutGui.BackColor := "2b2b2b"
FlyoutGui.SetFont("s12", "Segoe MDL2 Assets")
FlyoutGui.MarginX := 0
FlyoutGui.MarginY := 0
FlyoutGui.Add("Text", "vIconText cFFFFFF x12 w28 h" (BorderH - 2) " Center +0x200 Section", Chr(0xE995))
FlyoutGui.SetFont("s9", "Segoe UI")
FlyoutGui.Add("Progress", "vVolumeBar w102 h6 c5294E2 Background505050 Range0-100 ys+20 x+4", 0)
FlyoutGui.SetFont("s11", "Segoe UI Variable Display")
FlyoutGui.Add("Text", "vVolText cFFFFFF w32 h" (BorderH - 2) " Right +0x200 ys x+0", "100")

; Device OSD
DevBorderW := 280
DevBorderH := 40
DevBorderR := 16
DevGap := 8

DevBorderGui := Gui(GuiStyle)
DevBorderGui.BackColor := "222222"

DevFlyoutGui := Gui(GuiStyle " +Owner" DevBorderGui.Hwnd)
DevFlyoutGui.BackColor := "2b2b2b"
DevFlyoutGui.MarginX := 0
DevFlyoutGui.MarginY := 0
DevFlyoutGui.SetFont("s12", "Segoe MDL2 Assets")
DevFlyoutGui.Add("Text", "cFFFFFF x12 w28 h" (DevBorderH - 2) " Center +0x200 Section", Chr(0xE7F5))
DevFlyoutGui.SetFont("s11", "Segoe UI Variable Display")
DevFlyoutGui.Add("Text", "vDevName cFFFFFF w" (DevBorderW - 54) " h" (DevBorderH - 2) " +0x200 ys x+4", "")

HideAll(*) {
  DevFlyoutGui.Hide()
  DevBorderGui.Hide()
  FlyoutGui.Hide()
  BorderGui.Hide()
}

ShowVolOsd() {
  global BorderW, BorderH, BorderR
  vol := Round(SoundGetVolume(, GetDevice()))
  UpdateVolControls(FlyoutGui, vol)
  sw := A_ScreenWidth, sh := A_ScreenHeight
  bx := sw // 2 - BorderW // 2, by := sh - 110
  ShowOsdPair(BorderGui, FlyoutGui, BorderW, BorderH, BorderR, bx, by)
  SetTimer(HideAll, -2500)
}

ShowDeviceOsd(name) {
  global BorderW, BorderH, BorderR, DevBorderW, DevBorderH, DevBorderR, DevGap
  DevFlyoutGui["DevName"].Text := name
  try vol := Round(SoundGetVolume(, GetDevice()))
  catch
    vol := 0
  UpdateVolControls(FlyoutGui, vol)
  sw := A_ScreenWidth, sh := A_ScreenHeight
  volBx := sw // 2 - BorderW // 2, volBy := sh - 110
  devBx := sw // 2 - DevBorderW // 2, devBy := volBy - DevBorderH - DevGap
  ShowOsdPair(BorderGui, FlyoutGui, BorderW, BorderH, BorderR, volBx, volBy)
  ShowOsdPair(DevBorderGui, DevFlyoutGui, DevBorderW, DevBorderH, DevBorderR, devBx, devBy)
  SetTimer(HideAll, -2500)
}

; --- Startup ---

UpdateTrayIcon(vol) {
  global SndVolDll
  static hMod := DllCall("LoadLibraryEx", "Str", SndVolDll, "Ptr", 0, "UInt", 0x02, "Ptr")
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
  try UpdateTrayIcon(Round(SoundGetVolume(, GetDevice())))
  BuildTrayMenu()
}

if AudioDevice != ""
  ShowDeviceOsd(AudioDevice)

#HotIf IsMouseLocal() && IsDefaultDevice()
$Volume_Up::Volume(2)
$Volume_Down::Volume(-2)
#HotIf

#HotIf MouseOnIcon && IsDefaultDevice()
WheelUp::Volume(2)
WheelDown::Volume(-2)
#HotIf
