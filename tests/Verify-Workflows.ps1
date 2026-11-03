$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('uth-flow-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temp)
. "$PSScriptRoot\..\scripts\Helper.ps1" -DataDir $temp -SessionKey 'test-session'
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try {
    $config.AdbPath=Join-Path $temp 'adb.exe'
    $hashes=@{}
    foreach($name in 'adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll'){
        [IO.File]::WriteAllText((Join-Path $temp $name),'fixture')
        $hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $temp $name)).Hash
    }
    $config.AdbHashes=$hashes | ConvertTo-Json | ConvertFrom-Json
    function Test-Adb { 'mock 1.0.41' }
    function Ensure-AdbServer { }
    function Start-Sleep { }
    function Set-Status($State,$Detail){$script:lastStatus=$State}
    function Get-Nodes {
        @{'USB\VID_18D1&PID_0001\PHONE'=@{Parent='HUB';CompatibleIds=@('USB\Class_ff&SubClass_42&Prot_01')}}
    }
    $script:requests=@();$script:enabled=$false
    function Adb([string[]]$Arguments){
        $script:requests+=, $Arguments
        if($Arguments[0] -eq 'devices'){return 'PHONE device'}
        if($Arguments -contains 'setFunctions'){$script:enabled=$true;return ''}
        if($Arguments -contains 'ro.build.fingerprint'){return 'test-firmware-1'}
        return 'test-model'
    }
    function Get-Link($Target){if($script:enabled){[pscustomobject]@{Index=8;Root='fixture';Addresses=@('192.168.42.2');Gateways=@('192.168.42.1')}}}
    $Action='Connect';Connect-Phone
    Assert ($script:lastStatus -eq 'USB 网卡就绪') 'End-to-end simulated link'
    Assert ($config.Devices[0].Verified) 'Capability persisted after verification'
    $enable=@($script:requests | Where-Object {$_ -contains 'setFunctions'})
    Assert ($enable.Count -eq 1 -and $enable[0][1] -eq 'PHONE') 'Exactly one targeted enable'
    Assert ((Read-Json $configPath $null).Devices[0].Verified) 'Verified config on disk'
    # A newly inserted other phone cannot steal a still-present active phone.
    $before=$script:requests.Count;$Action='Auto';$EligibleKeys='OTHER';Connect-Phone
    Assert ($script:requests.Count -eq $before+1) 'Active phone preserves manual mode'
    # A changed firmware followed by failed verification invalidates cached support.
    $Action='Connect';$script:deadline=[DateTime]::UtcNow.AddSeconds(-1)
    function Get-Link { }
    $failed=$false
    try{Connect-Phone}catch{$failed=$true}
    Assert ($failed -and -not $config.Devices[0].Verified -and $config.Devices[0].Failures -eq 1) 'No cached success on link failure'
    # Simulate authorization timeout without sleeping or displaying UI.
    function Show-AuthorizationNotice { $null }
    function Adb([string[]]$Arguments){if($Arguments[0] -eq 'devices'){return 'PHONE unauthorized'};return ''}
    Connect-Phone
    Assert ($script:lastStatus -eq '等待授权') 'Authorization timeout stops polling'
    $script:authChecks=0;$script:deadline=[DateTime]::UtcNow.AddSeconds(120)
    function Adb([string[]]$Arguments){
        if($Arguments[0] -eq 'devices'){$script:authChecks++;if($script:authChecks -eq 1){return 'PHONE unauthorized'};return 'PHONE device'}
        return 'authorized-model'
    }
    function Get-Link { [pscustomobject]@{Index=8} }
    Connect-Phone
    Assert ($script:authChecks -eq 2 -and $script:lastStatus -eq 'USB 网卡就绪') 'Authorization automatically continues'
    function Get-Nodes { @{} }
    Connect-Phone
    Assert ($script:lastStatus -eq '连接失败') 'Unassociated device never enabled'
    # Inject task registration failure into the real install/rollback implementation.
    $programDir=Join-Path $temp 'source';$installDir=Join-Path $temp 'installed'
    [void][IO.Directory]::CreateDirectory((Join-Path $programDir 'scripts'))
    [void][IO.Directory]::CreateDirectory((Join-Path $programDir 'docs'))
    [void][IO.Directory]::CreateDirectory($installDir)
    foreach($name in 'UsbTetherHelper.exe','README.md','LICENSE','THIRD_PARTY.md','VERSION'){
        [IO.File]::WriteAllText((Join-Path $programDir $name),'new')
    }
    [IO.File]::WriteAllText((Join-Path $programDir 'scripts\Helper.ps1'),'new script')
    [IO.File]::WriteAllText((Join-Path $installDir 'UsbTetherHelper.exe'),'old')
    Save-Config;$baseline=Get-Content -LiteralPath $configPath -Raw
    function Start-Process { [pscustomobject]@{ExitCode=0} }
    function Get-ScheduledTask($TaskName){if($TaskName){[pscustomobject]@{TaskName=$TaskName;State='Ready'}}}
    function Export-ScheduledTask { '<old-task />' }
    function Disable-ScheduledTask { }
    function Stop-ScheduledTask { }
    function Start-ScheduledTask { $script:restoredStarted=$true }
    function Get-CimInstance { @() }
    function Register-Startup { throw 'injected failure' }
    function Register-ScheduledTask($TaskName,$Xml){$script:restoredXml=$Xml}
    $failed=$false
    try{Install}catch{$failed=$true}
    Assert $failed 'Rollback injection must fail install'
    Assert ((Get-Content -LiteralPath (Join-Path $installDir 'UsbTetherHelper.exe') -Raw) -eq 'old') 'Old program restored'
    Assert ((Get-Content -LiteralPath $configPath -Raw) -eq $baseline) 'Old config restored'
    Assert ($script:restoredXml -match 'old-task' -and $script:restoredStarted) 'Old task restored and restarted'
    'PASS: simulated targeted connection, config persistence, active target, failure invalidation, authorization timeout/continue, unassociated safe stop, injected upgrade rollback'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'uth-flow-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
