<#
.SYNOPSIS
    Restore orchestration for the Intune Backup & Restore Tool.

.DESCRIPTION
    Provides a guided, safe restore flow:

      1.  Import-BackupManifest     – validate and load manifest.json + index.json
      2.  Get-BackupObjectList      – flatten index.json for the GUI grid
      3.  Test-RestoreConflicts     – compare backup objects against target tenant
      4.  Start-IntuneRestore       – restore selected objects, one by one
      5.  Invoke-RestoreObject      – dispatch to the workload Import-* function

    Conflict handling:
      The operator selects a ConflictMode in the Settings tab or the Restore tab:
        * Skip            (default)  – conflicting objects are not restored.
        * CreateDuplicate            – append " (restored YYYY-MM-DD HH:mm)" to the
                                       displayName/name and POST as new.
        * UpdateExisting             – PATCH the existing object with the import
                                       payload. Only allowed for workloads with
                                       SupportsUpdate = $true; otherwise degrades
                                       to Skip with a warning.

    Dry-run mode:
      When -DryRun is set, no Graph write calls are made. Each item is validated
      (payload size, presence of required fields, conflict status, endpoint
      version) and the result is written to Logs/restore-dryrun-<timestamp>.json
      in the backup folder.

    Assignments:
      When -RestoreAssignments is true and a sidecar <name>.assignments.json
      exists, AssignmentEngine::Import-IntuneAssignments is called after the
      object is created. Failures are logged per assignment.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Workload dispatch table
# ---------------------------------------------------------------------------

# Each entry:
#   ImportFn         – name of Import-* function (creates a new object)
#   UpdateFn         – name of Update-* function (PATCHes an existing object), or $null
#   ConflictFn       – name of Get-Existing* function (returns lower-case name -> id map)
#   NameField        – key in import JSON used as the displayName for conflict tests
#   SupportsUpdate   – $true if UpdateExisting is implemented
#   SubFolder        – folder name where the .import.json lives, relative to backup root
$script:WorkloadMap = @{
    CompliancePolicies = @{
        ImportFn       = 'Import-CompliancePolicy'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingCompliancePolicies'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'CompliancePolicies'
    }
    ConfigProfiles = @{
        ImportFn       = 'Import-ConfigProfile'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingConfigProfiles'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'ConfigProfiles'
    }
    SettingsCatalog = @{
        ImportFn       = 'Import-SettingsCatalogPolicy'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingSettingsCatalogPolicies'
        NameField      = 'name'
        SupportsUpdate = $false
        SubFolder      = 'SettingsCatalog'
    }
    EndpointSecurity = @{
        ImportFn       = 'Import-EndpointSecurityPolicy'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingEndpointSecurityPolicies'
        NameField      = 'name'
        SupportsUpdate = $false
        SubFolder      = 'EndpointSecurity'
    }
    DeviceScripts = @{
        ImportFn       = 'Import-DeviceScript'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingDeviceScripts'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'DeviceScripts'
    }
    Autopilot = @{
        ImportFn       = 'Import-AutopilotProfile'
        UpdateFn       = 'Update-AutopilotProfile'
        ConflictFn     = 'Get-ExistingAutopilotProfiles'
        NameField      = 'displayName'
        SupportsUpdate = $true
        SubFolder      = 'Autopilot'
    }
    EnrollmentConfigurations = @{
        ImportFn       = 'Import-EnrollmentConfiguration'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingEnrollmentConfigurations'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'EnrollmentConfigurations'
    }
    AppProtection = @{
        ImportFn       = 'Import-AppProtectionPolicy'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingAppProtectionPolicies'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'AppProtection'
    }
    AppConfiguration = @{
        ImportFn       = 'Import-AppConfiguration'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingAppConfigurations'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'AppConfiguration'
    }
    ProactiveRemediations = @{
        ImportFn       = 'Import-ProactiveRemediation'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingProactiveRemediations'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'ProactiveRemediations'
    }
    AdministrativeTemplates = @{
        ImportFn       = 'Import-AdministrativeTemplate'
        UpdateFn       = $null
        ConflictFn     = 'Get-ExistingAdministrativeTemplates'
        NameField      = 'displayName'
        SupportsUpdate = $false
        SubFolder      = 'AdministrativeTemplates'
    }
}

function Get-WorkloadMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:WorkloadMap
}

#endregion

# ---------------------------------------------------------------------------
#region Manifest / index loading
# ---------------------------------------------------------------------------

function Import-BackupManifest {
    <#
    .SYNOPSIS
        Loads and validates a backup folder. Returns structured data for
        the Restore tab to display.
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
        $result.Error = 'manifest.json could not be parsed.'
        return $result
    }

    if ($manifest.Status -ne 'Completed') {
        $result.Error = "Backup status is '$($manifest.Status)' (not 'Completed'). This backup may be incomplete."
        # Still return data – GUI can warn the user and let them proceed.
    }

    $index = $null
    if (Test-Path -Path $indexFile) {
        $index = Read-JsonFile -Path $indexFile
    }
    else {
        Write-LogMessage -Level WARN -Message 'index.json not found; object list will be empty.'
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
        Returns a flat list of backup objects from the loaded index.

    .OUTPUTS
        [hashtable[]]
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
            IsSelected      = $true
            DisplayName     = $obj.DisplayName
            SourceId        = $obj.SourceId
            Category        = $obj.Category
            CategoryLabel   = if ($obj.CategoryLabel) { $obj.CategoryLabel } else { $obj.Category }
            ODataType       = $obj.ODataType
            ImportFileName  = $obj.ImportFileName
            FileName        = $obj.FileName
            EndpointVersion = if ($obj.PSObject.Properties['EndpointVersion']) { $obj.EndpointVersion } else { 'v1.0' }
            HasAssignments  = if ($obj.PSObject.Properties['HasAssignments']) { [bool]$obj.HasAssignments } else { $false }
            RestoreWarning  = if ($obj.PSObject.Properties['RestoreWarning']) { $obj.RestoreWarning } else { $null }
            ConflictStatus  = 'Unknown'    # populated by Test-RestoreConflicts
            DryRunResult    = $null
            RestoreResult   = $null
            ExistingId      = $null        # populated when ConflictStatus = Conflict
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
        tenant and sets ConflictStatus + ExistingId on each row.

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

    Write-LogMessage -Level INFO -Message 'Checking conflicts in target tenant...'

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

    foreach ($item in $RestoreItems) {
        $wlKey    = $item.Category
        $existing = $existingByWorkload[$wlKey]
        $name     = if ($item.DisplayName) { $item.DisplayName } else { '' }
        $nameLow  = $name.ToLowerInvariant()

        if ($existing -and $existing.ContainsKey($nameLow)) {
            $item.ConflictStatus = 'Conflict'
            $item.ExistingId     = $existing[$nameLow]
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
#region Restore orchestrator
# ---------------------------------------------------------------------------

function Start-IntuneRestore {
    <#
    .SYNOPSIS
        Restores selected objects from a backup into the current tenant.
        Intended to run in a background runspace.

    .PARAMETER ConflictMode
        Skip | CreateDuplicate | UpdateExisting

    .PARAMETER DryRun
        Validate only; do not write to Graph.

    .PARAMETER RestoreAssignments
        If $true and an *.assignments.json sidecar exists for the object,
        attempt to recreate assignments after the object is created.

    .OUTPUTS
        [hashtable[]] per-item results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Hashtable]$GlobalState,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][hashtable[]]$SelectedItems,
        [ValidateSet('Skip','CreateDuplicate','UpdateExisting')]
        [string]$ConflictMode = 'Skip',
        [bool]$DryRun = $false,
        [bool]$RestoreAssignments = $false,
        [int] $MaxRetries = 3
    )

    $GlobalState.IsRestoreRunning    = $true
    $GlobalState.RestoreProgress     = 0
    $GlobalState.RestoreProgressText = if ($DryRun) { 'Dry run starting...' } else { 'Starting restore...' }

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $total   = $SelectedItems.Count
    $done    = 0

    # Build group cache once if any item will need assignment restore
    if ($RestoreAssignments -and -not $DryRun) {
        try { Initialize-GroupCache -MaxRetries $MaxRetries } catch {
            Write-LogMessage -Level WARN -Message "Group cache init failed: $($_.Exception.Message)"
        }
    }

    try {
        $modeLabel = if ($DryRun) { '[DRY RUN] ' } else { '' }
        Write-LogMessage -Level INFO -Message "=== ${modeLabel}Restore started ==="
        Write-LogMessage -Level INFO -Message "Target tenant      : $($GlobalState.TenantDisplayName) ($($GlobalState.TenantId))"
        Write-LogMessage -Level INFO -Message "Backup path        : $BackupPath"
        Write-LogMessage -Level INFO -Message "Conflict mode      : $ConflictMode"
        Write-LogMessage -Level INFO -Message "Restore assignments: $RestoreAssignments"
        Write-LogMessage -Level INFO -Message "Objects chosen     : $total"

        foreach ($item in $SelectedItems) {
            $done++
            $GlobalState.RestoreProgress     = [int](($done / [Math]::Max($total, 1)) * 100)
            $GlobalState.RestoreProgressText = "[$done/$total] $($item.DisplayName)"

            $r = Invoke-RestoreObject `
                -Item               $item `
                -BackupPath         $BackupPath `
                -ConflictMode       $ConflictMode `
                -DryRun             $DryRun `
                -RestoreAssignments $RestoreAssignments `
                -MaxRetries         $MaxRetries

            $item.RestoreResult = $r.Result
            $results.Add($r)
        }

        $succeeded = @($results | Where-Object { $_.Result -eq 'Success'  }).Count
        $skipped   = @($results | Where-Object { $_.Result -eq 'Skipped'  }).Count
        $updated   = @($results | Where-Object { $_.Result -eq 'Updated'  }).Count
        $duplicated = @($results | Where-Object { $_.Result -eq 'Duplicated' }).Count
        $dryRunOK  = @($results | Where-Object { $_.Result -eq 'DryRunOk' }).Count
        $dryFail   = @($results | Where-Object { $_.Result -eq 'DryRunFail' }).Count
        $failed    = @($results | Where-Object { $_.Result -eq 'Error'    }).Count

        $GlobalState.RestoreProgress     = 100
        if ($DryRun) {
            $GlobalState.RestoreProgressText = "Dry run done — OK: $dryRunOK, Issues: $dryFail"
            Write-LogMessage -Level SUCCESS -Message '=== Dry run completed ==='
            Write-LogMessage -Level INFO -Message "Validated OK : $dryRunOK"
            if ($dryFail -gt 0) {
                Write-LogMessage -Level WARN -Message "Issues found : $dryFail"
            }

            $reportPath = Join-Path $BackupPath ('Logs/restore-dryrun-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + '.json')
            try {
                if (-not (Test-Path (Split-Path $reportPath))) {
                    New-Item -ItemType Directory -Path (Split-Path $reportPath) -Force | Out-Null
                }
                Save-JsonFile -Object @{
                    GeneratedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                    Tenant        = "$($GlobalState.TenantDisplayName) / $($GlobalState.TenantId)"
                    ConflictMode  = $ConflictMode
                    Items         = $results.ToArray()
                } -Path $reportPath
                Write-LogMessage -Level INFO -Message "Dry-run report: $reportPath"
            } catch {
                Write-LogMessage -Level WARN -Message "Could not write dry-run report: $($_.Exception.Message)"
            }
        }
        else {
            $GlobalState.RestoreProgressText = "Done — Created:$succeeded Updated:$updated Duplicated:$duplicated Skipped:$skipped Errors:$failed"
            Write-LogMessage -Level SUCCESS -Message '=== Restore completed ==='
            Write-LogMessage -Level SUCCESS -Message "Created   : $succeeded"
            if ($updated    -gt 0) { Write-LogMessage -Level SUCCESS -Message "Updated   : $updated"    }
            if ($duplicated -gt 0) { Write-LogMessage -Level SUCCESS -Message "Duplicated: $duplicated" }
            Write-LogMessage -Level WARN    -Message "Skipped   : $skipped"
            if ($failed -gt 0) { Write-LogMessage -Level ERROR -Message "Errors    : $failed" }
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
        Restores a single object honoring ConflictMode and DryRun.

    .OUTPUTS
        [hashtable] DisplayName, Category, Result, NewId, Error, Reason,
                    AssignmentResult (when RestoreAssignments and successful)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Item,
        [Parameter(Mandatory)][string]   $BackupPath,
        [ValidateSet('Skip','CreateDuplicate','UpdateExisting')]
        [string]$ConflictMode = 'Skip',
        [bool]$DryRun = $false,
        [bool]$RestoreAssignments = $false,
        [int]$MaxRetries = 3
    )

    $wlKey = $Item.Category
    $name  = $Item.DisplayName
    $map   = $script:WorkloadMap[$wlKey]

    if (-not $map) {
        $err = "No import handler registered for category '$wlKey'."
        Write-LogMessage -Level ERROR -Message "$err ($name)"
        return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$err; Reason=$err }
    }

    # Locate the import file relative to the backup path
    $importFile = Join-Path $BackupPath $map.SubFolder | Join-Path -ChildPath $Item.ImportFileName

    if (-not (Test-Path -Path $importFile)) {
        $err = "Import file not found: $importFile"
        Write-LogMessage -Level ERROR -Message $err
        return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$err; Reason=$err }
    }

    $importData = Read-JsonFile -Path $importFile
    if (-not $importData) {
        $err = "Could not parse import file: $importFile"
        Write-LogMessage -Level ERROR -Message $err
        return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$err; Reason=$err }
    }

    $importHt = ConvertTo-Hashtable -InputObject $importData

    # ---------- DRY RUN ----------
    if ($DryRun) {
        $issues = [System.Collections.Generic.List[string]]::new()
        if (-not $importHt[$map.NameField]) {
            $issues.Add("Missing required field '$($map.NameField)'.")
        }
        if ($Item.RestoreWarning) {
            $issues.Add("Workload warning: $($Item.RestoreWarning)")
        }
        if ($Item.ConflictStatus -eq 'Conflict' -and $ConflictMode -eq 'Skip') {
            $issues.Add('Would be SKIPPED (conflict + ConflictMode=Skip).')
        }
        if ($ConflictMode -eq 'UpdateExisting' -and -not $map.SupportsUpdate) {
            $issues.Add("Workload does not support UpdateExisting; would degrade to Skip.")
        }

        # Payload size sanity
        $payloadBytes = [System.Text.Encoding]::UTF8.GetByteCount(($importHt | ConvertTo-Json -Depth 20 -Compress))
        $action = switch ($ConflictMode) {
            'Skip'            { if ($Item.ConflictStatus -eq 'Conflict') { 'WouldSkip' }       else { 'WouldCreate' } }
            'CreateDuplicate' { if ($Item.ConflictStatus -eq 'Conflict') { 'WouldDuplicate' }  else { 'WouldCreate' } }
            'UpdateExisting'  { if ($Item.ConflictStatus -eq 'Conflict' -and $map.SupportsUpdate) { 'WouldUpdate' }
                                elseif ($Item.ConflictStatus -eq 'Conflict') { 'WouldSkip' }
                                else { 'WouldCreate' } }
        }
        $resultLabel = if ($issues.Count -eq 0) { 'DryRunOk' } else { 'DryRunFail' }
        Write-LogMessage -Level INFO -Message "[DryRun][$wlKey] $name -> $action ($($issues.Count) issue(s), $payloadBytes bytes)"

        $Item.DryRunResult = "$action ($resultLabel)"
        return @{
            DisplayName    = $name
            Category       = $wlKey
            Result         = $resultLabel
            NewId          = $null
            Action         = $action
            PayloadBytes   = $payloadBytes
            Issues         = $issues.ToArray()
            ConflictStatus = $Item.ConflictStatus
            EndpointVersion = $Item.EndpointVersion
        }
    }

    # ---------- REAL RESTORE ----------
    $isConflict = ($Item.ConflictStatus -eq 'Conflict')

    if ($isConflict) {
        switch ($ConflictMode) {
            'Skip' {
                Write-LogMessage -Level WARN -Message "SKIPPED (conflict, mode=Skip): $name [$wlKey]"
                return @{ DisplayName=$name; Category=$wlKey; Result='Skipped'; NewId=$null; Reason='Name already exists, ConflictMode=Skip' }
            }
            'CreateDuplicate' {
                $suffix = ' (restored ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ')'
                if ($importHt[$map.NameField]) {
                    $importHt[$map.NameField] = "$($importHt[$map.NameField])$suffix"
                }
                Write-LogMessage -Level INFO -Message "DUPLICATE: '$name' -> '$($importHt[$map.NameField])'"
            }
            'UpdateExisting' {
                if (-not $map.SupportsUpdate -or -not $map.UpdateFn) {
                    Write-LogMessage -Level WARN -Message "UpdateExisting not supported for $wlKey; degrading to Skip for '$name'."
                    return @{ DisplayName=$name; Category=$wlKey; Result='Skipped'; NewId=$null; Reason="UpdateExisting unsupported for $wlKey" }
                }
                # PATCH path
                try {
                    $upd = & $map.UpdateFn -ImportData $importHt -ExistingId $Item.ExistingId -MaxRetries $MaxRetries
                    if ($upd.Success) {
                        $aResult = $null
                        if ($RestoreAssignments) {
                            $aResult = _RestoreAssignments -Item $Item -NewObjectId $upd.NewId -BackupPath $BackupPath -MaxRetries $MaxRetries
                        }
                        return @{ DisplayName=$name; Category=$wlKey; Result='Updated'; NewId=$upd.NewId; Error=$null; AssignmentResult=$aResult }
                    }
                    return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$upd.Error; Reason=$upd.Error }
                }
                catch {
                    Write-LogMessage -Level ERROR -Message "Unexpected update error '$name': $($_.Exception.Message)"
                    return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$_.Exception.Message }
                }
            }
        }
    }

    # POST path (no conflict, or duplicate)
    try {
        $outcome = & $map.ImportFn -ImportData $importHt -MaxRetries $MaxRetries
        if (-not $outcome.Success) {
            return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$outcome.Error; Reason=$outcome.Error }
        }

        $resultLabel = if ($isConflict -and $ConflictMode -eq 'CreateDuplicate') { 'Duplicated' } else { 'Success' }

        $aResult = $null
        if ($RestoreAssignments) {
            $aResult = _RestoreAssignments -Item $Item -NewObjectId $outcome.NewId -BackupPath $BackupPath -MaxRetries $MaxRetries
        }

        return @{
            DisplayName     = $name
            Category        = $wlKey
            Result          = $resultLabel
            NewId           = $outcome.NewId
            Error           = $null
            AssignmentResult = $aResult
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "Unexpected error restoring '$name'" -ErrorRecord $_
        return @{ DisplayName=$name; Category=$wlKey; Result='Error'; NewId=$null; Error=$_.Exception.Message; Reason=$_.Exception.Message }
    }
}

function _RestoreAssignments {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Item,
        [Parameter(Mandatory)][string]$NewObjectId,
        [Parameter(Mandatory)][string]$BackupPath,
        [int]$MaxRetries = 3
    )

    $map = $script:WorkloadMap[$Item.Category]
    if (-not $map) { return $null }

    # The assignment sidecar is base + ".assignments.json"
    $importFileName = $Item.ImportFileName
    if ($importFileName -match '\.import\.json$') {
        $base = $importFileName -replace '\.import\.json$', ''
    }
    else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($importFileName)
    }
    $sidecar = Join-Path $BackupPath $map.SubFolder | Join-Path -ChildPath "$base.assignments.json"

    if (-not (Test-Path $sidecar)) {
        return @{ Restored=0; Skipped=0; Errors=0; Note='No assignments sidecar found.' }
    }

    return Import-IntuneAssignments `
        -WorkloadKey         $Item.Category `
        -NewObjectId         $NewObjectId `
        -AssignmentsFilePath $sidecar `
        -MaxRetries          $MaxRetries
}

#endregion

Export-ModuleMember -Function `
    Get-WorkloadMap, `
    Import-BackupManifest, `
    Get-BackupObjectList, `
    Test-RestoreConflicts, `
    Start-IntuneRestore, `
    Invoke-RestoreObject
