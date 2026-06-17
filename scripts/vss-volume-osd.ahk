#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
SendMode("Input")
SetWorkingDir(A_ScriptDir)

RegKey := "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK"
try
  AudioDevice := RegRead(RegKey, "AudioDevice")
catch {
  MsgBox "Registry key not found. Run vss-device-select.bat first."
  ExitApp
}

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
    ShowVolOsd()
  }
}

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

if (AudioDevice != "")
  ShowDeviceOsd(AudioDevice)

#HotIf IsMouseLocal() && IsDefaultDevice()
$Volume_Up::Volume(2)
$Volume_Down::Volume(-2)
#HotIf
