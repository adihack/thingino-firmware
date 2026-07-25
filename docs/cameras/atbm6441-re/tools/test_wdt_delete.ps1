param(
  [int]$Watch=80,
  [string]$Dir='C:\Users\adria\AppData\Local\Temp\claude\c--dev-cinnado-s2\117da92c-6626-41f3-83f2-34eee82f19bb\scratchpad\dualog'
)
# DUAL-CONSOLE TEST: does U-Boot `atbm wdt off` (msg_id 0x13) delete the ATBM master_wdt?
# COM3 = T23 U-Boot (we interrupt autoboot, send the cmd, watch for reset/survival)
# COM11 = ATBM AT console (we read the master_wdt gp-data region before & after)
$ErrorActionPreference='Continue'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$log=Join-Path $Dir ("wdttest-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+".log")
$w=New-Object System.IO.StreamWriter($log,$false);$w.AutoFlush=$true
function L($m){ $s="[{0,7:N2}] $m" -f ($sw.Elapsed.TotalSeconds); $w.WriteLine($s); Write-Host $s }

$soc=New-Object System.IO.Ports.SerialPort 'COM3',115200,'None',8,'One'
$soc.DtrEnable=$true;$soc.RtsEnable=$true;$soc.ReadTimeout=50;$soc.Open()
$atb=New-Object System.IO.Ports.SerialPort 'COM11',115200,'None',8,'One'
$atb.DtrEnable=$false;$atb.RtsEnable=$false;$atb.ReadTimeout=50;$atb.Open()
$sw=[System.Diagnostics.Stopwatch]::StartNew()

function SocDrain([int]$ms){ $end=(Get-Date).AddMilliseconds($ms);$a=''
  while((Get-Date) -lt $end){try{$c=$soc.ReadExisting()}catch{$c=''}; if($c.Length){$a+=$c}else{Start-Sleep -Milliseconds 10}}; return $a }
function AtRead($addr){ $atb.DiscardInBuffer(); $atb.Write("AT+rmem=$addr,128`r`n")
  $end=(Get-Date).AddMilliseconds(1500);$a=''
  while((Get-Date) -lt $end){try{$c=$atb.ReadExisting()}catch{$c=''}; if($c.Length){$a+=$c; if($a -match '\+OK'){break}}else{Start-Sleep -Milliseconds 8}}
  $rows=@(); foreach($ln in ($a -split "`r?`n")){ if($ln.Trim() -match '^[0-9a-fA-F]{8}:\s+(.+)$'){ $rows+=$ln.Trim() } }; return $rows }
function Snapshot($tag){ $w.WriteLine("  [$tag] master_wdt gp-data region (gp+0x202c=0x90072f4):")
  $all=@()
  foreach($a in @('9007200','9007280','9007300','9007380')){ foreach($r in (AtRead $a)){ $w.WriteLine("    $r"); Write-Host "    $tag $r"; $all+=$r } }
  return $all }
function DiffSnap($b,$a){ $w.WriteLine("  [DIFF before->after]:")
  for($i=0;$i -lt [Math]::Min($b.Count,$a.Count);$i++){ if($b[$i] -ne $a[$i]){ $w.WriteLine("    - $($b[$i])"); $w.WriteLine("    + $($a[$i])"); Write-Host "    CHANGED: $($b[$i])  =>  $($a[$i])" -ForegroundColor Yellow } }
  if(($b -join '') -eq ($a -join '')){ Write-Host "    (no change in region)" -ForegroundColor DarkGray; $w.WriteLine("    (no change)") } }

$atb.Write("AT+DEFAULT_DEBUG_ENABLE=0`r`n"); Start-Sleep -Milliseconds 400; $atb.DiscardInBuffer()

L "PHASE A: waiting (up to 10 min) for a REBOOT. I only spam space AFTER the boot banner (safe if Linux is running idle)."
$bootSeen=$false; $atPrompt=$false; $spamUntil=[datetime]::MinValue; $bootlog=''
$deadline=(Get-Date).AddSeconds(600)
while((Get-Date) -lt $deadline -and -not $atPrompt){
  $s=SocDrain 120
  if($s){ $w.Write($s); $bootlog+=$s }
  if(-not $bootSeen -and $s -match 'T23 TPL|U-Boot SPL|Hit any key'){ $bootSeen=$true; $spamUntil=(Get-Date).AddSeconds(14); L "boot detected -> interrupting autoboot" }
  if((Get-Date) -lt $spamUntil){ $soc.Write(' ') }
  if($s -match '=>\s*$' -or $s -match 'isvp.*#'){ $atPrompt=$true }
}
# SAFETY: did the boot hook already send atbm wdt off (0x13)? A 2nd send is fatal.
$autoSent = ($bootlog -match 'atbm|0x043A|wdt off|cmd=0x13|disabling MCU wdt')
if(-not $atPrompt){ L "did not reach U-Boot prompt (timeout). Check COM3."; $soc.Close();$atb.Close();$w.Close(); exit 1 }
L "PHASE A done: at U-Boot prompt."
Start-Sleep -Milliseconds 400; $soc.DiscardInBuffer()

L "PHASE B: baseline read of ATBM master_wdt (timer active, counting toward reboot)"
$before=Snapshot 'BEFORE'

if($autoSent){
  L "PHASE C: boot hook ALREADY sent 0x13 (found in boot log). NOT re-sending (a 2nd atbm wdt off is FATAL). Observing only."
} else {
  L "PHASE C: send 'atbm wdt off' on COM3 ONCE (msg_id 0x13)"
  $soc.Write("atbm wdt off`r`n")
  $c=SocDrain 4000; $w.Write($c)
  foreach($ln in ($c -split "`r?`n")){ if($ln -match 'confirm|cmd=0x|retcode|0x043A|CONTROL'){ L ("  COM3: "+$ln.Trim()) } }
}

L "PHASE D: re-read ATBM master_wdt (did 0x13 delete/stop it?)"
$after=Snapshot 'AFTER'
DiffSnap $before $after

L "PHASE E: watch COM3 for $Watch s -- RESET (=0x13 failed) or SURVIVAL past ~56s (=success)"
$reset=$false; $end=(Get-Date).AddSeconds($Watch)
while((Get-Date) -lt $end){
  $s=SocDrain 200; if($s){ $w.Write($s); if($s -match 'T23 TPL|U-Boot SPL'){ $reset=$true; L "*** SoC RESET observed -> 0x13 did NOT stop the host-alive reboot ***"; break } }
}
if(-not $reset){ L "*** NO reset in $Watch s -> host-alive reboot was PREVENTED (0x13 worked) ***" }

L "PHASE F: returning the camera to Linux ('boot') so it is not left idle/looping"
$soc.DiscardInBuffer(); $soc.Write("boot`r`n"); Start-Sleep -Milliseconds 500
$soc.Write("run bootcmd`r`n")
$bb=SocDrain 6000; $w.Write($bb)
$soc.Close();$atb.Close();$w.Close()
Write-Host "`nlog: $log"
