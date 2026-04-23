<#
.SYNOPSIS
    Centralized logging module for the Intune Backup & Restore Tool.

.DESCRIPTION
    Writes log entries to a session log file and optionally enqueues them
    into a ConcurrentQueue for asynchronous GUI display.

    Thread-safe:
      - File writes use a [System.Threading.Mutex] to prevent interleaving.
      - GUI updates go through a ConcurrentQueue; the GUI drains it via a Timer.

    Log levels (ordered):
        DEBUG < INFO < SUCCESS < WARN < ERROR < FATAL
    FATAL is always emitted regardless of the configured level.

.NOTES
    Usage pattern:
        Initialize-Logging -LogFile 'C:\logs\session.log' -LogLevel INFO
        Register-LogQueue  -Queue $sharedQueue        # optional, for GUI
        Write-LogMessage   -Level INFO -Message 'Hello'
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------
$script:LogFile  = $null
$script:LogLevel = 'INFO'
$script:LogQueue = $null          # [System.Collections.Concurrent.ConcurrentQueue[hashtable]]
$script:LogMutex = [System.Threading.Mutex]::new($false, 'Global\IntuneBackupRestoreLog')

$script:LevelOrder = @{
    DEBUG   = 0
    INFO    = 1
    SUCCESS = 2
    WARN    = 3
    ERROR   = 4
    FATAL   = 5
}

$script:ConsoleColor = @{
    DEBUG   = 'DarkGray'
    INFO    = 'Gray'
    SUCCESS = 'Green'
    WARN    = 'Yellow'
    ERROR   = 'Red'
    FATAL   = 'Magenta'
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function Initialize-Logging {
    <#
    .SYNOPSIS
        Sets the target log file and level, and writes a session header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogFile,

        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$LogLevel = 'INFO'
    )

    $script:LogFile  = $LogFile
    $script:LogLevel = $LogLevel

    $dir = Split-Path -Path $LogFile -Parent
    if ($dir -and -not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $header = @(
        ('=' * 80)
        '  Intune Backup & Restore Tool - Session Log'
        "  Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "  Log level: $LogLevel"
        "  Host     : $([System.Net.Dns]::GetHostName())"
        "  User     : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        "  PS       : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        ('=' * 80)
        ''
    ) -join [Environment]::NewLine

    try {
        Set-Content -Path $LogFile -Value $header -Encoding UTF8 -Force
    }
    catch {
        Write-Warning "Could not create log file '$LogFile': $($_.Exception.Message)"
    }
}

function Register-LogQueue {
    <#
    .SYNOPSIS
        Registers a ConcurrentQueue so that log entries are also enqueued for
        the GUI. Call this from the GUI layer after creating the shared queue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$Queue
    )
    $script:LogQueue = $Queue
}

function Set-LogLevel {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level
    )
    $script:LogLevel = $Level
}

function Get-LogFilePath {
    return $script:LogFile
}

function Write-LogMessage {
    <#
    .SYNOPSIS
        Writes a log entry. Safe to call from any thread.

    .PARAMETER Level
        Severity. FATAL is always written regardless of the configured filter.

    .PARAMETER Message
        Human-readable log text.

    .PARAMETER ErrorRecord
        Optional ErrorRecord; the exception message and a short stack summary
        will be appended on separate lines.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null
    )

    # Level filtering (FATAL always passes)
    $configuredOrder = $script:LevelOrder[$script:LogLevel]
    $messageOrder    = $script:LevelOrder[$Level]
    if ($messageOrder -lt $configuredOrder -and $Level -ne 'FATAL') {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line      = "$timestamp [$($Level.PadRight(7))] $Message"

    if ($ErrorRecord) {
        $line += [Environment]::NewLine + "  >> Exception : $($ErrorRecord.Exception.Message)"
        if ($ErrorRecord.ScriptStackTrace) {
            $stack = ($ErrorRecord.ScriptStackTrace -split "`n" |
                      Select-Object -First 3 |
                      ForEach-Object { $_.Trim() }) -join ' | '
            $line += [Environment]::NewLine + "  >> Stack     : $stack"
        }
    }

    # --- File output (mutex-protected) -------------------------------------
    if ($script:LogFile) {
        $acquired = $false
        try {
            $acquired = $script:LogMutex.WaitOne(2000)
            if ($acquired) {
                Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
            }
        }
        catch {
            # Fallback: best-effort console warning, do not throw
            Write-Warning "Log write failed: $($_.Exception.Message)"
        }
        finally {
            if ($acquired) {
                try { $script:LogMutex.ReleaseMutex() } catch { }
            }
        }
    }

    # --- GUI queue ---------------------------------------------------------
    if ($script:LogQueue) {
        try {
            $script:LogQueue.Enqueue(@{
                Timestamp = $timestamp
                Level     = $Level
                Message   = $Message
                Formatted = $line
            })
        }
        catch { }
    }

    # --- Console output ----------------------------------------------------
    try {
        $color = $script:ConsoleColor[$Level]
        Write-Host $line -ForegroundColor $color
    }
    catch { }
}

function Export-LogToFile {
    <#
    .SYNOPSIS
        Copies the current session log to the target file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if (-not $script:LogFile -or -not (Test-Path -Path $script:LogFile)) {
        throw "No active log file to export."
    }

    Copy-Item -Path $script:LogFile -Destination $DestinationPath -Force
    Write-LogMessage -Level INFO -Message "Log exported to: $DestinationPath"
}

Export-ModuleMember -Function `
    Initialize-Logging, `
    Register-LogQueue, `
    Set-LogLevel, `
    Get-LogFilePath, `
    Write-LogMessage, `
    Export-LogToFile
