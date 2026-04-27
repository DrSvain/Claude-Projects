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
# 1. Platform / version guard
# ════════════════════════════════════════════════════════════════════════
if (-not $IsWindows) {
    Write-Host 'ERROR: This tool requires Windows.' -ForegroundColor Red
    exit 1
}

Write-Host "[Startup] PowerShell $($PSVersionTable.PSVersion) on $([System.Environment]::OSVersion.VersionString)" -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════════════════
# 2. Paths
# ════════════════════════════════════════════════════════════════════════
$AppRoot = $PSScriptRoot
Write-Host "[Startup] AppRoot: $AppRoot" -ForegroundColor Cyan

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
        Write-Host "[Startup] Config loaded: $ConfigFile" -ForegroundColor Cyan
    } catch {
        Write-Host "[Startup] WARNING: Could not parse config: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[Startup] Config file not found, using defaults: $ConfigFile" -ForegroundColor Yellow
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
# 5. Initialise logging
# ════════════════════════════════════════════════════════════════════════
$LogQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
try {
    Initialize-Logging -Level $Config['LogLevel'] -LogQueue $LogQueue
    Write-Host '[Startup] Logging initialised.' -ForegroundColor Cyan
} catch {
    Write-Host "ERROR initialising logging: $_" -ForegroundColor Red
    Read-Host 'Press Enter to exit'
    exit 1
}

# ════════════════════════════════════════════════════════════════════════
# 6. Global state
# ════════════════════════════════════════════════════════════════════════
$GlobalState = [System.Collections.Hashtable]::Synchronized(@{
    AppRoot            = $AppRoot
    Config             = $Config
    ConfigFile         = $ConfigFile
    LogQueue           = $LogQueue
    LoggingInitialized = $true
    Connected          = $false
    TenantId           = ''
    TenantName         = ''
    UserPrincipalName  = ''
    AccountId          = ''
    BackupResult       = $null
    RestoreResult      = $null
    ConflictResult     = $null
    BackupProgress     = 0
    RestoreProgress    = 0
})

# ════════════════════════════════════════════════════════════════════════
# 7. Load WinForms assemblies
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
# 8. Dot-source GUI files
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
        Write-Host "ERROR loading GUI file $rel : $_" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

Write-Host '[Startup] Launching GUI...' -ForegroundColor Green

# ════════════════════════════════════════════════════════════════════════
# 9. Run
# ════════════════════════════════════════════════════════════════════════
try {
    Start-MainForm -GlobalState $GlobalState
} catch {
    Write-Host "FATAL ERROR in GUI: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Read-Host 'Press Enter to exit'
} finally {
    if ($Config['LogToFile']) {
        try { Export-LogToFile -GlobalState $GlobalState } catch {}
    }
}
