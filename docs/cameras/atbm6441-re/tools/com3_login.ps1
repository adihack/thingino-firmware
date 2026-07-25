param([string]$Port='COM3',[int]$Baud=115200,[string]$Pass='root')
$ErrorActionPreference='Continue'
$sp=New-Object System.IO.Ports.SerialPort $Port,$Baud,'None',8,'One'
$sp.DtrEnable=$true;$sp.RtsEnable=$true;$sp.ReadTimeout=50;$sp.Open()
function Drain([int]$ms){ $end=(Get-Date).AddMilliseconds($ms);$acc=''
  while((Get-Date) -lt $end){try{$c=$sp.ReadExisting()}catch{$c=''}; if($c.Length){$acc+=$c}else{Start-Sleep -Milliseconds 15}}
  return $acc }
function WaitFor([string]$re,[int]$ms){ $end=(Get-Date).AddMilliseconds($ms);$acc=''
  while((Get-Date) -lt $end){ $acc+=Drain 200; if($acc -match $re){ return @($true,$acc) } }
  return @($false,$acc) }

Write-Host "step1: hit enter, look for prompt/login" -ForegroundColor Cyan
$sp.Write("`n"); $r=Drain 1000; Write-Host ("[$r]")
if($r -match '#\s*$'){ Write-Host "already at shell" -ForegroundColor Green }
else {
  $sp.Write("`n")
  $res=WaitFor 'login:|#' 4000
  Write-Host ("saw: [" + $res[1] + "]")
  if($res[1] -match 'login:'){
    Write-Host "step2: send root" -ForegroundColor Cyan
    $sp.Write("root`n")
    $res=WaitFor 'assword|#' 3000
    Write-Host ("saw: [" + $res[1] + "]")
    if($res[1] -match 'assword'){
      Write-Host "step3: send password" -ForegroundColor Cyan
      $sp.Write("$Pass`n")
      $res=WaitFor '#|ncorrect|assword|login' 4000
      Write-Host ("saw: [" + $res[1] + "]")
    }
  }
}
Write-Host "step4: run marker command" -ForegroundColor Cyan
$sp.DiscardInBuffer()
$sp.Write("echo MK1_`$(id -un)_`$(uname -r)_MK2`n")
$res=WaitFor 'MK1_.*_MK2' 5000
Write-Host ("RESULT: [" + $res[1] + "]")
$sp.Close()
