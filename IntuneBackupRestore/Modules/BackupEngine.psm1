<#
.SYNOPSIS
    Backup orchestration for the Intune Backup & Restore Tool.

.DESCRIPTION
    Coordinates a complete or partial Intune backup:
      1.  Creates the dated folder hierarchy under the backup root.
      2.  Calls each selected workload-specific export function.
      3.  Writes manifest.json (start info + final summary).
      4.  Writes index.json (flat list of every exported object).

    Progress and log messages are written to the shared $GlobalState
    hashtable so the GUI timer can reflect them without blocking the UI.

    Folder layout produced:
        <BackupRoot>\
          <TenantName>_<TenantId>\
            <yyyy-MM-dd_HH-mm-ss>\
              Manifest\
                manifest.json
                index.json
              CompliancePolicies\
              ConfigProfiles\
              SettingsCatalog\
              EndpointSecurity\
              DeviceScripts\
              Logs\
#>

Set-StrictMode -Version Latest

# Tool schema version – stored in manifest.json for forward-compatibility checks.
$script:SchemaVersion = '1.0'
$script:ToolVersion   = '1.0.0'

# ---------------------------------------------------------------------------
#region Folder helpers
# ---------------------------------------------------------------------------

function New-BackupSession {
    <#
    .SYNOPSIS
        Creates the dated backup folder hierarchy.
    .OUTPUTS
        [hashtable] of named paths: Root, Manifest, CompliancePolicies, …, Logs
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BackupRootPath,
        [Parameter(Mandatory)][string]$TenantDisplayName,
        [Parameter(Mandatory)][string]$TenantId
    )

    $safeTenant  = ($TenantDisplayName -replace '[\\/:*?"<>|]', '_').Trim('_. ')
    $timestamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $sessionRoot = Join-Path $BackupRootPath "${safeTenant}_${TenantId}" | Join-Path -ChildPath $timestamp

    $paths = [ordered]@{
        Root               = $sessionRoot
        Manifest           = Join-Path $sessionRoot 'Manifest'
        CompliancePolicies = Join-Path $sessionRoot 'CompliancePolicies'
        ConfigProfiles     = Join-Path $sessionRoot 'ConfigProfiles'
        SettingsCatalog    = Join-Path $sessionRoot 'SettingsCatalog'
        EndpointSecurity   = Join-Path $sessionRoot 'EndpointSecurity'
        DeviceScripts      = Join-Path $sessionRoot 'DeviceScripts'
        Logs               = Join-Path $sessionRoot 'Logs'
    }

    foreach ($p in $paths.Values) {
        if (-not (Test-Path -Path $p)) {
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }
    }

    Write-LogMessage -Level INFO -Message "Backup session folder: $sessionRoot"
    return $paths
}

#endregion

# ---------------------------------------------------------------------------
#region Manifest helpers
# ---------------------------------------------------------------------------

function Write-BackupManifest {
    <#
    .SYNOPSIS
        Writes (or overwrites) manifest.json in the Manifest subfolder.
    .PARAMETER Paths
        The paths hashtable from New-BackupSession.
    .PARAMETER Status
        'InProgress' at the start; 'Completed' or 'Failed' at the end.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]   $TenantDisplayName,
        [Parameter(Mandatory)][string]   $TenantId,
        [string]   $ConnectedUser      = '',
        [string]   $Status             = 'InProgress',
        [string[]] $SelectedWorkloads  = @(),
        [hashtable]$WorkloadCounts     = @{},
        [hashtable]$WorkloadWarnings   = @{},
        [string[]] $SessionWarnings    = @(),
        [string]   $StartedAt         = '',
        [string]   $CompletedAt       = ''
    )

    $total    = 0
    $summary  = @{}
    foreach ($wl in $WorkloadCounts.Keys) {
        $summary[$wl] = @{
            ExportedCount = $WorkloadCounts[$wl]
            Warnings      = if ($WorkloadWarnings[$wl]) { $WorkloadWarnings[$wl] } else { @() }
        }
        $total += $WorkloadCounts[$wl]
    }

    $manifest = [ordered]@{
        SchemaVersion     = $script:SchemaVersion
        ToolVersion       = $script:ToolVersion
        Status            = $Status
        StartedAt         = $StartedAt
        CompletedAt       = $CompletedAt
        Tenant            = [ordered]@{
            DisplayName = $TenantDisplayName
            Id          = $TenantId
        }
        BackedUpBy        = $ConnectedUser
        SelectedWorkloads = $SelectedWorkloads
        TotalObjectCount  = $total
        WorkloadSummary   = $summary
        SessionWarnings   = $SessionWarnings
    }

    $file = Join-Path $Paths.Manifest 'manifest.json'
    Save-JsonFile -Object $manifest -Path $file
    Write-LogMessage -Level DEBUG -Message "Manifest written: $file"
    return $file
}

function Write-BackupIndex {
    <#
    .SYNOPSIS
        Writes index.json – a flat list of every exported object.
        Useful for the Restore tab to enumerate backup contents quickly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestFolderPath,
        [Parameter(Mandatory)][System.Collections.Generic.List[hashtable]]$Entries
    )

    $index = [ordered]@{
        GeneratedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        TotalObjects = $Entries.Count
        Objects      = $Entries.ToArray()
    }

    $file = Join-Path $ManifestFolderPath 'index.json'
    Save-JsonFile -Object $index -Path $file
    Write-LogMessage -Level DEBUG -Message "Index written: $file ($($Entries.Count) object(s))"
    return $file
}

#endregion

# ---------------------------------------------------------------------------
#region Main orchestrator
# ---------------------------------------------------------------------------

function Start-IntuneBackup {
    <#
    .SYNOPSIS
        Main backup entry point. Intended to run in a background runspace.

    .DESCRIPTION
        Iterates over the selected workloads in order, calling the matching
        Export-* function from the Workloads\ modules.
        All progress is reflected in $GlobalState so the GUI timer can update
        the progress bar and status label without blocking.

    .PARAMETER GlobalState
        The shared Synchronized Hashtable from Main.ps1.

    .PARAMETER WorkloadSelection
        [hashtable] Workload key -> [bool]. E.g.:
            @{ CompliancePolicies=$true; ConfigProfiles=$true; ... }

    .PARAMETER IncludeAssignments
        Export assignment data for documentation (never restored).

    .PARAMETER ComputeChecksums
        Compute SHA-256 for every exported JSON file.

    .PARAMETER MaxRetries
        Passed to all Graph calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Hashtable]$GlobalState,

        [hashtable]$WorkloadSelection = @{
            CompliancePolicies = $true
            ConfigProfiles     = $true
            SettingsCatalog    = $true
            EndpointSecurity   = $true
            DeviceScripts      = $true
        },

        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3
    )

    $GlobalState.IsBackupRunning    = $true
    $GlobalState.BackupProgress     = 0
    $GlobalState.BackupProgressText = 'Initializing...'

    $startedAt       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $counts          = @{}
    $warnings        = @{}
    $sessionWarnings = [System.Collections.Generic.List[string]]::new()
    $indexEntries    = [System.Collections.Generic.List[hashtable]]::new()
    $manifestFile    = $null
    $paths           = $null

    # Workload definitions – order = display order
    $workloads = @(
        @{ Key = 'CompliancePolicies'; Label = 'Compliance Policies';      ExportFn = 'Export-CompliancePolicies';  SubDir = 'CompliancePolicies' }
        @{ Key = 'ConfigProfiles';     Label = 'Device Config Profiles';   ExportFn = 'Export-ConfigProfiles';      SubDir = 'ConfigProfiles'     }
        @{ Key = 'SettingsCatalog';    Label = 'Settings Catalog';         ExportFn = 'Export-SettingsCatalog';     SubDir = 'SettingsCatalog'    }
        @{ Key = 'EndpointSecurity';   Label = 'Endpoint Security';        ExportFn = 'Export-EndpointSecurity';    SubDir = 'EndpointSecurity'   }
        @{ Key = 'DeviceScripts';      Label = 'Device Mgmt Scripts';      ExportFn = 'Export-DeviceScripts';       SubDir = 'DeviceScripts'      }
    )

    $selected = @($workloads | Where-Object { $WorkloadSelection[$_.Key] })

    try {
        Write-LogMessage -Level INFO -Message '=== Backup started ==='
        Write-LogMessage -Level INFO -Message "Tenant : $($GlobalState.TenantDisplayName) ($($GlobalState.TenantId))"
        Write-LogMessage -Level INFO -Message "Root   : $($GlobalState.BackupRootPath)"
        Write-LogMessage -Level INFO -Message "Workloads: $($selected.Label -join ', ')"

        # 1. Create folders
        $GlobalState.BackupProgressText = 'Creating folder structure...'
        $paths = New-BackupSession `
            -BackupRootPath    $GlobalState.BackupRootPath `
            -TenantDisplayName $GlobalState.TenantDisplayName `
            -TenantId          $GlobalState.TenantId

        $GlobalState.CurrentBackupDir = $paths.Root

        # Copy live log into backup Logs folder so the backup is self-contained
        $liveLog = Get-LogFilePath
        if ($liveLog -and (Test-Path $liveLog)) {
            Copy-Item -Path $liveLog -Destination (Join-Path $paths.Logs 'session.log') -Force -ErrorAction SilentlyContinue
        }

        # 2. Initial manifest (status = InProgress)
        $manifestFile = Write-BackupManifest `
            -Paths             $paths `
            -TenantDisplayName $GlobalState.TenantDisplayName `
            -TenantId          $GlobalState.TenantId `
            -ConnectedUser     $GlobalState.ConnectedUser `
            -Status            'InProgress' `
            -SelectedWorkloads @($selected.Key) `
            -StartedAt         $startedAt

        # 3. Export each workload
        $done  = 0
        $total = $selected.Count

        foreach ($wl in $selected) {
            $GlobalState.BackupProgressText = "Exporting $($wl.Label)..."
            $GlobalState.BackupProgress     = [int](($done / [Math]::Max($total, 1)) * 88)

            Write-LogMessage -Level INFO -Message "--- $($wl.Label) ---"

            try {
                $result = & $wl.ExportFn `
                    -ExportPath         $paths[$wl.SubDir] `
                    -IncludeAssignments $IncludeAssignments `
                    -ComputeChecksums   $ComputeChecksums `
                    -MaxRetries         $MaxRetries

                $counts[$wl.Key]   = $result.ExportedCount
                $warnings[$wl.Key] = $result.Warnings

                if ($result.Warnings.Count -gt 0) {
                    foreach ($w in $result.Warnings) { $sessionWarnings.Add($w) }
                }
                if ($result.IndexEntries.Count -gt 0) {
                    $indexEntries.AddRange([hashtable[]]$result.IndexEntries)
                }

                Write-LogMessage -Level SUCCESS -Message "$($wl.Label): $($result.ExportedCount) object(s) exported"
            }
            catch {
                $msg = "$($wl.Label) export failed: $($_.Exception.Message)"
                Write-LogMessage -Level ERROR -Message $msg -ErrorRecord $_
                $counts[$wl.Key]   = 0
                $warnings[$wl.Key] = @($msg)
                $sessionWarnings.Add($msg)
            }

            $done++
        }

        # 4. Write index
        $GlobalState.BackupProgressText = 'Writing index...'
        $GlobalState.BackupProgress     = 92
        Write-BackupIndex -ManifestFolderPath $paths.Manifest -Entries $indexEntries | Out-Null

        # 5. Final manifest (Completed)
        $GlobalState.BackupProgressText = 'Finalising manifest...'
        $GlobalState.BackupProgress     = 96
        Write-BackupManifest `
            -Paths             $paths `
            -TenantDisplayName $GlobalState.TenantDisplayName `
            -TenantId          $GlobalState.TenantId `
            -ConnectedUser     $GlobalState.ConnectedUser `
            -Status            'Completed' `
            -SelectedWorkloads @($selected.Key) `
            -WorkloadCounts    $counts `
            -WorkloadWarnings  $warnings `
            -SessionWarnings   $sessionWarnings.ToArray() `
            -StartedAt         $startedAt `
            -CompletedAt       (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-Null

        $grandTotal = ($counts.Values | Measure-Object -Sum).Sum
        $GlobalState.BackupProgress     = 100
        $GlobalState.BackupProgressText = "Done — $grandTotal object(s) exported"

        Write-LogMessage -Level SUCCESS -Message "=== Backup completed — $grandTotal object(s) ==="
        Write-LogMessage -Level SUCCESS -Message "Location: $($paths.Root)"

        if ($sessionWarnings.Count -gt 0) {
            Write-LogMessage -Level WARN -Message "$($sessionWarnings.Count) warning(s):"
            foreach ($w in $sessionWarnings) {
                Write-LogMessage -Level WARN -Message "  $w"
            }
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message '=== Backup failed ===' -ErrorRecord $_
        $GlobalState.BackupProgressText = "Failed: $($_.Exception.Message)"

        if ($manifestFile -and (Test-Path $manifestFile)) {
            try {
                Write-BackupManifest `
                    -Paths             $paths `
                    -TenantDisplayName $GlobalState.TenantDisplayName `
                    -TenantId          $GlobalState.TenantId `
                    -Status            'Failed' `
                    -SessionWarnings   @("Backup failed: $($_.Exception.Message)") `
                    -StartedAt         $startedAt `
                    -CompletedAt       (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-Null
            }
            catch { }
        }
        throw
    }
    finally {
        $GlobalState.IsBackupRunning = $false
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Recent-backups helper (for GUI list)
# ---------------------------------------------------------------------------

function Get-RecentBackups {
    <#
    .SYNOPSIS
        Scans the backup root and returns a list of backup summaries
        for display in the GUI.
    .OUTPUTS
        [hashtable[]]  BackupDate, TenantName, TenantId, TotalObjects, Status, BackupPath, ManifestPath
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][string]$BackupRootPath,
        [int]$MaxResults = 50
    )

    $results = [System.Collections.Generic.List[hashtable]]::new()

    if (-not (Test-Path -Path $BackupRootPath)) {
        return $results.ToArray()
    }

    $manifests = Get-ChildItem -Path $BackupRootPath -Recurse -Filter 'manifest.json' `
                               -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First $MaxResults

    foreach ($mf in $manifests) {
        try {
            $m = Read-JsonFile -Path $mf.FullName
            if (-not $m) { continue }

            $results.Add(@{
                BackupDate   = if ($m.StartedAt) { $m.StartedAt } else { $mf.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
                TenantName   = if ($m.Tenant.DisplayName) { $m.Tenant.DisplayName } else { 'Unknown' }
                TenantId     = if ($m.Tenant.Id) { $m.Tenant.Id } else { '' }
                TotalObjects = if ($m.TotalObjectCount) { $m.TotalObjectCount } else { 0 }
                Status       = if ($m.Status) { $m.Status } else { 'Unknown' }
                BackupPath   = $mf.DirectoryName | Split-Path -Parent
                ManifestPath = $mf.FullName
            })
        }
        catch {
            Write-LogMessage -Level DEBUG -Message "Cannot parse manifest: $($mf.FullName)"
        }
    }

    return $results.ToArray()
}

#endregion

Export-ModuleMember -Function `
    New-BackupSession, `
    Write-BackupManifest, `
    Write-BackupIndex, `
    Start-IntuneBackup, `
    Get-RecentBackups
