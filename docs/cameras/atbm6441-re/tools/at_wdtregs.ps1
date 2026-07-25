param([string]$Port='COM11',[int]$Baud=115200)
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false;$sp.RtsEnable=$false;$sp.ReadTimeout=40;$sp.Open()
function Ask($c,$w=1200){
  $sp.DiscardInBuffer();$sp.Write($c+"`r`n")
  $end=(Get-Date).AddMilliseconds($w);$acc=''
  while((Get-Date) -lt $end){try{$x=$sp.ReadExisting()}catch{$x=''}
    if($x.Length){$acc+=$x; if($acc -match '\+OK|error'){Start-Sleep -Milliseconds 25;try{$acc+=$sp.ReadExisting()}catch{};break}}else{Start-Sleep -Milliseconds 8}}
  return ($acc -replace "`e\[[0-9;]*m",'')
}
Ask 'AT+DEFAULT_DEBUG_ENABLE=0' 900 | Out-Null
function Show($a,$label){
  $r=Ask "AT+rmem=$a,64" 1400
  Write-Host ">>> $label (0x$a):" -ForegroundColor Cyan
  foreach($ln in ($r -split "`r?`n")){$c=$ln.Trim(); if($c -match '^[0-9a-fA-F]{8}:'){Write-Host "    $c"}}
}
# read the WDT-family registers twice, ~1.2s apart, to see which fields count/change
for($pass=1;$pass -le 3;$pass++){
  Write-Host "===== PASS $pass ($(Get-Date -Format HH:mm:ss.fff)) =====" -ForegroundColor Yellow
  Show '16600000' 'WDT 0x16600000 (+00 ctrl,+1c,+28 cnt)'
  Show '16101000' '0x16101000 (+30,+bc)'
  Start-Sleep -Milliseconds 1200
}
$sp.Close()
