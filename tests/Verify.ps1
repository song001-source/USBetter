$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\scripts\Core.ps1"
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
$nodes=@{
 'USB\VID_18D1&PID_4EE7\PIXEL'=@{Parent='HUB';CompatibleIds=@()}
 'USB\VID_18D1&PID_4EE7&MI_01\ADB'=@{Parent='USB\VID_18D1&PID_4EE7\PIXEL';CompatibleIds=@('USB\Class_ff&SubClass_42&Prot_01')}
 'USB\VID_1234&PID_5678\OTHER'=@{Parent='HUB';CompatibleIds=@()}
 'USB\VID_1234&PID_5678&MI_00\NET'=@{Parent='USB\VID_1234&PID_5678\OTHER';CompatibleIds=@()}
}
$devices=@(ConvertFrom-AdbDevices "List of devices attached`nPIXEL device`n192.168.0.1:5555 device`nemulator-5554 device`nX._adb-tls-connect._tcp device")
Assert ($devices.Count -eq 1) 'Wireless/emulator filtering'
$c=@(Get-Candidates $devices $nodes)
Assert ($c.Count -eq 1 -and $c[0].Serial -eq 'PIXEL') 'Non-Xiaomi association'
Assert ((Find-UsbRoot 'USB\VID_1234&PID_5678&MI_00\NET' $nodes) -ne $c[0].Root) 'Adapter isolation'
$nodes['USB\VID_9999&PID_0001\PIXEL']=@{Parent='HUB';CompatibleIds=@()}
Assert (@(Get-Candidates $devices $nodes).Count -eq 0) 'Duplicate serial must fail closed'
$two=@([pscustomobject]@{Serial='A'},[pscustomobject]@{Serial='B'})
Assert ($null -eq (Select-Candidate $two '' '')) 'Ambiguous selection'
Assert ((Select-Candidate $two 'B' 'A').Serial -eq 'A') 'Active target preserved'
Assert ((Select-Candidate $two 'B' '').Serial -eq 'B') 'Explicit target'
Assert (-not (Test-Link @(@{IPAddress='169.254.1.2';AddressState='Preferred'}) @(@{NextHop='1.2.3.4'}))) 'APIPA rejected'
Assert (Test-Link @(@{IPAddress='192.168.42.2';AddressState='Preferred'}) @(@{NextHop='192.168.42.1'})) 'USB link'
Assert (-not (Test-Link @(@{IPAddress='192.168.42.2';AddressState='Preferred'}) @())) 'Gateway required'
$temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()+'.json')
try {
 Write-JsonAtomic $temp @{Path='C:\中文 路径\';Serial='TEST'}
 Assert ((Read-Json $temp $null).Path -eq 'C:\中文 路径\') 'Unicode config'
 Write-JsonAtomic $temp @{Path='changed'}
 Assert ((Read-Json $temp $null).Path -eq 'changed') 'Atomic replace'
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
Get-ChildItem "$PSScriptRoot\.." -Recurse -Filter *.ps1 | ForEach-Object {
 $tokens=$null; $errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
 Assert ($errors.Count -eq 0) ("Parse: "+$_.Name+': '+$errors)
}
'PASS: identity, isolation, ambiguity, active selection, link criteria, atomic Unicode config, script syntax'
