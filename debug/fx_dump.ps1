# print every FxProperties value of render endpoints
# usage: fx_dump.ps1 -endpoint '{guid}'[,'{guid}']   (guids from endpoint_list.ps1)
param([Parameter(Mandatory)][string[]]$endpoint)
$render = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
foreach ($id in $endpoint) {
  $fx = "$render\$id\FxProperties"
  Write-Output "=== $id ==="
  if (Test-Path $fx) {
    $k = Get-Item $fx
    foreach ($p in $k.Property) {
      $v = $k.GetValue($p)
      if ($v -is [array]) { $v = $v -join ' | ' }
      Write-Output "$p = $v"
    }
    if (-not $k.Property) { Write-Output '(empty)' }
  } else { Write-Output 'NO FxProperties' }
}
