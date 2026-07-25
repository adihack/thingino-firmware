param(
  [string]$Port = 'COM11',
  [int]$Baud    = 115200,
  [string]$Dir  = 'C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\dualog'
)
# READ-ONLY probe of the ATBM6441 AT console. We only ask for command lists /
# identity. Nothing here writes flash or changes state.
$ErrorActionPreference='Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$f = Join-Path $Dir "atprobe-$stamp.log"
$w = New-Object System.IO.StreamWriter($f,$false); $w.AutoFlush=$true
$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false; $sp.RtsEnable=$false; $sp.ReadTimeout=50
$sp.Open()
Write-Host "opened $Port @ $Baud"
$sw=[System.Diagnostics.Stopwatch]::StartNew()
function T { '{0,7:N2}' -f ($sw.ElapsedMilliseconds/1000.0) }
function Drain([int]$ms){
  $end=(Get-Date).AddMilliseconds($ms); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$sp.ReadExisting()}catch{$c=''}
    if($c.Length){ $acc+=$c } else { Start-Sleep -Milliseconds 20 }
  }
  if($acc.Length){
    foreach($ln in (($acc -replace "`e\[[0-9;]*m",'') -split "`r?`n")){
      $cl=$ln.TrimEnd(); if($cl.Length){ $l="[$(T)] $cl"; $w.WriteLine($l); Write-Host $l }
    }
  }
  return $acc.Length
}
function Try1($cmd,$eol,$wait){
  $l=">>> SEND: '$cmd' (eol=$eol)"; $w.WriteLine($l); Write-Host ""; Write-Host $l -ForegroundColor Cyan
  $sp.Write($cmd + $eol)
  $n = Drain $wait
  if($n -eq 0){ $w.WriteLine("    <no reply>"); Write-Host "    <no reply>" -ForegroundColor DarkGray }
  return $n
}
Write-Host "--- baseline (listen 2s, unsolicited traffic only) ---"
Drain 2000 | Out-Null

$total = 0
$total += Try1 ''            "`r`n" 800    # bare CR: does it print a prompt / echo?
$total += Try1 'help'        "`r`n" 2500
$total += Try1 '?'           "`r`n" 1200
$total += Try1 'AT'          "`r`n" 1200
$total += Try1 'AT+HELP'     "`r`n" 1500
$total += Try1 'at+help'     "`r`n" 1500
$total += Try1 'help'        "`r"   1500   # CR-only, in case LF confuses the parser
$total += Try1 'AT+LIST'     "`r`n" 1200
$total += Try1 'version'     "`r`n" 1200

$sp.Close(); $w.Close()
Write-Host ""
Write-Host "=== response bytes total: $total ==="
Write-Host "log: $f"
if($total -eq 0){ Write-Host "NOTHING came back -> either TX is not soldered/connected, or the console is RX-deaf." -ForegroundColor Yellow }
