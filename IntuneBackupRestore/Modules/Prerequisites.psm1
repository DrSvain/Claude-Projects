<#
.SYNOPSIS
    Module and dependency checks for the Intune Backup & Restore Tool.

.DESCRIPTION
    - Get-RequiredModuleSpec  : Returns the required-module manifest.
    - Test-Prerequisites      : Evaluates installed vs. required versions.
                                Returns status rows suitable for a DataGrid.
    - Get-MissingModules      : Filters Test-Prerequisites for action needed.
    - Install-ModuleConfirmed : Installs a single module. Requires -Confirmed
                                so the GUI is forced to collect consent first.
    - Get-PSEnvironmentInfo   : PowerShell + OS information for the GUI.

    IMPORTANT
        This module MUST NOT install anything implicitly.
        The GUI layer displays the list of missing modules, asks the user,
        and only then calls Install-ModuleConfirmed -Confirmed.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
#region Required-module manifest
# ---------------------------------------------------------------------------

$script:RequiredModules = @(
    [PSCustomObject]@{
        Name         = 'Microsoft.Graph.Authentication'
        MinVersion   = '2.0.0'
        Required     = $true
        Purpose      = 'Interactive auth + Invoke-MgGraphRequest for all Intune calls'
        InstallScope = 'CurrentUser'
    }
)

# Optional modules – surfaced in the UI but never block operation.
$script:OptionalModules = @()

#endregion

# ---------------------------------------------------------------------------
#region Public functions
# ---------------------------------------------------------------------------

function Get-RequiredModuleSpec {
    <#
    .SYNOPSIS
        Returns the combined list of required + optional modules.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    return @($script:RequiredModules + $script:OptionalModules)
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Evaluates installed module versions against the manifest.

    .OUTPUTS
        [hashtable[]]
            Name             - Module name
            Required         - 'Yes' / 'No'
            MinVersion       - required minimum
            InstalledVersion - highest installed or '-'
            Status           - OK | Outdated | Missing | Error
            Purpose          - human text
            InstallScope     - CurrentUser / AllUsers
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    Write-LogMessage -Level INFO -Message 'Checking prerequisites...'

    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($spec in (Get-RequiredModuleSpec)) {

        $row = @{
            Name             = $spec.Name
            Required         = if ($spec.Required) { 'Yes' } else { 'No' }
            MinVersion       = $spec.MinVersion
            InstalledVersion = '-'
            Status           = 'Missing'
            Purpose          = $spec.Purpose
            InstallScope     = $spec.InstallScope
        }

        try {
            $installed = Get-Module -Name $spec.Name -ListAvailable -ErrorAction SilentlyContinue |
                         Sort-Object -Property Version -Descending |
                         Select-Object -First 1

            if ($installed) {
                $row.InstalledVersion = $installed.Version.ToString()

                if ([System.Version]$installed.Version -ge [System.Version]$spec.MinVersion) {
                    $row.Status = 'OK'
                    Write-LogMessage -Level DEBUG -Message "Module OK : $($spec.Name) v$($installed.Version)"
                }
                else {
                    $row.Status = 'Outdated'
                    Write-LogMessage -Level WARN  -Message "Module outdated: $($spec.Name) v$($installed.Version) (required v$($spec.MinVersion))"
                }
            }
            else {
                $level = if ($spec.Required) { 'WARN' } else { 'INFO' }
                Write-LogMessage -Level $level -Message "Module missing: $($spec.Name)"
            }
        }
        catch {
            $row.Status = 'Error'
            Write-LogMessage -Level ERROR -Message "Prerequisite check failed for $($spec.Name)" -ErrorRecord $_
        }

        $results.Add($row)
    }

    $problems = @($results | Where-Object { $_.Required -eq 'Yes' -and $_.Status -ne 'OK' })
    if ($problems.Count -gt 0) {
        Write-LogMessage -Level WARN    -Message "$($problems.Count) required module(s) need attention"
    }
    else {
        Write-LogMessage -Level SUCCESS -Message 'All required modules satisfied'
    }

    return $results.ToArray()
}

function Get-MissingModules {
    <#
    .SYNOPSIS
        Returns only the required modules that are missing, outdated or errored.
        The GUI passes these to the confirmation dialog.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    $all = Test-Prerequisites
    return @($all | Where-Object { $_.Required -eq 'Yes' -and $_.Status -in 'Missing','Outdated','Error' })
}

function Install-ModuleConfirmed {
    <#
    .SYNOPSIS
        Installs a single module from PSGallery.
        Installation ONLY proceeds when -Confirmed is passed explicitly,
        ensuring the GUI has collected consent.

    .PARAMETER Name
        Module name.

    .PARAMETER MinVersion
        Minimum version required.

    .PARAMETER Scope
        'CurrentUser' (default) or 'AllUsers' (needs elevation).

    .PARAMETER Confirmed
        Switch that must be passed by the caller after user approval.

    .OUTPUTS
        [hashtable] Success / Version / Error
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinVersion = $null,

        [ValidateSet('CurrentUser', 'AllUsers')]
        [string]$Scope = 'CurrentUser',

        [Parameter(Mandatory)]
        [switch]$Confirmed
    )

    if (-not $Confirmed) {
        # Belt-and-braces – parameter is [Mandatory] but guard anyway.
        throw "Install-ModuleConfirmed requires -Confirmed. The GUI must obtain user consent first."
    }

    Write-LogMessage -Level INFO -Message "Installing module '$Name' (Scope=$Scope)..."

    try {
        $params = @{
            Name         = $Name
            Scope        = $Scope
            Force        = $true
            AllowClobber = $true
            Repository   = 'PSGallery'
            ErrorAction  = 'Stop'
        }
        if ($MinVersion) { $params['MinimumVersion'] = $MinVersion }

        Install-Module @params

        $installed = Get-Module -Name $Name -ListAvailable |
                     Sort-Object -Property Version -Descending |
                     Select-Object -First 1

        if (-not $installed) {
            throw "Installation reported success but module not found in Get-Module -ListAvailable."
        }

        Write-LogMessage -Level SUCCESS -Message "Installed: $Name v$($installed.Version)"
        return @{
            Success = $true
            Version = $installed.Version.ToString()
            Error   = $null
        }
    }
    catch {
        Write-LogMessage -Level ERROR -Message "Failed to install '$Name'" -ErrorRecord $_
        return @{
            Success = $false
            Version = $null
            Error   = $_.Exception.Message
        }
    }
}

function Get-PSEnvironmentInfo {
    <#
    .SYNOPSIS
        Gathers PowerShell + OS info for the Prerequisites tab.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    return @{
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        PSEdition      = $PSVersionTable.PSEdition
        ApartmentState = [System.Threading.Thread]::CurrentThread.ApartmentState.ToString()
        OS             = if ($PSVersionTable.PSObject.Properties.Name -contains 'OS') {
                             $PSVersionTable.OS
                         } else {
                             [Environment]::OSVersion.VersionString
                         }
        Is64BitProcess = [Environment]::Is64BitProcess
        IsAdmin        = $isAdmin
        HostName       = [System.Net.Dns]::GetHostName()
        UserName       = [Environment]::UserName
    }
}

#endregion

Export-ModuleMember -Function `
    Get-RequiredModuleSpec, `
    Test-Prerequisites, `
    Get-MissingModules, `
    Install-ModuleConfirmed, `
    Get-PSEnvironmentInfo
