#Requires -Version 7.0
<#
.SYNOPSIS
    Restore tab — load backup, select objects, detect conflicts, run restore.

.DESCRIPTION
    Augments the previous Restore tab with:
      * ConflictMode dropdown (Skip / CreateDuplicate / UpdateExisting)
      * RestoreAssignments checkbox
      * Dry-run checkbox
      * JSON preview pane (right side, below the log)
      * Additional grid columns: Category, Original Id, Backup Date,
        Source Tenant, Endpoint Version, Restorable, DryRunResult.
#>

function Initialize-TabRestore {
    param(
        [hashtable]$UIRefs,
        [hashtable]$GlobalState
    )

    $Tab = New-Object System.Windows.Forms.TabPage
    $Tab.Text = 'Restore'
    $Tab.Padding = [System.Windows.Forms.Padding]::new(10)

    # ── Outer split: left selection panel | right log+preview panel ────────
    $split = [System.Windows.Forms.SplitContainer]::new()
    $split.Dock          = 'Fill'
    $split.Orientation   = 'Vertical'
    $split.Panel1MinSize = 25
    $split.Panel2MinSize = 25
    $Tab.Controls.Add($split)

    $split.Add_HandleCreated({
        try {
            if ($split.Width -ge 600) {
                $split.Panel2MinSize    = 280
                $split.SplitterDistance = [Math]::Min(680, $split.Width - $split.Panel2MinSize - 10)
            }
        } catch { }
    })

    # ════════════════════════════════════════════════════════════════════════
    # LEFT PANEL
    # ════════════════════════════════════════════════════════════════════════
    $left = $split.Panel1

    # ── Section 1 : Backup source ────────────────────────────────────────────
    $grpSource = _New-RestoreGroup -Text 'Backup Source' -Dock 'Top' -Height 70
    $left.Controls.Add($grpSource)

    $txtPath = [System.Windows.Forms.TextBox]::new()
    $txtPath.Location  = [System.Drawing.Point]::new(8, 22)
    $txtPath.Width     = 520
    $txtPath.Height    = 22
    $txtPath.ReadOnly  = $true
    $txtPath.BackColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($txtPath)

    $btnBrowse = _New-RestoreButton -Text 'Browse...' -X 534 -Y 21 -Width 80 -Height 24
    $grpSource.Controls.Add($btnBrowse)

    $btnLoad = _New-RestoreButton -Text 'Load Backup' -X 620 -Y 21 -Width 100 -Height 24
    $btnLoad.Enabled = $false
    $grpSource.Controls.Add($btnLoad)

    # ── Section 2 : Manifest info ────────────────────────────────────────────
    $grpManifest = _New-RestoreGroup -Text 'Backup Manifest' -Dock 'Top' -Height 96
    $left.Controls.Add($grpManifest)

    $lblManifest = [System.Windows.Forms.Label]::new()
    $lblManifest.Location  = [System.Drawing.Point]::new(8, 18)
    $lblManifest.Size      = [System.Drawing.Size]::new(710, 72)
    $lblManifest.Text      = 'No backup loaded.'
    $lblManifest.ForeColor = [System.Drawing.Color]::Gray
    $lblManifest.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $grpManifest.Controls.Add($lblManifest)

    # ── Section 3 : Object selection grid ───────────────────────────────────
    $grpObjects = _New-RestoreGroup -Text 'Objects to Restore' -Dock 'Fill'
    $left.Controls.Add($grpObjects)

    # toolbar above grid
    $toolPanel = [System.Windows.Forms.Panel]::new()
    $toolPanel.Dock   = 'Top'
    $toolPanel.Height = 30
    $grpObjects.Controls.Add($toolPanel)

    $btnSelAll  = _New-RestoreButton -Text 'Select All'    -X 4   -Y 3 -Width 90  -Height 24
    $btnSelNone = _New-RestoreButton -Text 'Select None'   -X 98  -Y 3 -Width 90  -Height 24
    $btnSelConflict = _New-RestoreButton -Text 'Skip Conflicts' -X 192 -Y 3 -Width 100 -Height 24
    $btnSelConflict.Enabled = $false
    $toolPanel.Controls.AddRange(@($btnSelAll, $btnSelNone, $btnSelConflict))

    $lblConflictCount = [System.Windows.Forms.Label]::new()
    $lblConflictCount.Location  = [System.Drawing.Point]::new(300, 7)
    $lblConflictCount.Size      = [System.Drawing.Size]::new(360, 18)
    $lblConflictCount.Text      = ''
    $lblConflictCount.ForeColor = [System.Drawing.Color]::DarkOrange
    $toolPanel.Controls.Add($lblConflictCount)

    # DataGridView
    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Dock                    = 'Fill'
    $grid.AutoSizeColumnsMode     = 'Fill'
    $grid.RowHeadersVisible       = $false
    $grid.AllowUserToAddRows      = $false
    $grid.AllowUserToDeleteRows   = $false
    $grid.MultiSelect             = $false
    $grid.SelectionMode           = 'FullRowSelect'
    $grid.BackgroundColor         = [System.Drawing.Color]::White
    $grid.BorderStyle             = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ColumnHeadersHeight     = 24
    $grid.RowTemplate.Height      = 22
    $grpObjects.Controls.Add($grid)

    # Columns
    $colCheck = [System.Windows.Forms.DataGridViewCheckBoxColumn]::new()
    $colCheck.Name       = 'Selected'
    $colCheck.HeaderText = ''
    $colCheck.Width      = 30
    $colCheck.AutoSizeMode = 'None'
    $grid.Columns.Add($colCheck) | Out-Null

    foreach ($col in @(
        @{Name='Category';       Header='Category';     Fill=14},
        @{Name='DisplayName';    Header='Name';         Fill=24},
        @{Name='OriginalId';     Header='Source Id';    Fill=14},
        @{Name='Conflict';       Header='Conflict';     Fill=8},
        @{Name='EndpointVersion';Header='API';          Fill=5},
        @{Name='Assignments';    Header='Assign';       Fill=5},
        @{Name='DryRunResult';   Header='Dry-run';      Fill=10},
        @{Name='Warning';        Header='Warning';      Fill=20}
    )) {
        $c = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $c.Name       = $col.Name
        $c.HeaderText = $col.Header
        $c.FillWeight = $col.Fill
        $c.ReadOnly   = ($col.Name -ne 'Selected')
        $grid.Columns.Add($c) | Out-Null
    }

    # ── Section 4 : Restore options + action ────────────────────────────────
    $grpAction = _New-RestoreGroup -Text 'Restore Options' -Dock 'Bottom' -Height 110
    $left.Controls.Add($grpAction)

    # Conflict mode
    $lblCM = [System.Windows.Forms.Label]::new()
    $lblCM.Text = 'Conflict mode:'
    $lblCM.Location = [System.Drawing.Point]::new(8, 22)
    $lblCM.Size = [System.Drawing.Size]::new(100, 20)
    $grpAction.Controls.Add($lblCM)

    $cmbConflict = [System.Windows.Forms.ComboBox]::new()
    $cmbConflict.Location = [System.Drawing.Point]::new(108, 19)
    $cmbConflict.Width    = 160
    $cmbConflict.DropDownStyle = 'DropDownList'
    $cmbConflict.Items.AddRange([string[]]@('Skip','CreateDuplicate','UpdateExisting'))
    $defaultMode = if ($GlobalState.Config -and $GlobalState.Config['ConflictMode']) { $GlobalState.Config['ConflictMode'] } else { 'Skip' }
    $idx = $cmbConflict.Items.IndexOf($defaultMode)
    $cmbConflict.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    $grpAction.Controls.Add($cmbConflict)

    # Restore assignments
    $chkRestoreAssign = [System.Windows.Forms.CheckBox]::new()
    $chkRestoreAssign.Text     = 'Restore assignments (resolve groups by displayName)'
    $chkRestoreAssign.Location = [System.Drawing.Point]::new(280, 21)
    $chkRestoreAssign.Size     = [System.Drawing.Size]::new(380, 20)
    $chkRestoreAssign.Checked  = [bool]($GlobalState.Config -and $GlobalState.Config['RestoreAssignmentsByDefault'] -eq $true)
    $grpAction.Controls.Add($chkRestoreAssign)

    # Dry run
    $chkDryRun = [System.Windows.Forms.CheckBox]::new()
    $chkDryRun.Text     = 'Dry run (validate only, no changes)'
    $chkDryRun.Location = [System.Drawing.Point]::new(8, 50)
    $chkDryRun.Size     = [System.Drawing.Size]::new(300, 20)
    $chkDryRun.Checked  = [bool]($GlobalState.Config -and $GlobalState.Config['DryRunByDefault'] -eq $true)
    $grpAction.Controls.Add($chkDryRun)

    # Buttons
    $btnDetectConflicts = _New-RestoreButton -Text 'Detect Conflicts' -X 8 -Y 78 -Width 130 -Height 26
    $btnDetectConflicts.Enabled = $false
    $grpAction.Controls.Add($btnDetectConflicts)

    $btnStartRestore = _New-RestoreButton -Text 'Start Restore' -X 144 -Y 78 -Width 130 -Height 26
    $btnStartRestore.Enabled    = $false
    $btnStartRestore.BackColor  = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnStartRestore.ForeColor  = [System.Drawing.Color]::White
    $btnStartRestore.FlatStyle  = 'Flat'
    $grpAction.Controls.Add($btnStartRestore)

    $lblTargetTenant = [System.Windows.Forms.Label]::new()
    $lblTargetTenant.Location  = [System.Drawing.Point]::new(280, 82)
    $lblTargetTenant.Size      = [System.Drawing.Size]::new(420, 20)
    $lblTargetTenant.Text      = 'Target tenant: (not connected)'
    $lblTargetTenant.ForeColor = [System.Drawing.Color]::DarkBlue
    $lblTargetTenant.Font      = [System.Drawing.Font]::new('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $grpAction.Controls.Add($lblTargetTenant)

    # progress + status
    $restoreProgress = [System.Windows.Forms.ProgressBar]::new()
    $restoreProgress.Dock    = 'Bottom'
    $restoreProgress.Height  = 18
    $restoreProgress.Minimum = 0
    $restoreProgress.Maximum = 100
    $restoreProgress.Value   = 0
    $left.Controls.Add($restoreProgress)

    $lblRestoreStatus = [System.Windows.Forms.Label]::new()
    $lblRestoreStatus.Dock      = 'Bottom'
    $lblRestoreStatus.Height    = 20
    $lblRestoreStatus.Text      = 'Ready.'
    $lblRestoreStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblRestoreStatus.Font      = [System.Drawing.Font]::new('Segoe UI', 8.5)
    $left.Controls.Add($lblRestoreStatus)

    # ════════════════════════════════════════════════════════════════════════
    # RIGHT PANEL — Restore log (top) + JSON preview (bottom)
    # ════════════════════════════════════════════════════════════════════════
    $right = $split.Panel2

    $rightSplit = [System.Windows.Forms.SplitContainer]::new()
    $rightSplit.Dock          = 'Fill'
    $rightSplit.Orientation   = 'Horizontal'
    $rightSplit.Panel1MinSize = 50
    $rightSplit.Panel2MinSize = 50
    $right.Controls.Add($rightSplit)

    $rightSplit.Add_HandleCreated({
        try {
            if ($rightSplit.Height -ge 200) {
                $rightSplit.SplitterDistance = [int]($rightSplit.Height * 0.45)
            }
        } catch { }
    })

    # Top half: log
    $grpLog = _New-RestoreGroup -Text 'Restore Log' -Dock 'Fill'
    $rightSplit.Panel1.Controls.Add($grpLog)

    $rtbLog = [System.Windows.Forms.RichTextBox]::new()
    $rtbLog.Dock      = 'Fill'
    $rtbLog.ReadOnly  = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $rtbLog.ForeColor = [System.Drawing.Color]::LightGray
    $rtbLog.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $grpLog.Controls.Add($rtbLog)

    $btnClearLog = _New-RestoreButton -Text 'Clear' -X 4 -Y 0 -Width 60 -Height 22
    $btnClearLog.Dock = 'Bottom'
    $grpLog.Controls.Add($btnClearLog)

    # Bottom half: JSON preview
    $grpPreview = _New-RestoreGroup -Text 'JSON preview (selected object)' -Dock 'Fill'
    $rightSplit.Panel2.Controls.Add($grpPreview)

    $rtbPreview = [System.Windows.Forms.RichTextBox]::new()
    $rtbPreview.Dock      = 'Fill'
    $rtbPreview.ReadOnly  = $true
    $rtbPreview.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $rtbPreview.ForeColor = [System.Drawing.Color]::Black
    $rtbPreview.Font      = [System.Drawing.Font]::new('Consolas', 8)
    $rtbPreview.WordWrap  = $false
    $grpPreview.Controls.Add($rtbPreview)

    # ════════════════════════════════════════════════════════════════════════
    # Register UIRefs
    # ════════════════════════════════════════════════════════════════════════
    $UIRefs.RestoreObjectGrid       = $grid
    $UIRefs.BtnStartRestore         = $btnStartRestore
    $UIRefs.BtnDetectConflicts      = $btnDetectConflicts
    $UIRefs.RestoreProgressBar      = $restoreProgress
    $UIRefs.RestoreStatusLabel      = $lblRestoreStatus
    $UIRefs.RestoreLogBox           = $rtbLog
    $UIRefs.ChkRestoreDryRun        = $chkDryRun
    $UIRefs.ChkRestoreAssignments   = $chkRestoreAssign
    $UIRefs.CmbConflictMode         = $cmbConflict
    $UIRefs.RestoreJsonPreview      = $rtbPreview
    $UIRefs.LblRestoreTargetTenant  = $lblTargetTenant

    # ════════════════════════════════════════════════════════════════════════
    # State
    # ════════════════════════════════════════════════════════════════════════
    $script:RestoreItems   = $null   # populated rows for the grid (hashtable[])
    $script:BackupRoot     = $null
    $script:RestoreRunning = $false

    # ── Helper: append line to restore log ──────────────────────────────────
    function Add-RestoreLog {
        param([string]$Text, [string]$Level = 'INFO')
        $color = switch ($Level) {
            'ERROR'   { [System.Drawing.Color]::Tomato }
            'WARN'    { [System.Drawing.Color]::Gold }
            'OK'      { [System.Drawing.Color]::LightGreen }
            'SUCCESS' { [System.Drawing.Color]::LightGreen }
            default   { [System.Drawing.Color]::LightGray }
        }
        $ts = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] $Text`n"
        $rtbLog.SelectionStart  = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor  = $color
        $rtbLog.AppendText($line)
        $rtbLog.ScrollToCaret()
    }

    # ── Helper: populate grid from $script:RestoreItems ────────────────────
    function Render-Grid {
        $grid.SuspendLayout()
        $grid.Rows.Clear()
        if (-not $script:RestoreItems) { $grid.ResumeLayout(); return }

        foreach ($item in $script:RestoreItems) {
            $rowIdx = $grid.Rows.Add()
            $row = $grid.Rows[$rowIdx]
            $row.Cells['Selected'].Value         = [bool]$item.IsSelected
            $row.Cells['Category'].Value         = $item.Category
            $row.Cells['DisplayName'].Value      = $item.DisplayName
            $row.Cells['OriginalId'].Value       = $item.SourceId
            $row.Cells['Conflict'].Value         = $item.ConflictStatus
            $row.Cells['EndpointVersion'].Value  = $item.EndpointVersion
            $row.Cells['Assignments'].Value      = if ($item.HasAssignments) { 'yes' } else { '' }
            $row.Cells['DryRunResult'].Value     = if ($item.DryRunResult) { $item.DryRunResult } else { '' }
            $row.Cells['Warning'].Value          = if ($item.RestoreWarning) { $item.RestoreWarning } else { '' }

            if ($item.ConflictStatus -eq 'Conflict') {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            }
            elseif ($item.ConflictStatus -eq 'Warning' -or $item.RestoreWarning) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            }
        }
        $grid.ResumeLayout()

        $cnt = @($script:RestoreItems | Where-Object { $_.ConflictStatus -eq 'Conflict' }).Count
        if ($cnt -gt 0) {
            $lblConflictCount.Text  = "$cnt conflict(s) detected"
            $btnSelConflict.Enabled = $true
        } else {
            $lblConflictCount.Text  = ''
            $btnSelConflict.Enabled = $false
        }
    }

    function Get-SelectedItems {
        $sel = [System.Collections.Generic.List[hashtable]]::new()
        # Sync IsSelected from grid
        for ($i=0; $i -lt $grid.Rows.Count; $i++) {
            $row = $grid.Rows[$i]
            if ($i -lt $script:RestoreItems.Count) {
                $script:RestoreItems[$i].IsSelected = [bool]$row.Cells['Selected'].Value
            }
        }
        foreach ($item in $script:RestoreItems) {
            if ($item.IsSelected) { $sel.Add($item) }
        }
        return $sel.ToArray()
    }

    # ════════════════════════════════════════════════════════════════════════
    # Event: Browse
    # ════════════════════════════════════════════════════════════════════════
    $btnBrowse.Add_Click({
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dlg.Description = 'Select a backup snapshot folder (contains Manifest\manifest.json)'
        $dlg.ShowNewFolderButton = $false
        $cfgPath = $GlobalState['Config']?['BackupRootPath']
        if ($cfgPath -and (Test-Path $cfgPath)) { $dlg.SelectedPath = $cfgPath }
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtPath.Text    = $dlg.SelectedPath
            $btnLoad.Enabled = $true
        }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Event: Load Backup
    # ════════════════════════════════════════════════════════════════════════
    $btnLoad.Add_Click({
        $folder = $txtPath.Text.Trim()
        if (-not $folder -or -not (Test-Path $folder)) {
            [System.Windows.Forms.MessageBox]::Show('Folder not found.', 'Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        try {
            $loaded = Import-BackupManifest -BackupPath $folder
            if (-not $loaded.Manifest) {
                [System.Windows.Forms.MessageBox]::Show($loaded.Error, 'Invalid Backup',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            $script:BackupRoot = $folder
            $manifest = $loaded.Manifest

            $statusTxt = @(
                "Tenant      : $($manifest.Tenant.DisplayName)  ($($manifest.Tenant.Id))"
                "Backup time : $($manifest.StartedAt)  ->  $($manifest.CompletedAt)"
                "Status      : $($manifest.Status)    Objects: $($manifest.TotalObjectCount)"
                "Tool ver    : $($manifest.ToolVersion)  Schema: $($manifest.SchemaVersion)"
            ) -join "`n"
            $lblManifest.Text      = $statusTxt
            $lblManifest.ForeColor = if ($manifest.Status -eq 'Completed') { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkOrange }

            if ($loaded.Index) {
                $rows = Get-BackupObjectList -Index $loaded.Index -BackupPath $folder
                $script:RestoreItems = @($rows)
                Render-Grid
                $btnDetectConflicts.Enabled = $true
                $btnStartRestore.Enabled    = $true
                Add-RestoreLog "Loaded $(@($script:RestoreItems).Count) object(s) from backup." 'OK'
            } else {
                Add-RestoreLog 'index.json not found — cannot populate object list.' 'WARN'
            }
        } catch {
            Add-RestoreLog "Failed to load backup: $($_.Exception.Message)" 'ERROR'
        }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Event: Selection helpers
    # ════════════════════════════════════════════════════════════════════════
    $btnSelAll.Add_Click({
        foreach ($r in $grid.Rows) { $r.Cells['Selected'].Value = $true }
        $grid.RefreshEdit()
    })
    $btnSelNone.Add_Click({
        foreach ($r in $grid.Rows) { $r.Cells['Selected'].Value = $false }
        $grid.RefreshEdit()
    })
    $btnSelConflict.Add_Click({
        foreach ($r in $grid.Rows) {
            if ($r.Cells['Conflict'].Value -eq 'Conflict') {
                $r.Cells['Selected'].Value = $false
            }
        }
        $grid.RefreshEdit()
        Add-RestoreLog 'Deselected all conflicting objects.' 'INFO'
    })
    $btnClearLog.Add_Click({ $rtbLog.Clear() })

    # ════════════════════════════════════════════════════════════════════════
    # Event: JSON preview on row select
    # ════════════════════════════════════════════════════════════════════════
    $grid.Add_SelectionChanged({
        try {
            if ($grid.SelectedRows.Count -eq 0 -or -not $script:BackupRoot) { return }
            $idx = $grid.SelectedRows[0].Index
            if ($idx -lt 0 -or $idx -ge $script:RestoreItems.Count) { return }
            $item = $script:RestoreItems[$idx]
            $map  = (Get-WorkloadMap)[$item.Category]
            if (-not $map) { return }

            $importFile = Join-Path $script:BackupRoot $map.SubFolder | Join-Path -ChildPath $item.ImportFileName
            if (-not (Test-Path $importFile)) {
                $rtbPreview.Text = "(File not found: $importFile)"
                return
            }
            # Cap preview at ~64 KB to keep the GUI responsive
            $size = (Get-Item $importFile).Length
            if ($size -gt 65536) {
                $rtbPreview.Text = "(File too large to preview: $size bytes — open in editor: $importFile)"
                return
            }
            $rtbPreview.Text = Get-Content -Path $importFile -Raw -Encoding UTF8
            $rtbPreview.SelectionStart = 0
            $rtbPreview.ScrollToCaret()
        }
        catch { }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Event: Detect Conflicts
    # ════════════════════════════════════════════════════════════════════════
    $btnDetectConflicts.Add_Click({
        if (-not $GlobalState.IsConnected) {
            [System.Windows.Forms.MessageBox]::Show('Connect to Intune first.', 'Not Connected',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not $script:RestoreItems -or $script:RestoreItems.Count -eq 0) { return }

        $btnDetectConflicts.Enabled = $false
        $btnDetectConflicts.Text    = 'Detecting...'
        Add-RestoreLog 'Detecting conflicts in target tenant...' 'INFO'

        # Pass items via GlobalState — simpler than runspace argument plumbing
        $GlobalState.RestoreItemsForCheck = $script:RestoreItems

        $payload = {
            param($State, $ExtraArgs)
            try {
                $items = [hashtable[]]$State.RestoreItemsForCheck
                $maxR  = if ($State.MaxRetries) { [int]$State.MaxRetries } else { 3 }
                $checked = Test-RestoreConflicts -RestoreItems $items -MaxRetries $maxR
                $State.RestoreItemsAfterCheck = $checked
            }
            catch {
                Write-LogMessage -Level ERROR -Message "Conflict detection failed: $($_.Exception.Message)"
            }
        }
        Start-BackgroundOperation -ScriptBlock $payload -OperationType 'ConflictCheck'

        $pollTimer = [System.Windows.Forms.Timer]::new()
        $pollTimer.Interval = 400
        $pollTimer.Add_Tick({
            if (-not $script:ActiveRunspace) {
                $pollTimer.Stop(); $pollTimer.Dispose()
                if ($GlobalState.RestoreItemsAfterCheck) {
                    $script:RestoreItems = @($GlobalState.RestoreItemsAfterCheck)
                    Render-Grid
                    $cnt = @($script:RestoreItems | Where-Object { $_.ConflictStatus -eq 'Conflict' }).Count
                    Add-RestoreLog "Conflict detection complete. $cnt conflict(s)." 'OK'
                } else {
                    Add-RestoreLog 'Conflict detection returned no data.' 'WARN'
                }
                $btnDetectConflicts.Text    = 'Detect Conflicts'
                $btnDetectConflicts.Enabled = $true
            }
        })
        $pollTimer.Start()
    })

    # ════════════════════════════════════════════════════════════════════════
    # Event: Start Restore
    # ════════════════════════════════════════════════════════════════════════
    $btnStartRestore.Add_Click({
        if ($script:RestoreRunning) { return }
        if (-not $GlobalState.IsConnected) {
            [System.Windows.Forms.MessageBox]::Show('Connect to Intune first.', 'Not Connected',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $selected = Get-SelectedItems
        if ($selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('No objects selected for restore.', 'Nothing to Restore',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $isDryRun       = $chkDryRun.Checked
        $conflictMode   = $cmbConflict.SelectedItem.ToString()
        $restoreAssign  = $chkRestoreAssign.Checked

        $modeLabel = if ($isDryRun) { ' (DRY RUN)' } else { '' }
        $confirm   = @(
            "Restore $($selected.Count) object(s)$modeLabel"
            "Target tenant : $($GlobalState.TenantDisplayName)"
            "Conflict mode : $conflictMode"
            "Assignments   : $(if ($restoreAssign) { 'yes' } else { 'no' })"
            ''
        )
        $grouped = $selected | Group-Object Category
        foreach ($g in $grouped) { $confirm += "  $($g.Name) : $($g.Count)" }
        if (-not $isDryRun) { $confirm += ''; $confirm += 'This operation cannot be automatically undone. Continue?' }

        $dlg = [System.Windows.Forms.MessageBox]::Show(
            ($confirm -join "`n"), "Confirm restore$modeLabel",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($dlg -ne 'Yes') {
            Add-RestoreLog 'Restore cancelled by user.' 'INFO'
            return
        }

        $script:RestoreRunning      = $true
        $btnStartRestore.Enabled    = $false
        $btnDetectConflicts.Enabled = $false
        $lblRestoreStatus.Text      = if ($isDryRun) { 'Dry run...' } else { 'Restoring...' }
        $lblRestoreStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        $restoreProgress.Value      = 0

        Add-RestoreLog "Starting restore of $($selected.Count) object(s)$modeLabel (mode=$conflictMode, assignments=$restoreAssign)" 'INFO'

        $GlobalState.SelectedRestoreItems = [hashtable[]]$selected
        $GlobalState.RestoreBackupPath    = $script:BackupRoot
        $GlobalState.RestoreConflictMode  = $conflictMode
        $GlobalState.RestoreDryRun        = [bool]$isDryRun
        $GlobalState.RestoreAssignments   = [bool]$restoreAssign

        $payload = {
            param($State, $ExtraArgs)
            try {
                Start-IntuneRestore `
                    -GlobalState        $State `
                    -BackupPath         $State.RestoreBackupPath `
                    -SelectedItems      ([hashtable[]]$State.SelectedRestoreItems) `
                    -ConflictMode       $State.RestoreConflictMode `
                    -DryRun             ([bool]$State.RestoreDryRun) `
                    -RestoreAssignments ([bool]$State.RestoreAssignments) `
                    -MaxRetries         (if ($State.MaxRetries) { [int]$State.MaxRetries } else { 3 }) | Out-Null
            }
            catch {
                Write-LogMessage -Level ERROR -Message "Restore runspace error: $($_.Exception.Message)"
            }
        }
        Start-BackgroundOperation -ScriptBlock $payload -OperationType 'Restore'

        $restoreTimer = [System.Windows.Forms.Timer]::new()
        $restoreTimer.Interval = 500
        $restoreTimer.Add_Tick({
            if ($GlobalState.IsRestoreRunning) {
                $pct = $GlobalState.RestoreProgress
                if ($null -ne $pct) { $restoreProgress.Value = [Math]::Min([int]$pct, 100) }
                $lblRestoreStatus.Text = $GlobalState.RestoreProgressText
            }

            if (-not $script:ActiveRunspace -and -not $GlobalState.IsRestoreRunning) {
                $restoreTimer.Stop(); $restoreTimer.Dispose()

                $lblRestoreStatus.Text = $GlobalState.RestoreProgressText
                $restoreProgress.Value = 100
                Add-RestoreLog $GlobalState.RestoreProgressText 'OK'

                $btnStartRestore.Enabled    = $true
                $btnDetectConflicts.Enabled = $true
                $script:RestoreRunning      = $false

                # Re-render to show DryRunResult / RestoreResult
                Render-Grid
            }
        })
        $restoreTimer.Start()
    })

    # Initial preview placeholder
    $rtbPreview.Text = '(Select an object in the grid to preview its normalized .import.json)'

    return $Tab
}

# ── Helpers (private to this file, prefixed to avoid cross-tab collisions) ──
function _New-RestoreGroup {
    param([string]$Text, [string]$Dock = 'None', [int]$Height = 0)
    $gb = [System.Windows.Forms.GroupBox]::new()
    $gb.Text    = $Text
    $gb.Dock    = $Dock
    if ($Height -gt 0) { $gb.Height = $Height }
    $gb.Padding = [System.Windows.Forms.Padding]::new(6)
    return $gb
}

function _New-RestoreButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 90, [int]$Height = 26)
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text     = $Text
    $btn.Location = [System.Drawing.Point]::new($X, $Y)
    $btn.Size     = [System.Drawing.Size]::new($Width, $Height)
    $btn.FlatStyle = 'Flat'
    return $btn
}
