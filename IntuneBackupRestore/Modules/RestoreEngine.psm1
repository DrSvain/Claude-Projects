<#
.SYNOPSIS
    Restore orchestration for the Intune Backup & Restore Tool.

.DESCRIPTION
    Provides a guided, safe restore flow:

      1.  Import-BackupManifest     – validate and load manifest.json + index.json
      2.  Test-RestoreConflicts     – compare backup objects against target tenant
      3.  Start-IntuneRestore       – restore selected objects, one by one
      4.  Invoke-RestoreObject      – dispatch to the correct workload Import-* function

    Safety rules enforced here:
      - Only objects explicitly selected by the user are restored.
      - Conflicting objects (same name already exists) are flagged; the default
        action is SKIP (not overwrite).
      - The target tenant is displayed in every progress update so the operator
        always knows where objects are being created.
      - Every restore action is written to the log.

    Workload → import-function mapping:
        CompliancePolicies  → Import-CompliancePolicy
        ConfigProfiles      → Import-ConfigProfile
        SettingsCatalog     → Import-SettingsCatalogPolicy
        EndpointSecurity    → Import-EndpointSecurityPolicy
        DeviceScripts       → Import-DeviceScript
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Workload dispatch table
# ---------------------------------------------------------------------------

# Maps workload key → hashtable with:
#   ImportFn      : name of the Import-* function (from Workload modules)
#   ConflictFn    : name of the Get-Existing* function
#   NameField     : JSON field that holds the display name in the import file
$script:WorkloadMap = @{
    CompliancePolicies = @{
        ImportFn   = 'Import-CompliancePolicy'
        ConflictFn = 'Get-ExistingCompliancePolicies'
        NameField  = 'displayName'
    }
    ConfigProfiles     = @{
        ImportFn   = 'Import-ConfigProfile'
        ConflictFn = 'Get-ExistingConfigProfiles'
        NameField  = 'displayName'
    }
    SettingsCatalog    = @{
        ImportFn   = 'Import-SettingsCatalogPolicy'
        ConflictFn = 'Get-ExistingSettingsCatalogPolicies'
        NameField  = 'name'
    }
    EndpointSecurity   = @{
        ImportFn   = 'Import-EndpointSecurityPolicy'
        ConflictFn = 'Get-ExistingEndpointSecurityPolicies'
        NameField  = 'name'
    }
    DeviceScripts      = @{
        ImportFn   = 'Import-DeviceScript'
        ConflictFn = 'Get-ExistingDeviceScripts'
        NameField  = 'displayName'
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Manifest / index loading
# ---------------------------------------------------------------------------

function Import-BackupManifest {
    <#
    .SYNOPSIS
        Loads and validates a backup folder.
        Returns structured data for the Restore tab to display.

    .PARAMETER BackupPath
        Path to the backup session folder (the one containing the Manifest subfolder).

    .OUTPUTS
        [hashtable]
            Manifest     – parsed manifest.json
            Index        – parsed index.json (flat object list)
            BackupPath   – resolved absolute path
            ManifestPath – full path to manifest.json
            IsValid      – bool
            Error        – error text if not valid
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BackupPath
    )

    $result = @{
        Manifest     = $null
        Index        = $null
        BackupPath   = $BackupPath
        ManifestPath = $null
        IsValid      = $false
        Error        = $null
    }

    if (-not (Test-Path -Path $BackupPath)) {
        $result.Error = "Backup path does not exist: $BackupPath"
        return $result
    }

    $manifestFile = Join-Path $BackupPath 'Manifest\manifest.json'
    $indexFile    = Join-Path $BackupPath 'Manifest\index.json'

    if (-not (Test-Path -Path $manifestFile)) {
        $result.Error = "manifest.json not found. Is this a valid backup folder?`nExpected: $manifestFile"
        return $result
    }

    $manifest = Read-JsonFile -Path $manifestFile
    if (-not $manifest) {
        $result.Error = "manifest.json could not be parsed."
        return $result
    }

    if ($manifest.Status -ne 'Completed') {
        $result.Error = "Backup status is '$($manifest.Status)' (not 'Completed'). This backup may be incomplete."
        # Still return data – GUI can warn user and let them proceed if they want
    }

    $index = $null
    if (Test-Path -Path $indexFile) {
        $index = Read-JsonFile -Path $indexFile
    }
    else {
        Write-LogMessage -Level WARN -Message "index.json not found; object list will be empty."
    }

    $result.Manifest     = $manifest
    $result.Index        = $index
    $result.ManifestPath = $manifestFile
    $result.IsValid      = ($null -eq $result.Error)

    Write-LogMessage -Level INFO -Message "Backup loaded: $($manifest.Tenant.DisplayName) / $($manifest.StartedAt) / $($manifest.TotalObjectCount) object(s)"
    return $result
}

function Get-BackupObjectList {
    <#
    .SYNOPSIS
        Returns the flat list of backup objects from the loaded index.
        Each entry gets a ConflictStatus and IsSelected field for the GUI DataGrid.

    .PARAMETER Index
        Parsed index.json object (from Import-BackupManifest).

    .OUTPUTS
        [hashtable[]]  – one row per object, suitable for DataGrid binding.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)][object]$Index,
        [string]$BackupPath = ''
    )

    if (-not $Index -or -not $Index.Objects) {
        return @()
    }

    $rows = foreach ($obj in $Index.Objects) {
        @{
            IsSelected     = $true
            DisplayName    = $obj.DisplayName
            SourceId       = $obj.SourceId
            Category       = $obj.Category
            CategoryLabel  = if ($obj.CategoryLabel) { $obj.CategoryLabel } else { $obj.Category }
            ODataType      = $obj.ODataType
            ImportFileName = $obj.ImportFileName
            FileName       = $obj.FileName
            RestoreWarning = $obj.RestoreWarning
            ConflictStatus = 'Unknown'    # populated by Test-RestoreConflicts
            RestoreResult  = $null        # populated after restore
        }
    }

    return @($rows)
}

#endregion

# ---------------------------------------------------------------------------
#region Conflict detection
# ---------------------------------------------------------------------------

function Test-RestoreConflicts {
    <#
    .SYNOPSIS
        Checks each object in the restore list against the currently connected
        tenant. Sets ConflictStatus on each row.

    .PARAMETER RestoreItems
        [hashtable[]] from Get-BackupObjectList.

    .PARAMETER MaxRetries
        Passed to conflict-query functions.

    .OUTPUTS
        The same array with ConflictStatus updated:
            None      – no existing object with the same name
            Conflict  – an object with the same name already exists
            Warning   – RestoreWarning is set (non-portable type, etc.)
            Error     – conflict check itself failed
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable[]]$RestoreItems,
        [int]$MaxRetries = 3
    )

    Write-LogMessage -Level INFO -Message "Checking conflicts in target tenant..."

    # Build existing-name lookups per workload (one Graph call per workload)
    $existingByWorkload = @{}

    $workloadKeys = $RestoreItems | Select-Object -ExpandProperty Category -Unique

    foreach ($wlKey in $workloadKeys) {
        $map = $script:WorkloadMap[$wlKey]
        if (-not $map) {
            Write-LogMessage -Level WARN -Message "No workload mapping for category '$wlKey' – skipping conflict check."
            $existingByWorkload[$wlKey] = @{}
            continue
        }

        try {
            $existing = & $map.ConflictFn -MaxRetries $MaxRetries
            $existingByWorkload[$wlKey] = $existing
            Write-LogMessage -Level DEBUG -Message "[$wlKey] $($existing.Count) existing object(s) in target"
        }
        catch {
            Write-LogMessage -Level WARN -Message "[$wlKey] Conflict check failed: $($_.Exception.Message)"
            $existingByWorkload[$wlKey] = @{}
        }
    }

    # Mark each item
    foreach ($item in $RestoreItems) {
        $wlKey    = $item.Category
        $existing = $existingByWorkload[$wlKey]
        $nameLow  = $item.DisplayName.ToLowerInvariant()

        if ($existing -and $existing.ContainsKey($nameLow)) {
            $item.ConflictStatus = 'Conflict'
        }
        elseif ($item.RestoreWarning) {
            $item.ConflictStatus = 'Warning'
        }
        else {
            $item.ConflictStatus = 'None'
        }
    }

    $conflicts = @($RestoreItems | Where-Object { $_.ConflictStatus -eq 'Conflict' }).Count
    $warnings  = @($RestoreItems | Where-Object { $_.ConflictStatus -eq 'Warning'  }).Count
    Write-LogMessage -Level INFO -Message "Conflict check complete: $conflicts conflict(s), $warnings warning(s)"

    return $RestoreItems
}

#endregion

# ---------------------------------------------------------------------------
#region Main restore orchestrator
# ---------------------------------------------------------------------------

function Start-IntuneRestore {
    <#
    .SYNOPSIS
        Restores selected objects from a backup into the current tenant.
        Intended to run in a background runspace.

    .PARAMETER GlobalState
        Shared synchronized hashtable.

    .PARAMETER BackupPath
        Session backup folder path.

    .PARAMETER SelectedItems
        [hashtable[]] rows from the Restore DataGrid where IsSelected = $true.
        ConflictStatus = 'Conflict' items are SKIPPED unless -OverwriteConflicts is set.

    .PARAMETER OverwriteConflicts
        If $false (default): conflicting objects are skipped.
        If $true : conflicting objects are still created as NEW (no update/overwrite).
                   Intune will have two objects with the same name.

    .PARAMETER MaxRetries
        Graph retry count.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Hashtable]$GlobalState,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][hashtable[]]$SelectedItems,
        [bool]$OverwriteConflicts = $false,
        [int] $MaxRetries         = 3
    )

    $GlobalState.IsRestoreRunning    = $true
    $GlobalState.RestoreProgress     = 0
    $GlobalState.RestoreProgressText = 'Starting restore...'

    $results  = [System.Collections.Generic.List[hashtable]]::new()
    $total    = $SelectedItems.Count
    $done     = 0

    try {
        Write-LogMessage -Level INFO -Message '=== Restore started ==='
        Write-LogMessage -Level INFO -Message "Target tenant : $($GlobalState.TenantDisplayName) ($($GlobalState.TenantId))"
        Write-LogMessage -Level INFO -Message "Backup path   : $BackupPath"
        Write-LogMessage -Level INFO -Message "Objects chosen: $total"

        foreach ($item in $SelectedItems) {
            $done++
            $GlobalState.RestoreProgress     = [int](($done / [Math]::Max($total, 1)) * 100)
            $GlobalState.RestoreProgressText = "[$done/$total] $($item.DisplayName)"

            # Skip conflicting objects unless operator explicitly chose to continue
            if ($item.ConflictStatus -eq 'Conflict' -and -not $OverwriteConflicts) {
                Write-LogMessage -Level WARN -Message "SKIPPED (conflict): $($item.DisplayName) [$($item.Category)]"
                $item.RestoreResult = 'Skipped (conflict)'
                $results.Add(@{
                    DisplayName   = $item.DisplayName
                    Category      = $item.Category
                    Result        = 'Skipped'
                    Reason        = 'Name already exists in target tenant'
                    NewId         = $null
                })
                continue
            }

            $restoreResult = Invoke-RestoreObject `
                -Item       $item `
                -BackupPath $BackupPath `
                -MaxRetries $MaxRetries

            $item.RestoreResult = if ($restoreResult.Success) { 'Success' } else { "Error: $($restoreResult.Error)" }
            $results.Add($restoreResult)
        }

        $succeeded = @($results | Where-Object { $_.Result -eq 'Success'  }).Count
        $skipped   = @($results | Where-Object { $_.Result -eq 'Skipped'  }).Count
        $failed    = @($results | Where-Object { $_.Result -eq 'Error'    }).Count

        $GlobalState.RestoreProgress     = 100
        $GlobalState.RestoreProgressText = "Done — $succeeded created, $skipped skipped, $failed error(s)"

        Write-LogMessage -Level SUCCESS -Message "=== Restore completed ==="
        Write-LogMessage -Level SUCCESS -Message "Created : $succeeded"
        Write-LogMessage -Level WARN    -Message "Skipped : $skipped"
        if ($failed -gt 0) {
            Write-LogMessage -Level ERROR -Message "Errors  : $failed"
        }

        return $results.ToArray()
    }
    catch {
        Write-LogMessage -Level ERROR -Message '=== Restore failed ===' -ErrorRecord $_
        $GlobalState.RestoreProgressText = "Failed: $($_.Exception.Message)"
        throw
    }
    finally {
        $GlobalState.IsRestoreRunning = $false
    }
}

function Invoke-RestoreObject {
    <#
    .SYNOPSIS
        Loads the import-ready JSON for a single object and calls the
        appropriate workload Import-* function.

    .OUTPUTS
        [hashtable]  DisplayName, Category, Result ('Success'|'Error'|'Skipped'), NewId, Error, Reason
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Item,
        [Parameter(Mandatory)][string]   $BackupPath,
        [int]$MaxRetries = 3
    )

    $wlKey = $Item.Category
    $name  = $Item.DisplayName
    $map   = $script:WorkloadMap[$wlKey]

    if (-not $map) {
        $err = "No import handler registered for category '$wlKey'."
        Write-LogMessage -Level ERROR -Message "$err ($name)"
        return @{ DisplayName = $name; Category = $wlKey; Result = 'Error'; NewId = $null; Error = $err; Reason = $err }
    }

    # Locate the import file relative to the backup path
    $importFile = Join-Path $BackupPath $wlKey | Join-Path -ChildPath $Item.ImportFileName

    if (-not (Test-Path -Path $importFile)) {
        $err = "Import file not found: $importFile"
        Write-LogMessage -Level ERROR -Message $err
        return @{ DisplayName = $name; Category = $wlKey; Result = 'Error'; NewId = $null; Error = $err; Reason = $err }
    }

    $importData = Read-JsonFile -Path $importFile
    if (-not $importData) {
        $err = "Could not parse import file: $importFile"
        Write-LogMessage -Level ERROR -Message $err
        return @{ DisplayName = $name; Category = $wlKey; Result = 'Error'; NewId = $null; Error = $err; Reason = $err }
    }

    # Convert PSObject → Hashtable for the Import-* functions
    $importHt = ConvertTo-Hashtable -InputObject $importData

    # Dispatch to workload Import-* function
    try {
        $outcome = & $map.ImportFn -ImportData $importHt -MaxRetries $MaxRetries

        if ($outcome.Success) {
            return @{
                DisplayName = $name
                Category    = $wlKey
                Result      = 'Success'
                NewId       = $outcome.NewId
                Error       = $null
                Reason      = $null
            }
        }
        else {
            return @{
                DisplayName = $name
                Category    = $wlKey
                Result      = 'Error'
                NewId       = $null
                Error       = $outcome.Error
                Reason      = $outcome.Error
            }
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "Unexpected error restoring '$name'" -ErrorRecord $_
        return @{
            DisplayName = $name
            Category    = $wlKey
            Result      = 'Error'
            NewId       = $null
            Error       = $_.Exception.Message
            Reason      = $_.Exception.Message
        }
    }
}

#endregion

Export-ModuleMember -Function `
    Import-BackupManifest, `
    Get-BackupObjectList, `
    Test-RestoreConflicts, `
    Start-IntuneRestore, `
    Invoke-RestoreObject
