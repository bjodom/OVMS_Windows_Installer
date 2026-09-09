#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Model,

    # Generous default: these models are 5-20+ GB, and workshop networks vary widely
    [ValidateRange(30, 10800)]
    [int]$WaitSeconds = 2700,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8000,

    [switch]$SkipHermesInstall,
    [switch]$DoNotStartServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$packageName = "hermes-ovms-workshop-windows-x64-intel-v1.0.0"
$installRoot = Join-Path $env:USERPROFILE "OVMS-Local-Workshop\$packageName"
$logDirectory = Join-Path $installRoot "logs"
$ovmsDir = Join-Path $installRoot "ovms"
$ovmsExe = Join-Path $ovmsDir "ovms.exe"
$stateDirectory = Join-Path $installRoot ".state"
$modelStatePath = Join-Path $stateDirectory "selected-model.json"
$modelConfigPath = Join-Path $PSScriptRoot "model-config.json"
$ovmsVersion = "2026.3.1"
$ovmsUrl = "https://github.com/openvinotoolkit/model_server/releases/download/v$ovmsVersion/ovms_windows_${ovmsVersion}_python_on.zip"
# Fallback for the pinned asset so the archive is still verified when the GitHub API is unreachable.
$ovmsExpectedSha256 = "fb904b4f1671beaa54d423153f8760b711754bcb645d69b81a5c16cc8fe0570a"
$ovmsZipPath = Join-Path $env:TEMP "ovms-$ovmsVersion.zip"
$hermesCommit = "30b83ab7b1f194503de9f5545d88c81c4db91e3f"
$installerUrl = "https://raw.githubusercontent.com/NousResearch/hermes-agent/$hermesCommit/scripts/install.ps1"
$installerPath = Join-Path $env:TEMP "hermes-install-$hermesCommit.ps1"
$transcriptStarted = $false

if (-not (Test-Path -LiteralPath $modelConfigPath)) {
    throw "Model configuration is missing: $modelConfigPath"
}
$modelConfigs = Get-Content -LiteralPath $modelConfigPath -Raw | ConvertFrom-Json
$savedModel = $null
if ([string]::IsNullOrWhiteSpace($Model) -and (Test-Path -LiteralPath $modelStatePath)) {
    try { $savedModel = (Get-Content -LiteralPath $modelStatePath -Raw | ConvertFrom-Json).model }
    catch { Write-Warning "Saved model state could not be read; using the default model." }
}
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = if ($savedModel) { $savedModel } else { "qwen3.5-27b" } }
if (@($modelConfigs.PSObject.Properties.Name) -notcontains $Model) {
    throw "Unsupported model '$Model'. Choose one of: $($modelConfigs.PSObject.Properties.Name -join ', ')"
}
$selectedModel = $modelConfigs.$Model
# The API exposes the model under its short name (e.g. Qwen3.5-27B-int4-ov), without the publisher prefix
$modelAlias = ($selectedModel.SourceModel -split "/")[-1]

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host "[$Number/6] $Message" -ForegroundColor Cyan
}

function Get-OVMSAssetDigest {
    param([string]$AssetName)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/openvinotoolkit/model_server/releases/tags/v$ovmsVersion" -Headers @{ "User-Agent" = "OVMS-Local-Workshop" } -TimeoutSec 30
        $asset = @($release.assets) | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
        if ($asset -and $asset.digest -match "^sha256:") { return $asset.digest.Substring(7) }
        Write-Warning "The OVMS release listing contained no digest for $AssetName; using the digest pinned in this script."
    }
    catch { Write-Warning "Could not retrieve the OVMS release digest from GitHub; using the digest pinned in this script." }
    return $ovmsExpectedSha256
}

function Test-FreeDiskSpace {
    $pathRoot = [IO.Path]::GetPathRoot($installRoot)
    if ($pathRoot -notmatch '^[A-Za-z]:\\$') {
        Write-Warning "Free space cannot be checked for a non-local install root ($pathRoot); make sure at least 40 GB is available."
        return
    }
    $driveName = $pathRoot.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $requiredBytes = 40GB
    if ($drive.Free -lt $requiredBytes) {
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        throw "At least 40 GB of free space is required on drive $driveName`: (currently $freeGb GB available)."
    }
    Write-Host "  - Free disk space: $([math]::Round($drive.Free / 1GB, 1)) GB"
}

function Invoke-DownloadWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$MaxAttempts = 3)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $MaxAttempts) { throw }
            $retryDelay = 5 * $attempt
            Write-Warning "Download attempt $attempt of $MaxAttempts failed ($($_.Exception.Message)). Retrying in $retryDelay seconds."
            Start-Sleep -Seconds $retryDelay
        }
    }
}

function Invoke-NativeCommandCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $capturedItems = @(& $FilePath @ArgumentList 2>&1)
        $nativeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $capturedText = @($capturedItems | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return [pscustomobject]@{ ExitCode = $nativeExitCode; Text = $capturedText }
}

function Invoke-HermesInstaller {
    param([string]$Label, [string[]]$InstallerArguments)
    $childPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    Write-Host "  - $Label"
    & $childPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installerPath @InstallerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

function Find-HermesLauncher {
    $hermesBin = Join-Path $env:LOCALAPPDATA "hermes\bin"
    $launcher = Get-ChildItem -LiteralPath $hermesBin -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("hermes.exe", "hermes.cmd") } |
        Select-Object -First 1
    if ($null -eq $launcher) {
        throw "Hermes launcher was not found under $hermesBin."
    }
    return $launcher.FullName
}

# HKCU\Environment is read and written unexpanded: [Environment]::SetEnvironmentVariable
# rewrites PATH as REG_SZ, permanently baking out any %VAR% references it contains.
function Add-UserPathEntry {
    param([string]$Directory)
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    if ($null -eq $environmentKey) {
        throw "The user environment registry key (HKCU\Environment) could not be opened."
    }
    try {
        $existingValue = [string]$environmentKey.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $existingEntries = @($existingValue -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($existingEntries -contains $Directory) { return }
        $valueKind = if (@($environmentKey.GetValueNames()) -contains "Path") {
            $environmentKey.GetValueKind("Path")
        }
        else {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        $environmentKey.SetValue("Path", ((@($Directory) + $existingEntries) -join ";"), $valueKind)
    }
    finally {
        $environmentKey.Dispose()
    }
}

function Get-HermesGitExecutable {
    $gitCandidates = @()
    $pathGit = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($pathGit) { $gitCandidates += $pathGit.Source }
    $gitCandidates += @(
        (Join-Path $env:LOCALAPPDATA "hermes\git\cmd\git.exe"),
        (Join-Path $env:LOCALAPPDATA "hermes\git\bin\git.exe")
    )
    foreach ($gitCandidate in $gitCandidates | Select-Object -Unique) {
        if ($gitCandidate -and (Test-Path -LiteralPath $gitCandidate)) {
            return $gitCandidate
        }
    }
    throw "Git was installed by the Hermes Git stage, but git.exe could not be located."
}

function Move-HermesManagedRepositoryAside {
    param([string]$Reason)
    $hermesRoot = Join-Path $env:LOCALAPPDATA "hermes"
    $repositoryPath = Join-Path $hermesRoot "hermes-agent"
    if (-not (Test-Path -LiteralPath $repositoryPath)) { return $null }

    $resolvedHermesRoot = [IO.Path]::GetFullPath($hermesRoot).TrimEnd("\") + "\"
    $resolvedRepository = [IO.Path]::GetFullPath($repositoryPath)
    if (-not $resolvedRepository.StartsWith($resolvedHermesRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to move a repository outside the managed Hermes directory: $resolvedRepository"
    }

    $backupRoot = Join-Path $hermesRoot "backups"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupPath = Join-Path $backupRoot ("hermes-agent-before-easy-workshop-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8)))
    Move-Item -LiteralPath $repositoryPath -Destination $backupPath
    Write-Warning "$Reason The existing managed repository was preserved at: $backupPath"
    return $backupPath
}

# The Hermes repository ships with CRLF/LF mixed line endings on some files (uv.lock,
# website docs). If core.autocrlf converts them on checkout, git sees "local changes"
# right after cloning and refuses to check out the pinned commit. Force autocrlf=false
# for this repo and repair any resulting uv.lock-only churn before pinning.
function Repair-HermesRepositoryForPin {
    param([string]$GitExecutable)
    $hermesRoot = Join-Path $env:LOCALAPPDATA "hermes"
    $repositoryPath = Join-Path $hermesRoot "hermes-agent"
    if (-not (Test-Path -LiteralPath $repositoryPath)) { return }

    if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath ".git"))) {
        Move-HermesManagedRepositoryAside "The existing Hermes source directory is not a Git repository."
        return
    }

    $originResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "remote", "get-url", "origin")
    if ($originResult.ExitCode -ne 0 -or $originResult.Text -notmatch "(?i)github\.com[:/]NousResearch/hermes-agent(?:\.git)?$") {
        Move-HermesManagedRepositoryAside "The existing Hermes repository has an unexpected origin."
        return
    }

    $configResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "config", "core.autocrlf", "false")
    if ($configResult.ExitCode -ne 0) {
        Move-HermesManagedRepositoryAside "The existing Hermes repository could not be configured for LF line endings."
        return
    }

    $statusResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "status", "--porcelain", "--untracked-files=all")
    if ($statusResult.ExitCode -ne 0) {
        Move-HermesManagedRepositoryAside "The existing Hermes repository status could not be read."
        return
    }

    $statusLines = @($statusResult.Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($statusLines.Count -eq 0) { return }

    $dirtyPaths = @(
        foreach ($statusLine in $statusLines) {
            if ($statusLine.Length -ge 4) {
                $statusLine.Substring(3).Trim().Trim('"')
            }
        }
    )
    $onlyLockfileChurn = ($dirtyPaths.Count -gt 0 -and @($dirtyPaths | Where-Object { $_ -ne "uv.lock" }).Count -eq 0)

    if ($onlyLockfileChurn) {
        $lockfilePath = Join-Path $repositoryPath "uv.lock"
        if (Test-Path -LiteralPath $lockfilePath) {
            $backupRoot = Join-Path $hermesRoot "backups"
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            $lockfileBackup = Join-Path $backupRoot ("uv.lock-before-easy-workshop-{0}.bak" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
            Copy-Item -LiteralPath $lockfilePath -Destination $lockfileBackup -Force
        }

        Write-Host "  - Repairing Git line-ending churn in the managed uv.lock file"
        $restoreResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "-c", "core.autocrlf=false", "checkout", "--", "uv.lock")
        if ($restoreResult.ExitCode -eq 0) {
            $verifyResult = Invoke-NativeCommandCapture -FilePath $GitExecutable -ArgumentList @("-C", $repositoryPath, "status", "--porcelain", "--untracked-files=all")
            if ($verifyResult.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($verifyResult.Text)) {
                Write-Host "[OK] Managed Hermes repository is clean for the pinned checkout." -ForegroundColor Green
                return
            }
        }
    }

    Move-HermesManagedRepositoryAside "The managed Hermes repository contains changes that cannot be safely repaired automatically."
}

function Invoke-HermesRepositoryStage {
    param([string]$GitExecutable)
    $previousCountText = [Environment]::GetEnvironmentVariable("GIT_CONFIG_COUNT", "Process")
    $configIndex = 0
    if (-not [string]::IsNullOrWhiteSpace($previousCountText)) {
        $parsedCount = 0
        if ([int]::TryParse($previousCountText, [ref]$parsedCount) -and $parsedCount -ge 0) {
            $configIndex = $parsedCount
        }
    }

    $keyVariable = "GIT_CONFIG_KEY_$configIndex"
    $valueVariable = "GIT_CONFIG_VALUE_$configIndex"
    $previousKey = [Environment]::GetEnvironmentVariable($keyVariable, "Process")
    $previousValue = [Environment]::GetEnvironmentVariable($valueVariable, "Process")

    try {
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_COUNT", [string]($configIndex + 1), "Process")
        [Environment]::SetEnvironmentVariable($keyVariable, "core.autocrlf", "Process")
        [Environment]::SetEnvironmentVariable($valueVariable, "false", "Process")

        Repair-HermesRepositoryForPin -GitExecutable $GitExecutable
        try {
            Invoke-HermesInstaller "Hermes repository stage" @("-Stage", "repository", "-Commit", $hermesCommit)
        }
        catch {
            Write-Warning "The first Hermes repository attempt failed. Preparing a clean managed checkout and retrying once."
            Repair-HermesRepositoryForPin -GitExecutable $GitExecutable
            Invoke-HermesInstaller "Hermes repository stage retry" @("-Stage", "repository", "-Commit", $hermesCommit)
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_COUNT", $previousCountText, "Process")
        [Environment]::SetEnvironmentVariable($keyVariable, $previousKey, "Process")
        [Environment]::SetEnvironmentVariable($valueVariable, $previousValue, "Process")
    }
}

function Invoke-Hermes {
    param([string]$Launcher, [string[]]$HermesArguments)
    $result = Invoke-NativeCommandCapture -FilePath $Launcher -ArgumentList $HermesArguments
    if ($result.ExitCode -ne 0) {
        throw "Hermes command failed: hermes $($HermesArguments -join ' ')`n$($result.Text)"
    }
    return $result.Text
}

try {
    if ($env:OS -ne "Windows_NT") {
        throw "This workshop package supports Windows only."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "A 64-bit Windows operating system is required."
    }

    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $transcriptPath = Join-Path $logDirectory ("easy-install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    # Start/Stop scripts must live in installRoot so their own $PSScriptRoot-relative
    # paths (ovms\ovms.exe, models\, .ovcache\, .state\) resolve to the real install location
    foreach ($scriptName in @("Start-OVMSLocalWorkshop.ps1", "Stop-OVMSLocalWorkshop.ps1", "model-config.json")) {
        $sourceFile = Join-Path $PSScriptRoot $scriptName
        $destinationFile = Join-Path $installRoot $scriptName
        if ([IO.Path]::GetFullPath($sourceFile) -ne [IO.Path]::GetFullPath($destinationFile)) {
            Copy-Item -LiteralPath $sourceFile -Destination $destinationFile -Force
        }
    }

    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host " HERMES + OVMS - EASY WORKSHOP SETUP" -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Blue
    Write-Host "Model: $Model ($($selectedModel.SourceModel))"
    Write-Host "Installation folder: $installRoot"
    Write-Host "Log file: $transcriptPath"

    Write-Step 1 "Verify this computer"
    Test-FreeDiskSpace
    $gpuControllers = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
    $gpuControllers | Format-Table -AutoSize | Out-Host
    $intelControllers = @($gpuControllers | Where-Object { $_.Name -match "Intel" })
    if ($intelControllers.Count -eq 0) {
        Write-Warning "No Intel GPU was detected. OVMS will still run, but on CPU only (slower)."
    }
    # No Vulkan SDK and no manual Git/uv install are required: OVMS ships as a
    # self-contained prebuilt zip, and the official Hermes installer provisions
    # its own portable Git and uv automatically in the next step.

    Write-Step 2 "Download and extract OVMS $ovmsVersion"
    if (Test-Path -LiteralPath $ovmsExe) {
        Write-Host "[OK] OVMS is already installed at $ovmsExe" -ForegroundColor Green
    }
    else {
        Invoke-DownloadWithRetry -Uri $ovmsUrl -OutFile $ovmsZipPath
        $expectedDigest = Get-OVMSAssetDigest ([IO.Path]::GetFileName($ovmsUrl))
        $actualDigest = (Get-FileHash -LiteralPath $ovmsZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualDigest -ne $expectedDigest.ToLowerInvariant()) {
            Remove-Item -LiteralPath $ovmsZipPath -Force -ErrorAction SilentlyContinue
            throw "OVMS download failed SHA-256 verification. Expected $expectedDigest, got $actualDigest."
        }
        Expand-Archive -Path $ovmsZipPath -DestinationPath $installRoot -Force
        Remove-Item -LiteralPath $ovmsZipPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $ovmsExe)) {
            throw "OVMS extraction did not produce $ovmsExe."
        }
        Write-Host "[OK] OVMS $ovmsVersion extracted." -ForegroundColor Green
    }

    Write-Step 3 "Install and verify Hermes Agent"
    if (-not $SkipHermesInstall) {
        Invoke-DownloadWithRetry -Uri $installerUrl -OutFile $installerPath
        if ((Get-Item -LiteralPath $installerPath).Length -lt 10000) {
            throw "The downloaded Hermes installer is unexpectedly small."
        }

        # Staged install (uv -> git -> repository -> python -> finish) so the
        # repository stage can force core.autocrlf=false and repair any uv.lock
        # line-ending churn before pinning to $hermesCommit.
        Invoke-HermesInstaller "Hermes uv stage" @("-Stage", "uv", "-Commit", $hermesCommit)
        Invoke-HermesInstaller "Hermes Git stage" @("-Stage", "git", "-Commit", $hermesCommit)
        $hermesGitExecutable = Get-HermesGitExecutable
        Invoke-HermesRepositoryStage -GitExecutable $hermesGitExecutable
        Invoke-HermesInstaller "Hermes Python stage" @("-Stage", "python", "-Commit", $hermesCommit)
        Invoke-HermesInstaller "Complete Hermes installation" @("-SkipSetup", "-Commit", $hermesCommit)
    }
    else {
        Write-Host "Hermes installation was skipped by request. Existing installation will be validated."
    }

    $hermesBin = Join-Path $env:LOCALAPPDATA "hermes\bin"
    $pathEntries = @($env:Path -split ";")
    if ($pathEntries -notcontains $hermesBin) {
        $env:Path = "$hermesBin;$env:Path"
    }
    Add-UserPathEntry -Directory $hermesBin

    $hermesLauncher = Find-HermesLauncher
    $hermesVersion = (Invoke-Hermes $hermesLauncher @("--version") | Out-String).Trim()
    Write-Host $hermesVersion
    Write-Host "[OK] Hermes Agent is installed." -ForegroundColor Green

    Write-Step 4 "Start $Model on OVMS (model downloads automatically on first run)"
    $startScript = Join-Path $installRoot "Start-OVMSLocalWorkshop.ps1"
    if (-not $DoNotStartServer) {
        & $startScript -Model $Model -WaitSeconds $WaitSeconds -Port $Port
    }
    else {
        # The start script records the selection when it runs; record it here when it doesn't.
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
        @{ model = $Model; source_model = $selectedModel.SourceModel; saved_at = (Get-Date).ToString("o") } |
            ConvertTo-Json | Set-Content -LiteralPath $modelStatePath -Encoding UTF8
        Write-Host "Server start was skipped by request."
    }

    Write-Step 5 "Test the local OpenAI-compatible API"
    if ($DoNotStartServer) {
        Write-Host "API test skipped because -DoNotStartServer was selected."
    }
    else {
        # Informational only: the endpoint readiness check in Step 4 already proved the
        # server works, so a slow/oddly-phrased model reply here should never block setup.
        try {
            $chatBody = @{
                model = $modelAlias
                messages = @(@{ role = "user"; content = "In one short sentence, confirm you are working." })
                temperature = 0
                max_tokens = 400
            } | ConvertTo-Json -Depth 6
            $chatResponse = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$Port/v1/chat/completions" `
                -Method Post `
                -ContentType "application/json" `
                -Body $chatBody `
                -TimeoutSec 180
            $chatContent = [string]$chatResponse.choices[0].message.content
            if ([string]::IsNullOrWhiteSpace($chatContent)) {
                Write-Warning "The API responded, but no answer text came back yet. This is informational only; continuing setup."
            }
            else {
                Write-Host "[OK] Local chat completion returned: $chatContent" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "API test call failed ($($_.Exception.Message)). This is informational only; continuing setup."
        }
    }

    Write-Step 6 "Connect Hermes to the local OVMS endpoint"
    $hermesConfig = Join-Path $env:LOCALAPPDATA "hermes\config.yaml"
    if (Test-Path -LiteralPath $hermesConfig) {
        $configBackup = "$hermesConfig.before-easy-workshop-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $hermesConfig -Destination $configBackup -Force
        Write-Host "Existing Hermes configuration backed up to: $configBackup"
    }

    Invoke-Hermes $hermesLauncher @("config", "set", "model.provider", "custom") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.base_url", "http://127.0.0.1:$Port/v1") | Out-Host
    Invoke-Hermes $hermesLauncher @("config", "set", "model.default", $modelAlias) | Out-Host

    $providerValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.provider") | Out-String).Trim()
    $baseUrlValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.base_url") | Out-String).Trim()
    $modelValue = (Invoke-Hermes $hermesLauncher @("config", "get", "model.default") | Out-String).Trim()
    if ($providerValue -notmatch "custom" -or
        $baseUrlValue -notmatch [regex]::Escape("http://127.0.0.1:$Port/v1") -or
        $modelValue -notmatch [regex]::Escape($modelAlias)) {
        throw "Hermes configuration verification failed.`nProvider: $providerValue`nBase URL: $baseUrlValue`nModel: $modelValue"
    }

    $readyFile = Join-Path $installRoot "WORKSHOP_READY.txt"
    @(
        "WORKSHOP READY"
        "Prepared: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
        "Hermes: $hermesVersion"
        "Model: $Model ($($selectedModel.SourceModel))"
        "Endpoint: http://127.0.0.1:$Port/v1"
    ) | Set-Content -LiteralPath $readyFile -Encoding UTF8

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host " WORKSHOP READY" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host "Local model: $Model ($($selectedModel.SourceModel))"
    Write-Host "Endpoint: http://127.0.0.1:$Port/v1"
    Write-Host ""
    Write-Host "Start Hermes now by entering:" -ForegroundColor Yellow
    Write-Host "  hermes" -ForegroundColor White
}
catch {
    Write-Host ""
    Write-Host "SETUP STOPPED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Correct the reported prerequisite or network issue, then run the same setup again." -ForegroundColor Yellow
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
