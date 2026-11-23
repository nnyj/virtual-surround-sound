# step a tone through each channel of an endpoint (tone_sweep.ps1) and print the endpoint peak per channel
# native route check, how to read the peaks: docs/native-route-internals.md, Checking a headset
# usage: channel_check.ps1 -id '{0.0.0.00000000}.{guid}'   (guid from endpoint_list.ps1)
param([Parameter(Mandatory)][string]$id, [double]$secs_per_ch = 2)
$meter_source = Get-Content (Join-Path $PSScriptRoot 'peak_read.ps1') -Raw
$type_start = $meter_source.IndexOf('Add-Type')
Invoke-Expression $meter_source.Substring($type_start, $meter_source.IndexOf("`"@", $type_start) + 2 - $type_start)
$tone_log = Join-Path $env:TEMP 'vss_tone_sweep.txt'
$tone = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $tone_log -ArgumentList `
  "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\tone_sweep.ps1`" -target $id -secs_per_ch $secs_per_ch"
# wait for the first channel line so the windows line up with the tone
while (!$tone.HasExited -and !(Select-String -Path $tone_log -Pattern 'channel 0' -Quiet -ErrorAction SilentlyContinue)) {
  Start-Sleep -Milliseconds 50
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$peaks = @{}
while (!$tone.HasExited) {
  $window = [int][Math]::Floor($clock.Elapsed.TotalSeconds / $secs_per_ch)
  # skip the edges of each window, the tone script fades between channels
  $offset = $clock.Elapsed.TotalSeconds - $window * $secs_per_ch
  $peak = [Meter]::Peak($id)
  if ($offset -gt 0.4 -and $offset -lt $secs_per_ch - 0.4 -and $peak -gt [double]$peaks[$window]) { $peaks[$window] = $peak }
  Start-Sleep -Milliseconds 50
}
Get-Content $tone_log | Select-Object -First 1
Remove-Item $tone_log
$names = 'FL', 'FR', 'C', 'LFE', 'RL', 'RR', 'SL', 'SR'
foreach ($window in ($peaks.Keys | Sort-Object)) { '{0,-4} peak {1:N4}' -f $names[$window], $peaks[$window] }
