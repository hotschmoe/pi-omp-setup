# Per-user Windows x64/ARM64 installation (PowerShell 5.1 or newer).
[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $HOME '.local\bin'),
    [string]$DataDir = (Join-Path $HOME '.local\share\pi-omp-setup'),
    [string]$PiDir = (Join-Path $HOME '.pi\agent'),
    [switch]$ConfigureOnly,
    [switch]$Plan,
    [switch]$LoadFunctionsOnly
)
$ErrorActionPreference = 'Stop'
$NodeMajor = 24
$PiPackage = '@earendil-works/pi-coding-agent'
$OmpDir = Join-Path $HOME '.omp\agent'
function Get-SetupArchitecture {
    # PROCESSOR_ARCHITEW6432 identifies the host when running an emulated shell.
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { throw "Unsupported Windows architecture: $native" } }
}
function Get-Download([string]$Url, [string]$Path) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
}
function Assert-Checksum([string]$Path, [string]$Manifest, [string]$Name) {
    $matches = @(Get-Content -LiteralPath $Manifest | Where-Object { $_ -match ('^[a-fA-F0-9]{64}\s+\*?' + [regex]::Escape($Name) + '$') })
    if ($matches.Count -ne 1) { throw "Missing/invalid checksum: $Name" }
    $expected = ($matches[0] -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $expected) { throw "Checksum mismatch: $Name" }
}
function Add-UserPath([string]$Directory) {
    $current = [string][Environment]::GetEnvironmentVariable('Path', 'User')
    if (@($current -split ';') -notcontains $Directory) {
        [Environment]::SetEnvironmentVariable('Path', (($current.TrimEnd(';') + ';' + $Directory).TrimStart(';')), 'User')
    }
    if (@($env:Path -split ';') -notcontains $Directory) { $env:Path = "$Directory;$env:Path" }
}
function Assert-Exit([string]$Name) { if ($LASTEXITCODE -ne 0) { throw "$Name exited with code $LASTEXITCODE" } }
function Install-Bash([string]$Arch, [string]$Scratch) {
    $candidates = @((Join-Path $DataDir 'git\bin\bash.exe'))
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { $candidates += (Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe') }
    $bashPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $bashPath) {
        Write-Host 'Installing portable Git for Windows to supply Bash required by Pi.'
        $flavor = if ($Arch -eq 'arm64') { 'arm64' } else { '64-bit' }
        $expected = if ($Arch -eq 'arm64') { '49d1dd3158017fa9805d07268433dbab7021b2ec1c1cc3fbabaf8b8255764dd0' } else { '5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290' }
        $archive = Join-Path $Scratch 'portable-git.exe'
        Get-Download "https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/PortableGit-2.55.0.5-$flavor.7z.exe" $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'Portable Git checksum mismatch' }
        $gitDir = Join-Path $DataDir 'git'
        $process = Start-Process -FilePath $archive -ArgumentList @('-y', ('-o"' + $gitDir + '"')) -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Portable Git extraction failed: $($process.ExitCode)" }
        $bashPath = Join-Path $gitDir 'bin\bash.exe'
        if (-not (Test-Path -LiteralPath $bashPath)) { throw 'Portable Git did not provide Bash' }
        Add-UserPath (Join-Path $gitDir 'cmd')
    }
    # Pi resolves bash.exe from PATH (there is no PI_BASH_PATH setting).
    Add-UserPath (Split-Path $bashPath)
}
function Remove-ManagedFile([string]$Path, [string]$Marker) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    if ((Get-Content -LiteralPath $Path -TotalCount 1) -ceq $Marker) { Remove-Item -LiteralPath $Path -Force; Write-Host "Removed $Path" }
    else { Write-Warning "Left custom file in place: $Path" }
}
# Remove files left by earlier versions (standalone Pi build, OMP, DCG, bang-guard).
# The ~/.omp directory is never deleted because it can hold the user's own sessions.
function Remove-LegacyInstall([string]$OmpDir) {
    foreach ($name in 'omp.exe','dcg.exe','pi.cmd') {
        $path = Join-Path $BinDir $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "Removed $path" }
    }
    Get-ChildItem -LiteralPath $DataDir -Directory -Filter 'pi-v*' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force; Write-Host "Removed $($_.FullName)"
    }
    Remove-ManagedFile (Join-Path $PiDir 'extensions\dcg-pi.ts') '// pi-omp-setup: managed dcg extension'
    Remove-ManagedFile (Join-Path $PiDir 'extensions\bang-guard.ts') '// bang-guard: managed extension'
    Remove-ManagedFile (Join-Path $OmpDir 'extensions\bang-guard.ts') '// bang-guard: managed extension'
    if (Test-Path -LiteralPath $OmpDir) { Write-Host "Oh My Pi is no longer installed; your data in $OmpDir was left untouched." }
}
function Get-NodeAsset([string]$Arch, [string]$Manifest) {
    $suffix = "-win-$Arch.zip"
    $names = @(Get-Content -LiteralPath $Manifest | ForEach-Object { if ($_ -match '^[a-fA-F0-9]{64}\s+\*?(node-v[0-9.]+-.*)$') { $Matches[1] } } | Where-Object { $_.EndsWith($suffix) })
    if ($names.Count -lt 1) { throw 'No Node.js build for this platform' }
    return $names[0]
}
function Install-Node([string]$Arch, [string]$Scratch) {
    $base = "https://nodejs.org/dist/latest-v$NodeMajor.x"
    $manifest = Join-Path $Scratch 'node.sha256'
    Get-Download "$base/SHASUMS256.txt" $manifest
    $asset = Get-NodeAsset $Arch $manifest
    $archive = Join-Path $Scratch $asset
    Get-Download "$base/$asset" $archive
    Assert-Checksum $archive $manifest $asset
    $unpacked = Join-Path $Scratch 'node-unpacked'
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
    $target = Join-Path $DataDir 'node'
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Move-Item -LiteralPath (Join-Path $unpacked ($asset -replace '\.zip$','')) -Destination $target
    if (-not (Test-Path -LiteralPath (Join-Path $target 'node.exe'))) { throw 'Node archive missing executable' }
}
function Install-Pi {
    $node = Join-Path $DataDir 'node'
    $prefix = Join-Path $DataDir 'npm'
    New-Item -ItemType Directory -Path $prefix -Force | Out-Null
    $savedPath = $env:Path; $savedPrefix = $env:NPM_CONFIG_PREFIX
    try {
        $env:Path = "$node;$env:Path"; $env:NPM_CONFIG_PREFIX = $prefix
        & (Join-Path $node 'npm.cmd') install -g --no-fund --no-audit --loglevel=error "$PiPackage@latest"
        Assert-Exit 'Pi installation'
    } finally { $env:Path = $savedPath; $env:NPM_CONFIG_PREFIX = $savedPrefix }
    if (-not (Test-Path -LiteralPath (Join-Path $prefix 'pi.cmd'))) { throw 'Pi package did not provide a pi command' }
    # The launcher points npm at the private prefix so `pi update` stays self-contained.
    $wrapper = '@echo off' + "`r`n" + 'setlocal' + "`r`n" +
        'set "NPM_CONFIG_PREFIX=' + $prefix + '"' + "`r`n" +
        'set "PATH=' + $node + ';' + $prefix + ';%PATH%"' + "`r`n" +
        '"' + (Join-Path $prefix 'pi.cmd') + '" %*' + "`r`n"
    [IO.File]::WriteAllText((Join-Path $BinDir 'pi.cmd'), $wrapper, [Text.Encoding]::Default)
}
function Invoke-Setup {
    $arch = Get-SetupArchitecture
    $helperAsset = "pi-omp-setup-windows-$arch.exe"
    if ($Plan) { Write-Output "node-v$NodeMajor-win-$arch",$PiPackage,$helperAsset; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('pi-omp-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch,$BinDir,$DataDir -Force | Out-Null
    try {
        if (-not $ConfigureOnly) {
            Remove-LegacyInstall $OmpDir
            Install-Bash $arch $scratch
            Install-Node $arch $scratch
            Install-Pi
        }
        $base = 'https://github.com/hotschmoe/pi-omp-setup/releases/download/v0.2.0'
        Get-Download "$base/$helperAsset" (Join-Path $scratch $helperAsset)
        Get-Download "$base/config.enc.json" (Join-Path $scratch 'config.enc.json')
        Get-Download "$base/SHA256SUMS" (Join-Path $scratch 'setup.sha256')
        Assert-Checksum (Join-Path $scratch $helperAsset) (Join-Path $scratch 'setup.sha256') $helperAsset
        Assert-Checksum (Join-Path $scratch 'config.enc.json') (Join-Path $scratch 'setup.sha256') 'config.enc.json'
        $helper = Join-Path $BinDir 'pi-omp-setup.exe'
        Copy-Item -LiteralPath (Join-Path $scratch $helperAsset) -Destination $helper -Force
        & $helper configure --bundle (Join-Path $scratch 'config.enc.json') --pi-dir $PiDir
        Assert-Exit 'Private configuration'
        Add-UserPath $BinDir
        Write-Host 'Installed. Open a new terminal and run pi (update later with: pi update).'
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
if (-not $LoadFunctionsOnly) { Invoke-Setup }
