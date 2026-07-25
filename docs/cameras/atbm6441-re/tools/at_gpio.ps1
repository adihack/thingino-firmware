param([string]$Port='COM11',[int]$Baud=115200)
# READ-ONLY GPIO enumeration. Only AT+GPIO_GET_DIR and AT+GPIO_READ are issued.
# No AT+GPIO_WRITE / SET_DIR / TOGGLE - we do not change any pin on the live cam.
$ErrorActionPreference='Continue'
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false;$sp.RtsEnable=$false;$sp.ReadTimeout=40;$sp.Open()
function Ask($c,$w=1000){
  $sp.DiscardInBuffer(); $sp.Write($c+"`r`n")
  $end=(Get-Date).AddMilliseconds($w);$acc=''
  while((Get-Date) -lt $end){try{$x=$sp.ReadExisting()}catch{$x=''}
    if($x.Length){$acc+=$x; if($acc -match '\+OK|\+ERR|Unknown'){Start-Sleep -Milliseconds 25;try{$acc+=$sp.ReadExisting()}catch{};break}}else{Start-Sleep -Milliseconds 8}}
  return ($acc -replace "`e\[[0-9;]*m",'')
}
if((Ask 'AT+GET_VER') -notmatch 'ATBM'){Write-Host 'console dead' -ForegroundColor Red;$sp.Close();exit 1}
Ask 'AT+DEFAULT_DEBUG_ENABLE=0' 1200 | Out-Null

Write-Host "=== syntax discovery for AT+GPIO_GET_DIR / AT+GPIO_READ ===" -ForegroundColor Cyan
foreach($c in @('AT+GPIO_GET_DIR','AT+GPIO_GET_DIR=?','AT+GPIO_GET_DIR=22','AT+GPIO_READ=22','AT+GPIO_READ','AT+GPIO_READ=?')){
  Write-Host ">>> $c" -ForegroundColor Yellow
  Write-Host ("    " + ((Ask $c 1200) -replace "`r?`n",' | '))
}
Write-Host "`n=== enumerate GPIO 0..40 (dir,value) ===" -ForegroundColor Cyan
for($g=0;$g -le 40;$g++){
  $d=(Ask ("AT+GPIO_GET_DIR={0}" -f $g) 700) -replace "`r?`n",' '
  $v=(Ask ("AT+GPIO_READ={0}" -f $g) 700) -replace "`r?`n",' '
  Write-Host ("gpio{0,2}: DIR[{1}]  VAL[{2}]" -f $g,$d.Trim(),$v.Trim())
}
$sp.Close()
