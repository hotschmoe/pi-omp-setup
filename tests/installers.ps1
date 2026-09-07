$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1') -LoadFunctionsOnly
$originalArch = $env:PROCESSOR_ARCHITECTURE
$originalWow = $env:PROCESSOR_ARCHITEW6432
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('setup-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $env:PROCESSOR_ARCHITEW6432 = ''
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    if ((Get-SetupArchitecture) -ne 'x64') { throw 'x64 mapping failed' }
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    if ((Get-SetupArchitecture) -ne 'arm64') { throw 'ARM64 mapping failed' }
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    if ((Get-SetupArchitecture) -ne 'arm64') { throw 'Emulation mapping failed' }
    $env:PROCESSOR_ARCHITEW6432 = ''; $env:PROCESSOR_ARCHITECTURE = 'x86'
    $rejected = $false
    try { Get-SetupArchitecture | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Accepted unsupported x86' }
    $asset = Join-Path $scratch 'tool.exe'
    $manifest = Join-Path $scratch 'SHA256SUMS'
    [IO.File]::WriteAllText($asset, 'fixture')
    [IO.File]::WriteAllText($manifest, (Get-FileHash $asset -Algorithm SHA256).Hash.ToLower() + '  tool.exe')
    Assert-Checksum $asset $manifest 'tool.exe'
    [IO.File]::AppendAllText($asset, 'tamper')
    $rejected = $false
    try { Assert-Checksum $asset $manifest 'tool.exe' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Accepted checksum mismatch' }
    function Invoke-WebRequest { param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile) [IO.File]::WriteAllText($OutFile, $Uri) }
    Get-Download 'https://example.invalid/asset' (Join-Path $scratch 'space name')
    if ([IO.File]::ReadAllText((Join-Path $scratch 'space name')) -ne 'https://example.invalid/asset') { throw 'Mock download path failed' }
    # Upstream DCG uses exit even on success: it must not terminate our caller.
    # Metacharacters in named arguments must remain literal across the child CLI.
    $child = Join-Path $scratch "child ' installer.ps1"
    $observed = Join-Path $scratch 'observed.txt'
    $literalValue = 'spaces '' apostrophe $(throw "injected") ` dollar $'
    [IO.File]::WriteAllText($child, 'param([string]$Output, [string]$Value, [switch]$Enabled); if (-not $Enabled) { exit 4 }; [IO.File]::WriteAllText($Output, $Value); exit 0')
    $policyBefore = Get-ExecutionPolicy -List | Out-String
    Invoke-DownloadedInstaller $child @{ Output = $observed; Value = $literalValue; Enabled = $true }
    if ([IO.File]::ReadAllText($observed) -cne $literalValue) { throw 'Child installer arguments changed' }
    if ((Get-ExecutionPolicy -List | Out-String) -cne $policyBefore) { throw 'Execution policy changed' }
    [IO.File]::WriteAllText($child, 'exit 7')
    $rejected = $false
    try { Invoke-DownloadedInstaller $child @{} } catch { $rejected = $true }
    if (-not $rejected) { throw 'Child installer failure was ignored' }
    Write-Host 'PowerShell architecture, checksums, mock downloads, and child installer checks passed.' 
} finally {
    $env:PROCESSOR_ARCHITECTURE = $originalArch; $env:PROCESSOR_ARCHITEW6432 = $originalWow
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
