# non-elevated TargetDeviceId write via exact rights (KEY_WRITE would be denied)
param([string]$id)
$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\VirtualSurroundSound',
  [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
  [System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue)
$k.SetValue('TargetDeviceId', $id, 'String')
$k.Close()
Write-Output "written $id"
