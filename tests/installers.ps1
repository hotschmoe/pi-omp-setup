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
    Write-Host 'PowerShell architecture, checksum rejection, and mock download checks passed.'
} finally {
    $env:PROCESSOR_ARCHITECTURE = $originalArch; $env:PROCESSOR_ARCHITEW6432 = $originalWow
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
