[CmdletBinding()]
param([ValidateSet('Auto','Connect','Detect','Choose','Inspect','Setup','Pause','Resume','Uninstall','Diagnose')][string]$Action='Diagnose',
      [string]$DataDir=(Join-Path $env:LOCALAPPDATA 'USBetter'), [string]$SessionKey='manual', [string]$EligibleKeys='', [int]$LauncherPid=0)
. "$PSScriptRoot\Core.ps1"
Add-Type -AssemblyName System.Windows.Forms
$programDir=Split-Path $PSScriptRoot
$installDir=Join-Path $env:LOCALAPPDATA 'Programs\USBetter'
[void][IO.Directory]::CreateDirectory($DataDir)
$configPath=Join-Path $DataDir 'config.json'
$statusPath=Join-Path $DataDir 'status.txt'
$taskName='USBetter-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$configSource=$configPath
$previousConfig=Join-Path $env:LOCALAPPDATA 'USB Tether Helper\config.json'
if($Action -eq 'Setup' -and -not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $previousConfig)){$configSource=$previousConfig}
$config=Read-Json $configSource ([pscustomobject]@{Schema=1;AdbPath='';AdbVersion='';AdbHashes=@{};Preferred='';Devices=@();Paused=$false;Migrated=$false})
$script:deadline=[DateTime]::UtcNow.AddSeconds(120)
function Save-Config { Write-JsonAtomic $configPath $config }
function Set-Status([string]$State,[string]$Detail='') {
    $text=$State+$(if($Detail){': '+$Detail})
    [IO.File]::WriteAllText($statusPath,$text,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $DataDir 'helper.log'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 131072) { Move-Item -LiteralPath $log -Destination "$log.1" -Force }
    Add-Content -LiteralPath $log -Encoding UTF8 -Value ((Get-Date -Format s)+' '+$text)
}
function Message($Text) { [void][Windows.Forms.MessageBox]::Show($Text,'USBetter') }
function Show-AuthorizationNotice {
    $notice=[Windows.Forms.NotifyIcon]::new(); $notice.Icon=[Drawing.SystemIcons]::Information; $notice.Visible=$true
    $notice.ShowBalloonTip(8000,'USBetter','请在手机上允许 USB 调试；授权后自动继续。',[Windows.Forms.ToolTipIcon]::Info)
    return $notice
}
function Invoke-Process($Exe,[string[]]$Arguments,[int]$Seconds=10) {
    $remaining=[int][Math]::Ceiling(($script:deadline-[DateTime]::UtcNow).TotalSeconds)
    if ($remaining -le 0) { throw '本次配置窗口已超时。请使用重新检测。' }
    $p=[Diagnostics.Process]::new()
    $p.StartInfo=[Diagnostics.ProcessStartInfo]::new()
    $p.StartInfo.FileName=$Exe
    $p.StartInfo.Arguments=($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
    try {
        [void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit([Math]::Min($Seconds,$remaining)*1000)) { $p.Kill(); $p.WaitForExit(); throw 'ADB 客户端超时（没有停止共享服务）。' }
        $text=$out.GetAwaiter().GetResult(); $errorText=$err.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) { throw "ADB 请求失败，退出码 $($p.ExitCode)。请查看授权、驱动和版本。" }
        return $text.Trim()
    } finally { $p.Dispose() }
}
function Test-Adb($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw '缺少 adb.exe。' }
    foreach ($dll in 'AdbWinApi.dll','AdbWinUsbApi.dll') {
        if (-not (Test-Path -LiteralPath (Join-Path (Split-Path $Path) $dll))) { throw "Platform-Tools 不完整：缺少 $dll" }
    }
    $version=Invoke-Process $Path @('version')
    if ($version -notmatch 'Android Debug Bridge version 1\.0\.41') { throw '仅支持 ADB 协议 1.0.41；请从官方更新 Platform-Tools。' }
    return $version
}
function Ensure-AdbServer {
    # ADB itself uses TCP. The helper exposes no network control endpoint.
    $client=[Net.Sockets.TcpClient]::new()
    try {
        $pending=$client.BeginConnect('127.0.0.1',5037,$null,$null)
        if (-not $pending.AsyncWaitHandle.WaitOne(1000)) { throw '现有 ADB 服务没有响应，未尝试重启。' }
        try { $client.EndConnect($pending) } catch [Net.Sockets.SocketException] {
            # WMI starts the server outside the connection worker's kill-on-close job.
            $command=(Quote-Argument $config.AdbPath)+' start-server'
            $result=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command;CurrentDirectory=(Split-Path $config.AdbPath)}
            if ($result.ReturnValue -ne 0) { throw '无法启动 ADB 服务。' }
            $until=[DateTime]::UtcNow.AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 250
                $probe=[Net.Sockets.TcpClient]::new()
                try { $probe.Connect('127.0.0.1',5037); return } catch { } finally { $probe.Dispose() }
            } while ([DateTime]::UtcNow -lt $until)
            throw 'ADB 服务启动超时。'
        }
        $stream=$client.GetStream(); $stream.ReadTimeout=2000; $stream.WriteTimeout=2000
        $request=[Text.Encoding]::ASCII.GetBytes('000chost:version'); $stream.Write($request,0,$request.Length)
        $buffer=New-Object byte[] 12; $read=0
        while ($read -lt 12) { $n=$stream.Read($buffer,$read,12-$read); if($n -eq 0){throw 'ADB 协议响应不完整。'}; $read+=$n }
        if ([Text.Encoding]::ASCII.GetString($buffer) -ne 'OKAY00040029') { throw '现有 ADB 服务协议不兼容，未停止它。请先在开发工具中自行处理版本冲突。' }
    } finally { $client.Dispose() }
}
function Adb([string[]]$Arguments) { Invoke-Process $config.AdbPath (@('-P','5037')+$Arguments) }
function Get-Nodes {
    $nodes=@{}
    foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object InstanceId -like 'USB\*')) {
        $props=@(Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Parent','DEVPKEY_Device_CompatibleIds' -ErrorAction SilentlyContinue)
        $parent=@($props | Where-Object KeyName -eq 'DEVPKEY_Device_Parent')
        $compat=@($props | Where-Object KeyName -eq 'DEVPKEY_Device_CompatibleIds')
        $nodes[$d.InstanceId]=@{Parent=$(if($parent.Count){$parent[0].Data}else{''});CompatibleIds=$(if($compat.Count){@($compat[0].Data)}else{@()})}
    }
    return $nodes
}
function Get-Link($Target) {
    $nodes=Get-Nodes
    # Re-enumeration may change PID; re-resolve the unique serial root each time.
    $roots=@($nodes.Keys | Where-Object { $_ -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[^\\]+$' -and $_.EndsWith('\'+$Target.Serial,[StringComparison]::OrdinalIgnoreCase) })
    if ($roots.Count -ne 1) { return }
    foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
        if ($a.Status -ne 'Up' -or -not $a.PnPDeviceID) { continue }
        if ((Find-UsbRoot $a.PnPDeviceID $nodes) -ne $roots[0]) { continue }
        $addresses=@(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $routes=@(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        if (Test-Link $addresses $routes) {
            [pscustomobject]@{Root=$roots[0];Index=$a.ifIndex;Addresses=@($addresses.IPAddress);Gateways=@($routes.NextHop)}
        }
    }
}
function Pick-Phone($Candidates) {
    $form=[Windows.Forms.Form]::new(); $form.Text='选择 USB 手机'; $form.Width=480; $form.Height=260; $form.StartPosition='CenterScreen'
    $list=[Windows.Forms.ListBox]::new(); $list.Dock='Fill'
    foreach ($d in $Candidates) { [void]$list.Items.Add($d.Serial+' ('+$d.State+')') }
    $button=[Windows.Forms.Button]::new(); $button.Text='使用此手机'; $button.Dock='Bottom'
    $button.Add_Click({if($list.SelectedIndex -ge 0){$form.DialogResult='OK';$form.Close()}})
    $form.Controls.Add($list); $form.Controls.Add($button)
    try { if($form.ShowDialog() -eq 'OK'){return $Candidates[$list.SelectedIndex]} } finally { $form.Dispose() }
    return $null
}
function Connect-Phone {
    if ($config.Paused) { Set-Status '已暂停'; return }
    if (-not $config.AdbPath -or -not (Test-Path -LiteralPath $config.AdbPath)) { Set-Status '缺少依赖' '请运行 --setup'; return }
    [void](Test-Adb $config.AdbPath)
    foreach($name in 'adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll') {
        $expected=$config.AdbHashes.PSObject.Properties[$name]
        if(-not $expected -or (Get-FileHash -LiteralPath (Join-Path (Split-Path $config.AdbPath) $name) -Algorithm SHA256).Hash -ne $expected.Value){throw 'ADB 文件自设置后发生变化，请重新运行 --setup 确认。'}
    }
    Ensure-AdbServer
    $runPath=Join-Path $DataDir 'connection.json'
    $run=Read-Json $runPath ([pscustomobject]@{Session='';Active=''})
    if ($run.Session -ne $SessionKey) { $run.Session=$SessionKey; $run.Active='' }
    $target=$null; $notified=$false; $selection=''
    do {
        $devices=@(ConvertFrom-AdbDevices (Adb @('devices','-l')))
        $nodes=Get-Nodes; $candidates=@(Get-Candidates $devices $nodes)
        if ($Action -eq 'Auto') {
            $eligible=@($EligibleKeys -split '\|')
            $activePresent=@($nodes.Keys | Where-Object { $run.Active -and $_.EndsWith('\'+$run.Active,[StringComparison]::OrdinalIgnoreCase) })
            if ($activePresent.Count -gt 0 -and $run.Active -notin $eligible) { return }
            if(-not @($candidates | Where-Object Serial -in $eligible).Count){return}
            $automatic=Select-Candidate $candidates $config.Preferred $run.Active
            if($automatic -and $automatic.Serial -notin $eligible){return}
        }
        if($selection){
            $selected=@($candidates | Where-Object Serial -eq $selection)
            $target=if($selected.Count -eq 1){$selected[0]}else{$null}
        }
        elseif ($Action -eq 'Choose' -and $candidates.Count) { $target=Pick-Phone $candidates }
        else { $target=Select-Candidate $candidates $config.Preferred $run.Active }
        if (-not $selection -and $Action -ne 'Choose' -and -not $target -and $candidates.Count -gt 1) { $target=Pick-Phone $candidates }
        if (-not $target) {
            if ($devices.Count -and -not $candidates.Count) { Set-Status '连接失败' '无法唯一关联 ADB 与 Windows USB 根设备；检查 USB 调试驱动，未操作任何手机。' }
            else { Set-Status '等待手机' '无候选或尚未选择手机。' }
            return
        }
        $selection=$target.Serial
        if ($target.State -eq 'device') { break }
        Set-Status '等待授权' '解锁手机并允许 USB 调试；120 秒内自动继续。'
        if (-not $notified) {
            # Nonmodal notification: do not block the authorization polling window.
            $notice=Show-AuthorizationNotice
            $notified=$true
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $script:deadline)
    if ($notified -and $notice) { $notice.Dispose() }
    if ($target.State -ne 'device') { Set-Status '等待授权' '授权窗口已结束。请使用重新检测。'; return }
    $run.Active=$target.Serial; Write-JsonAtomic $runPath $run
    $config.Preferred=$target.Serial
    $model=Adb @('-s',$target.Serial,'shell','getprop','ro.product.model')
    $release=Adb @('-s',$target.Serial,'shell','getprop','ro.build.version.release')
    $fingerprint=Adb @('-s',$target.Serial,'shell','getprop','ro.build.fingerprint')
    $known=@($config.Devices | Where-Object Serial -eq $target.Serial)
    $entry=[pscustomobject]@{Serial=$target.Serial;Model=$model;Android=$release;Fingerprint=$fingerprint;Root=$target.Root;Verified=$false;Failures=0;LastCheck='';Link=$null}
    if ($known.Count -eq 1 -and $known[0].Fingerprint -eq $fingerprint) { $entry.Failures=$known[0].Failures }
    $config.Devices=@($config.Devices | Where-Object Serial -ne $target.Serial)+@($entry)
    Set-Status '正在连接' '仅验证所选手机的 USB 网卡。'
    try {
        $links=@(Get-Link $target)
        if (-not $links.Count) {
            # No VID/PID or vendor capability assumptions. A request is never proof of support.
            try { [void](Adb @('-s',$target.Serial,'shell','svc','usb','setFunctions','rndis')) } catch { }
            do {
                $links=@(Get-Link $target)
                if ($links.Count) { break }
                Start-Sleep -Seconds 2
            } while ([DateTime]::UtcNow -lt $script:deadline)
        }
        if (-not $links.Count) { throw '目标 USB 网卡没有有效 IPv4 和默认网关；手机可能不支持命令开启共享，请在手机端检查。' }
        $entry.Verified=$true; $entry.Failures=0; $entry.Link=$links[0]; Set-Status 'USB 网卡就绪' '共享已建立，未推断互联网可访问。'
    } catch { $entry.Verified=$false; $entry.Failures++; throw }
    finally { $entry.LastCheck=[DateTime]::UtcNow.ToString('o'); Save-Config }
}
function Setup {
    $script:deadline=[DateTime]::UtcNow.AddHours(1)
    $adb=$config.AdbPath
    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) {
        $found=Get-Command adb.exe -ErrorAction SilentlyContinue
        if ($found) { $adb=$found.Source }
    }
    if (-not $adb -or -not (Test-Path -LiteralPath $adb)) {
        if ([Windows.Forms.MessageBox]::Show('需要完整的 Google Platform-Tools。是否打开官方下载说明？选择“否”可直接导入离线解压目录中的 adb.exe。','准备 ADB','YesNo') -eq 'Yes') {
            Start-Process 'https://developer.android.com/tools/releases/platform-tools'
        }
        $dialog=[Windows.Forms.OpenFileDialog]::new(); $dialog.Title='选择完整 Platform-Tools 内的 adb.exe'; $dialog.Filter='ADB|adb.exe'
        try { if($dialog.ShowDialog() -ne 'OK'){return}; $adb=$dialog.FileName } finally { $dialog.Dispose() }
    }
    $config.AdbVersion=Test-Adb $adb; $config.AdbPath=[IO.Path]::GetFullPath($adb)
    $hashes=@{}
    foreach($name in 'adb.exe','AdbWinApi.dll','AdbWinUsbApi.dll') { $hashes[$name]=(Get-FileHash -LiteralPath (Join-Path (Split-Path $adb) $name) -Algorithm SHA256).Hash }
    $config.AdbHashes=$hashes
    Install
    Message '设置完成。请开启手机 USB 调试并授权。状态和后续操作在系统托盘中。'
}
function Register-Startup {
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    $recovery=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $execute=New-ScheduledTaskAction -Execute (Join-Path $installDir 'USBetter.exe')
    Register-ScheduledTask -TaskName $taskName -Action $execute -Trigger @($trigger,$recovery) -Principal $principal -Settings $settings -Force | Out-Null
}
function Schedule-ProgramRemoval {
    # Separate hidden process survives the resident job and waits for its exit.
    $cleanup=@'
$ErrorActionPreference='Stop'
$until=[DateTime]::UtcNow.AddSeconds(30)
while(__PID__ -gt 0 -and (Get-Process -Id __PID__ -ErrorAction SilentlyContinue)) {
 if([DateTime]::UtcNow -gt $until){exit 1}; Start-Sleep -Milliseconds 200
}
$programs=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
$target=[IO.Path]::GetFullPath((Join-Path $programs 'USBetter'))
if([IO.Path]::GetDirectoryName($target) -ne $programs -or [IO.Path]::GetFileName($target) -ne 'USBetter'){exit 1}
if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force}
'@
    $cleanup=$cleanup.Replace('__PID__',[string]$LauncherPid)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanup))
    $startup=New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ShowWindow=[uint16]0}
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $result=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=((Quote-Argument $exe)+' -NoProfile -NonInteractive -EncodedCommand '+$encoded);ProcessStartupInformation=$startup}
    if($result.ReturnValue -ne 0){throw '自启已移除；程序文件清理未启动，请退出后手动删除安装目录。'}
}
function Install {
    $check=Start-Process -FilePath (Join-Path $programDir 'USBetter.exe') -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
    if($check.ExitCode -ne 0){throw '安装包原生自检失败。'}
    $backup=Join-Path $DataDir ('backup-'+(Get-Date -Format 'yyyyMMddHHmmssfff'))
    [void][IO.Directory]::CreateDirectory($backup)
    $oldTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $legacy=@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -in @(('AzqUsbTether-'+$sid),('UsbTetherHelper-'+$sid)) })
    $same=[IO.Path]::GetFullPath($programDir) -eq [IO.Path]::GetFullPath($installDir)
    if(Test-Path -LiteralPath $configPath){Copy-Item -LiteralPath $configPath -Destination (Join-Path $backup 'config.json')}
    if($oldTask){Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $backup 'task.xml') -Encoding Unicode}
    foreach($t in $legacy){Export-ScheduledTask -TaskName $t.TaskName | Set-Content -LiteralPath (Join-Path $backup ($t.TaskName+'.xml')) -Encoding Unicode}
    if(-not $same -and (Test-Path -LiteralPath $installDir)){Copy-Item -LiteralPath $installDir -Destination (Join-Path $backup 'program') -Recurse}
    try {
        if($oldTask){Disable-ScheduledTask -TaskName $taskName | Out-Null; Stop-ScheduledTask -TaskName $taskName}
        foreach($t in $legacy){Disable-ScheduledTask -TaskName $t.TaskName | Out-Null; Stop-ScheduledTask -TaskName $t.TaskName}
        # Target only executables installed under this user's known program directories.
        foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='USBetter.exe' OR Name='UsbTetherHelper.exe' OR Name='DeviceWatcher.exe'")) {
            if($p.ProcessId -ne $LauncherPid -and $p.ExecutablePath -in @((Join-Path $installDir 'USBetter.exe'),(Join-Path $env:LOCALAPPDATA 'Programs\USB Tether Helper\UsbTetherHelper.exe'),(Join-Path $env:LOCALAPPDATA 'AzqUsbTether\DeviceWatcher.exe'))){Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop}
        }
        if(-not $config.Migrated){
            foreach($t in $legacy){
                $arg=[string]$t.Actions[0].Arguments
                if($arg -match '^"?([a-zA-Z0-9_.-]+)"?\s'){$config.Preferred=$Matches[1]}
            }
            $config.Migrated=$true
        }
        if(-not $same){
            [void][IO.Directory]::CreateDirectory($installDir)
            foreach($name in 'USBetter.exe','scripts','docs','README.md','LICENSE','THIRD_PARTY.md','VERSION'){
                Copy-Item -LiteralPath (Join-Path $programDir $name) -Destination $installDir -Recurse -Force
            }
            foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $programDir 'scripts') -File)+@(Get-Item -LiteralPath (Join-Path $programDir 'USBetter.exe'))){
                $relative=$file.FullName.Substring($programDir.Length+1)
                if((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $installDir $relative)).Hash){throw '程序复制校验失败。'}
            }
        }
        $config.Paused=$false; Save-Config
        Remove-Item -LiteralPath (Join-Path $DataDir 'paused') -Force -ErrorAction SilentlyContinue
        Register-Startup; Start-ScheduledTask -TaskName $taskName
        $until=[DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $started=@(Get-CimInstance Win32_Process -Filter "Name='USBetter.exe'" | Where-Object ExecutablePath -eq (Join-Path $installDir 'USBetter.exe'))
            if($started.Count){break}
        } while([DateTime]::UtcNow -lt $until)
        if(-not $started.Count){throw '新监听器未启动，恢复旧安装。'}
    } catch {
        $failure=$_
        if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $taskName | Out-Null; Stop-ScheduledTask -TaskName $taskName}
        foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='USBetter.exe'")){
            if($p.ProcessId -ne $LauncherPid -and $p.ExecutablePath -eq (Join-Path $installDir 'USBetter.exe')){Stop-Process -Id $p.ProcessId -Force}
        }
        if(-not $same -and (Test-Path -LiteralPath (Join-Path $backup 'program'))){Copy-Item -Path (Join-Path $backup 'program\*') -Destination $installDir -Recurse -Force}
        if(Test-Path -LiteralPath (Join-Path $backup 'config.json')){Copy-Item -LiteralPath (Join-Path $backup 'config.json') -Destination $configPath -Force}
        if($oldTask){Register-ScheduledTask -TaskName $taskName -Xml (Get-Content -LiteralPath (Join-Path $backup 'task.xml') -Raw) -Force | Out-Null; if($oldTask.State -ne 'Disabled'){Start-ScheduledTask -TaskName $taskName}}
        else {Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue}
        foreach($t in $legacy){Register-ScheduledTask -TaskName $t.TaskName -Xml (Get-Content -LiteralPath (Join-Path $backup ($t.TaskName+'.xml')) -Raw) -Force | Out-Null; if($t.State -ne 'Disabled'){Start-ScheduledTask -TaskName $t.TaskName}}
        throw $failure
    }
}
function Main {
    switch($Action){
        Setup { Setup }
        Inspect {
            if($config.Paused){Set-Status '已暂停';return}
            $run=Read-Json (Join-Path $DataDir 'connection.json') ([pscustomobject]@{Session='';Active=''})
            if(-not $config.AdbPath){Set-Status '缺少依赖';return}
            if($run.Session -eq $SessionKey -and $run.Active){
                $links=@(Get-Link ([pscustomobject]@{Serial=$run.Active}))
                if($links.Count){Set-Status 'USB 网卡就绪' '共享已建立，未推断互联网可访问。'}
                else{Set-Status '等待手机' '没有就绪的目标网卡；保留用户当前 USB 模式。'}
            }else{Set-Status '等待手机'}
        }
        {$_ -in 'Auto','Connect','Detect','Choose'} { Connect-Phone }
        Pause { $config.Paused=$true; Save-Config; [IO.File]::WriteAllText((Join-Path $DataDir 'paused'),'paused'); if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $taskName | Out-Null}; Set-Status '已暂停' }
        Resume { $config.Paused=$false; Save-Config; Remove-Item -LiteralPath (Join-Path $DataDir 'paused') -Force -ErrorAction SilentlyContinue; if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Enable-ScheduledTask -TaskName $taskName | Out-Null}; Set-Status '等待手机' }
        Uninstall {
            if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $taskName | Out-Null; Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
            # Keep files until the resident process exits; never change phone USB mode.
            Set-Status '已卸载' '自启已移除，手机共享状态保留。退出后清理安装目录。'
            if([Windows.Forms.MessageBox]::Show('自启已移除，手机共享状态保留。是否删除本地配置、日志和备份？','卸载','YesNo') -eq 'Yes'){
                $resolved=[IO.Path]::GetFullPath($DataDir)
                $expected=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'USBetter'))
                if($resolved -ne $expected){throw '拒绝删除非默认数据目录。'}
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
            Schedule-ProgramRemoval
        }
        Diagnose {
            $status=if(Test-Path -LiteralPath $statusPath){Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8}else{'尚未配置'}
            # Export only a fixed allowlist, never exception text, serials or local paths.
            $safe=$status -replace '[:：].*',''
            $report=[pscustomobject]@{Version=(Get-Content -LiteralPath (Join-Path $programDir 'VERSION') -Raw).Trim();State=$safe;AdbPresent=[bool]($config.AdbPath -and (Test-Path -LiteralPath $config.AdbPath));VerifiedDevices=@($config.Devices | Where-Object Verified).Count;InternetTest='未执行';Drivers='请在设备管理器检查 Android ADB Interface 与 USB 网络适配器；本工具不修改驱动或注册表。'}
            Write-JsonAtomic (Join-Path $DataDir 'diagnostic-public.json') $report
            Message ($report | ConvertTo-Json)
        }
    }
}
if($MyInvocation.InvocationName -ne '.') {
    try { Main } catch { Set-Status '连接失败' $_.Exception.Message; if($Action -eq 'Setup'){Message $_.Exception.Message}; exit 1 }
}
