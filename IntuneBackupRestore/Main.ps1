#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Backup & Restore Tool - Entry Point
.DESCRIPTION
    Starts the WPF-based GUI for backing up and restoring Microsoft Intune
    configurations. Requires PowerShell 7 (recommended) or Windows PowerShell 5.1.
    WPF requires Single-Threaded Apartment (STA) mode.

    Usage:
        pwsh  -STA -NoProfile -File Main.ps1
        powershell -STA -NoProfile -File Main.ps1

    If launched without -STA the script restarts itself automatically.
#>

[CmdletBinding()]
param(
    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.0.0'
$script:AppName    = 'Intune Backup & Restore Tool'
$script:ScriptRoot = $PSScriptRoot

#region ── PowerShell Version Check ──────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error "PowerShell 5.1 or later is required. Detected: $($PSVersionTable.PSVersion)"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7 is recommended. Running on Windows PowerShell $($PSVersionTable.PSVersion)."
}
#endregion

#region ── STA Apartment State Enforcement ───────────────────────────────────
# WPF requires STA. PowerShell 7 defaults to MTA.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $exe  = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
    $file = $MyInvocation.MyCommand.Path

    if ([string]::IsNullOrEmpty($file)) {
        Write-Error "Cannot determine script path for STA restart. Please run with: $exe -STA -File Main.ps1"
        exit 1
    }

    Write-Host "Restarting in STA mode (required for WPF)..." -ForegroundColor Yellow
    $argList = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`"")
    if ($DebugMode) { $argList += '-DebugMode' }

    Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait
    exit 0
}
#endregion

#region ── WPF Assembly Loading ──────────────────────────────────────────────
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase            -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms   -ErrorAction Stop
}
catch {
    Write-Error "Failed to load WPF assemblies. Ensure you are running on Windows with .NET: $($_.Exception.Message)"
    exit 1
}
#endregion

#region ── Path Validation ───────────────────────────────────────────────────
$modulesPath = Join-Path -Path $script:ScriptRoot -ChildPath 'Modules'
$xamlPath    = Join-Path -Path $script:ScriptRoot -ChildPath 'Xaml'
$configPath  = Join-Path -Path $script:ScriptRoot -ChildPath 'Config'

foreach ($dir in @($modulesPath, $xamlPath, $configPath)) {
    if (-not (Test-Path -Path $dir)) {
        [System.Windows.MessageBox]::Show(
            "Required directory not found: $dir`n`nEnsure all tool files are present in the correct structure.",
            $script:AppName, 'OK', 'Error') | Out-Null
        exit 1
    }
}
#endregion

#region ── Module Import ─────────────────────────────────────────────────────
# Order matters: dependencies first
$moduleOrder = @(
    'Logging',
    'Helpers',
    'Prerequisites',
    'GraphConnection',
    'IntuneCompliance',
    'IntuneConfigProfiles',
    'IntuneSettingsCatalog',
    'IntuneEndpointSecurity',
    'IntuneScripts',
    'BackupEngine',
    'RestoreEngine',
    'UI'
)

foreach ($modName in $moduleOrder) {
    $modPath = Join-Path -Path $modulesPath -ChildPath "$modName.psm1"
    if (-not (Test-Path -Path $modPath)) {
        [System.Windows.MessageBox]::Show(
            "Required module not found: $modPath",
            $script:AppName, 'OK', 'Error') | Out-Null
        exit 1
    }
    try {
        Import-Module -Name $modPath -Force -Global -ErrorAction Stop
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Failed to load module '$modName':`n$($_.Exception.Message)",
            $script:AppName, 'OK', 'Error') | Out-Null
        exit 1
    }
}
#endregion

#region ── Application Configuration ────────────────────────────────────────
$appConfigFile = Join-Path -Path $configPath -ChildPath 'AppConfig.json'
if (Test-Path -Path $appConfigFile) {
    try {
        $script:AppConfig = Get-Content -Path $appConfigFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to parse AppConfig.json, using defaults: $($_.Exception.Message)"
        $script:AppConfig = Get-DefaultAppConfig
    }
}
else {
    $script:AppConfig = Get-DefaultAppConfig
}
#endregion

#region ── Logging Initialization ───────────────────────────────────────────
$logDir = if ($script:AppConfig.LogDirectory -and $script:AppConfig.LogDirectory -ne '') {
    $script:AppConfig.LogDirectory
}
else {
    Join-Path -Path $script:ScriptRoot -ChildPath 'Logs'
}

if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

$logFileName        = "IntuneBackupRestore_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
$script:LogFilePath = Join-Path -Path $logDir -ChildPath $logFileName

$initialLogLevel = if ($DebugMode) { 'DEBUG' }
                   elseif ($script:AppConfig.LogLevel) { $script:AppConfig.LogLevel }
                   else { 'INFO' }

Initialize-Logging -LogFile $script:LogFilePath -LogLevel $initialLogLevel
#endregion

#region ── Global State (synchronized for cross-thread access) ───────────────
$script:GlobalState = [System.Collections.Hashtable]::Synchronized(@{
    # Connection
    IsConnected        = $false
    TenantDisplayName  = ''
    TenantId           = ''
    ConnectedUser      = ''
    ConnectionTime     = $null

    # Backup
    BackupRootPath      = if ($script:AppConfig.DefaultBackupPath -and $script:AppConfig.DefaultBackupPath -ne '') {
                              $script:AppConfig.DefaultBackupPath
                          }
                          else {
                              Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'IntuneBackups'
                          }
    CurrentBackupDir    = ''

    # Operation state
    IsBackupRunning     = $false
    IsRestoreRunning    = $false
    BackupProgress      = 0
    BackupProgressText  = ''
    RestoreProgress     = 0
    RestoreProgressText = ''

    # Logging queue: background runspaces enqueue, UI timer dequeues
    LogQueue            = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()

    # Status
    StatusMessage       = 'Ready'
    LastError           = ''

    # Settings
    IncludeAssignments  = [bool]$(if ($null -ne $script:AppConfig.IncludeAssignments) { $script:AppConfig.IncludeAssignments } else { $true })
    ComputeChecksums    = [bool]$(if ($null -ne $script:AppConfig.ComputeChecksums)   { $script:AppConfig.ComputeChecksums   } else { $true })
    MaxRetries          = [int]$(if  ($null -ne $script:AppConfig.MaxRetries)          { $script:AppConfig.MaxRetries          } else { 3    })
    LogLevel            = $initialLogLevel

    # Restore operation data
    LoadedBackupManifest = $null
    LoadedBackupItems    = $null

    # Internal references
    ScriptRoot          = $script:ScriptRoot
    LogFilePath         = $script:LogFilePath
    AppVersion          = $script:AppVersion
})
#endregion

#region ── Launch GUI ────────────────────────────────────────────────────────
try {
    Write-LogMessage -Level INFO -Message "$($script:AppName) v$($script:AppVersion) starting"
    Write-LogMessage -Level INFO -Message "PowerShell : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-LogMessage -Level INFO -Message "Apartment  : $([System.Threading.Thread]::CurrentThread.ApartmentState)"
    Write-LogMessage -Level INFO -Message "Script root: $script:ScriptRoot"
    Write-LogMessage -Level INFO -Message "Log file   : $script:LogFilePath"

    $xamlFile = Join-Path -Path $xamlPath -ChildPath 'MainWindow.xaml'
    if (-not (Test-Path -Path $xamlFile)) {
        throw "MainWindow.xaml not found at: $xamlFile"
    }

    Start-MainWindow `
        -XamlPath    $xamlFile `
        -GlobalState $script:GlobalState `
        -AppVersion  $script:AppVersion `
        -AppName     $script:AppName `
        -AppConfig   $script:AppConfig `
        -LogFilePath $script:LogFilePath
}
catch {
    $errMsg = "Fatal error launching tool:`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
    Write-Error $errMsg
    try {
        if ($script:LogFilePath) {
            Add-Content -Path $script:LogFilePath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [FATAL] $errMsg" -Encoding UTF8
        }
    }
    catch { }
    [System.Windows.MessageBox]::Show($errMsg, $script:AppName, 'OK', 'Error') | Out-Null
    exit 1
}
#endregion
