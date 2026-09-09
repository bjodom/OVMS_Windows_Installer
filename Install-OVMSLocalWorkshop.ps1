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
$installerUrl = "https://hermes-agent.nousresearch.com/install.ps1"
$installerPath = Join-Path $env:TEMP "hermes-install.ps1"
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
    # Skips the api.github.com release lookup entirely: that endpoint shares GitHub's
    # unauthenticated 60-req/hour/IP limit and contributes to the 429s workshop users hit
    # on repeated runs, for a value we already have pinned and verified in this script.
    param([string]$AssetName)
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

function Get-Sha256Hash {
    # Avoids depending on the Get-FileHash cmdlet, which can be missing if
    # Microsoft.PowerShell.Utility fails to autoload in a locked-down environment.
    param([string]$LiteralPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fileStream = [IO.File]::OpenRead($LiteralPath)
        try {
            $hashBytes = $sha256.ComputeHash($fileStream)
        }
        finally { $fileStream.Dispose() }
    }
    finally { $sha256.Dispose() }
    return [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()
}

function Get-HttpRetryAfterSeconds {
    # Works for both Windows PowerShell's WebException and PowerShell 7's HttpResponseException.
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if (-not $response) { return $null }
    try {
        $retryAfterValues = $null
        if ($response.Headers -is [System.Net.Http.Headers.HttpResponseHeaders]) {
            if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) {
                return [int]$response.Headers.RetryAfter.Delta.Value.TotalSeconds
            }
        }
        else {
            $retryAfterValues = $response.Headers["Retry-After"]
        }
        if ($retryAfterValues) {
            $parsedSeconds = 0
            if ([int]::TryParse(@($retryAfterValues)[0], [ref]$parsedSeconds)) { return $parsedSeconds }
        }
    }
    catch { }
    return $null
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) { return [int]$response.StatusCode }
    return $null
}

function Invoke-DownloadWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$MaxAttempts = 6)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            return
        }
        catch {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            if ($attempt -eq $MaxAttempts) { throw }
            $statusCode = Get-HttpStatusCode $_
            $retryAfterSeconds = Get-HttpRetryAfterSeconds $_
            if ($statusCode -eq 429) {
                # GitHub rate limits can require a longer cooldown than a simple backoff.
                $retryDelay = if ($retryAfterSeconds) { $retryAfterSeconds } else { 30 * $attempt }
                Write-Warning "Download attempt $attempt of $MaxAttempts was rate limited (HTTP 429). Retrying in $retryDelay seconds."
            }
            else {
                $retryDelay = 5 * $attempt
                Write-Warning "Download attempt $attempt of $MaxAttempts failed ($($_.Exception.Message)). Retrying in $retryDelay seconds."
            }
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
        $actualDigest = Get-Sha256Hash -LiteralPath $ovmsZipPath
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

        # Single, non-interactive install -- equivalent to the official
        # `iex (irm https://hermes-agent.nousresearch.com/install.ps1)` one-liner.
        Invoke-HermesInstaller "Installing Hermes Agent" @("-SkipSetup", "-NonInteractive")
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
