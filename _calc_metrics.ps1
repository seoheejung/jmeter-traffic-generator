param(
  [Parameter(Mandatory=$true)][string]$JtlPath,
  [Parameter(Mandatory=$true)][string]$Mode,
  [Parameter(Mandatory=$true)][string]$RunKey,
  [Parameter(Mandatory=$true)][string]$Threads,
  [Parameter(Mandatory=$true)][string]$TargetDir,
  [Parameter(Mandatory=$true)][string]$SummaryCsv
)

$rows = Import-Csv $JtlPath
if(-not $rows){ throw "Empty JTL" }

$cols = ($rows | Select-Object -First 1).PSObject.Properties.Name
foreach($need in @('label','elapsed','responseCode','timeStamp')){
  if(-not ($cols -contains $need)){ throw ("Missing required column: " + $need) }
}

$normal = $rows | Where-Object { $_.label -like 'Normal*' }
$attack = $rows | Where-Object { $_.label -like 'Attack*' }
if(-not $normal){ throw "No Normal samples (label like Normal*)" }

$elapsed = $normal | ForEach-Object { [int]$_.elapsed } | Sort-Object
$idx = [int]([Math]::Ceiling($elapsed.Count*0.95)-1)
if($idx -lt 0){ $idx = 0 }
$p95 = $elapsed[$idx]

$nCount = ($normal | Measure-Object).Count
$n500 = ($normal | Where-Object { $_.responseCode -eq '500' } | Measure-Object).Count
$n503 = ($normal | Where-Object { $_.responseCode -eq '503' } | Measure-Object).Count
$n429 = ($normal | Where-Object { $_.responseCode -eq '429' } | Measure-Object).Count
$n504 = ($normal | Where-Object { $_.responseCode -eq '504' } | Measure-Object).Count

$p500  = if($nCount -eq 0){ 0 } else { [Math]::Round(($n500/$nCount)*100, 4) }
$p503  = if($nCount -eq 0){ 0 } else { [Math]::Round(($n503/$nCount)*100, 4) }
$p429n = if($nCount -eq 0){ 0 } else { [Math]::Round(($n429/$nCount)*100, 4) }
$p504  = if($nCount -eq 0){ 0 } else { [Math]::Round(($n504/$nCount)*100, 4) }

$aCount = ($attack | Measure-Object).Count
$a429 = if($aCount -eq 0){ 0 } else { ($attack | Where-Object { $_.responseCode -eq '429' } | Measure-Object).Count }
$a504 = if($aCount -eq 0){ 0 } else { ($attack | Where-Object { $_.responseCode -eq '504' } | Measure-Object).Count }

$p429a = if($aCount -eq 0){ 0 } else { [Math]::Round(($a429/$aCount)*100, 4) }
$p504a = if($aCount -eq 0){ 0 } else { [Math]::Round(($a504/$aCount)*100, 4) }

$total = ($rows | Measure-Object).Count
$ts = $rows | ForEach-Object { [int64]$_.timeStamp } | Sort-Object
$durMs = ($ts[-1] - $ts[0])
if($durMs -le 0){ $durMs = 1 }
$rps = [Math]::Round($total / ($durMs/1000.0), 4)

$snapDir = (Resolve-Path $TargetDir).Path
$snapStartPath = Join-Path $snapDir ($RunKey + '_snapshot_start.json')
$snapMidPath   = Join-Path $snapDir ($RunKey + '_snapshot_mid.json')
$snapEndPath   = Join-Path $snapDir ($RunKey + '_snapshot_end.json')

$hStart = 0; $hEnd = 0; $cbEnd = ""
$cbStates = New-Object System.Collections.Generic.List[String]

if(Test-Path $snapStartPath){
  try{
    $js = (Get-Content $snapStartPath -Raw) | ConvertFrom-Json
    $hStart = [double]$js.data.hikariTimeoutCount
    $cbStates.Add([string]$js.data.circuitBreakerState) | Out-Null
  } catch {}
}
if(Test-Path $snapMidPath){
  try{
    $jm = (Get-Content $snapMidPath -Raw) | ConvertFrom-Json
    $cbStates.Add([string]$jm.data.circuitBreakerState) | Out-Null
  } catch {}
}
if(Test-Path $snapEndPath){
  try{
    $je = (Get-Content $snapEndPath -Raw) | ConvertFrom-Json
    $hEnd = [double]$je.data.hikariTimeoutCount
    $cbEnd = [string]$je.data.circuitBreakerState
    $cbStates.Add($cbEnd) | Out-Null
  } catch {}
}

$hDelta = [Math]::Round(($hEnd - $hStart), 4)
$cbOpen = if($cbStates -contains "OPEN"){ "Y" } else { "N" }

$line = "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16}" -f `
  $RunKey,$Mode,$Threads,$p95,$p500,$p503,$p429n,$p504,$p429a,$p504a,$rps,$total,$hStart,$hEnd,$hDelta,$cbOpen,$cbEnd

Add-Content -Path $SummaryCsv -Value $line
Write-Host ("[METRIC] " + $line)