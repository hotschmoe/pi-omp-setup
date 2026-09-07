# Per-user Windows x64/ARM64 installation (PowerShell 5.1 or newer).
[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $HOME '.local\bin'),
    [string]$DataDir = (Join-Path $HOME '.local\share\pi-omp-setup'),
    [string]$PiDir = (Join-Path $HOME '.pi\agent'),
    [string]$OmpDir = (Join-Path $HOME '.omp\agent'),
    [ValidateSet('Ask','Yes','No')][string]$Guards = 'Ask',
    [switch]$ConfigureOnly,
    [switch]$NoGuards,
    [switch]$Plan,
    [switch]$LoadFunctionsOnly
)
$ErrorActionPreference = 'Stop'
function Get-SetupArchitecture {
    # PROCESSOR_ARCHITEW6432 identifies the host when running an emulated shell.
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { throw "Unsupported Windows architecture: $native" } }
}
function Get-Download([string]$Url, [string]$Path) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path
}
function Invoke-DownloadedInstaller([string]$Path, [hashtable]$Parameters) {
    # A child process isolates upstream `exit` statements. Execute the downloaded
    # text as a scriptblock so no file execution-policy change is needed.
    $literalPath = "'" + $Path.Replace("'", "''") + "'"
    $entries = foreach ($key in $Parameters.Keys) {
        if ($key -notmatch '^[a-zA-Z][a-zA-Z0-9]*$') { throw 'Invalid installer parameter name' }
        $value = $Parameters[$key]
        if ($value -is [bool]) { $literal = if ($value) { '$true' } else { '$false' } }
        elseif ($value -is [string]) { $literal = "'" + $value.Replace("'", "''") + "'" }
        else { throw 'Unsupported installer parameter type' }
        "'$key' = $literal"
    }
    $command = '$ErrorActionPreference = ''Stop''; $installerParameters = @{' + ($entries -join '; ') + '}; & ([scriptblock]::Create([IO.File]::ReadAllText(' + $literalPath + '))) @installerParameters'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $executable = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $executable)) { $executable = Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $executable)) { $executable = Join-Path $PSHOME 'pwsh' }
    & $executable -NoProfile -EncodedCommand $encoded
    Assert-Exit 'Optional guard installer'
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
function Ask-Guard([string]$Name) {
    if ($Guards -eq 'No' -or $NoGuards) { return $false }
    if ($Guards -eq 'Yes') { return $true }
    $reply = Read-Host "Install $Name? [Y/n]"
    return ($reply -eq '' -or $reply -match '^(y|yes)$')
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
function Invoke-Setup {
    $arch = Get-SetupArchitecture
    $piAsset = "pi-windows-$arch.zip"
    $ompAsset = "omp-windows-$arch.exe"
    $helperAsset = "pi-omp-setup-windows-$arch.exe"
    if ($Plan) { Write-Output $piAsset,$ompAsset,$helperAsset; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('pi-omp-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch,$BinDir,$DataDir -Force | Out-Null
    try {
        if (-not $ConfigureOnly) {
            Install-Bash $arch $scratch
            $base = 'https://github.com/earendil-works/pi/releases/download/v0.85.1'
            Get-Download "$base/$piAsset" (Join-Path $scratch $piAsset)
            Get-Download "$base/SHA256SUMS" (Join-Path $scratch 'pi.sha256')
            Assert-Checksum (Join-Path $scratch $piAsset) (Join-Path $scratch 'pi.sha256') $piAsset
            Expand-Archive -LiteralPath (Join-Path $scratch $piAsset) -DestinationPath (Join-Path $scratch 'pi-unpacked')
            $piExe = Get-ChildItem -LiteralPath (Join-Path $scratch 'pi-unpacked') -Recurse -Filter pi.exe | Select-Object -First 1
            if (-not $piExe) { throw 'Pi archive missing executable' }
            $piHome = Join-Path $DataDir 'pi-v0.85.1'
            New-Item -ItemType Directory -Path $piHome -Force | Out-Null
            Copy-Item -Path (Join-Path $piExe.Directory.FullName '*') -Destination $piHome -Recurse -Force
            # Preserve executable-relative docs/themes; cmd wrapper needs no symlink privileges.
            $wrapper = '@echo off' + "`r`n" + '"' + (Join-Path $piHome 'pi.exe') + '" %*' + "`r`n"
            [IO.File]::WriteAllText((Join-Path $BinDir 'pi.cmd'), $wrapper, [Text.Encoding]::Default)
            $base = 'https://github.com/can1357/oh-my-pi/releases/download/v18.1.14'
            Get-Download "$base/$ompAsset" (Join-Path $scratch $ompAsset)
            Get-Download "$base/SHA256SUMS.txt" (Join-Path $scratch 'omp.sha256')
            Assert-Checksum (Join-Path $scratch $ompAsset) (Join-Path $scratch 'omp.sha256') $ompAsset
            Copy-Item -LiteralPath (Join-Path $scratch $ompAsset) -Destination (Join-Path $BinDir 'omp.exe') -Force
        }
        $base = 'https://github.com/hotschmoe/pi-omp-setup/releases/download/v0.1.0'
        Get-Download "$base/$helperAsset" (Join-Path $scratch $helperAsset)
        Get-Download "$base/config.enc.json" (Join-Path $scratch 'config.enc.json')
        Get-Download "$base/SHA256SUMS" (Join-Path $scratch 'setup.sha256')
        Assert-Checksum (Join-Path $scratch $helperAsset) (Join-Path $scratch 'setup.sha256') $helperAsset
        Assert-Checksum (Join-Path $scratch 'config.enc.json') (Join-Path $scratch 'setup.sha256') 'config.enc.json'
        $helper = Join-Path $BinDir 'pi-omp-setup.exe'
        Copy-Item -LiteralPath (Join-Path $scratch $helperAsset) -Destination $helper -Force
        & $helper configure --bundle (Join-Path $scratch 'config.enc.json') --pi-dir $PiDir --omp-dir $OmpDir
        Assert-Exit 'Private configuration'
        Add-UserPath $BinDir
        if (Ask-Guard 'Destructive Command Guard (DCG)') {
            $installer = Join-Path $scratch 'dcg-install.ps1'
            Get-Download 'https://raw.githubusercontent.com/Dicklesworthstone/destructive_command_guard/v0.14.0/install.ps1' $installer
            Invoke-DownloadedInstaller $installer @{ Version = 'v0.14.0'; EasyMode = $true; NoConfigure = $true; Dest = $BinDir }
            $savedProfile = $env:OMP_PROFILE; $savedLegacyProfile = $env:PI_PROFILE; $savedAgentDir = $env:PI_CODING_AGENT_DIR
            try {
                $env:OMP_PROFILE = 'default'; $env:PI_PROFILE = 'default'; $env:PI_CODING_AGENT_DIR = $OmpDir
                & (Join-Path $BinDir 'dcg.exe') install --omp
                Assert-Exit 'OMP DCG adapter installation'
            } finally {
                $env:OMP_PROFILE = $savedProfile; $env:PI_PROFILE = $savedLegacyProfile; $env:PI_CODING_AGENT_DIR = $savedAgentDir
            }
            $adapter = Join-Path $scratch 'dcg-pi.ts'
            Get-Download "$base/dcg-pi.ts" $adapter
            Assert-Checksum $adapter (Join-Path $scratch 'setup.sha256') 'dcg-pi.ts'
            $dest = Join-Path $PiDir 'extensions\dcg-pi.ts'
            $item = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            if ($item) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing symlink: $dest" }
                if ((Get-Content -LiteralPath $dest -TotalCount 1) -cne '// pi-omp-setup: managed dcg extension') { throw "Refusing to replace custom extension: $dest" }
                Copy-Item -LiteralPath $dest -Destination "$dest.bak" -Force
            }
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item -LiteralPath $adapter -Destination $dest -Force
        }
        if (Ask-Guard 'bang-guard') {
            $installer = Join-Path $scratch 'bang-install.ps1'
            Get-Download 'https://raw.githubusercontent.com/hotschmoe/bang-guard/v0.3.0/install.ps1' $installer
            Invoke-DownloadedInstaller $installer @{ Version = 'v0.3.0'; Target = 'Both'; PiDir = $PiDir; OmpDir = $OmpDir }
        }
        Write-Host 'Installed. Open a new terminal and run pi or omp.'
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
if (-not $LoadFunctionsOnly) { Invoke-Setup }
