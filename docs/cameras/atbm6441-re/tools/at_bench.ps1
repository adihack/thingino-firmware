param(
  [string]$Port = 'COM11',
  [int]$Baud    = 115200
)
# Why was the dump only 778 B/s with ~50% retries? Measure it.
$ErrorActionPreference='Continue'
$sp = New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$false; $sp.RtsEnable=$false; $sp.ReadTimeout=30; $sp.Open()
Write-Host "opened $Port @ $Baud"

# Reader that waits for the real end-of-response ('>' prompt after +OK),
# instead of guessing with a fixed sleep.
function Xact($cmd,[int]$tmo=2000){
  $sp.DiscardInBuffer(); $sp.Write($cmd + "`r`n")
  $end=(Get-Date).AddMilliseconds($tmo); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$sp.ReadExisting()}catch{ return $null }
    if($c.Length){ $acc+=$c; if($acc -match '\+OK[\s\S]*>'){ break } }
    else { Start-Sleep -Milliseconds 2 }
  }
  return $acc
}
function ParseOk($txt,[int]$len){
  if($null -eq $txt){ return $false }
  $need=[int]($len/4); $words=@{}
  foreach($ln in ($txt -split "`r?`n")){
    $cl=($ln -replace "`e\[[0-9;]*m",'').Trim()
    if($cl -match '^([0-9a-fA-F]{8}):\s+((?:[0-9a-fA-F]{8}\s*)+)$'){
      $off=[Convert]::ToUInt32($matches[1],16); $wd=$matches[2].Trim() -split '\s+'
      for($i=0;$i -lt $wd.Count;$i++){ $words[[uint32]($off+$i*4)]=$wd[$i] }
    }
  }
  for($i=0;$i -lt $need;$i++){ if(-not $words.ContainsKey([uint32]($i*4))){ return $false } }
  return $true
}
Write-Host "`n--- liveness ---"
$t = Xact 'AT+GET_VER' 1500
if($null -eq $t -or $t -notmatch 'ATBM'){ Write-Host "CONSOLE DEAD - power-cycle needed" -ForegroundColor Red; $sp.Close(); exit 1 }
Write-Host ($t -replace "`r?`n",' | ')

function Bench($label,[int]$len,[int]$n){
  $ok=0; $bad=0; $t0=Get-Date
  for($i=0;$i -lt $n;$i++){
    $a=[uint32](0x450000 + $i*$len)
    $r = Xact ("AT+rmem={0:x},{1}" -f $a,$len) 2000
    if(ParseOk $r $len){$ok++}else{$bad++}
  }
  $el=((Get-Date)-$t0).TotalSeconds
  $bps=[math]::Round(($ok*$len)/$el)
  $eta=[math]::Round(2097152/[math]::Max($bps,1)/60,1)
  "{0,-22} len={1,-4} ok={2,-3} bad={3,-3} {4,5} B/s  full-2MB ETA {5} min" -f $label,$len,$ok,$bad,$bps,$eta
}
Write-Host "`n--- chunk size sweep (prompt-accurate reader) ---"
Bench 'chunk160' 160 40
Bench 'chunk128' 128 40
Bench 'chunk96'   96 40

Write-Host "`n--- can we mute the async printk that mangles lines? ---"
foreach($c in @('AT+SetDbgMask=0','AT+SetDbgMask','AT+DEFAULT_DEBUG_ENABLE=0')){
  $r = Xact $c 1500
  Write-Host (">>> $c  ==>  " + (($r -replace "`r?`n",' | ')))
}
Write-Host "`n--- after mute attempt ---"
Bench 'chunk160-muted' 160 40
Bench 'chunk128-muted' 128 40
$sp.Close()
