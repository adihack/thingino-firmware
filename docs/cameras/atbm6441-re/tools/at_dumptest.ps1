param(
  [string]$Port = 'COM11',
  [int]$Baud    = 115200,
  [string]$Dir  = 'C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\dualog'
)
$ErrorActionPreference='Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$f = Join-Path $Dir "atdumptest-$stamp.log"
$w = New-Object System.IO.StreamWriter($f,$false); $w.AutoFlush=$true
$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false; $sp.RtsEnable=$false; $sp.ReadTimeout=50; $sp.Open()

function Raw($cmd,$wait){
  $sp.DiscardInBuffer(); $sp.Write($cmd + "`r`n")
  $end=(Get-Date).AddMilliseconds($wait); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$sp.ReadExisting()}catch{$c=''}
    if($c.Length){$acc+=$c; if($acc -match '\+OK'){ Start-Sleep -Milliseconds 60; try{$acc+=$sp.ReadExisting()}catch{}; break } }
    else{Start-Sleep -Milliseconds 10}
  }
  return $acc
}
function ParseDump($txt){
  $bytes = @{}
  foreach($ln in ($txt -split "`r?`n")){
    $c = ($ln -replace "`e\[[0-9;]*m",'').Trim()
    if($c -match '^([0-9a-fA-F]{8}):\s+((?:[0-9a-fA-F]{8}\s*)+)$'){
      $off = [Convert]::ToUInt32($matches[1],16)
      $wds = $matches[2].Trim() -split '\s+'
      for($i=0;$i -lt $wds.Count;$i++){ $bytes[[uint32]($off + ($i*4))] = $wds[$i] }
    }
  }
  return $bytes
}
function Report($name,$addr,$len,$wait){
  $t0=Get-Date
  $txt = Raw "AT+rmem=$addr,$len" $wait
  $ms = [int]((Get-Date)-$t0).TotalMilliseconds
  $b = ParseDump $txt
  $want = [math]::Ceiling($len/4)
  $got  = $b.Count
  $offs = @($b.Keys | Sort-Object)
  $maxoff = if($got){ $offs[-1] } else { -1 }
  $contig = $true
  for($i=0;$i -lt $got;$i++){ if($offs[$i] -ne [uint32]($i*4)){ $contig=$false; break } }
  $line = "{0,-8} addr={1,-8} len={2,-6} words got/want={3}/{4} contig={5} maxoff=0x{6:x} {7}ms" -f $name,$addr,$len,$got,$want,$contig,$maxoff,$ms
  $w.WriteLine($line); Write-Host $line -ForegroundColor $(if($contig -and $got -ge $want){'Green'}else{'Yellow'})
  return $b
}
Write-Host "=== chunk-size limit ===" -ForegroundColor Cyan
Report 'c256'  '400000' 256   2500  | Out-Null
Report 'c512'  '400000' 512   3000  | Out-Null
Report 'c1024' '400000' 1024  5000  | Out-Null
Report 'c2048' '400000' 2048  9000  | Out-Null
Report 'c4096' '400000' 4096 16000  | Out-Null

Write-Host ""
Write-Host "=== endianness / content scan ===" -ForegroundColor Cyan
foreach($a in @('401000','420000','440000','480000','4c0000','500000','540000','560000','580000','5c0000')){
  $b = Report "s_$a" $a 128 2500
  $offs = @($b.Keys | Sort-Object)
  $le=''; $be=''
  foreach($o in $offs){
    $hx = $b[$o]
    foreach($p in @($hx.Substring(6,2),$hx.Substring(4,2),$hx.Substring(2,2),$hx.Substring(0,2))){
      $v=[Convert]::ToByte($p,16); $le += $(if($v -ge 32 -and $v -lt 127){[char]$v}else{'.'}) }
    foreach($p in @($hx.Substring(0,2),$hx.Substring(2,2),$hx.Substring(4,2),$hx.Substring(6,2))){
      $v=[Convert]::ToByte($p,16); $be += $(if($v -ge 32 -and $v -lt 127){[char]$v}else{'.'}) }
  }
  $w.WriteLine("   LE: $le"); $w.WriteLine("   BE: $be")
  Write-Host "   LE: $le"
  Write-Host "   BE: $be"
}
Write-Host ""
Write-Host "=== UART config ===" -ForegroundColor Cyan
$t = Raw 'AT+UART_GET_CFG' 1500
$w.WriteLine($t); Write-Host $t
Write-Host ""
Write-Host "=== WDT regs twice, 1s apart ===" -ForegroundColor Cyan
$r1 = Raw 'AT+rmem=16600000,48' 1500; Start-Sleep -Milliseconds 1000; $r2 = Raw 'AT+rmem=16600000,48' 1500
$w.WriteLine($r1); $w.WriteLine('--- 1s later ---'); $w.WriteLine($r2)
Write-Host $r1; Write-Host "--- 1s later ---"; Write-Host $r2
$sp.Close(); $w.Close()
Write-Host ""; Write-Host "log: $f"
