<#
.SYNOPSIS
    Microsoft Graph connection management for the Intune Backup & Restore Tool.

.DESCRIPTION
    Handles interactive authentication, tenant switching, live connection
    verification and tenant information retrieval.

    All Intune REST calls elsewhere in the tool go through Invoke-MgGraphRequest,
    which reuses the static token context established by Connect-MgGraph.

.NOTES
    Required PowerShell module: Microsoft.Graph.Authentication (>= 2.0.0)
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Required Graph scopes
# ---------------------------------------------------------------------------

$script:RequiredScopes = @(
    [PSCustomObject]@{
        Scope       = 'Organization.Read.All'
        Purpose     = 'Read tenant display name and tenant ID'
        RequiredFor = 'Connection info'
    }
    [PSCustomObject]@{
        Scope       = 'DeviceManagementConfiguration.Read.All'
        Purpose     = 'Read configuration policies, settings catalog, endpoint security'
        RequiredFor = 'Backup (all policy workloads)'
    }
    [PSCustomObject]@{
        Scope       = 'DeviceManagementConfiguration.ReadWrite.All'
        Purpose     = 'Create configuration policies / settings catalog / endpoint security'
        RequiredFor = 'Restore (all policy workloads)'
    }
    [PSCustomObject]@{
        Scope       = 'DeviceManagementApps.Read.All'
        Purpose     = 'Read application + compliance-related contexts'
        RequiredFor = 'Compliance policies'
    }
    [PSCustomObject]@{
        Scope       = 'DeviceManagementManagedDevices.Read.All'
        Purpose     = 'Read managed device context (some policy APIs require this)'
        RequiredFor = 'Backup context'
    }
    [PSCustomObject]@{
        Scope       = 'Group.Read.All'
        Purpose     = 'Resolve group display names for assignment documentation'
        RequiredFor = 'Assignment export (documentation only)'
    }
)

#endregion

# ---------------------------------------------------------------------------
#region Public functions
# ---------------------------------------------------------------------------

function Get-RequiredGraphScopes {
    <#
    .SYNOPSIS
        Returns the list of Graph scopes the tool requests.
        Used by the Connection tab for display.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return $script:RequiredScopes
}

function Connect-IntuneTenant {
    <#
    .SYNOPSIS
        Opens an interactive Connect-MgGraph session.
        Supports explicit tenant selection for multi-tenant admins.

    .PARAMETER TenantId
        Optional tenant GUID or verified domain (e.g. 'contoso.onmicrosoft.com').
        If omitted, the user's default tenant is used.

    .OUTPUTS
        [hashtable]
            TenantDisplayName
            TenantId
            ConnectedUser
            ConnectionTime   (DateTime)
            Scopes           (string[])
        Throws on authentication failure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$TenantId
    )

    Write-LogMessage -Level INFO -Message 'Initiating Microsoft Graph authentication...'

    # Ensure the required module is available
    if (-not (Get-Module -Name 'Microsoft.Graph.Authentication' -ListAvailable)) {
        throw "Microsoft.Graph.Authentication is not installed. Please run the prerequisites check first."
    }
    if (-not (Get-Module -Name 'Microsoft.Graph.Authentication')) {
        Write-LogMessage -Level DEBUG -Message 'Importing Microsoft.Graph.Authentication...'
        Import-Module -Name 'Microsoft.Graph.Authentication' -ErrorAction Stop
    }

    $scopeList = $script:RequiredScopes.Scope

    # Disconnect any stale session first (ignore errors)
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }

    $connectParams = @{
        Scopes      = $scopeList
        NoWelcome   = $true
        ErrorAction = 'Stop'
    }
    if ($TenantId) {
        $connectParams['TenantId'] = $TenantId
        Write-LogMessage -Level INFO -Message "Connecting to tenant: $TenantId"
    }

    Write-LogMessage -Level INFO -Message "Requested scopes: $($scopeList -join ', ')"
    Write-LogMessage -Level INFO -Message 'Opening browser for interactive authentication...'

    Connect-MgGraph @connectParams | Out-Null

    $context = Get-MgContext
    if (-not $context) {
        throw 'Connect-MgGraph completed but Get-MgContext returned null.'
    }

    # Fetch tenant metadata
    $tenant = Get-IntuneTenantInformation

    $result = @{
        TenantDisplayName = $tenant.TenantDisplayName
        TenantId          = $tenant.TenantId
        ConnectedUser     = $context.Account
        ConnectionTime    = Get-Date
        Scopes            = @($context.Scopes)
    }

    Write-LogMessage -Level SUCCESS -Message "Connected to tenant: $($result.TenantDisplayName) ($($result.TenantId))"
    Write-LogMessage -Level SUCCESS -Message "Signed in as     : $($result.ConnectedUser)"
    return $result
}

function Disconnect-IntuneTenant {
    <#
    .SYNOPSIS
        Tears down the current Graph session cleanly.
    .OUTPUTS
        [bool] $true on success, $false if no session was active or an error occurred.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Write-LogMessage -Level INFO -Message 'Disconnecting from Microsoft Graph...'

    try {
        if (Get-Module -Name 'Microsoft.Graph.Authentication') {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        Write-LogMessage -Level SUCCESS -Message 'Disconnected from Microsoft Graph.'
        return $true
    }
    catch {
        Write-LogMessage -Level WARN -Message "Disconnect returned an error (may already be disconnected): $($_.Exception.Message)"
        return $false
    }
}

function Test-IntuneConnection {
    <#
    .SYNOPSIS
        Live connection check.
        Verifies both the local context and that a lightweight Graph call
        returns successfully (token still valid, network reachable).

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        if (-not (Get-Module -Name 'Microsoft.Graph.Authentication')) {
            return $false
        }

        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $ctx -or [string]::IsNullOrEmpty($ctx.TenantId)) {
            return $false
        }

        # Minimal live probe – /me is cheap and works for delegated auth.
        Invoke-MgGraphRequest `
            -Method GET `
            -Uri    'https://graph.microsoft.com/v1.0/me?$select=id' `
            -OutputType PSObject `
            -ErrorAction Stop | Out-Null

        return $true
    }
    catch {
        Write-LogMessage -Level DEBUG -Message "Connection test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-IntuneTenantInformation {
    <#
    .SYNOPSIS
        Retrieves the tenant display name and ID from /organization.

    .OUTPUTS
        [hashtable]
            TenantDisplayName
            TenantId
            VerifiedDomains (string[])
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    try {
        $response = Invoke-MgGraphRequest `
            -Method     GET `
            -Uri        'https://graph.microsoft.com/v1.0/organization?$select=displayName,id,verifiedDomains' `
            -OutputType PSObject `
            -ErrorAction Stop

        $org = if ($response.value -and $response.value.Count -gt 0) { $response.value[0] }
               else { $response }

        $domains = @()
        if ($org.verifiedDomains) {
            $domains = $org.verifiedDomains | ForEach-Object { $_.name }
        }

        return @{
            TenantDisplayName = $org.displayName
            TenantId          = $org.id
            VerifiedDomains   = $domains
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message 'Failed to retrieve tenant information' -ErrorRecord $_

        # Fallback from MgContext when /organization fails
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        return @{
            TenantDisplayName = 'Unknown'
            TenantId          = if ($ctx) { $ctx.TenantId } else { 'Unknown' }
            VerifiedDomains   = @()
        }
    }
}

#endregion

Export-ModuleMember -Function `
    Get-RequiredGraphScopes, `
    Connect-IntuneTenant, `
    Disconnect-IntuneTenant, `
    Test-IntuneConnection, `
    Get-IntuneTenantInformation
