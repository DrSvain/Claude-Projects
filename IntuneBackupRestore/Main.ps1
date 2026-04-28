#Requires -Version 7.0
<#
.SYNOPSIS
    Intune Backup & Restore Tool — entry point.
.EXAMPLE
    pwsh -File Main.ps1
    pwsh -File Main.ps1 -ConfigFile 'D:\MyConfig\AppConfig.json'
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = ''
)

$ErrorActionPreference = 'Stop'

# ════════════════════════════════════════════════════════════════════════
# 1. Platform guard
# ════════════════════════════════════════════════════════════════════════
if (-not $IsWindows) {
    Write-Host 'ERROR: This tool requires Windows.' -ForegroundColor Red
    exit 1
}

Write-Host "[Startup] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════════════════
# 2. Paths
# ════════════════════════════════════════════════════════════════════════
$AppRoot = $PSScriptRoot
Write-Host "[Startup] AppRoot: $AppRoot" -ForegroundColor Cyan

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $AppRoot 'Config\AppConfig.json'
}

# ════════════════════════════════════════════════════════════════════════
# 3. Unblock files (removes Zone.Identifier from files downloaded via browser)
# ════════════════════════════════════════════════════════════════════════
try {
    Get-ChildItem -Path $AppRoot -Recurse -Include '*.ps1','*.psm1' | Unblock-File
    Write-Host '[Startup] Files unblocked.' -ForegroundColor Cyan
} catch {
    Write-Host "[Startup] Unblock-File warning (non-fatal): $_" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════════
# 4. Load configuration
# ════════════════════════════════════════════════════════════════════════
$Config = @{}
if (Test-Path $ConfigFile) {
    try {
        $Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Write-Host "[Startup] Config loaded: $ConfigFile" -ForegroundColor Cyan
    } catch {
        Write-Host "[Startup] WARNING: Could not parse config: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[Startup] Config file not found, using defaults." -ForegroundColor Yellow
}

$defaults = @{
    BackupRootPath    = [System.IO.Path]::Combine($env:USERPROFILE, 'IntuneBackups')
    WriteChecksums    = $false
    ConfirmRestore    = $true
    ExportAssignments = $true
    LogLevel          = 'INFO'
    LogToFile         = $true
    MaxRetries        = 3
    BaseDelaySeconds  = 2
    PageSize          = 100
    ConfirmDisconnect = $true
    ShowDebugInUI     = $false
}
foreach ($key in $defaults.Keys) {
    if (-not $Config.ContainsKey($key)) { $Config[$key] = $defaults[$key] }
}

# ════════════════════════════════════════════════════════════════════════
# 5. Load modules
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

Write-Host '[Startup] Loading modules...' -ForegroundColor Cyan
foreach ($rel in $moduleOrder) {
    $full = Join-Path $AppRoot $rel
    if (-not (Test-Path $full)) {
        Write-Host "ERROR: Module not found: $full" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    try {
        Import-Module $full -Force -DisableNameChecking
        Write-Host "  OK  $rel" -ForegroundColor Green
    } catch {
        Write-Host "ERROR loading $rel : $_" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

# ════════════════════════════════════════════════════════════════════════
# 6. Initialise logging
#    Initialize-Logging needs a log FILE path and a log LEVEL.
#    Register-LogQueue wires the ConcurrentQueue for GUI display.
# ════════════════════════════════════════════════════════════════════════
$LogQueue   = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$sessionLog = Join-Path $env:TEMP "IntuneBackupRestore_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"

try {
    Initialize-Logging -LogFile $sessionLog -LogLevel $Config['LogLevel']
    Register-LogQueue  -Queue $LogQueue
    Write-Host "[Startup] Logging initialised. Session log: $sessionLog" -ForegroundColor Cyan
} catch {
    Write-Host "ERROR initialising logging: $_" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
# 7. Global state
# ════════════════════════════════════════════════════════════════════════
$GlobalState = [System.Collections.Hashtable]::Synchronized(@{
    # App identity
    AppRoot            = $AppRoot
    AppName            = 'Intune Backup & Restore Tool'
    AppVersion         = '1.0.0'
    Config             = $Config
    ConfigFile         = $ConfigFile

    # Logging
    LogQueue           = $LogQueue
    SessionLogFile     = $sessionLog
    LogFilePath        = $sessionLog          # backward-compat alias
    LogLevel           = $Config['LogLevel']
    LoggingInitialized = $true

    # Connection  — set by Tab_Connection on sign-in
    IsConnected        = $false               # used by Tab_Connection / Tab_Backup
    Connected          = $false               # used by Tab_Restore (new-arch key)
    TenantId           = ''
    TenantDisplayName  = ''                   # used by MainForm timer
    TenantName         = ''                   # used by Tab_Restore (new-arch key)
    ConnectedUser      = ''                   # used by MainForm timer
    UserPrincipalName  = ''                   # used by Tab_Restore (new-arch key)
    AccountId          = ''
    ConnectionTime     = $null

    # Backup  — populated from Config; overwritten by Tab_Backup UI
    BackupRootPath     = $(
        $raw = $Config['BackupRootPath']
        if ($raw) { [System.Environment]::ExpandEnvironmentVariables($raw) }
        else      { $defaults['BackupRootPath'] }
    )
    IncludeAssignments = [bool]($Config['ExportAssignments'] -ne $false)
    ComputeChecksums   = [bool]($Config['WriteChecksums']   -eq $true)
    MaxRetries         = [int]$Config['MaxRetries']
    IsBackupRunning    = $false
    BackupProgress     = 0
    BackupProgressText = ''

    # Restore
    IsRestoreRunning   = $false
    RestoreProgress    = 0
    RestoreProgressText = ''
    BackupResult       = $null
    RestoreResult      = $null
    ConflictResult     = $null
})

# ════════════════════════════════════════════════════════════════════════
# 8. Load WinForms
# ════════════════════════════════════════════════════════════════════════
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    Write-Host '[Startup] WinForms ready.' -ForegroundColor Cyan
} catch {
    Write-Host "ERROR loading WinForms: $_" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
# 9. Dot-source GUI files
# ════════════════════════════════════════════════════════════════════════
$guiFiles = @(
    'GUI\MainForm.ps1'
    'GUI\Tab_Connection.ps1'
    'GUI\Tab_Prerequisites.ps1'
    'GUI\Tab_Backup.ps1'
    'GUI\Tab_Restore.ps1'
    'GUI\Tab_Log.ps1'
    'GUI\Tab_Settings.ps1'
)

Write-Host '[Startup] Loading GUI files...' -ForegroundColor Cyan
foreach ($rel in $guiFiles) {
    $full = Join-Path $AppRoot $rel
    if (-not (Test-Path $full)) {
        Write-Host "ERROR: GUI file not found: $full" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
    try {
        . $full
        Write-Host "  OK  $rel" -ForegroundColor Green
    } catch {
        Write-Host "ERROR in $rel : $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

Write-Host '[Startup] Launching GUI...' -ForegroundColor Green

# ════════════════════════════════════════════════════════════════════════
# 10. Run
# ════════════════════════════════════════════════════════════════════════
try {
    Start-MainForm -GlobalState $GlobalState
} catch {
    Write-Host "FATAL ERROR in GUI: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Read-Host 'Press Enter to exit'
} finally {
    # Copy session log into backup root if configured
    if ($Config['LogToFile']) {
        $backupRoot = $Config['BackupRootPath']
        if ($backupRoot -and (Test-Path $backupRoot) -and (Test-Path $sessionLog)) {
            $dest = Join-Path $backupRoot "session_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
            try { Copy-Item -Path $sessionLog -Destination $dest -Force } catch {}
        }
    }
}
