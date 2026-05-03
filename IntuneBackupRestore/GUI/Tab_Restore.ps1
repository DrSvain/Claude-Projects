#Requires -Version 7.0
<#
.SYNOPSIS
    Restore tab — load backup, select objects, detect conflicts, run restore.
#>

function Initialize-TabRestore {
    param(
        [hashtable]$UIRefs,
        [hashtable]$GlobalState
    )

    $Tab = New-Object System.Windows.Forms.TabPage
    $Tab.Text = 'Restore'
    $Tab.Padding = [System.Windows.Forms.Padding]::new(10)

    # ── outer split: left panel | right log panel ────────────────────────────
    # NOTE: SplitterDistance / Panel*MinSize must satisfy
    #   Panel1MinSize + Panel2MinSize <= Width
    # When the SplitContainer is first created its Width is tiny (the parent
    # TabPage hasn't been added to a TabControl yet), so we defer the final
    # values to HandleCreated, which fires after layout when Width is real.
    $split = [System.Windows.Forms.SplitContainer]::new()
    $split.Dock          = 'Fill'
    $split.Orientation   = 'Vertical'
    $split.Panel1MinSize = 25
    $split.Panel2MinSize = 25
    $Tab.Controls.Add($split)

    $split.Add_HandleCreated({
        try {
            if ($split.Width -ge 500) {
                $split.Panel2MinSize    = 200
                $split.SplitterDistance = [Math]::Min(680, $split.Width - $split.Panel2MinSize - 10)
            }
        } catch { }
    })

    # ════════════════════════════════════════════════════════════════════════
    # LEFT PANEL
    # ════════════════════════════════════════════════════════════════════════
    $left = $split.Panel1

    # ── Section 1 : Backup source ────────────────────────────────────────────
    $grpSource = New-GroupBox -Text 'Backup Source' -Dock 'Top' -Height 70
    $left.Controls.Add($grpSource)

    $txtPath = [System.Windows.Forms.TextBox]::new()
    $txtPath.Location  = [System.Drawing.Point]::new(8, 22)
    $txtPath.Width     = 520
    $txtPath.Height    = 22
    $txtPath.ReadOnly  = $true
    $txtPath.BackColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($txtPath)

    $btnBrowse = New-Button -Text 'Browse...' -X 534 -Y 21 -Width 80 -Height 24
    $grpSource.Controls.Add($btnBrowse)

    $btnLoad = New-Button -Text 'Load Backup' -X 620 -Y 21 -Width 100 -Height 24
    $btnLoad.Enabled = $false
    $grpSource.Controls.Add($btnLoad)

    # ── Section 2 : Manifest info ────────────────────────────────────────────
    $grpManifest = New-GroupBox -Text 'Backup Manifest' -Dock 'Top' -Height 90
    $left.Controls.Add($grpManifest)

    $lblManifest = [System.Windows.Forms.Label]::new()
    $lblManifest.Location  = [System.Drawing.Point]::new(8, 18)
    $lblManifest.Size      = [System.Drawing.Size]::new(710, 65)
    $lblManifest.Text      = 'No backup loaded.'
    $lblManifest.ForeColor = [System.Drawing.Color]::Gray
    $lblManifest.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $grpManifest.Controls.Add($lblManifest)

    # ── Section 3 : Object selection grid ───────────────────────────────────
    $grpObjects = New-GroupBox -Text 'Objects to Restore' -Dock 'Fill'
    $left.Controls.Add($grpObjects)

    # toolbar above grid
    $toolPanel = [System.Windows.Forms.Panel]::new()
    $toolPanel.Dock   = 'Top'
    $toolPanel.Height = 30
    $grpObjects.Controls.Add($toolPanel)

    $btnSelAll  = New-Button -Text 'Select All'   -X 4  -Y 3 -Width 90 -Height 24
    $btnSelNone = New-Button -Text 'Select None'  -X 98 -Y 3 -Width 90 -Height 24
    $btnSelConflict = New-Button -Text 'Skip Conflicts' -X 192 -Y 3 -Width 100 -Height 24
    $btnSelConflict.Enabled = $false
    $toolPanel.Controls.AddRange(@($btnSelAll, $btnSelNone, $btnSelConflict))

    $lblConflictCount = [System.Windows.Forms.Label]::new()
    $lblConflictCount.Location  = [System.Drawing.Point]::new(300, 7)
    $lblConflictCount.Size      = [System.Drawing.Size]::new(300, 18)
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
        @{Name='Workload';  Header='Workload';   Fill=15},
        @{Name='Name';      Header='Name';       Fill=40},
        @{Name='Conflict';  Header='Conflict';   Fill=10},
        @{Name='FileName';  Header='File';       Fill=25},
        @{Name='Warning';   Header='Warning';    Fill=10}
    )) {
        $c = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $c.Name       = $col.Name
        $c.HeaderText = $col.Header
        $c.FillWeight = $col.Fill
        $c.ReadOnly   = $true
        $grid.Columns.Add($c) | Out-Null
    }

    # ── Section 4 : Restore options + action ────────────────────────────────
    $grpAction = New-GroupBox -Text 'Restore Options' -Dock 'Bottom' -Height 80
    $left.Controls.Add($grpAction)

    $chkSkipConflicts = [System.Windows.Forms.CheckBox]::new()
    $chkSkipConflicts.Text     = 'Skip conflicting objects (already exist in tenant)'
    $chkSkipConflicts.Location = [System.Drawing.Point]::new(8, 20)
    $chkSkipConflicts.Size     = [System.Drawing.Size]::new(380, 20)
    $chkSkipConflicts.Checked  = $true
    $grpAction.Controls.Add($chkSkipConflicts)

    $chkDryRun = [System.Windows.Forms.CheckBox]::new()
    $chkDryRun.Text     = 'Dry run (log only, no changes)'
    $chkDryRun.Location = [System.Drawing.Point]::new(8, 44)
    $chkDryRun.Size     = [System.Drawing.Size]::new(280, 20)
    $chkDryRun.Checked  = $false
    $grpAction.Controls.Add($chkDryRun)

    $btnDetectConflicts = New-Button -Text 'Detect Conflicts' -X 420 -Y 18 -Width 130 -Height 26
    $btnDetectConflicts.Enabled = $false
    $grpAction.Controls.Add($btnDetectConflicts)

    $btnStartRestore = New-Button -Text 'Start Restore' -X 556 -Y 18 -Width 120 -Height 26
    $btnStartRestore.Enabled    = $false
    $btnStartRestore.BackColor  = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $btnStartRestore.ForeColor  = [System.Drawing.Color]::White
    $btnStartRestore.FlatStyle  = 'Flat'
    $grpAction.Controls.Add($btnStartRestore)

    # progress bar + status
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
    # RIGHT PANEL  —  Restore log
    # ════════════════════════════════════════════════════════════════════════
    $right = $split.Panel2

    $grpLog = New-GroupBox -Text 'Restore Log' -Dock 'Fill'
    $right.Controls.Add($grpLog)

    $rtbLog = [System.Windows.Forms.RichTextBox]::new()
    $rtbLog.Dock      = 'Fill'
    $rtbLog.ReadOnly  = $true
    $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $rtbLog.ForeColor = [System.Drawing.Color]::LightGray
    $rtbLog.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $grpLog.Controls.Add($rtbLog)

    $btnClearLog = New-Button -Text 'Clear' -X 4 -Y 0 -Width 60 -Height 22
    $btnClearLog.Dock = 'Bottom'
    $grpLog.Controls.Add($btnClearLog)

    # ════════════════════════════════════════════════════════════════════════
    # Register UIRefs
    # ════════════════════════════════════════════════════════════════════════
    $UIRefs.RestoreObjectGrid      = $grid
    $UIRefs.BtnStartRestore        = $btnStartRestore
    $UIRefs.BtnDetectConflicts     = $btnDetectConflicts
    $UIRefs.RestoreProgressBar     = $restoreProgress
    $UIRefs.RestoreStatusLabel     = $lblRestoreStatus
    $UIRefs.RestoreLogBox          = $rtbLog
    $UIRefs.ChkRestoreSkipConflict = $chkSkipConflicts
    $UIRefs.ChkRestoreDryRun       = $chkDryRun

    # ════════════════════════════════════════════════════════════════════════
    # State for this tab
    # ════════════════════════════════════════════════════════════════════════
    $script:RestoreIndex   = $null   # parsed index.json
    $script:BackupRoot     = $null   # folder containing manifest.json
    $script:ConflictMap    = @{}     # workload -> [conflicting names]
    $script:RestoreRunning = $false

    # ════════════════════════════════════════════════════════════════════════
    # Helper: append line to restore log
    # ════════════════════════════════════════════════════════════════════════
    function Add-RestoreLog {
        param([string]$Text, [string]$Level = 'INFO')
        $color = switch ($Level) {
            'ERROR' { [System.Drawing.Color]::Tomato }
            'WARN'  { [System.Drawing.Color]::Gold }
            'OK'    { [System.Drawing.Color]::LightGreen }
            default { [System.Drawing.Color]::LightGray }
        }
        $ts = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] $Text`n"
        $rtbLog.SelectionStart  = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor  = $color
        $rtbLog.AppendText($line)
        $rtbLog.ScrollToCaret()
    }

    # ════════════════════════════════════════════════════════════════════════
    # Helper: populate grid from index
    # ════════════════════════════════════════════════════════════════════════
    function Load-GridFromIndex {
        $grid.Rows.Clear()
        if ($null -eq $script:RestoreIndex) { return }

        foreach ($entry in $script:RestoreIndex) {
            $hasWarning  = if ($entry.PSObject.Properties['RestoreWarning']) { '⚠' } else { '' }
            $isConflict  = $false
            if ($script:ConflictMap.ContainsKey($entry.Workload)) {
                $isConflict = $script:ConflictMap[$entry.Workload] -contains $entry.Name
            }
            $conflictTxt = if ($isConflict) { 'YES' } else { '' }

            $rowIdx = $grid.Rows.Add()
            $row    = $grid.Rows[$rowIdx]
            $row.Cells['Selected'].Value  = (-not $isConflict)  # pre-deselect conflicts
            $row.Cells['Workload'].Value  = $entry.Workload
            $row.Cells['Name'].Value      = $entry.Name
            $row.Cells['Conflict'].Value  = $conflictTxt
            $row.Cells['FileName'].Value  = $entry.FileName
            $row.Cells['Warning'].Value   = $hasWarning

            if ($isConflict) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkOrange
            } elseif ($hasWarning) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            }
        }

        $conflictTotal = ($grid.Rows | Where-Object { $_.Cells['Conflict'].Value -eq 'YES' }).Count
        if ($conflictTotal -gt 0) {
            $lblConflictCount.Text = "$conflictTotal conflict(s) detected"
            $btnSelConflict.Enabled = $true
        } else {
            $lblConflictCount.Text = ''
            $btnSelConflict.Enabled = $false
        }
    }

    # ════════════════════════════════════════════════════════════════════════
    # Browse button
    # ════════════════════════════════════════════════════════════════════════
    $btnBrowse.Add_Click({
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dlg.Description = 'Select a backup snapshot folder (contains manifest.json)'
        $dlg.ShowNewFolderButton = $false

        # pre-populate from config
        $cfgPath = $GlobalState['Config']?['BackupRootPath']
        if ($cfgPath -and (Test-Path $cfgPath)) {
            $dlg.SelectedPath = $cfgPath
        }

        if ($dlg.ShowDialog() -eq 'OK') {
            $txtPath.Text       = $dlg.SelectedPath
            $btnLoad.Enabled    = $true
        }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Load backup button
    # ════════════════════════════════════════════════════════════════════════
    $btnLoad.Add_Click({
        $folder = $txtPath.Text.Trim()
        if (-not $folder -or -not (Test-Path $folder)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Folder not found.', 'Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        $manifestFile = Join-Path $folder 'manifest.json'
        $indexFile    = Join-Path $folder 'index.json'

        if (-not (Test-Path $manifestFile)) {
            [System.Windows.Forms.MessageBox]::Show(
                "manifest.json not found in:`n$folder",
                'Invalid Backup',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        try {
            $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
            $script:BackupRoot = $folder

            $statusTxt = @(
                "Tenant : $($manifest.TenantName)  ($($manifest.TenantId))"
                "Date   : $($manifest.BackupStarted)"
                "Status : $($manifest.Status)    Objects: $($manifest.TotalObjects)"
                "Workloads: $($manifest.Workloads -join ', ')"
            ) -join "`n"
            $lblManifest.Text      = $statusTxt
            $lblManifest.ForeColor = if ($manifest.Status -eq 'Completed') {
                [System.Drawing.Color]::DarkGreen
            } else {
                [System.Drawing.Color]::DarkOrange
            }

            if (Test-Path $indexFile) {
                $script:RestoreIndex   = Get-Content $indexFile -Raw | ConvertFrom-Json
                $script:ConflictMap    = @{}
                Load-GridFromIndex
                $btnDetectConflicts.Enabled = $true
                $btnStartRestore.Enabled    = $true
                Add-RestoreLog "Loaded $(@($script:RestoreIndex).Count) object(s) from backup." 'OK'
            } else {
                Add-RestoreLog 'index.json not found — cannot populate object list.' 'WARN'
            }
        } catch {
            Add-RestoreLog "Failed to load backup: $_" 'ERROR'
        }
    })

    # ════════════════════════════════════════════════════════════════════════
    # Select All / None / Skip Conflicts
    # ════════════════════════════════════════════════════════════════════════
    $btnSelAll.Add_Click({
        foreach ($row in $grid.Rows) { $row.Cells['Selected'].Value = $true }
        $grid.RefreshEdit()
    })

    $btnSelNone.Add_Click({
        foreach ($row in $grid.Rows) { $row.Cells['Selected'].Value = $false }
        $grid.RefreshEdit()
    })

    $btnSelConflict.Add_Click({
        foreach ($row in $grid.Rows) {
            if ($row.Cells['Conflict'].Value -eq 'YES') {
                $row.Cells['Selected'].Value = $false
            }
        }
        $grid.RefreshEdit()
        Add-RestoreLog 'Deselected all conflicting objects.' 'INFO'
    })

    # ════════════════════════════════════════════════════════════════════════
    # Detect Conflicts button
    # ════════════════════════════════════════════════════════════════════════
    $btnDetectConflicts.Add_Click({
        if (-not $GlobalState['Connected']) {
            [System.Windows.Forms.MessageBox]::Show(
                'Connect to Intune first.',
                'Not Connected',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($null -eq $script:RestoreIndex) { return }

        $btnDetectConflicts.Enabled = $false
        $btnDetectConflicts.Text    = 'Detecting...'
        Add-RestoreLog 'Detecting conflicts in target tenant...' 'INFO'

        # Build workload list from index
        $workloads = @($script:RestoreIndex | Select-Object -ExpandProperty Workload -Unique)

        # Run conflict detection in background
        $backupRoot   = $script:BackupRoot
        $restoreIndex = $script:RestoreIndex

        $UIRefs.MainForm.Invoke([Action]{
            Start-BackgroundOperation -GlobalState $GlobalState -UIRefs $UIRefs `
                -OperationKey 'ConflictDetect' `
                -ScriptBlock {
                    param($State, $BRoot, $RIndex)
                    Import-Module (Join-Path $State['AppRoot'] 'Modules/RestoreEngine.psm1') -Force

                    $conflictResult = @{}
                    foreach ($wl in ($RIndex | Select-Object -ExpandProperty Workload -Unique)) {
                        try {
                            $conflicts = Test-RestoreConflicts -Workload $wl -LogQueue $State['LogQueue']
                            $conflictResult[$wl] = $conflicts
                        } catch {
                            Write-LogToQueue -Queue $State['LogQueue'] -Level 'WARN' `
                                -Message "Conflict check failed for $wl : $_"
                        }
                    }
                    $State['ConflictResult'] = $conflictResult
                } `
                -ArgumentList @($GlobalState, $backupRoot, $restoreIndex)
        })

        # Poll until done
        $pollTimer = [System.Windows.Forms.Timer]::new()
        $pollTimer.Interval = 400
        $pollTimer.Add_Tick({
            if (-not $GlobalState['OperationRunning_ConflictDetect']) {
                $pollTimer.Stop()
                $pollTimer.Dispose()

                $result = $GlobalState['ConflictResult']
                if ($null -ne $result) {
                    $script:ConflictMap = $result
                    Load-GridFromIndex
                    $total = ($result.Values | ForEach-Object { $_ } | Measure-Object).Count
                    Add-RestoreLog "Conflict detection complete. $total conflict(s) found." 'OK'
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
    # Clear log
    # ════════════════════════════════════════════════════════════════════════
    $btnClearLog.Add_Click({ $rtbLog.Clear() })

    # ════════════════════════════════════════════════════════════════════════
    # Start Restore button
    # ════════════════════════════════════════════════════════════════════════
    $btnStartRestore.Add_Click({
        if ($script:RestoreRunning) { return }

        if (-not $GlobalState['Connected']) {
            [System.Windows.Forms.MessageBox]::Show(
                'Connect to Intune first.',
                'Not Connected',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        # Collect selected rows
        $selectedItems = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($row in $grid.Rows) {
            if ($row.Cells['Selected'].Value -eq $true) {
                $selectedItems.Add(@{
                    Workload = $row.Cells['Workload'].Value
                    Name     = $row.Cells['Name'].Value
                    FileName = $row.Cells['FileName'].Value
                })
            }
        }

        if ($selectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'No objects selected for restore.',
                'Nothing to Restore',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        # Confirmation dialog
        $isDryRun    = $chkDryRun.Checked
        $dryRunLabel = if ($isDryRun) { ' (DRY RUN)' } else { '' }
        $confirmMsg  = @(
            "You are about to restore $($selectedItems.Count) object(s)$dryRunLabel to:"
            "Tenant: $($GlobalState['TenantName'])  ($($GlobalState['TenantId']))"
            ''
        )

        # Group by workload for readability
        $grouped = $selectedItems | Group-Object Workload
        foreach ($g in $grouped) {
            $confirmMsg += "  $($g.Name) : $($g.Count) object(s)"
        }

        if (-not $isDryRun) {
            $confirmMsg += ''
            $confirmMsg += 'This operation CANNOT be automatically undone. Continue?'
        }

        $dlgResult = [System.Windows.Forms.MessageBox]::Show(
            ($confirmMsg -join "`n"),
            "Confirm Restore$dryRunLabel",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)

        if ($dlgResult -ne 'Yes') {
            Add-RestoreLog 'Restore cancelled by user.' 'INFO'
            return
        }

        # ── Launch restore ────────────────────────────────────────────────
        $script:RestoreRunning      = $true
        $btnStartRestore.Enabled    = $false
        $btnDetectConflicts.Enabled = $false
        $lblRestoreStatus.Text      = 'Restoring...'
        $lblRestoreStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        $restoreProgress.Value      = 0

        Add-RestoreLog "Starting restore of $($selectedItems.Count) object(s)$dryRunLabel..." 'INFO'

        $backupRoot      = $script:BackupRoot
        $skipConflicts   = $chkSkipConflicts.Checked
        $dryRun          = $isDryRun
        $itemsToRestore  = $selectedItems

        Start-BackgroundOperation -GlobalState $GlobalState -UIRefs $UIRefs `
            -OperationKey 'Restore' `
            -ScriptBlock {
                param($State, $BRoot, $Items, $SkipConflicts, $DryRun)
                Import-Module (Join-Path $State['AppRoot'] 'Modules/RestoreEngine.psm1') -Force

                Start-IntuneRestore `
                    -BackupFolder    $BRoot `
                    -ItemsToRestore  $Items `
                    -SkipConflicts   $SkipConflicts `
                    -DryRun          $DryRun `
                    -GlobalState     $State
            } `
            -ArgumentList @($GlobalState, $backupRoot, $itemsToRestore, $skipConflicts, $dryRun)

        # Poll for completion
        $restoreTimer = [System.Windows.Forms.Timer]::new()
        $restoreTimer.Interval = 500
        $restoreTimer.Add_Tick({
            # Drain progress from GlobalState
            $pct = $GlobalState['RestoreProgress']
            if ($null -ne $pct) {
                $restoreProgress.Value = [Math]::Min([int]$pct, 100)
            }

            # Drain log messages written by runspace
            $logQ = $GlobalState['LogQueue']
            if ($null -ne $logQ) {
                $msg = $null
                while ($logQ.TryDequeue([ref]$msg)) {
                    $level = if ($msg.Level) { $msg.Level } else { 'INFO' }
                    Add-RestoreLog $msg.Message $level
                }
            }

            if (-not $GlobalState['OperationRunning_Restore']) {
                $restoreTimer.Stop()
                $restoreTimer.Dispose()

                $result     = $GlobalState['RestoreResult']
                $succeeded  = if ($result?.Succeeded) { $result.Succeeded } else { 0 }
                $failed     = if ($result?.Failed)    { $result.Failed }    else { 0 }
                $skipped    = if ($result?.Skipped)   { $result.Skipped }   else { 0 }

                $summary = "Restore complete — Succeeded: $succeeded  Failed: $failed  Skipped: $skipped"
                Add-RestoreLog $summary 'OK'

                $lblRestoreStatus.Text      = $summary
                $lblRestoreStatus.ForeColor = if ($failed -gt 0) {
                    [System.Drawing.Color]::DarkRed
                } else {
                    [System.Drawing.Color]::DarkGreen
                }
                $restoreProgress.Value = 100

                $btnStartRestore.Enabled    = $true
                $btnDetectConflicts.Enabled = $true
                $script:RestoreRunning      = $false
            }
        })
        $restoreTimer.Start()
    })

    return $Tab
}

# ── Small helpers (avoid duplication with other tabs) ────────────────────────
function New-GroupBox {
    param([string]$Text, [string]$Dock = 'None', [int]$Height = 0)
    $gb = [System.Windows.Forms.GroupBox]::new()
    $gb.Text    = $Text
    $gb.Dock    = $Dock
    if ($Height -gt 0) { $gb.Height = $Height }
    $gb.Padding = [System.Windows.Forms.Padding]::new(6)
    return $gb
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 90, [int]$Height = 26)
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text     = $Text
    $btn.Location = [System.Drawing.Point]::new($X, $Y)
    $btn.Size     = [System.Drawing.Size]::new($Width, $Height)
    $btn.FlatStyle = 'Flat'
    return $btn
}
