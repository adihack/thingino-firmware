param(
  [string]$Port = 'COM11',
  [int]$Baud    = 115200,
  [string]$Dir  = 'C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\dualog'
)
# READ-ONLY syntax probe. Deliberately NOT touched: AT+wmem, AT+RESTORE,
# AT+REBOOT, AT+SYS_EXCEPTION*, AT+FLASH_CONFIG_RESET, AT+DEEP_SLEEP,
# AT+WIFI_ETF_SAVE_EFUSE - all of those write state or crash the chip.
$ErrorActionPreference='Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$f = Join-Path $Dir "atprobe2-$stamp.log"
$w = New-Object System.IO.StreamWriter($f,$false); $w.AutoFlush=$true
$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false; $sp.RtsEnable=$false; $sp.ReadTimeout=50; $sp.Open()
function Ask($cmd,$wait){
  $sp.DiscardInBuffer()
  $w.WriteLine(">>> $cmd"); Write-Host ""; Write-Host ">>> $cmd" -ForegroundColor Cyan
  $sp.Write($cmd + "`r`n")
  $end=(Get-Date).AddMilliseconds($wait); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$sp.ReadExisting()}catch{$c=''}
    if($c.Length){$acc+=$c}else{Start-Sleep -Milliseconds 20}
  }
  foreach($ln in (($acc -replace "`e\[[0-9;]*m",'') -split "`r?`n")){
    $cl=$ln.TrimEnd(); if($cl.Length){ $w.WriteLine("    $cl"); Write-Host "    $cl" }
  }
  if(-not $acc.Length){ $w.WriteLine("    <no reply>"); Write-Host "    <no reply>" -ForegroundColor DarkGray }
}
# 1. identity / firmware info
Ask 'AT+GET_VER'         1200
Ask 'AT+GET_SDK_VER'     1200
Ask 'AT+WIFI_GET_FWINFO' 1500
Ask 'AT+GET_SYS_STATUS'  1500
Ask 'AT+GET_SYS_TIME'    1200
# 2. rmem syntax hunt - wrong args should print a usage string
Ask 'AT+rmem'            1200
Ask 'AT+rmem=?'          1200
Ask 'AT+rmem?'           1200
Ask 'AT+rmem 0'          1200
# 3. plausible call forms against a safe, certainly-mapped address.
#    0x00030000 = IVB / code base seen in the boot log.
Ask 'AT+rmem=0x30000,16'  1500
Ask 'AT+rmem 0x30000 16'  1500
Ask 'AT+rmem=0x30000'     1500
Ask 'AT+rmem 0x30000'     1500
Ask 'AT+rmem=30000,16'    1500
$sp.Close(); $w.Close()
Write-Host ""; Write-Host "log: $f"
