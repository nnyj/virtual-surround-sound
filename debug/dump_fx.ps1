$render = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
foreach ($id in '{252b3e5d-6b9f-4ddd-bffc-28f5bafda088}','{df289d1a-058d-406c-a321-e1a0a6011984}') {
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
