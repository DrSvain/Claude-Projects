<#
.SYNOPSIS
    Backup orchestration for the Intune Backup & Restore Tool.

.DESCRIPTION
    Coordinates a complete or partial Intune backup:
      1.  Creates the dated folder hierarchy under the backup root.
      2.  Calls each selected workload-specific export function.
      3.  Writes manifest.json (start info + final summary).
      4.  Writes index.json (flat list of every exported object).

    Folder layout produced (manifest v2):
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
              Autopilot\
              EnrollmentConfigurations\
              AppProtection\
              AppConfiguration\
              ProactiveRemediations\
              AdministrativeTemplates\
              Logs\
#>

Set-StrictMode -Version Latest

# Tool schema version – stored in manifest.json for forward-compatibility checks.
$script:SchemaVersion = '2.0'
$script:ToolVersion   = '1.1.0'

# Workload registry. Order = display order in the GUI checkbox list and on
# disk. Each entry: Key, Label, ExportFn, SubDir, BackupOnly (true if a category
# can be exported but is not safe to restore generically).
$script:WorkloadRegistry = @(
    @{ Key='CompliancePolicies';       Label='Compliance Policies';      ExportFn='Export-CompliancePolicies';     SubDir='CompliancePolicies';       BackupOnly=$false }
    @{ Key='ConfigProfiles';           Label='Device Config Profiles';   ExportFn='Export-ConfigProfiles';         SubDir='ConfigProfiles';           BackupOnly=$false }
    @{ Key='SettingsCatalog';          Label='Settings Catalog';         ExportFn='Export-SettingsCatalog';        SubDir='SettingsCatalog';          BackupOnly=$false }
    @{ Key='EndpointSecurity';         Label='Endpoint Security';        ExportFn='Export-EndpointSecurity';       SubDir='EndpointSecurity';         BackupOnly=$false }
    @{ Key='DeviceScripts';            Label='Device Mgmt Scripts';      ExportFn='Export-DeviceScripts';          SubDir='DeviceScripts';            BackupOnly=$false }
    @{ Key='Autopilot';                Label='Autopilot Profiles';       ExportFn='Export-AutopilotProfiles';      SubDir='Autopilot';                BackupOnly=$false }
    @{ Key='EnrollmentConfigurations'; Label='Enrollment Configurations';ExportFn='Export-EnrollmentConfigurations';SubDir='EnrollmentConfigurations';BackupOnly=$false }
    @{ Key='AppProtection';            Label='App Protection (MAM)';     ExportFn='Export-AppProtectionPolicies';  SubDir='AppProtection';            BackupOnly=$false }
    @{ Key='AppConfiguration';         Label='App Configuration';        ExportFn='Export-AppConfigurationPolicies';SubDir='AppConfiguration';        BackupOnly=$false }
    @{ Key='ProactiveRemediations';    Label='Proactive Remediations';   ExportFn='Export-ProactiveRemediations';  SubDir='ProactiveRemediations';    BackupOnly=$false }
    @{ Key='AdministrativeTemplates';  Label='Administrative Templates'; ExportFn='Export-AdministrativeTemplates';SubDir='AdministrativeTemplates';  BackupOnly=$false }
)

function Get-IntuneBackupCategories {
    <#
    .SYNOPSIS
        Returns the workload registry. Used by the Backup tab to populate
        checkboxes and by the manifest writer to enumerate categories.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    return ,$script:WorkloadRegistry
}

# ---------------------------------------------------------------------------
#region Folder helpers
# ---------------------------------------------------------------------------

function Resolve-BackupSessionPath {
    <#
    .SYNOPSIS
        Builds a session folder path from the configured naming pattern.

    .PARAMETER Pattern
        Tokens: {tenant} {tenantId} {timestamp}
        Default: '{tenant}_{tenantId}/{timestamp}'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BackupRootPath,
        [Parameter(Mandatory)][string]$TenantDisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$Pattern = '{tenant}_{tenantId}/{timestamp}'
    )

    $safeTenant = ($TenantDisplayName -replace '[\\/:*?"<>|]', '_').Trim('_. ')
    if ([string]::IsNullOrWhiteSpace($safeTenant)) { $safeTenant = 'Tenant' }
    $timestamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

    # Use String.Replace (literal) rather than -replace (regex) so the token
    # values themselves cannot inject regex metacharacters or replacement
    # backreferences ($1, $&, etc.).
    $rel = $Pattern
    $rel = $rel.Replace('{tenant}',    $safeTenant)
    $rel = $rel.Replace('{tenantId}',  $TenantId)
    $rel = $rel.Replace('{timestamp}', $timestamp)

    # Normalize separators to the platform default
    $rel = $rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar.ToString())

    return [System.IO.Path]::Combine($BackupRootPath, $rel)
}

function New-BackupSession {
    <#
    .SYNOPSIS
        Creates the dated backup folder hierarchy.

    .OUTPUTS
        [hashtable] of named paths (one entry per workload + Manifest + Logs + Root).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BackupRootPath,
        [Parameter(Mandatory)][string]$TenantDisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$NamingPattern = '{tenant}_{tenantId}/{timestamp}'
    )

    $sessionRoot = Resolve-BackupSessionPath `
        -BackupRootPath    $BackupRootPath `
        -TenantDisplayName $TenantDisplayName `
        -TenantId          $TenantId `
        -Pattern           $NamingPattern

    $paths = [ordered]@{
        Root     = $sessionRoot
        Manifest = Join-Path $sessionRoot 'Manifest'
        Logs     = Join-Path $sessionRoot 'Logs'
    }
    foreach ($wl in $script:WorkloadRegistry) {
        $paths[$wl.SubDir] = Join-Path $sessionRoot $wl.SubDir
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Paths,
        [Parameter(Mandatory)][string]   $TenantDisplayName,
        [Parameter(Mandatory)][string]   $TenantId,
        [string]   $ConnectedUser        = '',
        [string]   $Status               = 'InProgress',
        [string[]] $SelectedWorkloads    = @(),
        [hashtable]$WorkloadCounts       = @{},
        [hashtable]$WorkloadWarnings     = @{},
        [string[]] $SessionWarnings      = @(),
        [hashtable]$EndpointVersionsUsed = @{},
        [string[]] $CategoriesBackupOnly = @(),
        [bool]     $ExportedAssignments  = $false,
        [string]   $StartedAt           = '',
        [string]   $CompletedAt         = ''
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
        SchemaVersion        = $script:SchemaVersion
        ToolVersion          = $script:ToolVersion
        Status               = $Status
        StartedAt            = $StartedAt
        CompletedAt          = $CompletedAt
        Tenant               = [ordered]@{
            DisplayName = $TenantDisplayName
            Id          = $TenantId
        }
        BackedUpBy           = $ConnectedUser
        SelectedWorkloads    = $SelectedWorkloads
        SelectedCategories   = $SelectedWorkloads   # alias for spec compatibility
        TotalObjectCount     = $total
        WorkloadSummary      = $summary
        EndpointVersionsUsed = $EndpointVersionsUsed
        CategoriesBackupOnly = $CategoriesBackupOnly
        ExportedAssignments  = $ExportedAssignments
        SessionWarnings      = $SessionWarnings
    }

    $file = Join-Path $Paths.Manifest 'manifest.json'
    Save-JsonFile -Object $manifest -Path $file
    Write-LogMessage -Level DEBUG -Message "Manifest written: $file"
    return $file
}

function Add-AssignmentSidecars {
    <#
    .SYNOPSIS
        Ensures that every index entry in $Entries has a companion
        <name>.assignments.json sidecar (when assignments exist).

    .DESCRIPTION
        The five legacy workload modules embed assignments inside their raw
        JSON package rather than writing a sidecar. AssignmentEngine restore
        expects a sidecar. This helper bridges the two by emitting sidecars
        for any entry whose sidecar is not yet present and whose workload is
        registered in AssignmentEngine.

    .NOTES
        Idempotent — entries that already have a sidecar (the new workload
        modules) are skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[hashtable]]$Entries,
        [Parameter(Mandatory)][hashtable]$Paths,
        [int]$MaxRetries = 3
    )

    foreach ($entry in $Entries) {
        $wlKey = $entry.Category
        if (-not $wlKey -or -not $entry.SourceId -or -not $entry.FileName) { continue }
        $subDir = $script:WorkloadRegistry | Where-Object { $_.Key -eq $wlKey } | Select-Object -ExpandProperty SubDir -First 1
        if (-not $subDir) { continue }

        $base    = [System.IO.Path]::GetFileNameWithoutExtension($entry.FileName)
        $outBase = Join-Path $Paths[$subDir] $base
        $sidecar = "$outBase.assignments.json"
        if (Test-Path $sidecar) { continue }

        try {
            $info = Export-IntuneAssignments `
                -WorkloadKey $wlKey `
                -ObjectId    $entry.SourceId `
                -OutFileBase $outBase `
                -MaxRetries  $MaxRetries
            if ($info.HasAssignments) { $entry.HasAssignments = $true }
        }
        catch {
            Write-LogMessage -Level DEBUG -Message "Sidecar generation failed for $wlKey/$($entry.SourceId): $($_.Exception.Message)"
        }
    }
}

function Write-BackupIndex {
    <#
    .SYNOPSIS
        Writes index.json – a flat list of every exported object.
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Hashtable]$GlobalState,

        [hashtable]$WorkloadSelection = $null,

        [bool]$IncludeAssignments = $true,
        [bool]$ComputeChecksums   = $true,
        [int] $MaxRetries         = 3,

        [string]$NamingPattern = '{tenant}_{tenantId}/{timestamp}'
    )

    # Default to all workloads if no selection passed
    if (-not $WorkloadSelection) {
        $WorkloadSelection = @{}
        foreach ($w in $script:WorkloadRegistry) { $WorkloadSelection[$w.Key] = $true }
    }

    $GlobalState.IsBackupRunning    = $true
    $GlobalState.BackupProgress     = 0
    $GlobalState.BackupProgressText = 'Initializing...'

    $startedAt       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $counts          = @{}
    $warnings        = @{}
    $endpointsUsed   = @{}
    $sessionWarnings = [System.Collections.Generic.List[string]]::new()
    $indexEntries    = [System.Collections.Generic.List[hashtable]]::new()
    $manifestFile    = $null
    $paths           = $null

    $selected = @($script:WorkloadRegistry | Where-Object { $WorkloadSelection[$_.Key] })

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
            -TenantId          $GlobalState.TenantId `
            -NamingPattern     $NamingPattern

        $GlobalState.CurrentBackupDir = $paths.Root

        # Copy live log
        try {
            $liveLog = Get-LogFilePath
            if ($liveLog -and (Test-Path $liveLog)) {
                Copy-Item -Path $liveLog -Destination (Join-Path $paths.Logs 'session.log') -Force -ErrorAction SilentlyContinue
            }
        } catch { }

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

            # Track endpoint version actually used
            try { $endpointsUsed[$wl.Key] = Get-EndpointVersion -WorkloadKey $wl.Key } catch { $endpointsUsed[$wl.Key] = 'v1.0' }

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

        # 4a. Generate assignment sidecars for legacy workloads that embed
        # assignments in the raw package. Idempotent — skips workloads whose
        # exporters already wrote a sidecar.
        if ($IncludeAssignments) {
            $GlobalState.BackupProgressText = 'Writing assignment sidecars...'
            $GlobalState.BackupProgress     = 90
            try {
                Add-AssignmentSidecars -Entries $indexEntries -Paths $paths -MaxRetries $MaxRetries
            }
            catch {
                Write-LogMessage -Level WARN -Message "Assignment sidecar pass failed: $($_.Exception.Message)"
            }
        }

        # 4b. Write index
        $GlobalState.BackupProgressText = 'Writing index...'
        $GlobalState.BackupProgress     = 92
        Write-BackupIndex -ManifestFolderPath $paths.Manifest -Entries $indexEntries | Out-Null

        # 5. Final manifest
        $GlobalState.BackupProgressText = 'Finalising manifest...'
        $GlobalState.BackupProgress     = 96

        $backupOnlyCats = @(
            $script:WorkloadRegistry | Where-Object { $_.BackupOnly -and $WorkloadSelection[$_.Key] } | Select-Object -ExpandProperty Key
        )

        Write-BackupManifest `
            -Paths                $paths `
            -TenantDisplayName    $GlobalState.TenantDisplayName `
            -TenantId             $GlobalState.TenantId `
            -ConnectedUser        $GlobalState.ConnectedUser `
            -Status               'Completed' `
            -SelectedWorkloads    @($selected.Key) `
            -WorkloadCounts       $counts `
            -WorkloadWarnings     $warnings `
            -SessionWarnings      $sessionWarnings.ToArray() `
            -EndpointVersionsUsed $endpointsUsed `
            -CategoriesBackupOnly $backupOnlyCats `
            -ExportedAssignments  $IncludeAssignments `
            -StartedAt            $startedAt `
            -CompletedAt          (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-Null

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
        Scans the backup root and returns a list of backup summaries.
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
                ToolVersion  = if ($m.PSObject.Properties['ToolVersion']) { $m.ToolVersion } else { '' }
                SchemaVersion = if ($m.PSObject.Properties['SchemaVersion']) { $m.SchemaVersion } else { '1.0' }
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
    Get-IntuneBackupCategories, `
    Resolve-BackupSessionPath, `
    New-BackupSession, `
    Write-BackupManifest, `
    Write-BackupIndex, `
    Add-AssignmentSidecars, `
    Start-IntuneBackup, `
    Get-RecentBackups
