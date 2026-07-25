param(
  [string]$Port  = 'COM11',
  [int]$Baud     = 115200,
  [uint32]$Start = 0x400000,
  [uint32]$Size  = 0x200000,
  [int]$Chunk    = 128,        # 8 hexdump lines - measured 0/40 corrupt; 160 is 14/40
  [string]$Out   = 'C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\atbm_flash2.bin'
)
# ATBM6441 internal 2MB flash dump over the AT console. READ ONLY: the only
# commands sent are AT+rmem and one AT+DEFAULT_DEBUG_ENABLE=0 (mutes async
# printk so it cannot land inside a hexdump line). Resumable; survives the
# USB adapter disappearing.
$ErrorActionPreference='Continue'
$log="$Out.log"; $badlog="$Out.bad"
$w=New-Object System.IO.StreamWriter($log,$true); $w.AutoFlush=$true
function L($m){ $s="[{0:HH:mm:ss}] $m" -f (Get-Date); $w.WriteLine($s); Write-Host $s }

$script:sp=$null
function OpenPort(){
  for($i=0;$i -lt 60;$i++){
    try{
      if($script:sp){ try{$script:sp.Close()}catch{} ; $script:sp=$null }
      $p=New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
      $p.DtrEnable=$false; $p.RtsEnable=$false; $p.ReadTimeout=30; $p.WriteTimeout=1500
      $p.Open(); $script:sp=$p
      if($i -gt 0){ L "port reopened after $i attempt(s)" }
      return $true
    }catch{ Start-Sleep -Seconds 2 }
  }
  return $false
}
function Xact($cmd,[int]$tmo=2000){
  try{ $script:sp.DiscardInBuffer(); $script:sp.Write($cmd + "`r`n") }catch{ return $null }
  $end=(Get-Date).AddMilliseconds($tmo); $acc=''
  while((Get-Date) -lt $end){
    try{$c=$script:sp.ReadExisting()}catch{ return $null }
    if($c.Length){ $acc+=$c; if($acc -match '\+OK[\s\S]*>'){ break } }
    else { Start-Sleep -Milliseconds 2 }
  }
  return $acc
}
function ChunkBytes($txt,[int]$len){
  if($null -eq $txt){ return $null }
  $need=[int]($len/4); $words=@{}
  foreach($ln in ($txt -split "`r?`n")){
    $cl=($ln -replace "`e\[[0-9;]*m",'').Trim()
    if($cl -match '^([0-9a-fA-F]{8}):\s+((?:[0-9a-fA-F]{8}\s*)+)$'){
      $off=[Convert]::ToUInt32($matches[1],16); $wd=$matches[2].Trim() -split '\s+'
      for($i=0;$i -lt $wd.Count;$i++){ $words[[uint32]($off+$i*4)]=$wd[$i] }
    }
  }
  $buf=New-Object byte[] $len
  for($i=0;$i -lt $need;$i++){
    $k=[uint32]($i*4); if(-not $words.ContainsKey($k)){ return $null }
    $h=$words[$k]
    $buf[$i*4+0]=[Convert]::ToByte($h.Substring(6,2),16)
    $buf[$i*4+1]=[Convert]::ToByte($h.Substring(4,2),16)
    $buf[$i*4+2]=[Convert]::ToByte($h.Substring(2,2),16)
    $buf[$i*4+3]=[Convert]::ToByte($h.Substring(0,2),16)
  }
  return $buf
}
$done=0
if(Test-Path $Out){ $done=[uint32]([math]::Floor((Get-Item $Out).Length/$Chunk)*$Chunk); if($done){ L "resuming at $done" } }
if(-not (OpenPort)){ L "cannot open $Port - aborting"; exit 2 }
$v = Xact 'AT+GET_VER' 1500
if($null -eq $v -or $v -notmatch 'ATBM'){ L "console not answering - power-cycle the camera and rerun"; exit 3 }
L ("console alive: " + (($v -split "`r?`n" | Where-Object {$_ -match 'ATBM'}) -join ''))
Xact 'AT+DEFAULT_DEBUG_ENABLE=0' 1500 | Out-Null
L "async debug printk muted"

$fs=New-Object System.IO.FileStream($Out,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::Write)
$fs.SetLength($done); $fs.Position=$done
L "dumping 0x$('{0:x}' -f $Start)+0x$('{0:x}' -f $Size) chunk=$Chunk -> $Out"
$t0=Get-Date; $retries=0; $fail=0; $reopens=0
for($off=$done; $off -lt $Size; $off+=$Chunk){
  $n=[math]::Min($Chunk,$Size-$off); $b=$null
  for($try=0;$try -lt 8 -and $null -eq $b;$try++){
    if($try -gt 0){ $retries++; Start-Sleep -Milliseconds 80 }
    if($try -eq 4){ $reopens++; L "no answer at 0x$('{0:x}' -f ($Start+$off)) - reopening port"; if(-not (OpenPort)){ L 'port gone for good'; break } }
    $b = ChunkBytes (Xact ("AT+rmem={0:x},{1}" -f [uint32]($Start+$off),$n) 2500) $n
  }
  if($null -eq $b){
    $fail++
    Add-Content -Path $badlog -Value ("0x{0:x} {1}" -f [uint32]($Start+$off),$n)
    L "FAILED 0x$('{0:x}' -f ($Start+$off)) - zero-filled, logged for repair"
    $b=New-Object byte[] $n
  }
  $fs.Write($b,0,$n); $fs.Flush()
  if((($off/$Chunk) % 500) -eq 0){
    $el=((Get-Date)-$t0).TotalSeconds
    $rate=if($el -gt 0){[math]::Round(($off-$done)/$el)}else{0}
    L ("{0}% 0x{1:x}/{2:x}  {3} B/s  ETA {4}s  retries={5} fail={6} reopens={7}" -f `
       [math]::Round(100.0*$off/$Size,1),$off,$Size,$rate,$(if($rate){[math]::Round(($Size-$off)/$rate)}else{0}),$retries,$fail,$reopens)
  }
}
$fs.Close()
L "DUMP DONE: $((Get-Item $Out).Length) bytes retries=$retries fail=$fail reopens=$reopens in $([math]::Round(((Get-Date)-$t0).TotalSeconds))s"

# independent verification: re-read 48 random chunks and compare against the file
L "verifying 48 random chunks..."
$rnd=New-Object System.Random 12345
$bytes=[System.IO.File]::ReadAllBytes($Out)
$vok=0;$vbad=0
for($i=0;$i -lt 48;$i++){
  $ci=$rnd.Next(0,[int]($Size/$Chunk)); $off=$ci*$Chunk
  $b=$null
  for($try=0;$try -lt 4 -and $null -eq $b;$try++){ $b=ChunkBytes (Xact ("AT+rmem={0:x},{1}" -f [uint32]($Start+$off),$Chunk) 2500) $Chunk }
  if($null -eq $b){ continue }
  $same=$true
  for($k=0;$k -lt $Chunk;$k++){ if($bytes[$off+$k] -ne $b[$k]){ $same=$false; break } }
  if($same){$vok++}else{$vbad++; L "MISMATCH at 0x$('{0:x}' -f ($Start+$off))"}
}
L "VERIFY: $vok match, $vbad mismatch"
try{$script:sp.Close()}catch{}
$w.Close()
