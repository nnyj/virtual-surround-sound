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
    ShowFlyout()
  }
}

; Draw border and fill as separate borderless windows for rounded outline.
BorderW := 192
BorderH := 48
BorderR := 16
FlyoutW := BorderW - 2
FlyoutH := BorderH - 2
FlyoutR := BorderR - 1

BorderGui := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 -DPIScale")
BorderGui.BackColor := "222222"

FlyoutGui := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 -DPIScale +Owner" BorderGui.Hwnd)
FlyoutGui.BackColor := "2b2b2b"
FlyoutGui.SetFont("s12", "Segoe MDL2 Assets")
FlyoutGui.MarginX := 0
FlyoutGui.MarginY := 0

FlyoutGui.Add("Text", "vIconText cFFFFFF x12 w28 h" FlyoutH " Center +0x200 Section", Chr(0xE995))
FlyoutGui.SetFont("s9", "Segoe UI")
FlyoutGui.Add("Progress", "vVolumeBar w102 h6 c5294E2 Background505050 Range0-100 ys+20 x+4", 0)
FlyoutGui.SetFont("s11", "Segoe UI Variable Display")
FlyoutGui.Add("Text", "vVolText cFFFFFF w32 h" FlyoutH " Right +0x200 ys x+0", "100")

FlyoutGui.OnEvent("Escape", (*) => FlyoutGui.Hide())

RoundCorners(guiObj, w, h, r) {
  hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r)
  DllCall("SetWindowRgn", "Ptr", guiObj.Hwnd, "Ptr", hRgn, "Int", true)
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

ShowFlyout() {
  global FlyoutW, FlyoutH, FlyoutR, BorderW, BorderH, BorderR
  vol := Round(SoundGetVolume(, GetDevice()))
  FlyoutGui["IconText"].Text := VolIcon(vol)
  FlyoutGui["VolumeBar"].Value := vol
  FlyoutGui["VolText"].Text := vol
  sw := A_ScreenWidth
  sh := A_ScreenHeight
  bx := sw // 2 - BorderW // 2
  by := sh - 110
  BorderGui.Show("NoActivate w" BorderW " h" BorderH " x" bx " y" by)
  RoundCorners(BorderGui, BorderW, BorderH, BorderR)
  FlyoutGui.Show("NoActivate w" FlyoutW " h" FlyoutH " x" (bx + 1) " y" (by + 1))
  RoundCorners(FlyoutGui, FlyoutW, FlyoutH, FlyoutR)
  WinSetAlwaysOnTop(1, BorderGui)
  WinSetAlwaysOnTop(1, FlyoutGui)
  SetTimer(HideFlyout, -2500)
}

HideFlyout(*) {
  FlyoutGui.Hide()
  BorderGui.Hide()
}

#HotIf IsMouseLocal() && IsDefaultDevice()
$Volume_Up::Volume(2)
$Volume_Down::Volume(-2)
#HotIf
