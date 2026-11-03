$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('uth-host-中文 空格-'+[guid]::NewGuid())
$savedLocal=$env:LOCALAPPDATA
$resident=$null;$restarted=$null
try{
    $app=Join-Path $temp 'app';$data=Join-Path $temp 'USB Tether Helper'
    [void][IO.Directory]::CreateDirectory($app);[void][IO.Directory]::CreateDirectory($data)
    Copy-Item -LiteralPath "$PSScriptRoot\..\build\UsbTetherHelper.exe" -Destination $app
    [IO.File]::WriteAllText((Join-Path $data 'config.json'),'{"Paused":true}')
    [IO.File]::WriteAllText((Join-Path $data 'paused'),'paused')
    $env:LOCALAPPDATA=$temp;$exe=Join-Path $app 'UsbTetherHelper.exe'
    $resident=Start-Process -FilePath $exe -ArgumentList '--resident' -WindowStyle Hidden -PassThru
    $until=[DateTime]::UtcNow.AddSeconds(15)
    do{Start-Sleep -Milliseconds 100;$files=@(Get-ChildItem -LiteralPath $data -Filter 'attachments-*.txt')}while(-not $files.Count -and [DateTime]::UtcNow -lt $until)
    if(-not $files.Count -or $resident.HasExited){throw 'Resident failed to initialize'}
    $before=Get-Content -LiteralPath $files[0].FullName -Raw
    $status=Start-Process -FilePath $exe -ArgumentList '--status' -RedirectStandardOutput (Join-Path $temp 'status-output.txt') -WindowStyle Hidden -Wait -PassThru
    if($status.ExitCode -ne 0){throw 'Named-pipe status failed'}
    $duplicate=Start-Process -FilePath $exe -ArgumentList '--resident' -WindowStyle Hidden -Wait -PassThru
    if($duplicate.ExitCode -ne 0 -or $resident.HasExited){throw 'Single-instance check failed'}
    $p=Get-Process -Id $resident.Id;$cpu=$p.CPU
    Start-Sleep -Seconds 2
    $p=Get-Process -Id $resident.Id
    $measurement=[pscustomobject]@{WorkingSetMiB=[Math]::Round($p.WorkingSet64/1MB,2);PrivateMiB=[Math]::Round($p.PrivateMemorySize64/1MB,2);CpuSecondsIn2Seconds=[Math]::Round($p.CPU-$cpu,4)}
    Stop-Process -Id $resident.Id -Force;$resident.WaitForExit()
    $restarted=Start-Process -FilePath $exe -ArgumentList '--resident' -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    $status=Start-Process -FilePath $exe -ArgumentList '--status' -RedirectStandardOutput (Join-Path $temp 'status-output.txt') -WindowStyle Hidden -Wait -PassThru
    if($status.ExitCode -ne 0 -or $restarted.HasExited){throw 'Restart IPC failed'}
    if((Get-Content -LiteralPath $files[0].FullName -Raw) -ne $before){throw 'Restart changed attachment claims'}
    if((Get-Content -LiteralPath (Join-Path $data 'status.txt') -Raw -Encoding UTF8) -ne '已暂停'){throw 'Pause lost across restart'}
    'PASS: real native resident, current-user pipe, duplicate launch, restart persistence, paused startup, Unicode/space executable path'
    $measurement | ConvertTo-Json -Compress
}finally{
    foreach($p in @($resident,$restarted)){if($p -and -not $p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}}
    $env:LOCALAPPDATA=$savedLocal
    $resolved=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'uth-host-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
