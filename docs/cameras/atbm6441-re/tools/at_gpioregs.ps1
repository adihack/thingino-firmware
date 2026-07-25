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
function Word($a){
  $r = Ask "AT+rmem=$a,4" 1000
  foreach($ln in ($r -split "`r?`n")){ if($ln.Trim() -match '^00000000:\s+([0-9a-fA-F]{8})'){ return [Convert]::ToUInt32($matches[1],16) } }
  return $null
}
function Bits($v){ $s=''; for($b=31;$b -ge 0;$b--){ $s+= (($v -shr $b) -band 1) ; if($b % 4 -eq 0){$s+=' '} }; return $s }
Ask 'AT+DEFAULT_DEBUG_ENABLE=0' 900 | Out-Null
Write-Host "ATBM GPIO controller 0x16800000  (bit index = pin number)`n" -ForegroundColor Cyan
Write-Host "                 bit: 3         2         1         0"
Write-Host "                       10987654 32109876 54321098 76543210"
foreach($rg in @(@('16800020','INPUT level '),@('16800024','OUTPUT data '),@('16800028','OUT-ENABLE  '),@('16800034','IN/INT-EN   '),@('16800050','INT enable  '),@('16800064','INT pending '))){
  $v=Word $rg[0]
  if($v -ne $null){ Write-Host ("{0} 0x{1:x8}  {2}" -f $rg[1],$v,(Bits $v)) } else { Write-Host ("{0} <no read>" -f $rg[1]) }
}
$inp=Word '16800020'
if($inp -ne $null){
  Write-Host ""
  Write-Host ("pin16 PIR   = {0} (active-high: 1=motion)" -f (($inp -shr 16) -band 1)) -ForegroundColor Green
  Write-Host ("pin17 KEY0  = {0} (active-low: 0=RST pressed)" -f (($inp -shr 17) -band 1)) -ForegroundColor Green
  Write-Host ("pin22 wake  = {0}" -f (($inp -shr 22) -band 1)) -ForegroundColor Green
}
$sp.Close()
