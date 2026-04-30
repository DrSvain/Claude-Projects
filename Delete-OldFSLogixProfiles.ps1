#name: Delete Old FSLogix Profiles enhanced
#description: Deletes FSlogix .vhd(x) files older than specified days and removes any empty directories in the specified Azure Files share.
#tags: beckmann.ch, FSLogix

<#
.SYNOPSIS
    Loescht alte FSLogix-Profile (.vhd/.vhdx) aus einem Azure Files Share.

.DESCRIPTION
    Dieses Skript prueft die FSLogix-Profile in einem Azure Files Share und loescht
    Profile, die laenger als die definierte Anzahl Tage nicht mehr im Zugriff waren.
    Leere Verzeichnisse werden anschliessend ebenfalls entfernt.

    Die Parameter sind in diesem Skript fest vorgegeben (hardcoded).
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# Fest vorgegebene Parameter
# ============================================================================
$ResourceGroupName    = 'RG-AVD-Storage'
$StorageAccountName   = 'saavdfslogixschomburg'
$ShareName            = 'msix'
$DaysOld              = 180
# WICHTIG: Storage Account Key NICHT im Klartext im Skript ablegen / einchecken.
# In Nerdio als "Secure Variable" hinterlegen oder hier zur Laufzeit ersetzen.
# Wenn leer, wird ueber den angemeldeten Az-Context ein SAS-Token erstellt.
$StorageKeySecureVar  = '<PLACEHOLDER_STORAGE_ACCOUNT_KEY>'
$WhatIf               = $true   # true = Testlauf, false = Loeschungen werden ausgefuehrt
# ============================================================================

If ($WhatIf -eq $false) {
    Write-Output "WhatIf is set to false, changes will be made"
} ElseIf ($WhatIf -eq $true) {
    Write-Output "WhatIf is set to true, no changes will be made"
} Else {
    Write-Output "WhatIf is not set to true or false, no changes will be made"
    Exit
}

function New-BesAzureFilesSASToken {
    param (
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [string]$FileShareName,
        [string]$Permissions = "rwdl", # Read, write, delete and list permissions
        [int]$TokenLifeTime = 60       # Token lifetime in minutes
    )

    begin {
        $date = Get-Date
        $actDate = $date.ToUniversalTime()
        $expiringDate = $actDate.AddMinutes($TokenLifeTime)
        $expiringDate = (Get-Date $expiringDate -Format 'yyyy-MM-ddTHH:mm:ssZ')
    }

    process {
        # Retrieve storage account key
        $storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName)[0].Value

        # Create storage context
        $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $storageAccountKey

        # Create SAS token
        $sasToken = New-AzStorageShareSASToken -Context $storageContext -ShareName $FileShareName -Permission $Permissions -ExpiryTime $expiringDate
    }

    end {
        return $sasToken
    }
}

If ($StorageKeySecureVar) {
    # Create a new storage context using the storage account key
    $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKeySecureVar
    Write-Output "Storage Account Connected (using StorageKeySecureVar)"
} Else {
    # Get the current Azure context
    $azContext = Get-AzContext

    # Write the current Azure context to the output
    Write-Output "Current Azure Subscription: $($azContext.Subscription.Name)"
    Write-Output "Current Azure Tenant:       $($azContext.Tenant.Id)"
    Write-Output "Current Azure Account:      $($azContext.Account.Id)"

    # Create a new SAS token for the storage account
    $sasToken = New-BesAzureFilesSASToken -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -FileShareName $ShareName
    Write-Output ("SAS Token: " + $sasToken.Substring(0, 70) + "...")

    # Create a new storage context using the SAS token
    $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $sasToken
    Write-Output "Storage Account Connected (using SAS Token)"
}

$Dirs = $StorageContext | Get-AzStorageFile -ShareName "$ShareName" | Where-Object { $_.GetType().Name -eq "AzureStorageFileDirectory" }
Write-Verbose "Directories in $ShareName"
$Dirs | ForEach-Object { Write-Verbose $_.Name }

# Get files from each directory, check if older than $DaysOld, delete it if it is
foreach ($dir in $Dirs) {
    $Files = Get-AzStorageFile -ShareName "$ShareName" -Path $dir.Name -Context $StorageContext | Get-AzStorageFile
    foreach ($file in $Files) {
        # check if file is not .vhd/.vhdx, if so, skip and move to next iteration
        if ($file.Name -notmatch '\.vhdx?$') {
            Write-Output "$($file.Name) is not a VHD/VHDX file, skipping..."
            continue
        }
        # get lastmodified property using Get-AzStorageFile; if lastmodified is older than $DaysOld, delete the file
        $File = Get-AzStorageFile -ShareName "$ShareName" -Path ($dir.Name + '/' + $file.Name) -Context $StorageContext
        $LastModified = $File.LastModified.DateTime
        $DaysSinceModified = (Get-Date) - $LastModified
        if ($DaysSinceModified.Days -gt $DaysOld) {
            Write-Output "$($file.Name) is older than $DaysOld days (last modified: $LastModified), deleting..."
            If ($WhatIf -eq $false) {
                $File | Remove-AzStorageFile
            }
        } else {
            Write-Output "$($file.Name) is not older than $DaysOld days (last modified: $LastModified), skipping..."
        }
    }
    # if directory is now empty, delete it
    $Files = Get-AzStorageFile -ShareName "$ShareName" -Path $dir.Name -Context $StorageContext | Get-AzStorageFile
    if ($Files.Count -eq 0) {
        Write-Output "$($dir.Name) is empty, deleting..."
        If ($WhatIf -eq $false) {
            Remove-AzStorageDirectory -Context $StorageContext -ShareName "$ShareName" -Path $dir.Name
        }
    }
}
