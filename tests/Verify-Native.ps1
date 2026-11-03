$ErrorActionPreference='Stop'
$exe=Join-Path $PSScriptRoot '..\build\UsbTetherHelper.exe'
$p=Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if($p.ExitCode -ne 0){throw 'Native state/argument tests failed'}
$p=Start-Process -FilePath $exe -ArgumentList '--invalid' -WindowStyle Hidden -Wait -PassThru
if($p.ExitCode -ne 2){throw 'Unknown option accepted'}
'PASS: native insertion, mode transition, process restart, disconnect heuristic, Unicode argument round-trip, CLI validation'
