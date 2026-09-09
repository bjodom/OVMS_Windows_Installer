#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Model,

    # Generous default: these models are 5-20+ GB, and workshop networks vary widely
    [ValidateRange(30, 10800)]
    [int]$WaitSeconds = 2700,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8000,

    [ValidateSet("Auto", "GPU", "CPU")]
    [string]$TargetDevice = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workshopRoot = $PSScriptRoot
$ovmsExe = Join-Path $workshopRoot "ovms\ovms.exe"
$modelRepositoryPath = Join-Path $workshopRoot "models"
$cacheDirectory = Join-Path $workshopRoot ".ovcache"
$stateDirectory = Join-Path $workshopRoot ".state"
$modelStatePath = Join-Path $stateDirectory "selected-model.json"
$modelConfigPath = Join-Path $workshopRoot "model-config.json"
$logDirectory = Join-Path $workshopRoot "logs"
$pidFile = Join-Path $stateDirectory "ovms-server.pid"
$serverInfoFile = Join-Path $stateDirectory "ovms-server.json"
$modelsUrl = "http://127.0.0.1:$Port/v1/models"

if (-not (Test-Path -LiteralPath $modelConfigPath)) {
    throw "Model configuration is missing: $modelConfigPath"
}
$modelConfigs = Get-Content -LiteralPath $modelConfigPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Model) -and (Test-Path -LiteralPath $modelStatePath)) {
    try { $Model = (Get-Content -LiteralPath $modelStatePath -Raw | ConvertFrom-Json).model }
    catch { Write-Warning "Saved model state could not be read; using the default model." }
}
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = "qwen3.5-27b" }
if (@($modelConfigs.PSObject.Properties.Name) -notcontains $Model) {
    throw "Unsupported model '$Model'. Choose one of: $($modelConfigs.PSObject.Properties.Name -join ', ')"
}
$selectedModel = $modelConfigs.$Model
# The API exposes the model under its short name (e.g. Qwen3.5-27B-int4-ov), without the publisher prefix
$modelAlias = ($selectedModel.SourceModel -split "/")[-1]

function Test-WorkshopEndpoint {
    try {
        $models = Invoke-RestMethod -Uri $modelsUrl -Method Get -TimeoutSec 10
        $ids = @($models.data | ForEach-Object { [string]$_.id })
        return ($ids -contains $modelAlias)
    }
    catch {
        return $false
    }
}

# Start-Process joins ArgumentList with spaces, so every element carries its own quoting:
# the install path lives under %USERPROFILE% and can contain spaces.
function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Save-SelectedModelState {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    @{ model = $Model; source_model = $selectedModel.SourceModel; saved_at = (Get-Date).ToString("o") } |
        ConvertTo-Json | Set-Content -LiteralPath $modelStatePath -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $ovmsExe)) {
    throw "ovms.exe is missing: $ovmsExe. Run Install-OVMSLocalWorkshop.ps1 first."
}

$gpuControllers = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "Intel" })
if ($TargetDevice -eq "Auto") {
    $TargetDevice = if ($gpuControllers.Count -gt 0) { "GPU" } else { "CPU" }
    if ($TargetDevice -eq "CPU") { Write-Warning "No Intel GPU was detected; starting OVMS on CPU." }
}

# A previous run that timed out (e.g. a slow model download) can leave ovms.exe
# running hidden in the background even after this script has exited. Starting a
# second instance against the same model files then crashes almost immediately.
# Clean up any such leftover before proceeding, unless it's actually serving already.
if (-not (Test-WorkshopEndpoint)) {
    $staleProcesses = @(Get-Process -Name "ovms" -ErrorAction SilentlyContinue | Where-Object {
        try { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($ovmsExe) } catch { $false }
    })
    foreach ($staleProcess in $staleProcesses) {
        Write-Warning "Stopping a leftover ovms.exe process (PID $($staleProcess.Id)) from a previous run that never finished starting."
        Stop-Process -Id $staleProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($staleProcesses.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
}

# ovms\setupvars.ps1 points PATH/PYTHONHOME/PYTHONPATH at OVMS's own bundled Python,
# which is incompatible with Hermes's separate Python venv. Snapshot the environment
# so it can be restored after ovms.exe is launched, instead of leaking into the rest
# of this PowerShell session (e.g. the Hermes calls the installer makes afterward).
$envSnapshotBeforeSetupVars = @{}
foreach ($entry in [Environment]::GetEnvironmentVariables("Process").GetEnumerator()) {
    $envSnapshotBeforeSetupVars[$entry.Key] = $entry.Value
}

try {
    $setupVars = Join-Path $workshopRoot "ovms\setupvars.ps1"
    if (Test-Path -LiteralPath $setupVars) {
        Write-Host "Running $setupVars ..." -ForegroundColor DarkGray
        & $setupVars 2>&1 | Out-Null
    }
    else {
        Write-Warning "setupvars.ps1 not found at $setupVars -- ovms.exe may fail to load its runtime."
    }

    if (Test-WorkshopEndpoint) {
        Save-SelectedModelState
        $readyListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($readyListener) {
            [IO.File]::WriteAllText($pidFile, [string]$readyListener.OwningProcess)
        }
        Write-Host "[OK] $Model is already available at http://127.0.0.1:$Port/v1" -ForegroundColor Green
        return
    }

    $existingListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($existingListener) {
        $ownerIds = @($existingListener | Select-Object -ExpandProperty OwningProcess -Unique)
        throw "Port $Port is already in use by process ID(s): $($ownerIds -join ', '). Close that application and run this script again."
    }

    New-Item -ItemType Directory -Path $modelRepositoryPath -Force | Out-Null
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

    # Hugging Face's newer "Xet" HTTP/2 CDN is more prone to mid-download stream resets
    # on corporate/flaky networks than the classic download path. Workshop laptops hit
    # this often enough that it's worth disabling by default rather than per-failure.
    $env:HF_HUB_DISABLE_XET = "1"

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stdoutLog = Join-Path $logDirectory "ovms-server-$timestamp.out.log"
    $stderrLog = Join-Path $logDirectory "ovms-server-$timestamp.err.log"

    $serverArguments = @(
        "--source_model", $selectedModel.SourceModel,
        "--model_repository_path", $modelRepositoryPath,
        "--rest_port", [string]$Port,
        "--target_device", $TargetDevice,
        "--task", "text_generation",
        "--cache_dir", $cacheDirectory,
        "--model_name", $modelAlias,
        "--tool_parser", $selectedModel.ToolParser,
        "--reasoning_parser", $selectedModel.ReasoningParser,
        "--log_level", "INFO"
    )
    $serverArguments += $selectedModel.ExtraArgs
    $serverArguments = @($serverArguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })

    Write-Host "Starting $Model on OVMS (first run also downloads the model from Hugging Face)..." -ForegroundColor Cyan
    Save-SelectedModelState
    $serverProcess = Start-Process `
        -FilePath $ovmsExe `
        -ArgumentList $serverArguments `
        -WorkingDirectory $workshopRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    # ovms.exe has now inherited the OVMS-flavored environment at process creation
    # time; restore this session's own environment immediately so nothing downstream
    # (Hermes commands, etc.) sees OVMS's PYTHONHOME/PYTHONPATH/PATH.
    foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
        if (-not $envSnapshotBeforeSetupVars.ContainsKey($key)) {
            [Environment]::SetEnvironmentVariable($key, $null, "Process")
        }
    }
    foreach ($key in $envSnapshotBeforeSetupVars.Keys) {
        [Environment]::SetEnvironmentVariable($key, $envSnapshotBeforeSetupVars[$key], "Process")
    }

    [IO.File]::WriteAllText($pidFile, [string]$serverProcess.Id)
    @{
        process_id = $serverProcess.Id
        executable = $ovmsExe
        model = $Model
        source_model = $selectedModel.SourceModel
        alias = $modelAlias
        started_at = (Get-Date).ToString("o")
        stdout_log = $stdoutLog
        stderr_log = $stderrLog
    } | ConvertTo-Json | Set-Content -LiteralPath $serverInfoFile -Encoding UTF8

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $stdoutLinesShown = 0
    $stderrLinesShown = 0

    function Show-NewLogLines {
        param([string]$LogPath, [ref]$LinesShown)
        if (-not (Test-Path -LiteralPath $LogPath)) { return }
        $allLines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
        if ($allLines.Count -gt $LinesShown.Value) {
            $allLines[$LinesShown.Value..($allLines.Count - 1)] | ForEach-Object { Write-Host $_ }
            $LinesShown.Value = $allLines.Count
        }
    }

    do {
        Show-NewLogLines -LogPath $stdoutLog -LinesShown ([ref]$stdoutLinesShown)
        Show-NewLogLines -LogPath $stderrLog -LinesShown ([ref]$stderrLinesShown)

        if ($serverProcess.HasExited) {
            $stdoutText = if (Test-Path -LiteralPath $stdoutLog) { (Get-Content -LiteralPath $stdoutLog -Tail 30 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { $null }
            $stderrText = if (Test-Path -LiteralPath $stderrLog) { (Get-Content -LiteralPath $stderrLog -Tail 30 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { $null }
            $stdoutSummary = if ([string]::IsNullOrWhiteSpace($stdoutText)) { "(stdout log is empty)" } else { $stdoutText }
            $stderrSummary = if ([string]::IsNullOrWhiteSpace($stderrText)) { "(stderr log is empty)" } else { $stderrText }
            $crashHint = if ([string]::IsNullOrWhiteSpace($stdoutText) -and [string]::IsNullOrWhiteSpace($stderrText)) {
                "`nBoth logs are empty, which usually means ovms.exe crashed before writing any output (e.g. a missing DLL or native fault). Check Windows Event Viewer > Windows Logs > Application for an 'Application Error' entry referencing ovms.exe around this time."
            } else { "" }
            throw "ovms.exe exited before becoming ready (exit code: $($serverProcess.ExitCode)).`nSTDOUT: $stdoutSummary`nSTDERR: $stderrSummary$crashHint"
        }

        if (Test-WorkshopEndpoint) {
            Write-Host "[OK] Local $Model endpoint is ready: http://127.0.0.1:$Port/v1" -ForegroundColor Green
            Write-Host "[OK] ovms.exe process ID: $($serverProcess.Id)" -ForegroundColor Green
            return
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    # Don't leave this process running hidden in the background for the next run to collide with.
    if (-not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    throw "Timed out waiting for $Model to become ready (model download can take a while on first run). Review: $stderrLog"
}
finally {
    # Belt-and-suspenders: guarantee the caller's environment is restored even if an
    # unexpected error occurred before the explicit restore above ran.
    foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
        if (-not $envSnapshotBeforeSetupVars.ContainsKey($key)) {
            [Environment]::SetEnvironmentVariable($key, $null, "Process")
        }
    }
    foreach ($key in $envSnapshotBeforeSetupVars.Keys) {
        [Environment]::SetEnvironmentVariable($key, $envSnapshotBeforeSetupVars[$key], "Process")
    }
}

