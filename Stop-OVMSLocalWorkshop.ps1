#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workshopRoot = $PSScriptRoot
$expectedExe = Join-Path $workshopRoot "ovms\ovms.exe"
$pidFile = Join-Path $workshopRoot ".state\ovms-server.pid"
$serverInfoFile = Join-Path $workshopRoot ".state\ovms-server.json"

function Test-ExpectedServerProcess {
    param($ProcessInfo)
    if ($null -eq $ProcessInfo) { return $false }
    try {
        if ($ProcessInfo.Path) {
            return [string]::Equals(
                [IO.Path]::GetFullPath($ProcessInfo.Path),
                [IO.Path]::GetFullPath($expectedExe),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    }
    catch {
        return $false
    }
    return $false
}

$serverProcess = $null
$serverPid = 0
if (Test-Path -LiteralPath $pidFile) {
    $pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ([int]::TryParse($pidText, [ref]$serverPid)) {
        $candidate = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
        if (Test-ExpectedServerProcess $candidate) {
            $serverProcess = $candidate
        }
    }
}

if ($null -eq $serverProcess) {
    $listenerPids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($listenerPid in $listenerPids) {
        $candidate = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
        if (Test-ExpectedServerProcess $candidate) {
            $serverProcess = $candidate
            $serverPid = [int]$listenerPid
            break
        }
    }
}

if ($null -eq $serverProcess) {
    if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
    if (Test-Path -LiteralPath $serverInfoFile) { Remove-Item -LiteralPath $serverInfoFile -Force }
    Write-Host "No running ovms.exe belonging to this workshop package was found."
    return
}

Stop-Process -Id $serverPid -Force
try {
    Wait-Process -Id $serverPid -Timeout 10 -ErrorAction Stop
}
catch {
    if (Get-Process -Id $serverPid -ErrorAction SilentlyContinue) {
        throw "OVMS process $serverPid did not exit after 10 seconds."
    }
}
Start-Sleep -Seconds 1
if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
if (Test-Path -LiteralPath $serverInfoFile) { Remove-Item -LiteralPath $serverInfoFile -Force }
Write-Host "[OK] Workshop ovms.exe process $serverPid stopped." -ForegroundColor Green
