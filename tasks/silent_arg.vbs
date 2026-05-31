'Run hidden script with arguments without stealing focus.
'Limitation: Path of this script must not have spaces in Task Scheduler
Dim WinScriptHost, FSO
Set FSO = CreateObject("Scripting.FileSystemObject")

If Not FSO.FileExists(WScript.Arguments(0)) Then
  WScript.Echo("File does not exist: " + Chr(34) + WScript.Arguments(0) + Chr(34))
  WScript.Quit()
End If

run = ""
If WScript.Arguments.Count > 0 Then
  For i = 0 To WScript.Arguments.Count - 1
    run = run + Chr(34) + WScript.Arguments(i) + Chr(34) + Chr(32)
  Next
  Set WinScriptHost = CreateObject("WScript.Shell")
  WinScriptHost.Run run, 0
  Set WinScriptHost = Nothing
End If
