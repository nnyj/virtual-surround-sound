# list active render endpoints: name + id
$render = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
Get-ChildItem $render | ForEach-Object {
  $props = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
  $name = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
  $desc = $props.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
  $state = (Get-ItemProperty $_.PSPath).DeviceState
  if ($state -eq 1) { Write-Output "$($_.PSChildName)  [$name / $desc]" }
}
