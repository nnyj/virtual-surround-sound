#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon
SendMode("Input")
SetWorkingDir(A_ScriptDir)

RegKey := "HKCU\SOFTWARE\SteelSeries ApS\Sonar.APO\AHK"
try
  AudioDevice := RegRead(RegKey, "AudioDevice")
catch {
  MsgBox "Registry key not found. Run Steelseries_select_device.bat first."
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

Volume(Offset, Key) {
  if !IsDefaultDevice() {
    Send("{" Key "}")
    return
  }
  dev := GetDevice()
  try {
    SoundSetVolume Format("{:+d}", Offset), , dev
    ShowFlyout()
  }
}

BorderW := 300, BorderH := 56, BorderR := 18
FlyoutW := BorderW - 2, FlyoutH := BorderH - 2, FlyoutR := BorderR - 1

BorderGui := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000")
BorderGui.BackColor := "555555"

FlyoutGui := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000000 +Owner" BorderGui.Hwnd)
FlyoutGui.BackColor := "1e1e1e"
FlyoutGui.SetFont("s14", "Segoe UI")
FlyoutGui.MarginX := 16
FlyoutGui.MarginY := 12

FlyoutGui.Add("Text", "vIconText cBBBBBB w28 Center Section", "🔊")
FlyoutGui.SetFont("s9", "Segoe UI")
FlyoutGui.Add("Progress", "vVolumeBar w170 h6 c5294E2 Background3a3a3a Range0-100 ys+11 x+8", 0)
FlyoutGui.SetFont("s13", "Segoe UI")
FlyoutGui.Add("Text", "vVolText cCCCCCC w42 Right ys+1 x+4", "100")

FlyoutGui.OnEvent("Escape", (*) => FlyoutGui.Hide())

RoundCorners(guiObj, w, h, r) {
  hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r)
  DllCall("SetWindowRgn", "Ptr", guiObj.Hwnd, "Ptr", hRgn, "Int", true)
}

VolIcon(vol) {
  if (vol <= 0)
    return "🔇"
  if (vol <= 33)
    return "🔈"
  if (vol <= 66)
    return "🔉"
  return "🔊"
}

ShowFlyout() {
  global FlyoutW, FlyoutH, FlyoutR, BorderW, BorderH, BorderR
  vol := Round(SoundGetVolume(, GetDevice()))
  FlyoutGui["IconText"].Text := VolIcon(vol)
  FlyoutGui["VolumeBar"].Value := vol
  FlyoutGui["VolText"].Text := vol
  sw := A_ScreenWidth, sh := A_ScreenHeight
  bx := sw // 2 - BorderW // 2, by := sh - 120
  BorderGui.Show("NoActivate w" BorderW " h" BorderH " x" bx " y" by)
  RoundCorners(BorderGui, BorderW, BorderH, BorderR)
  FlyoutGui.Show("NoActivate w" FlyoutW " h" FlyoutH " x" (bx + 1) " y" (by + 1))
  RoundCorners(FlyoutGui, FlyoutW, FlyoutH, FlyoutR)
  SetTimer(HideFlyout, -1500)
}

HideFlyout(*) {
  FlyoutGui.Hide()
  BorderGui.Hide()
}

$Volume_Up::Volume("+2", "Volume_Up")
$Volume_Down::Volume("-2", "Volume_Down")
