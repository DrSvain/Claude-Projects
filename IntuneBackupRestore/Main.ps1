#Requires -Version 7.0
<#
.SYNOPSIS
    Intune Backup & Restore Tool — entry point.
.DESCRIPTION
    Checks prerequisites, loads configuration, initialises logging and
    global state, then launches the WinForms GUI on the current thread.
    Must be run on Windows with PowerShell 7.0 or newer.
.EXAMPLE
    pwsh -File Main.ps1
    pwsh -File Main.ps1 -ConfigFile 'D:\MyConfig\AppConfig.json'
#>
[CmdletBinding()]
param(
    # Override the default Config\AppConfig.json location
    [string]$ConfigFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ════════════════════════════════════════════════════════════════════════
# 1. Platform / version guard
# ════════════════════════════════════════════════════════════════════════
if (-not $IsWindows) {
    Write-Error 'This tool requires Windows. WinForms is not available on Linux/macOS.'
    exit 1
}

if ($PSVersionTable.PSVersion -lt [version]'7.0') {
    Write-Error "PowerShell 7.0 or newer is required. Current version: $($PSVersionTable.PSVersion)"
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
# 2. Paths
# ════════════════════════════════════════════════════════════════════════
$AppRoot = $PSScriptRoot   # folder containing Main.ps1

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $AppRoot 'Config\AppConfig.json'
}

# ════════════════════════════════════════════════════════════════════════
# 3. Load configuration
# ════════════════════════════════════════════════════════════════════════
$Config = @{}
if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Failed to parse config file '$ConfigFile': $_"
        Write-Warning 'Using built-in defaults.'
    }
}

# Apply defaults for any missing keys
$defaults = @{
    BackupRootPath       = [System.IO.Path]::Combine($env:USERPROFILE, 'IntuneBackups')
    WriteChecksums       = $false
    ConfirmRestore       = $true
    ExportAssignments    = $true
    LogLevel             = 'INFO'
    LogToFile            = $true
    MaxRetries           = 3
    BaseDelaySeconds     = 2
    PageSize             = 100
    ConfirmDisconnect    = $true
    ShowDebugInUI        = $false
}
foreach ($key in $defaults.Keys) {
    if (-not $Config.ContainsKey($key)) { $Config[$key] = $defaults[$key] }
}

# ════════════════════════════════════════════════════════════════════════
# 4. Load modules
# ════════════════════════════════════════════════════════════════════════
$moduleOrder = @(
    'Modules\Logging.psm1'
    'Modules\Helpers.psm1'
    'Modules\Prerequisites.psm1'
    'Modules\GraphConnection.psm1'
    'Modules\Workloads\CompliancePolicies.psm1'
    'Modules\Workloads\ConfigProfiles.psm1'
    'Modules\Workloads\SettingsCatalog.psm1'
    'Modules\Workloads\EndpointSecurity.psm1'
    'Modules\Workloads\DeviceScripts.psm1'
    'Modules\BackupEngine.psm1'
    'Modules\RestoreEngine.psm1'
)

foreach ($rel in $moduleOrder) {
    $full = Join-Path $AppRoot $rel
    if (-not (Test-Path $full)) {
        Write-Error "Required module not found: $full"
        exit 1
    }
    Import-Module $full -Force -DisableNameChecking
}

# ════════════════════════════════════════════════════════════════════════
# 5. Initialise logging
# ════════════════════════════════════════════════════════════════════════
# ConcurrentQueue shared between UI thread and background runspaces
$LogQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()

Initialize-Logging -Level $Config['LogLevel'] -LogQueue $LogQueue

# ════════════════════════════════════════════════════════════════════════
# 6. Global state — synchronized hashtable visible to all runspaces
# ════════════════════════════════════════════════════════════════════════
$GlobalState = [System.Collections.Hashtable]::Synchronized(@{
    # Infrastructure
    AppRoot            = $AppRoot
    Config             = $Config
    ConfigFile         = $ConfigFile
    LogQueue           = $LogQueue
    LoggingInitialized = $true

    # Connection
    Connected          = $false
    TenantId           = ''
    TenantName         = ''
    UserPrincipalName  = ''
    AccountId          = ''

    # Operation flags  (key pattern: OperationRunning_{Key})
    # Populated dynamically by Start-BackgroundOperation in MainForm.ps1

    # Shared results written by background runspaces
    BackupResult       = $null
    RestoreResult      = $null
    ConflictResult     = $null
    BackupProgress     = 0
    RestoreProgress    = 0
})

# ════════════════════════════════════════════════════════════════════════
# 7. Launch GUI
# ════════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Dot-source the GUI files (they define functions, not run code at parse time)
$guiFiles = @(
    'GUI\MainForm.ps1'
    'GUI\Tab_Connection.ps1'
    'GUI\Tab_Prerequisites.ps1'
    'GUI\Tab_Backup.ps1'
    'GUI\Tab_Restore.ps1'
    'GUI\Tab_Log.ps1'
    'GUI\Tab_Settings.ps1'
)

foreach ($rel in $guiFiles) {
    $full = Join-Path $AppRoot $rel
    if (-not (Test-Path $full)) {
        Write-Error "Required GUI file not found: $full"
        exit 1
    }
    . $full
}

# Write-LogMessage is available after Initialize-Logging
Write-LogMessage -Level 'INFO' -Message 'Intune Backup & Restore Tool starting.'
Write-LogMessage -Level 'INFO' -Message "PowerShell $($PSVersionTable.PSVersion)  |  AppRoot: $AppRoot"
Write-LogMessage -Level 'INFO' -Message "Config: $ConfigFile"

# Start-MainForm runs [Application]::Run() — blocks until the window closes
try {
    Start-MainForm -GlobalState $GlobalState
} finally {
    Write-LogMessage -Level 'INFO' -Message 'Application closed.'

    # Flush any remaining log entries to file if configured
    if ($Config['LogToFile']) {
        try { Export-LogToFile -GlobalState $GlobalState } catch {}
    }
}
