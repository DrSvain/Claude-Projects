<#
.SYNOPSIS
    Backup tab for the Intune Backup & Restore Tool GUI.

.DESCRIPTION
    Provides:
      - Backup root path selector (text box + folder browse)
      - Workload checkboxes (one per supported Intune workload)
      - Options: include assignments, compute checksums
      - Start Backup button with progress bar
      - Recent backups DataGrid (auto-refreshed after each backup)
#>

Set-StrictMode -Version Latest

function Initialize-TabBackup {
    [CmdletBinding()]
    param(
        [hashtable]$UIRefs,
        [System.Collections.Hashtable]$GlobalState
    )

    $tab         = New-Object System.Windows.Forms.TabPage
    $tab.Text    = '💾 Backup'
    $tab.Padding = [System.Windows.Forms.Padding]::new(10)

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock       = 'Fill'
    $scroll.AutoScroll = $true

    # ── Backup Path ───────────────────────────────────────────────────────
    $grpPath = _New-GBB -Text 'Backup Storage Location' -Top 8 -Left 8 -Width 980 -Height 66

    $txtPath = New-Object System.Windows.Forms.TextBox
    $txtPath.Location = [System.Drawing.Point]::new(10, 26)
    $txtPath.Size     = [System.Drawing.Size]::new(840, 24)
    $txtPath.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    $txtPath.Text     = $GlobalState.BackupRootPath

    $btnBrowse = _New-BtnB -Text 'Browse…' -Top 24 -Left 858 -Width 108 `
                           -Color ([System.Drawing.Color]::FromArgb(100,100,100))

    $grpPath.Controls.AddRange(@($txtPath, $btnBrowse))

    # ── Workloads ─────────────────────────────────────────────────────────
    $grpWL = _New-GBB -Text 'Workloads to Back Up' -Top 84 -Left 8 -Width 980 -Height 68

    $workloadDefs = @(
        @{Key='CompliancePolicies'; Label='Compliance Policies';        Left=10  }
        @{Key='ConfigProfiles';     Label='Device Config Profiles';     Left=210 }
        @{Key='SettingsCatalog';    Label='Settings Catalog';           Left=420 }
        @{Key='EndpointSecurity';   Label='Endpoint Security';          Left=610 }
        @{Key='DeviceScripts';      Label='Device Mgmt Scripts';        Left=790 }
    )

    $chkBoxes = @{}
    foreach ($wl in $workloadDefs) {
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text     = $wl.Label
        $chk.Checked  = $true
        $chk.Location = [System.Drawing.Point]::new($wl.Left, 28)
        $chk.AutoSize = $true
        $chk.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
        $chkBoxes[$wl.Key] = $chk
        $grpWL.Controls.Add($chk)
    }

    # ── Options ───────────────────────────────────────────────────────────
    $grpOpt = _New-GBB -Text 'Options' -Top 162 -Left 8 -Width 980 -Height 56

    $chkAssignments = New-Object System.Windows.Forms.CheckBox
    $chkAssignments.Text     = 'Export assignment data (documentation only, not restored)'
    $chkAssignments.Checked  = $GlobalState.IncludeAssignments
    $chkAssignments.Location = [System.Drawing.Point]::new(10, 24)
    $chkAssignments.AutoSize = $true
    $chkAssignments.Font     = [System.Drawing.Font]::new('Segoe UI', 9)

    $chkChecksums = New-Object System.Windows.Forms.CheckBox
    $chkChecksums.Text     = 'Compute SHA-256 checksums'
    $chkChecksums.Checked  = $GlobalState.ComputeChecksums
    $chkChecksums.Location = [System.Drawing.Point]::new(490, 24)
    $chkChecksums.AutoSize = $true
    $chkChecksums.Font     = [System.Drawing.Font]::new('Segoe UI', 9)

    $grpOpt.Controls.AddRange(@($chkAssignments, $chkChecksums))

    # ── Actions + Progress ────────────────────────────────────────────────
    $grpAction = _New-GBB -Text 'Backup Actions' -Top 228 -Left 8 -Width 980 -Height 86

    $btnStart = _New-BtnB -Text '▶  Start Backup' -Top 22 -Left 10 -Width 170 `
                          -Color ([System.Drawing.Color]::FromArgb(0,153,76))
    $btnStart.Enabled = $false    # enabled after connect
    $btnStart.Name    = 'BtnStartBackup'

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text     = 'Connect to a tenant first.'
    $lblStatus.Location = [System.Drawing.Point]::new(190, 30)
    $lblStatus.Size     = [System.Drawing.Size]::new(780, 20)
    $lblStatus.Font     = [System.Drawing.Font]::new('Segoe UI', 9)
    $lblStatus.ForeColor= [System.Drawing.Color]::FromArgb(80,80,80)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = [System.Drawing.Point]::new(10, 58)
    $pb.Size     = [System.Drawing.Size]::new(955, 18)
    $pb.Minimum  = 0
    $pb.Maximum  = 100
    $pb.Value    = 0

    $grpAction.Controls.AddRange(@($btnStart, $lblStatus, $pb))

    # Register in UIRefs for timer updates
    $UIRefs.BtnStartBackup   = $btnStart
    $UIRefs.BackupProgressBar = $pb
    $UIRefs.BackupStatusLabel = $lblStatus

    # ── Recent Backups ────────────────────────────────────────────────────
    $grpRecent = _New-GBB -Text 'Recent Backups' -Top 324 -Left 8 -Width 980 -Height 230

    $btnRefresh = _New-BtnB -Text '↺ Refresh' -Top 22 -Left 10 -Width 100 `
                            -Color ([System.Drawing.Color]::FromArgb(100,100,100))

    $dgRecent = New-Object System.Windows.Forms.DataGridView
    $dgRecent.Location              = [System.Drawing.Point]::new(10, 62)
    $dgRecent.Size                  = [System.Drawing.Size]::new(955, 156)
    $dgRecent.ReadOnly              = $true
    $dgRecent.AllowUserToAddRows    = $false
    $dgRecent.AllowUserToDeleteRows = $false
    $dgRecent.AllowUserToResizeRows = $false
    $dgRecent.SelectionMode         = 'FullRowSelect'
    $dgRecent.AutoSizeColumnsMode   = 'Fill'
    $dgRecent.BorderStyle           = 'FixedSingle'
    $dgRecent.BackgroundColor       = [System.Drawing.Color]::White
    $dgRecent.RowHeadersVisible     = $false
    $dgRecent.Font                  = [System.Drawing.Font]::new('Segoe UI', 9)
    $dgRecent.ColumnHeadersDefaultCellStyle.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    foreach ($col in @(
        @{Name='BackupDate';   Header='Date / Time';   Weight=22}
        @{Name='TenantName';   Header='Tenant';        Weight=24}
        @{Name='TotalObjects'; Header='Objects';        Weight=10}
        @{Name='Status';       Header='Status';         Weight=12}
        @{Name='BackupPath';   Header='Path';           Weight=32}
    )) {
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $col.Name; $c.HeaderText = $col.Header; $c.FillWeight = $col.Weight
        $dgRecent.Columns.Add($c) | Out-Null
    }

    $grpRecent.Controls.AddRange(@($btnRefresh, $dgRecent))

    # ── Assemble ──────────────────────────────────────────────────────────
    $scroll.Controls.AddRange(@($grpPath, $grpWL, $grpOpt, $grpAction, $grpRecent))
    $tab.Controls.Add($scroll)

    # ── Helper: refresh recent-backups list ───────────────────────────────
    function Refresh-RecentBackups {
        $path = $txtPath.Text.Trim()
        if (-not $path -or -not (Test-Path $path)) { return }
        try {
            $list = Get-RecentBackups -BackupRootPath $path
            $dgRecent.Rows.Clear()
            foreach ($b in $list) {
                $idx = $dgRecent.Rows.Add($b.BackupDate, $b.TenantName, $b.TotalObjects, $b.Status, $b.BackupPath)
                if ($b.Status -ne 'Completed') {
                    $dgRecent.Rows[$idx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                }
            }
        }
        catch {
            Write-LogMessage -Level WARN -Message "Could not load recent backups: $($_.Exception.Message)"
        }
    }

    # ── Event: Browse path ────────────────────────────────────────────────
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description         = 'Select backup root folder'
        $dlg.ShowNewFolderButton = $true
        if ($txtPath.Text -and (Test-Path $txtPath.Text)) {
            $dlg.SelectedPath = $txtPath.Text
        }
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtPath.Text               = $dlg.SelectedPath
            $GlobalState.BackupRootPath = $dlg.SelectedPath
            Refresh-RecentBackups
        }
    })

    # ── Event: Refresh ────────────────────────────────────────────────────
    $btnRefresh.Add_Click({ Refresh-RecentBackups })

    # ── Event: Start Backup ───────────────────────────────────────────────
    $btnStart.Add_Click({
        $rootPath = $txtPath.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Please select a backup storage location first.',
                'No Path', 'OK', 'Warning') | Out-Null
            return
        }

        # Collect workload selection
        $selection = @{}
        foreach ($key in $chkBoxes.Keys) {
            $selection[$key] = $chkBoxes[$key].Checked
        }

        if (-not ($selection.Values | Where-Object { $_ })) {
            [System.Windows.Forms.MessageBox]::Show(
                'Please select at least one workload to back up.',
                'No Workload', 'OK', 'Warning') | Out-Null
            return
        }

        $GlobalState.BackupRootPath = $rootPath

        $includeAssignments = $chkAssignments.Checked
        $computeChecksums   = $chkChecksums.Checked
        $maxRetries         = $GlobalState.MaxRetries

        $btnStart.Text    = 'Running…'
        $btnStart.Enabled = $false
        $pb.Value         = 0
        $lblStatus.Text   = 'Starting...'

        $backupScript = {
            param($GlobalState, $ExtraArgs)
            $sel     = $ExtraArgs[0]
            $inclAss = $ExtraArgs[1]
            $chkSums = $ExtraArgs[2]
            $retries = $ExtraArgs[3]

            Start-IntuneBackup `
                -GlobalState        $GlobalState `
                -WorkloadSelection  $sel `
                -IncludeAssignments $inclAss `
                -ComputeChecksums   $chkSums `
                -MaxRetries         $retries
        }

        Start-BackgroundOperation `
            -ScriptBlock    $backupScript `
            -OperationType  'Backup' `
            -AdditionalArgs @($selection, $includeAssignments, $computeChecksums, $maxRetries)

        # Refresh list after a short delay once the op ends
        # (detected by the timer resetting BtnStartBackup)
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            if (-not $GlobalState.IsBackupRunning) {
                $timer.Stop()
                $timer.Dispose()
                Refresh-RecentBackups
                $btnStart.Text    = '▶  Start Backup'
                $btnStart.Enabled = $GlobalState.IsConnected
            }
        })
        $timer.Start()
    })

    # Initial load of recent backups
    if ($GlobalState.BackupRootPath -and (Test-Path $GlobalState.BackupRootPath)) {
        Refresh-RecentBackups
    }

    return $tab
}

# ---------------------------------------------------------------------------
#region Private helpers
# ---------------------------------------------------------------------------
function _New-GBB {
    param([string]$Text,[int]$Top,[int]$Left,[int]$Width,[int]$Height)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text; $g.Location = [System.Drawing.Point]::new($Left,$Top)
    $g.Size = [System.Drawing.Size]::new($Width,$Height)
    $g.Font = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    return $g
}
function _New-BtnB {
    param([string]$Text,[int]$Top,[int]$Left,[int]$Width,
          [System.Drawing.Color]$Color=[System.Drawing.Color]::SteelBlue)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = [System.Drawing.Point]::new($Left,$Top)
    $b.Size = [System.Drawing.Size]::new($Width,32)
    $b.BackColor = $Color; $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.Font   = [System.Drawing.Font]::new('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}
#endregion
