# Installs VSS Forwarder APO as mode effect (MFX) on the VB-Cable "CABLE Input" endpoint.
# -endpoint '{guid}' [-remove]: turns the native APO on or off in the stream effect slot of one render endpoint.
# Run as admin. Rollback: uninstall.ps1
# Requirements discovered the hard way (see docs/apo-forwarder-internals.md):
# - audiodg aggregates APOs, dll must support COM aggregation
# - MFX slot alone never loads on this endpoint, SFX slot must be populated (EqualizerAPO fills it)
# - dll must live in a stable path, installed copy goes to Program Files
# - audiodg LPAC token needs explicit read ACE on the config key
param([ValidatePattern('^\{[0-9a-fA-F-]{36}\}$')][string]$endpoint, [switch]$remove)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'install.log') -Force | Out-Null
trap { Write-Host "FAILED: $_"; Stop-Transcript; exit 1 }
$apo_clsid = '{B2F007A1-EAD1-478B-9888-ABC593E55B5D}'
$native_clsid = '{7C1E5A42-5D0B-4E0C-9B7A-6F3B2D9E8A11}'
$eapo_sfx_clsid = '{EACD2258-FCAC-4FF4-B36D-419E924A6D79}'
$sfx_slot = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5'
# own subkey, the APO watches the parent key for writes
$saved_subpath = 'SOFTWARE\VirtualSurroundSound\NativeSaved'
$render_subpath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$build_dll = Join-Path $PSScriptRoot 'build\vss_apo.dll'
$install_dir = 'C:\Program Files\VssAPO'
$dll_path = Join-Path $install_dir 'vss_apo.dll'

# FxProperties ACL grants admins SetValue but not CreateSubKey, Set-ItemProperty requests
# KEY_WRITE (includes CreateSubKey) and gets denied, open with exact rights instead
function open_fx_key($endpoint_guid) {
  $fx_key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$render_subpath\$endpoint_guid\FxProperties",
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
    [System.Security.AccessControl.RegistryRights]::QueryValues -bor [System.Security.AccessControl.RegistryRights]::SetValue)
  if (!$fx_key) { throw "FxProperties key missing on endpoint $endpoint_guid" }
  $fx_key
}

if ($endpoint) {
  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'run as admin' }
  if (!$remove -and !(Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$native_clsid")) {
    throw 'native APO class not registered, run install.ps1 without arguments first'
  }
  if (!(Test-Path "HKLM:\$render_subpath\$endpoint\FxProperties")) { throw "endpoint $endpoint not found" }
  # parent grants Users SetValue, a user must not choose the clsid an admin later restores,
  # so the key gets its own ACL in the create call, without inheritance
  $saved_acl = New-Object System.Security.AccessControl.RegistrySecurity
  $saved_acl.SetAccessRuleProtection($true, $false)
  foreach ($grant in ('S-1-5-32-544', 'FullControl'), ('S-1-5-18', 'FullControl'), ('S-1-5-32-545', 'ReadKey')) {
    $saved_acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
      (New-Object System.Security.Principal.SecurityIdentifier($grant[0])), $grant[1], 'ContainerInherit', 'None', 'Allow')))
  }
  try {
    Stop-Service audiosrv -Force
    Stop-Service AudioEndpointBuilder -Force
    $saved_key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($saved_subpath,
      [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $saved_acl)
    $fx_key = open_fx_key $endpoint
    $current = $fx_key.GetValue($sfx_slot)
    $saved = $saved_key.GetValue($endpoint)
    if ($remove) {
      # saved empty string: slot was absent before the native APO
      if ($saved) { $fx_key.SetValue($sfx_slot, $saved, 'String') }
      elseif ($null -ne $saved -or $current -eq $native_clsid) { $fx_key.DeleteValue($sfx_slot, $false) }
      $saved_key.DeleteValue($endpoint, $false)
    } else {
      if ($current -ne $native_clsid) { $saved_key.SetValue($endpoint, [string]$current, 'String') }
      $fx_key.SetValue($sfx_slot, $native_clsid, 'String')
    }
    Write-Host "endpoint $endpoint stream effect: $($fx_key.GetValue($sfx_slot))"
    $fx_key.Close()
    $saved_key.Close()
  } finally {
    Start-Service AudioEndpointBuilder
    Start-Service audiosrv
  }
  # without this call the mix format stays as stored: 2 ch after install, 8 ch after removal
  & (Join-Path $PSScriptRoot 'format_policy.ps1') -endpoint $endpoint -mode native
  Stop-Transcript | Out-Null
  exit 0
}

if (!(Test-Path $build_dll)) { throw "missing $build_dll, run build.bat first" }

# deploy to Program Files (stop audio first in case an old copy is loaded)
Stop-Service audiosrv -Force -ErrorAction SilentlyContinue
Stop-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
New-Item $install_dir -ItemType Directory -Force | Out-Null
Copy-Item $build_dll $dll_path -Force
Start-Service audiosrv

& regsvr32 /s $dll_path
if ($LASTEXITCODE) { throw 'regsvr32 failed' }

$cable_endpoint = Get-ChildItem "HKLM:\$render_subpath" | Where-Object {
  (Get-ItemProperty ($_.PSPath + '\Properties') -ErrorAction SilentlyContinue).'{a45c254e-df1c-4efd-8020-67d146a850e0},2' -eq 'CABLE Input'
} | Select-Object -First 1
if (!$cable_endpoint) { throw 'CABLE Input endpoint not found, is VB-Cable (Pack45+) installed?' }
Write-Host "CABLE Input endpoint: $($cable_endpoint.PSChildName)"
$fx_key = open_fx_key $cable_endpoint.PSChildName

# Composite FX (Win10 1803+): MULTI_SZ clsid lists, multiple APOs per position.
# Layout: SFX(13)=[EAPO pre-mix], MFX(14)=[EAPO post-mix (HeSuVi convolution), vss forwarder].
# HeSuVi runs Stage: post-mix, so EAPO's post-mix class must precede our forwarder in MFX.
$eapo_mfx_clsid = '{EC1CC9CE-FAED-4822-828A-82A81A6F018F}'
if (!(Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$eapo_mfx_clsid")) {
  throw 'EqualizerAPO not installed; chain requires it (HeSuVi host + SFX presence). Install EqualizerAPO first.'
}
# clear classic single-clsid slots so they do not shadow composite
foreach ($slot in '5', '6', '7') { $fx_key.DeleteValue("{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},$slot", $false) }
# PKEY_CompositeFX_StreamEffectClsid / PKEY_CompositeFX_ModeEffectClsid
$fx_key.SetValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},13', [string[]]@($eapo_sfx_clsid), 'MultiString')
$fx_key.SetValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14', [string[]]@($eapo_mfx_clsid, $apo_clsid), 'MultiString')
# PKEY_FX_Association = KSNODETYPE_ANY, engine skips unassociated FX entries
$fx_key.SetValue('{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},0', '{00000000-0000-0000-0000-000000000000}', 'String')
# ProcessingModes_Supported_For_Streaming = DEFAULT mode, without this FX never attach to streams
$fx_key.SetValue('{d3993a3f-99c2-4402-b5ec-a92a0367664b},5', [string[]]@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}'), 'MultiString')
$fx_key.SetValue('{d3993a3f-99c2-4402-b5ec-a92a0367664b},6', [string[]]@('{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}'), 'MultiString')
# PKEY_AudioEndpoint_Disable_SysFx = 0, keep enhancements on
$fx_key.SetValue('{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5', 0, 'DWord')
$fx_key.Close()

# allow unsigned APOs in protected audio path (Equalizer APO sets this too)
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Audio' -Name 'DisableProtectedAudioDG' -Value 1 -Type DWord

# config key, readable by audiodg's LPAC token (else TargetDeviceId read fails silently)
# no -Force: on an existing key New-Item -Force drops the values and the NativeSaved subkey
if (!(Test-Path 'HKLM:\SOFTWARE\VirtualSurroundSound')) { New-Item 'HKLM:\SOFTWARE\VirtualSurroundSound' | Out-Null }
$acl = Get-Acl 'HKLM:\SOFTWARE\VirtualSurroundSound'
foreach ($sid in 'S-1-15-2-1', 'S-1-15-2-2') {  # ALL APPLICATION PACKAGES, ALL RESTRICTED APPLICATION PACKAGES
  $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier($sid)),
    'ReadKey', 'ContainerInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
}
# Users get SetValue so device-select script can hot-switch TargetDeviceId without elevation (APO watches the key)
$acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
  (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')),
  'QueryValues,SetValue,ReadKey', 'ContainerInherit', 'None', 'Allow')))
Set-Acl 'HKLM:\SOFTWARE\VirtualSurroundSound' $acl

# endpoint builder caches FX config, restart both (stopping builder stops audiosrv)
Restart-Service AudioEndpointBuilder -Force
Start-Service audiosrv
Write-Host "Installed. Next: pick output via scripts\vss-device-select.bat, set CABLE Input to 7.1 (apo\format_policy.ps1 -mode cable -endpoint '$($cable_endpoint.PSChildName)' or speaker setup)."
Stop-Transcript | Out-Null
