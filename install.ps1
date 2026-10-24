# Per-user Windows x64/ARM64 installation of Pi and Oh My Pi release binaries.
# No Node.js, npm, or administrator account is required. PowerShell 5.1 or newer.
[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $HOME '.local\bin'),
    [string]$DataDir = (Join-Path $HOME '.local\share\pi-omp-setup'),
    [string]$PiDir = (Join-Path $HOME '.pi\agent'),
    [string]$OmpDir = (Join-Path $HOME '.omp\agent'),
    [switch]$ConfigureOnly,
    [switch]$Update,
    [switch]$SkipProbe,
    [switch]$Plan,
    [switch]$LoadFunctionsOnly
)
$ErrorActionPreference = 'Stop'
$SetupVersion = 'v0.3.1'
$PiRelease = 'https://github.com/earendil-works/pi/releases/latest/download'
$OmpRelease = 'https://github.com/can1357/oh-my-pi/releases/latest/download'
function Get-SetupArchitecture {
    # PROCESSOR_ARCHITEW6432 identifies the host when running an emulated shell.
    $native = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($native) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { throw "Unsupported Windows architecture: $native" } }
}
function Get-PiAsset([string]$Arch) { return "pi-windows-$Arch.zip" }
function Get-OmpAsset([string]$Arch) { return "omp-windows-$Arch.exe" }
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
function Find-Bash {
    $candidates = @((Join-Path $DataDir 'git\bin\bash.exe'))
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { $candidates += (Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe') }
    return $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
function Install-Bash([string]$Arch, [string]$Scratch) {
    $bashPath = Find-Bash
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
    # The WSL stub in System32 precedes user PATH entries, so the path is
    # also written to each client's shellPath setting by the configure step.
    Add-UserPath (Split-Path $bashPath)
    return $bashPath
}
function Remove-ManagedFile([string]$Path, [string]$Marker) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    $first = Get-Content -LiteralPath $Path -TotalCount 1
    # A prefix matches the full managed header, including DCG's longer generated line.
    if ($first -clike ($Marker + '*')) { Remove-Item -LiteralPath $Path -Force; Write-Host "Removed $Path" }
    else { Write-Warning "Left custom file in place: $Path" }
}
# Remove files left by the npm-based installer. Session data is never deleted.
function Remove-LegacyInstall([string]$AgentDir) {
    foreach ($name in 'omp.exe','dcg.exe','pi.cmd','pi.exe') {
        $path = Join-Path $BinDir $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "Removed $path" }
    }
    Get-ChildItem -LiteralPath $DataDir -Directory -Filter 'pi-v*' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force; Write-Host "Removed $($_.FullName)"
    }
    foreach ($name in 'node','npm') {
        $path = Join-Path $DataDir $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Host "Removed $path" }
    }
    Remove-ManagedFile (Join-Path $PiDir 'extensions\dcg-pi.ts') '// pi-omp-setup: managed dcg extension'
    Remove-ManagedFile (Join-Path $AgentDir 'extensions\dcg-guard.ts') '// dcg-omp-extension:'
    Remove-ManagedFile (Join-Path $PiDir 'extensions\bang-guard.ts') '// bang-guard: managed extension'
    Remove-ManagedFile (Join-Path $AgentDir 'extensions\bang-guard.ts') '// bang-guard: managed extension'
}
function Install-PiBinary([string]$Arch, [string]$Scratch) {
    $asset = Get-PiAsset $Arch
    $manifest = Join-Path $Scratch 'pi.sha256'
    Get-Download "$PiRelease/SHA256SUMS" $manifest
    $archive = Join-Path $Scratch $asset
    Get-Download "$PiRelease/$asset" $archive
    Assert-Checksum $archive $manifest $asset
    $unpacked = Join-Path $Scratch 'pi-unpacked'
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'pi.exe'))) { throw 'Pi archive missing executable' }
    $target = Join-Path $DataDir 'pi'
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Move-Item -LiteralPath $unpacked -Destination $target
    $shim = '@echo off' + "`r`n" + '"' + (Join-Path $target 'pi.exe') + '" %*' + "`r`n"
    [IO.File]::WriteAllText((Join-Path $BinDir 'pi.cmd'), $shim)
}
function Install-OmpBinary([string]$Arch, [string]$Scratch) {
    $asset = Get-OmpAsset $Arch
    $manifest = Join-Path $Scratch 'omp.sha256'
    Get-Download "$OmpRelease/SHA256SUMS.txt" $manifest
    $archive = Join-Path $Scratch $asset
    Get-Download "$OmpRelease/$asset" $archive
    Assert-Checksum $archive $manifest $asset
    Copy-Item -LiteralPath $archive -Destination (Join-Path $BinDir 'omp.exe') -Force
}
function Install-Updater {
    $url = "https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/$SetupVersion/install.ps1"
    function Quote-Ps([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
    $script = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$url = $(Quote-Ps $url)
`$body = (New-Object Net.WebClient).DownloadString(`$url)
& ([scriptblock]::Create(`$body)) -Update -BinDir $(Quote-Ps $BinDir) -DataDir $(Quote-Ps $DataDir) -PiDir $(Quote-Ps $PiDir) -OmpDir $(Quote-Ps $OmpDir) @args
"@
    $path = Join-Path $BinDir 'pi-omp-update.ps1'
    [IO.File]::WriteAllText($path, $script)
    $cmd = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $path + '" %*' + "`r`n"
    [IO.File]::WriteAllText((Join-Path $BinDir 'pi-omp-update.cmd'), $cmd)
}
function Invoke-ModelProbe([string]$Name, [string]$FilePath, [string]$Arguments) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('pi-omp-probe-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $dir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill() } catch {}
            throw "$Name probe timed out"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0) { throw "$Name probe failed: $stderr" }
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw "$Name returned an empty response: $stderr" }
        Write-Host ("$Name responded: " + $stdout.Trim())
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-ConfiguredProbe {
    $settings = Join-Path $PiDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { throw 'Model settings are missing; cannot probe.' }
    $parsed = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
    $provider = [string]$parsed.defaultProvider
    $model = [string]$parsed.defaultModel
    if (-not $provider -or -not $model) { throw 'Model settings are missing; cannot probe.' }
    $pi = Join-Path $DataDir 'pi\pi.exe'
    $omp = Join-Path $BinDir 'omp.exe'
    if (-not (Test-Path -LiteralPath $pi) -or -not (Test-Path -LiteralPath $omp)) { throw 'pi and omp must be installed before the probe.' }
    $prompt = 'Reply with the single word OK.'
    Invoke-ModelProbe 'pi' $pi "--no-extensions --no-skills --no-tools --no-session --no-approve --provider $provider --model $model -p `"$prompt`""
    Invoke-ModelProbe 'omp' $omp "--no-extensions --no-skills --no-tools --no-session --model $provider/$model -p `"$prompt`""
}
function Invoke-Setup {
    if ($ConfigureOnly -and $Update) { throw 'Use either -ConfigureOnly or -Update.' }
    $arch = Get-SetupArchitecture
    $helperAsset = "pi-omp-setup-windows-$arch.exe"
    if ($Plan) { Write-Output (Get-PiAsset $arch),(Get-OmpAsset $arch),$helperAsset; return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('pi-omp-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch,$BinDir,$DataDir -Force | Out-Null
    try {
        if (-not $ConfigureOnly) {
            if (-not $Update) { Remove-LegacyInstall $OmpDir }
            $null = Install-Bash $arch $scratch
            Install-PiBinary $arch $scratch
            Install-OmpBinary $arch $scratch
            Install-Updater
            foreach ($name in 'node','npm') {
                $runtime = Join-Path $DataDir $name
                if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force; Write-Host "Removed $runtime" }
            }
        }
        if (-not $Update) {
            $base = "https://github.com/hotschmoe/pi-omp-setup/releases/download/$SetupVersion"
            Get-Download "$base/$helperAsset" (Join-Path $scratch $helperAsset)
            Get-Download "$base/config.enc.json" (Join-Path $scratch 'config.enc.json')
            Get-Download "$base/SHA256SUMS" (Join-Path $scratch 'setup.sha256')
            Assert-Checksum (Join-Path $scratch $helperAsset) (Join-Path $scratch 'setup.sha256') $helperAsset
            Assert-Checksum (Join-Path $scratch 'config.enc.json') (Join-Path $scratch 'setup.sha256') 'config.enc.json'
            $helper = Join-Path $BinDir 'pi-omp-setup.exe'
            Copy-Item -LiteralPath (Join-Path $scratch $helperAsset) -Destination $helper -Force
            $configureArgs = @('configure', '--bundle', (Join-Path $scratch 'config.enc.json'), '--pi-dir', $PiDir, '--omp-dir', $OmpDir)
            $bash = Find-Bash
            if ($bash) { $configureArgs += @('--shell-path', $bash) }
            & $helper @configureArgs
            Assert-Exit 'Private configuration'
            Add-UserPath $BinDir
        }
        $probeError = $null
        if (-not $SkipProbe) { try { Invoke-ConfiguredProbe } catch { $probeError = $_.Exception.Message } }
        if ($Update) { Write-Host 'Updated. pi and omp are the latest published release binaries.' }
        else { Write-Host 'Installed. Open a new terminal and run pi or omp. Update both later with: pi-omp-update' }
        if ($probeError) { Write-Warning "Installed, but the model probe failed. Rerun with -ConfigureOnly after fixing:`r`n$probeError" }
    } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
if (-not $LoadFunctionsOnly) { Invoke-Setup }
