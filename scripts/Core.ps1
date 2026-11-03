Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Quote-Argument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Write-JsonAtomic($Path, $Value) {
    $temp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,"$temp.previous"); [IO.File]::Delete("$temp.previous") }
    else { [IO.File]::Move($temp,$Path) }
}
function Read-Json($Path, $Default) {
    if (Test-Path -LiteralPath $Path) { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    return $Default
}
function ConvertFrom-AdbDevices([string]$Text) {
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([^\s]+)\s+(device|unauthorized|offline)\b') {
            $serial=$Matches[1]; $state=$Matches[2]
            # Wireless transports and emulator serials never enter USB association.
            if ($serial -match '[:/\\]' -or $serial -like 'emulator-*' -or $serial -like '*._tcp*') { continue }
            [pscustomobject]@{ Serial=$serial; State=$state }
        }
    }
}
function Find-UsbRoot($Id, $Nodes) {
    $visited=@{}
    for ($i=0; $i -lt 32 -and $Id; $i++) {
        if ($visited.ContainsKey($Id) -or -not $Nodes.ContainsKey($Id)) { return $null }
        $visited[$Id]=$true; $node=$Nodes[$Id]
        if ($Id -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[^\\]+$') { return $Id }
        $Id=$node.Parent
    }
    return $null
}
function Get-Candidates($Devices, $Nodes) {
    foreach ($d in $Devices) {
        $roots=@($Nodes.Keys | Where-Object {
            $_ -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\[^\\]+$' -and
            $_.EndsWith('\'+$d.Serial,[StringComparison]::OrdinalIgnoreCase)
        })
        # Exact serial equality plus a present ADB interface under the root is required.
        $adbRoots=@($Nodes.Keys | Where-Object {
            @($Nodes[$_].CompatibleIds | Where-Object { $_ -match 'Class_ff&SubClass_42&Prot_01' }).Count -gt 0
        } | ForEach-Object { Find-UsbRoot $_ $Nodes } | Select-Object -Unique)
        if ($roots.Count -eq 1 -and $roots[0] -in $adbRoots) {
            [pscustomobject]@{ Serial=$d.Serial; State=$d.State; Root=$roots[0] }
        }
    }
}
function Select-Candidate($Candidates, [string]$Preferred, [string]$Active) {
    if ($Active) {
        $found=@($Candidates | Where-Object Serial -eq $Active)
        if ($found.Count -eq 1) { return $found[0] }
    }
    if ($Preferred) {
        $found=@($Candidates | Where-Object Serial -eq $Preferred)
        if ($found.Count -eq 1) { return $found[0] }
    }
    if (@($Candidates).Count -eq 1) { return @($Candidates)[0] }
    return $null
}
function Test-Link($Addresses, $Routes) {
    $valid=@($Addresses | Where-Object {
        $ip=$null
        [Net.IPAddress]::TryParse($_.IPAddress,[ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork' -and
        $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(0\.|127\.|169\.254\.|22[4-9]\.|2[3-5][0-9]\.)'
    })
    return $valid.Count -gt 0 -and @($Routes | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' }).Count -gt 0
}
