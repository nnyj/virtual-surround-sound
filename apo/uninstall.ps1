# Removes VSS Forwarder APO. Registry-only parachute, works even if the DLL crashes audiodg.
$ErrorActionPreference = 'Continue'
$apo_clsids = '{B2F007A1-EAD1-478B-9888-ABC593E55B5D}', '{8A4F0C6D-2B7E-4B36-9C51-3D1E7A5F0B42}'  # current + legacy dev clsid

$render_root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
Get-ChildItem $render_root | ForEach-Object {
  # exact-rights open, FxProperties ACL denies the KEY_WRITE that Remove-ItemProperty requests
  $fx_subpath = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$($_.PSChildName)\FxProperties"
  $fx_key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fx_subpath,
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
    [System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue)
  if ($fx_key) {
    foreach ($slot in '6', '7') {  # classic MFX/EFX from legacy installs
      if ($apo_clsids -contains $fx_key.GetValue("{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},$slot")) {
        $fx_key.DeleteValue("{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},$slot")
        $fx_key.DeleteValue("{d3993a3f-99c2-4402-b5ec-a92a0367664b},$slot", $false)
        Write-Host "removed slot ,$slot from endpoint $($_.PSChildName)"
      }
    }
    # composite MFX (,14): strip our clsid from the list, keep other effects (EAPO)
    $mfx14 = $fx_key.GetValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14')
    if ($mfx14 -and ($mfx14 | Where-Object { $apo_clsids -contains $_ })) {
      $rest = @($mfx14 | Where-Object { $apo_clsids -notcontains $_ })
      if ($rest.Count) { $fx_key.SetValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14', [string[]]$rest, 'MultiString') }
      else { $fx_key.DeleteValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14') }
      Write-Host "removed from composite MFX on endpoint $($_.PSChildName)"
    }
    $fx_key.Close()
  }
}

foreach ($clsid in $apo_clsids) {
  Remove-Item "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -Recurse -ErrorAction SilentlyContinue
  Remove-Item "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$clsid" -Recurse -ErrorAction SilentlyContinue
}
Remove-Item 'HKLM:\SOFTWARE\VirtualSurroundSound' -Recurse -ErrorAction SilentlyContinue
Remove-Item 'C:\Program Files\VssAPO' -Recurse -Force -ErrorAction SilentlyContinue
Restart-Service audiosrv -Force
Write-Host 'Uninstalled, audio service restarted.'
