param([string]$Version=(Get-Content "$PSScriptRoot\..\VERSION" -Raw).Trim())
$ErrorActionPreference='Stop'
if($Version -notmatch '^\d+\.\d+\.\d+-preview\.\d+$'){throw 'Preview version required'}
$root=Split-Path $PSScriptRoot
& "$PSScriptRoot\Build.cmd"
if($LASTEXITCODE){throw 'Build failed'}
& "$root\tests\Verify.ps1"
& "$root\tests\Verify-Native.ps1"
& "$root\tests\Verify-Workflows.ps1"
& "$root\tests\Verify-Host.ps1"
$out=Join-Path $root ('dist\USBetter-'+$Version+'-windows-x64')
if(Test-Path -LiteralPath $out){throw 'Package already exists; choose a new version or remove that exact output directory.'}
[void][IO.Directory]::CreateDirectory($out)
Copy-Item -LiteralPath "$root\build\USBetter.exe" -Destination $out
foreach($name in 'scripts','docs','README.md','LICENSE','THIRD_PARTY.md','VERSION'){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $out -Recurse}
$sourceFiles=@('src','scripts','tests','tools','.github','docs','README.md','LICENSE','THIRD_PARTY.md','VERSION','.gitignore')
$sourceManifest=@(foreach($name in $sourceFiles){Get-ChildItem -LiteralPath (Join-Path $root $name) -Recurse -File | ForEach-Object {
    [pscustomobject]@{File=$_.FullName.Substring($root.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}
}})
$sourceManifest | Sort-Object File | ConvertTo-Json | Set-Content -LiteralPath "$out\source-manifest.json" -Encoding UTF8
@{Version=$Version;Architecture='x64';SourceManifestSHA256=(Get-FileHash -LiteralPath "$out\source-manifest.json").Hash;Build='MSVC C++17 static runtime; deterministic PE (/Brepro)';Compatibility='See docs/ACCEPTANCE.md; hardware scenarios remain pending'} | ConvertTo-Json | Set-Content -LiteralPath "$out\build-info.json" -Encoding UTF8
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
 [pscustomobject]@{File=$_.FullName.Substring($out.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$manifest | ConvertTo-Json | Set-Content -LiteralPath "$out\manifest.json" -Encoding UTF8
$zip=$out+'.zip'
Compress-Archive -LiteralPath $out -DestinationPath $zip
((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash+'  '+[IO.Path]::GetFileName($zip)) | Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
Write-Output $zip
