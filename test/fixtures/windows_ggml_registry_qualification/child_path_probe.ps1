param([string]$Phase,[string]$GitExecutable='',[string]$DartExecutable='',[string]$FlutterBatch='')
$ErrorActionPreference='Stop'
$where="$env:WINDIR\System32\where.exe"
if(-not (Test-Path -LiteralPath $where)){throw 'Windows where.exe is unavailable'}
$rows=@()
function Find-PathCommand([string]$Name,[string]$Expected='') {
  $found=@(& $where $Name 2>$null)
  if($LASTEXITCODE -ne 0 -or $found.Count -eq 0){throw "child-effective PATH is missing $Name"}
  if($Expected -and $found[0].Trim().ToLowerInvariant() -ne $Expected.ToLowerInvariant()){throw "child-effective PATH selected an unpinned $Name"}
  return [pscustomobject]@{command=$Name;present=$true;pinnedMatch=([bool]$Expected)}
}
foreach($name in @('cmd.exe','where.exe','curl.exe','tar.exe','taskkill.exe','timeout.exe')){$rows+=Find-PathCommand $name}
$selectedShell=''
& $where /Q pwsh.exe
if($LASTEXITCODE -eq 0){$selectedShell='pwsh.exe'}else{
  & $where /Q PowerShell.exe
  if($LASTEXITCODE -eq 0){$selectedShell='PowerShell.exe'}
}
if(-not $selectedShell){throw 'child-effective PATH cannot resolve pwsh.exe or PowerShell.exe required by Flutter3.47.1'}
if($GitExecutable){
  $rows+=Find-PathCommand 'git.exe' $GitExecutable
  $rows+=Find-PathCommand 'dart.exe' $DartExecutable
  if($FlutterBatch){$rows+=Find-PathCommand 'flutter.bat' $FlutterBatch}
}
[ordered]@{phase=$Phase;childEffectivePathChecked=$true;requiredCommands=$rows;flutterPowerShellCommand=$selectedShell;pathOrEnvironmentDumped=$false} | ConvertTo-Json -Depth 6
