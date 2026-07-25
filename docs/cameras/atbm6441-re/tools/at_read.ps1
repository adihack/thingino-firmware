param([string]$Port='COM11',[int]$Baud=115200,[string]$Addrs='4ae44c,411380,30000,60000,100000,4ae400')
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false;$sp.RtsEnable=$false;$sp.ReadTimeout=40;$sp.Open()
function Ask($c,$w=1500){
  $sp.DiscardInBuffer();$sp.Write($c+"`r`n")
  $end=(Get-Date).AddMilliseconds($w);$acc=''
  while((Get-Date) -lt $end){try{$x=$sp.ReadExisting()}catch{$x=''}
    if($x.Length){$acc+=$x; if($acc -match '\+OK|\+ERR|error'){Start-Sleep -Milliseconds 30;try{$acc+=$sp.ReadExisting()}catch{};break}}else{Start-Sleep -Milliseconds 8}}
  return ($acc -replace "`e\[[0-9;]*m",'')
}
Ask 'AT+DEFAULT_DEBUG_ENABLE=0' 1000 | Out-Null
foreach($a in ($Addrs -split ',')){
  Write-Host ">>> AT+rmem=$a,64" -ForegroundColor Cyan
  $r = Ask "AT+rmem=$a,64" 1500
  foreach($ln in ($r -split "`r?`n")){ $c=$ln.Trim(); if($c -match '^[0-9a-fA-F]{8}:' -or $c -match 'Memory at'){ Write-Host "    $c" } }
}
$sp.Close()
