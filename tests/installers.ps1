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
    # Node archive selection ignores unrelated artifacts.
    [IO.File]::WriteAllText($manifest, ("a" * 64) + "  node-v24.1.0-win-x64.7z`n" + ("b" * 64) + "  node-v24.1.0-win-x64.zip`n" + ("c" * 64) + "  node-v24.1.0-win-arm64.zip`n")
    if ((Get-NodeAsset 'x64' $manifest) -ne 'node-v24.1.0-win-x64.zip') { throw 'Node x64 asset selection failed' }
    if ((Get-NodeAsset 'arm64' $manifest) -ne 'node-v24.1.0-win-arm64.zip') { throw 'Node ARM64 asset selection failed' }
    # Legacy cleanup removes only what earlier installers created.
    $script:BinDir = Join-Path $scratch 'bin'; $script:DataDir = Join-Path $scratch 'data'; $script:PiDir = Join-Path $scratch 'pi'
    $legacyOmp = Join-Path $scratch 'omp'
    New-Item -ItemType Directory -Path $BinDir, (Join-Path $DataDir 'pi-v0.85.1'), (Join-Path $PiDir 'extensions'), (Join-Path $legacyOmp 'extensions') | Out-Null
    foreach ($name in 'omp.exe','dcg.exe','pi.cmd','pi-omp-setup.exe') { [IO.File]::WriteAllText((Join-Path $BinDir $name), 'x') }
    [IO.File]::WriteAllText((Join-Path $PiDir 'extensions\dcg-pi.ts'), "// pi-omp-setup: managed dcg extension`n")
    [IO.File]::WriteAllText((Join-Path $PiDir 'extensions\bang-guard.ts'), "// bang-guard: managed extension`n")
    [IO.File]::WriteAllText((Join-Path $legacyOmp 'extensions\bang-guard.ts'), "// my own extension`n")
    Remove-LegacyInstall $legacyOmp 6>$null 3>$null
    foreach ($gone in 'bin\omp.exe','bin\dcg.exe','bin\pi.cmd','data\pi-v0.85.1','pi\extensions\dcg-pi.ts','pi\extensions\bang-guard.ts') {
        if (Test-Path -LiteralPath (Join-Path $scratch $gone)) { throw "Cleanup left $gone" }
    }
    foreach ($kept in 'bin\pi-omp-setup.exe','omp\extensions\bang-guard.ts') {
        if (-not (Test-Path -LiteralPath (Join-Path $scratch $kept))) { throw "Cleanup removed $kept" }
    }
    Write-Host 'PowerShell architecture, checksums, mock downloads, Node selection, and cleanup checks passed.' 
} finally {
    $env:PROCESSOR_ARCHITECTURE = $originalArch; $env:PROCESSOR_ARCHITEW6432 = $originalWow
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
