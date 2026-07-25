param(
  [string]$Port = 'COM11',
  [int]$Baud    = 115200,
  [string]$Dir  = 'C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\dualog'
)
# Address-space scan via AT+rmem (READ ONLY). Small reads only.
$ErrorActionPreference='Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$f = Join-Path $Dir "atmap-$stamp.log"
$w = New-Object System.IO.StreamWriter($f,$false); $w.AutoFlush=$true
$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false; $sp.RtsEnable=$false; $sp.ReadTimeout=50; $sp.Open()
function Ask($cmd,$wait){
  $sp.DiscardInBuffer()
  $w.WriteLine(">>> $cmd"); Write-Host ">>> $cmd" -ForegroundColor Cyan
  $sp.Write($cmd + "`r`n")
  $end=(Get-Date).AddMilliseconds($wait); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$sp.ReadExisting()}catch{$c=''}
    if($c.Length){$acc+=$c}else{Start-Sleep -Milliseconds 15}
  }
  foreach($ln in (($acc -replace "`e\[[0-9;]*m",'') -split "`r?`n")){
    $cl=$ln.TrimEnd(); if($cl.Length){ $w.WriteLine("    $cl"); Write-Host "    $cl" }
  }
  if(-not $acc.Length){ $w.WriteLine("    <NO REPLY - chip may have faulted>"); Write-Host "    <NO REPLY>" -ForegroundColor Red }
  return $acc
}
Write-Host "=== A. length semantics (is len hex or decimal?) ===" -ForegroundColor Yellow
Ask 'AT+rmem=30000,10'  1200   # hex 0x10=16B (1 line) vs dec 10 (<1 line)
Ask 'AT+rmem=30000,20'  1500   # hex 0x20=32B (2 lines) vs dec 20 (1.25 lines)
Ask 'AT+rmem=30000,100' 2500   # hex 0x100=256B (16 lines) vs dec 100 (6.25)
Write-Host ""
Write-Host "=== B. address map scan, 32 bytes each ===" -ForegroundColor Yellow
foreach($a in @('0','10000','30000','40000','100000','200000','400000','410000','500000','560000','600000','800000','810000','900000')){
  Ask "AT+rmem=$a,20" 1200
}
Write-Host ""
Write-Host "=== C. the WDT the boot log armed: wdtx = 0x16600000 ===" -ForegroundColor Yellow
Ask 'AT+rmem=16600000,40' 1500
Write-Host ""
Write-Host "=== D. firmware checksum helpers (read-only) ===" -ForegroundColor Yellow
Ask 'AT+FWCHKSUM'  3000
$sp.Close(); $w.Close()
Write-Host ""; Write-Host "log: $f"
