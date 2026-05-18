<#
.SYNOPSIS
    Centralized assignment export and restore logic.

.DESCRIPTION
    Many Intune object types share the same assignment shape:
        {
            assignments: [
                {
                    target: {
                        "@odata.type": "#microsoft.graph.groupAssignmentTarget",
                        groupId: "<guid>"
                    },
                    [optional]: filter / intent / settings
                }
            ]
        }

    The endpoints differ per object type but the BODY structure is uniform
    enough to centralize. This module:

      - Exports assignments alongside the object (denormalized: group ids
        resolved to display names so restore in another tenant is feasible)
      - Resolves groups in the target tenant by displayName during restore
      - Soft-fails per assignment so a single broken target does not halt
        the rest of the restore.

.NOTES
    The /assign action endpoint expects a body with the wrapper key 'assignments'
    (NOT 'value'). Some workloads (e.g. mobileAppConfigurations) wrap the
    assignments in a different structure; Get-AssignmentRestoreBody handles
    those branches.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Per-workload assignment endpoint table
# ---------------------------------------------------------------------------
#
# Each entry: WorkloadKey -> @{
#   ListUriTemplate   = path appended to Get-GraphRoot output, with {id} placeholder.
#                       Used to GET assignments during export.
#   AssignAction      = path with {id} placeholder, used to POST /assign during restore.
#   BodyKey           = key in the POST body that wraps the assignments array.
#                       Most use 'assignments'; some legacy MAM endpoints differ.
#   SupportsAssign    = $false for objects whose assignment surface is not exposed
#                       (e.g. Autopilot profiles use a different model).
# }
$script:AssignmentMap = @{
    CompliancePolicies = @{
        ListUriTemplate = '/deviceManagement/deviceCompliancePolicies/{id}/assignments'
        AssignAction    = '/deviceManagement/deviceCompliancePolicies/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    ConfigProfiles = @{
        ListUriTemplate = '/deviceManagement/deviceConfigurations/{id}/assignments'
        AssignAction    = '/deviceManagement/deviceConfigurations/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    SettingsCatalog = @{
        ListUriTemplate = '/deviceManagement/configurationPolicies/{id}/assignments'
        AssignAction    = '/deviceManagement/configurationPolicies/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    EndpointSecurity = @{
        ListUriTemplate = '/deviceManagement/configurationPolicies/{id}/assignments'
        AssignAction    = '/deviceManagement/configurationPolicies/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    DeviceScripts = @{
        ListUriTemplate = '/deviceManagement/deviceManagementScripts/{id}/assignments'
        AssignAction    = '/deviceManagement/deviceManagementScripts/{id}/assign'
        # Per Graph schema this body uses 'deviceManagementScriptAssignments'
        BodyKey         = 'deviceManagementScriptAssignments'
        SupportsAssign  = $true
    }
    Autopilot = @{
        ListUriTemplate = '/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assignments'
        AssignAction    = '/deviceManagement/windowsAutopilotDeploymentProfiles/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    EnrollmentConfigurations = @{
        ListUriTemplate = '/deviceManagement/deviceEnrollmentConfigurations/{id}/assignments'
        AssignAction    = '/deviceManagement/deviceEnrollmentConfigurations/{id}/assign'
        BodyKey         = 'enrollmentConfigurationAssignments'
        SupportsAssign  = $true
    }
    AppProtection = @{
        # managedAppPolicies has a polymorphic /assign that varies per derived
        # type. Restoring assignments here is best-effort.
        ListUriTemplate = '/deviceAppManagement/managedAppPolicies/{id}/assignments'
        AssignAction    = '/deviceAppManagement/managedAppPolicies/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    AppConfiguration = @{
        ListUriTemplate = '/deviceAppManagement/mobileAppConfigurations/{id}/assignments'
        AssignAction    = '/deviceAppManagement/mobileAppConfigurations/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
    ProactiveRemediations = @{
        # deviceHealthScripts only exists on /beta
        ListUriTemplate = '/deviceManagement/deviceHealthScripts/{id}/assignments'
        AssignAction    = '/deviceManagement/deviceHealthScripts/{id}/assign'
        BodyKey         = 'deviceHealthScriptAssignments'
        SupportsAssign  = $true
    }
    AdministrativeTemplates = @{
        ListUriTemplate = '/deviceManagement/groupPolicyConfigurations/{id}/assignments'
        AssignAction    = '/deviceManagement/groupPolicyConfigurations/{id}/assign'
        BodyKey         = 'assignments'
        SupportsAssign  = $true
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Group lookup cache (per restore session)
# ---------------------------------------------------------------------------

# Lower-case displayName -> [object[]] of group entries (id, displayName)
# A single name may be ambiguous across multiple groups; we keep all matches
# and warn during restore.
$script:GroupCacheByName = $null

function Initialize-GroupCache {
    <#
    .SYNOPSIS
        Builds (or rebuilds) an in-memory map of all Entra ID groups in the
        target tenant, keyed by lower-case displayName. Used during restore
        to resolve assignment targets.

    .NOTES
        For very large tenants (>10k groups) this can take a few seconds; we
        only fetch id and displayName via $select to keep it fast.
    #>
    [CmdletBinding()]
    param(
        [int]$MaxRetries = 3
    )

    $cache = @{}
    try {
        Write-LogMessage -Level INFO -Message '[Assignments] Building group lookup cache...'
        $uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName,securityEnabled,mailEnabled&`$top=999"
        $groups = Get-GraphAllPages -Uri $uri -MaxRetries $MaxRetries

        foreach ($g in $groups) {
            if (-not $g.displayName) { continue }
            $key = $g.displayName.ToLowerInvariant()
            if (-not $cache.ContainsKey($key)) {
                $cache[$key] = [System.Collections.Generic.List[object]]::new()
            }
            $cache[$key].Add(@{
                Id              = $g.id
                DisplayName     = $g.displayName
                SecurityEnabled = [bool]$g.securityEnabled
                MailEnabled     = [bool]$g.mailEnabled
            })
        }
        Write-LogMessage -Level INFO -Message "[Assignments] Group cache: $($groups.Count) groups indexed."
    }
    catch {
        Write-LogMessage -Level WARN -Message "[Assignments] Group cache failed: $($_.Exception.Message). Assignment restore by displayName will not work."
    }
    $script:GroupCacheByName = $cache
}

function Resolve-GroupByName {
    <#
    .SYNOPSIS
        Returns the new tenant's group id matching the given source group
        displayName, or $null if not found / ambiguous.

    .OUTPUTS
        [hashtable]  Found, NewId, Reason
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$DisplayName
    )

    if ($null -eq $script:GroupCacheByName) {
        Initialize-GroupCache
    }
    if ($null -eq $script:GroupCacheByName) {
        return @{ Found = $false; NewId = $null; Reason = 'Group cache unavailable' }
    }

    $key = $DisplayName.ToLowerInvariant()
    if (-not $script:GroupCacheByName.ContainsKey($key)) {
        return @{ Found = $false; NewId = $null; Reason = "Group '$DisplayName' not found in target tenant" }
    }

    $matches = $script:GroupCacheByName[$key]
    if ($matches.Count -gt 1) {
        return @{
            Found  = $false
            NewId  = $null
            Reason = "Ambiguous: $($matches.Count) groups in target tenant share the displayName '$DisplayName'"
        }
    }
    return @{ Found = $true; NewId = $matches[0].Id; Reason = $null }
}

#endregion

# ---------------------------------------------------------------------------
#region Export
# ---------------------------------------------------------------------------

function Export-IntuneAssignments {
    <#
    .SYNOPSIS
        Exports assignments for a single backed-up object.

    .DESCRIPTION
        Writes a sidecar file '<base>.assignments.json' next to the object's
        raw JSON. Includes:
          - The raw assignment array as returned by Graph
          - A denormalized list with group displayNames resolved (for
            cross-tenant restore)

    .PARAMETER WorkloadKey
        Must match a key in $AssignmentMap.

    .PARAMETER ObjectId
        Source-tenant id of the object.

    .PARAMETER OutFileBase
        Full path WITHOUT extension. We append '.assignments.json'.

    .OUTPUTS
        [hashtable]  HasAssignments, AssignmentCount, FilePath
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$WorkloadKey,
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][string]$OutFileBase,
        [int]$MaxRetries = 3
    )

    $map = $script:AssignmentMap[$WorkloadKey]
    if (-not $map -or -not $map.SupportsAssign) {
        return @{ HasAssignments = $false; AssignmentCount = 0; FilePath = $null }
    }

    $root = Get-GraphRoot -WorkloadKey $WorkloadKey
    $uri  = $root + ($map.ListUriTemplate -replace '\{id\}', $ObjectId)

    $raw = $null
    try {
        $resp = Invoke-GraphRequestRetry -Method GET -Uri $uri -MaxRetries $MaxRetries
        $raw  = if ($resp.value) { $resp.value } else { @() }
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "[Assignments] Could not fetch assignments for $WorkloadKey/$ObjectId : $($_.Exception.Message)"
        return @{ HasAssignments = $false; AssignmentCount = 0; FilePath = $null }
    }

    if (-not $raw -or @($raw).Count -eq 0) {
        return @{ HasAssignments = $false; AssignmentCount = 0; FilePath = $null }
    }

    # Denormalize: resolve group displayNames (best-effort, only when cheap)
    $denormalized = foreach ($a in $raw) {
        $row = ConvertTo-Hashtable -InputObject $a
        if ($row.target -and $row.target.groupId) {
            $name = Get-GroupDisplayNameById -GroupId $row.target.groupId -MaxRetries $MaxRetries
            if ($name) { $row.target['_resolvedDisplayName'] = $name }
        }
        $row
    }

    $package = [ordered]@{
        ExportedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Workload     = $WorkloadKey
        ObjectId     = $ObjectId
        Endpoint     = $uri
        Raw          = $raw
        Denormalized = @($denormalized)
    }

    $file = "$OutFileBase.assignments.json"
    Save-JsonFile -Object $package -Path $file

    return @{
        HasAssignments  = $true
        AssignmentCount = @($raw).Count
        FilePath        = $file
    }
}

# Lightweight in-process cache for source-tenant group lookups during export.
$script:ExportGroupNameCache = @{}

function Get-GroupDisplayNameById {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [int]$MaxRetries = 3
    )

    if ($script:ExportGroupNameCache.ContainsKey($GroupId)) {
        return $script:ExportGroupNameCache[$GroupId]
    }

    try {
        $g = Invoke-GraphRequestRetry `
            -Method GET `
            -Uri    "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=displayName" `
            -MaxRetries $MaxRetries
        $name = $g.displayName
    }
    catch {
        $name = $null
    }
    $script:ExportGroupNameCache[$GroupId] = $name
    return $name
}

#endregion

# ---------------------------------------------------------------------------
#region Restore
# ---------------------------------------------------------------------------

function Import-IntuneAssignments {
    <#
    .SYNOPSIS
        Restores assignments for a single newly-created object.

    .DESCRIPTION
        Steps:
          1. Read the .assignments.json sidecar.
          2. For each entry:
               - groupAssignmentTarget   → resolve groupId by displayName.
               - allLicensedUsersAssignmentTarget / allDevicesAssignmentTarget
                 → keep as-is.
               - exclusionGroupAssignmentTarget → resolve like group.
          3. POST { assignments: [...] } to the workload's /assign action.
          4. Soft-fail per assignment: if a group cannot be resolved, log and
             skip that single assignment, then submit the remaining assignments.

    .PARAMETER NewObjectId
        Id of the freshly-created object in the TARGET tenant.

    .PARAMETER AssignmentsFilePath
        Full path to the .assignments.json sidecar.

    .OUTPUTS
        [hashtable]  Restored, Skipped, Errors, Details
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$WorkloadKey,
        [Parameter(Mandatory)][string]$NewObjectId,
        [Parameter(Mandatory)][string]$AssignmentsFilePath,
        [int]$MaxRetries = 3
    )

    $result = @{
        Restored = 0
        Skipped  = 0
        Errors   = 0
        Details  = [System.Collections.Generic.List[hashtable]]::new()
    }

    $map = $script:AssignmentMap[$WorkloadKey]
    if (-not $map -or -not $map.SupportsAssign) {
        Write-LogMessage -Level DEBUG -Message "[Assignments] Workload '$WorkloadKey' does not support assignment restore."
        return $result
    }

    if (-not (Test-Path $AssignmentsFilePath)) {
        return $result
    }

    $package = Read-JsonFile -Path $AssignmentsFilePath
    if (-not $package) { return $result }

    # Prefer denormalized form (has _resolvedDisplayName) over raw
    $entries = @()
    if ($package.Denormalized) { $entries = @($package.Denormalized) }
    elseif ($package.Raw)      { $entries = @($package.Raw) }
    if ($entries.Count -eq 0)  { return $result }

    Write-LogMessage -Level INFO -Message "[Assignments] Restoring $($entries.Count) assignment(s) for $WorkloadKey/$NewObjectId"

    $newAssignments = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($e in $entries) {
        $h = ConvertTo-Hashtable -InputObject $e
        $h.Remove('id')

        # Target shape: usually $h.target, but some legacy assignments have
        # a flat structure. Defensive: treat missing target as skip.
        if (-not $h.target) {
            $result.Skipped++
            $result.Details.Add(@{ Status='Skipped'; Reason='Assignment has no target' })
            continue
        }

        $tgt    = ConvertTo-Hashtable -InputObject $h.target
        $tgtType = [string]$tgt['@odata.type']

        switch -Wildcard ($tgtType) {
            '*allLicensedUsersAssignmentTarget' {
                # No resolution needed
                break
            }
            '*allDevicesAssignmentTarget' {
                break
            }
            '*groupAssignmentTarget' {
                $name = $tgt['_resolvedDisplayName']
                $resolution = $null
                if ($name) {
                    $resolution = Resolve-GroupByName -DisplayName $name
                }
                if (-not $resolution -or -not $resolution.Found) {
                    # Fall back to original groupId – may or may not exist
                    $oldId = $tgt['groupId']
                    Write-LogMessage -Level WARN -Message "[Assignments] Group '$name' could not be resolved in target tenant ($($resolution.Reason)). Skipping this assignment."
                    $result.Skipped++
                    $result.Details.Add(@{ Status='Skipped'; Reason=$resolution.Reason; OriginalGroupId=$oldId; OriginalGroupName=$name })
                    $tgt = $null
                }
                else {
                    $tgt['groupId'] = $resolution.NewId
                }
                break
            }
            '*exclusionGroupAssignmentTarget' {
                $name = $tgt['_resolvedDisplayName']
                $resolution = $null
                if ($name) { $resolution = Resolve-GroupByName -DisplayName $name }
                if (-not $resolution -or -not $resolution.Found) {
                    Write-LogMessage -Level WARN -Message "[Assignments] Exclusion group '$name' not resolvable. Skipping."
                    $result.Skipped++
                    $result.Details.Add(@{ Status='Skipped'; Reason=$resolution.Reason; OriginalGroupName=$name })
                    $tgt = $null
                }
                else {
                    $tgt['groupId'] = $resolution.NewId
                }
                break
            }
            default {
                # Unknown target type – pass through; Graph will reject if invalid
                break
            }
        }

        if ($null -eq $tgt) { continue }

        # Strip private resolution markers
        $tgt.Remove('_resolvedDisplayName')

        $h.target = $tgt
        $newAssignments.Add($h)
    }

    if ($newAssignments.Count -eq 0) {
        Write-LogMessage -Level WARN -Message "[Assignments] No usable assignments after group resolution for $NewObjectId."
        return $result
    }

    # Build POST body
    $body = @{}
    $body[$map.BodyKey] = @($newAssignments)

    $root = Get-GraphRoot -WorkloadKey $WorkloadKey
    $uri  = $root + ($map.AssignAction -replace '\{id\}', $NewObjectId)

    try {
        Invoke-GraphRequestRetry -Method POST -Uri $uri -Body $body -MaxRetries $MaxRetries | Out-Null
        $result.Restored = $newAssignments.Count
        Write-LogMessage -Level SUCCESS -Message "[Assignments] $($newAssignments.Count) assignment(s) created for $NewObjectId"
    }
    catch {
        $result.Errors = $newAssignments.Count
        Write-LogMessage -Level ERROR -Message "[Assignments] /assign failed for $WorkloadKey/$NewObjectId : $($_.Exception.Message)"
        $result.Details.Add(@{ Status='Error'; Reason=$_.Exception.Message })
    }

    return $result
}

#endregion

Export-ModuleMember -Function `
    Initialize-GroupCache, `
    Resolve-GroupByName, `
    Export-IntuneAssignments, `
    Import-IntuneAssignments
