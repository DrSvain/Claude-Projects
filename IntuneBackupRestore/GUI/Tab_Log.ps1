#Requires -Version 7.0
<#
.SYNOPSIS
    Log tab — colour-coded live log viewer with filter, search and export.
#>

function Initialize-TabLog {
    param(
        [System.Windows.Forms.TabPage]$Tab,
        [hashtable]$GlobalState,
        [hashtable]$UIRefs
    )

    $Tab.Text    = 'Log'
    $Tab.Padding = [System.Windows.Forms.Padding]::new(8)

    # ── Toolbar panel ───────────────────────────────────────────────────────────────
    $toolbar = [System.Windows.Forms.Panel]::new()
    $toolbar.Dock   = 'Top'
    $toolbar.Height = 36
    $Tab.Controls.Add($toolbar)

    # Level filter
    $lblFilter = New-Label -Text 'Level:' -X 4 -Y 10 -Width 40
    $toolbar.Controls.Add($lblFilter)

    $cmbLevel = [System.Windows.Forms.ComboBox]::new()
    $cmbLevel.Location     = [System.Drawing.Point]::new(46, 7)
    $cmbLevel.Width        = 90
    $cmbLevel.DropDownStyle = 'DropDownList'
    $cmbLevel.Items.AddRange([string[]]@('ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR'))
    $cmbLevel.SelectedIndex = 0
    $toolbar.Controls.Add($cmbLevel)

    # Search box
    $lblSearch = New-Label -Text 'Search:' -X 146 -Y 10 -Width 50
    $toolbar.Controls.Add($lblSearch)

    $txtSearch = [System.Windows.Forms.TextBox]::new()
    $txtSearch.Location = [System.Drawing.Point]::new(198, 7)
    $txtSearch.Width    = 200
    $toolbar.Controls.Add($txtSearch)

    $btnSearch = New-StdButton -Text 'Find' -X 402 -Y 6 -Width 55 -Height 24
    $toolbar.Controls.Add($btnSearch)

    $btnClearSearch = New-StdButton -Text 'Clear' -X 460 -Y 6 -Width 55 -Height 24
    $toolbar.Controls.Add($btnClearSearch)

    # Right-side controls
    $chkAutoScroll = [System.Windows.Forms.CheckBox]::new()
    $chkAutoScroll.Text     = 'Auto-scroll'
    $chkAutoScroll.Location = [System.Drawing.Point]::new(530, 9)
    $chkAutoScroll.Size     = [System.Drawing.Size]::new(95, 20)
    $chkAutoScroll.Checked  = $true
    $toolbar.Controls.Add($chkAutoScroll)

    $btnExport = New-StdButton -Text 'Export...' -X 632 -Y 6 -Width 75 -Height 24
    $toolbar.Controls.Add($btnExport)

    $btnClearLog = New-StdButton -Text 'Clear Log' -X 712 -Y 6 -Width 75 -Height 24
    $toolbar.Controls.Add($btnClearLog)

    # ── Status bar ──────────────────────────────────────────────────────────────────
    $statusBar = [System.Windows.Forms.Panel]::new()
    $statusBar.Dock   = 'Bottom'
    $statusBar.Height = 22
    $Tab.Controls.Add($statusBar)

    $lblLineCount = New-Label -Text 'Lines: 0' -X 4 -Y 4 -Width 120
    $statusBar.Controls.Add($lblLineCount)

    $lblMatchCount = New-Label -Text '' -X 130 -Y 4 -Width 200
    $lblMatchCount.ForeColor = [System.Drawing.Color]::DarkBlue
    $statusBar.Controls.Add($lblMatchCount)

    # ── RichTextBox ──────────────────────────────────────────────────────────────────
    $rtb = [System.Windows.Forms.RichTextBox]::new()
    $rtb.Dock      = 'Fill'
    $rtb.ReadOnly  = $true
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $rtb.ForeColor = [System.Drawing.Color]::LightGray
    $rtb.Font      = [System.Drawing.Font]::new('Consolas', 8.5)
    $rtb.WordWrap  = $false
    $Tab.Controls.Add($rtb)

    # ── In-memory log store (so we can re-filter without losing history) ─────────────
    # Each entry: @{ Timestamp=''; Level=''; Message='' }
    $script:LogStore   = [System.Collections.Generic.List[hashtable]]::new()
    $script:LastFilter = 'ALL'
    $script:LastSearch = ''

    # Register UIRefs so MainForm timer can push log entries here
    $UIRefs.LogTabBox        = $rtb
    $UIRefs.LogTabAutoScroll = $chkAutoScroll
    $UIRefs.LogTabLineCount  = $lblLineCount
    $UIRefs.LogTabStore      = $script:LogStore

    # ── Level colour map ────────────────────────────────────────────────────────────
    $script:LevelColors = @{
        'DEBUG' = [System.Drawing.Color]::FromArgb(130, 130, 180)
        'INFO'  = [System.Drawing.Color]::LightGray
        'WARN'  = [System.Drawing.Color]::Gold
        'ERROR' = [System.Drawing.Color]::Tomato
        'OK'    = [System.Drawing.Color]::LightGreen
    }

    # ── Helper: append single entry to RTB ──────────────────────────────────────
    function Append-Entry {
        param([hashtable]$Entry, [string]$Highlight = '')
        $color = $script:LevelColors[$Entry.Level]
        if (-not $color) { $color = [System.Drawing.Color]::LightGray }

        $line = "[$($Entry.Timestamp)] [$($Entry.Level,-5)] $($Entry.Message)"

        if ($Highlight -and $line -match [regex]::Escape($Highlight)) {
            # Write line in two passes: before-match normal, match highlighted, after normal
            $idx = $line.IndexOf($Highlight, [System.StringComparison]::OrdinalIgnoreCase)
            $before = $line.Substring(0, $idx)
            $match  = $line.Substring($idx, $Highlight.Length)
            $after  = $line.Substring($idx + $Highlight.Length)

            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionColor  = $color
            $rtb.AppendText($before)

            $rtb.SelectionStart      = $rtb.TextLength
            $rtb.SelectionColor      = [System.Drawing.Color]::Black
            $rtb.SelectionBackColor  = [System.Drawing.Color]::Yellow
            $rtb.AppendText($match)

            $rtb.SelectionStart     = $rtb.TextLength
            $rtb.SelectionColor     = $color
            $rtb.SelectionBackColor = $rtb.BackColor
            $rtb.AppendText("$after`n")
        } else {
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionLength = 0
            $rtb.SelectionColor  = $color
            $rtb.AppendText("$line`n")
        }
    }

    # ── Helper: full redraw of RTB from store, applying current filter+search ───────
    function Redraw-Log {
        $filterLevel = $cmbLevel.SelectedItem
        $searchTerm  = $txtSearch.Text.Trim()
        $script:LastFilter = $filterLevel
        $script:LastSearch = $searchTerm

        $rtb.SuspendLayout()
        $rtb.Clear()

        $matchCount = 0
        foreach ($entry in $script:LogStore) {
            if ($filterLevel -ne 'ALL' -and $entry.Level -ne $filterLevel) { continue }
            if ($searchTerm -and $entry.Message -notmatch [regex]::Escape($searchTerm)) { continue }
            Append-Entry -Entry $entry -Highlight $searchTerm
            $matchCount++
        }

        $rtb.ResumeLayout()
        $lblLineCount.Text  = "Lines: $($script:LogStore.Count)"
        $lblMatchCount.Text = if ($searchTerm -or $filterLevel -ne 'ALL') {
            "Showing: $matchCount"
        } else { '' }

        if ($chkAutoScroll.Checked) { $rtb.ScrollToCaret() }
    }

    # ── Public function called by MainForm timer to push new log entries ──────────
    # (Stored in UIRefs so MainForm can call it without knowing internals)
    $UIRefs.PushLogEntry = {
        param([hashtable]$Entry)
        # Entry: @{ Timestamp; Level; Message }
        $script:LogStore.Add($Entry)

        $filterLevel = $cmbLevel.SelectedItem
        $searchTerm  = $txtSearch.Text.Trim()

        $levelMatch = ($filterLevel -eq 'ALL') -or ($Entry.Level -eq $filterLevel)
        $searchMatch = (-not $searchTerm) -or ($Entry.Message -match [regex]::Escape($searchTerm))

        if ($levelMatch -and $searchMatch) {
            Append-Entry -Entry $Entry -Highlight $searchTerm
            $lblLineCount.Text = "Lines: $($script:LogStore.Count)"
            if ($chkAutoScroll.Checked) { $rtb.ScrollToCaret() }
        } else {
            $lblLineCount.Text = "Lines: $($script:LogStore.Count)"
        }
    }

    # ── Filter / Search events ────────────────────────────────────────────────────
    $cmbLevel.Add_SelectedIndexChanged({ Redraw-Log })

    $btnSearch.Add_Click({ Redraw-Log })

    $txtSearch.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Return') {
            Redraw-Log
            $e.SuppressKeyPress = $true
        }
    })

    $btnClearSearch.Add_Click({
        $txtSearch.Clear()
        Redraw-Log
    })

    # ── Clear log ──────────────────────────────────────────────────────────────────
    $btnClearLog.Add_Click({
        $dlg = [System.Windows.Forms.MessageBox]::Show(
            'Clear all log entries?',
            'Confirm Clear',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($dlg -eq 'Yes') {
            $script:LogStore.Clear()
            $rtb.Clear()
            $lblLineCount.Text  = 'Lines: 0'
            $lblMatchCount.Text = ''
        }
    })

    # ── Export log ──────────────────────────────────────────────────────────────────
    $btnExport.Add_Click({
        if ($script:LogStore.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'No log entries to export.',
                'Export Log',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }

        $sfd = [System.Windows.Forms.SaveFileDialog]::new()
        $sfd.Title      = 'Export Log'
        $sfd.Filter     = 'Log file (*.log)|*.log|Text file (*.txt)|*.txt|All files (*.*)|*.*'
        $sfd.FileName   = "IntuneBackupRestore_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"

        $cfgPath = $GlobalState['Config']?['BackupRootPath']
        if ($cfgPath -and (Test-Path $cfgPath)) { $sfd.InitialDirectory = $cfgPath }

        if ($sfd.ShowDialog() -ne 'OK') { return }

        try {
            $filterLevel = $cmbLevel.SelectedItem
            $searchTerm  = $txtSearch.Text.Trim()

            $lines = foreach ($entry in $script:LogStore) {
                if ($filterLevel -ne 'ALL' -and $entry.Level -ne $filterLevel) { continue }
                if ($searchTerm -and $entry.Message -notmatch [regex]::Escape($searchTerm)) { continue }
                "[$($entry.Timestamp)] [$($entry.Level,-5)] $($entry.Message)"
            }

            $lines | Set-Content -Path $sfd.FileName -Encoding UTF8

            [System.Windows.Forms.MessageBox]::Show(
                "Exported $(@($lines).Count) line(s) to:`n$($sfd.FileName)",
                'Export Complete',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Export failed: $_",
                'Export Error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })
}

# ── Small layout helpers (private to this file) ──────────────────────────────
function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 80)
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text      = $Text
    $lbl.Location  = [System.Drawing.Point]::new($X, $Y)
    $lbl.Size      = [System.Drawing.Size]::new($Width, 18)
    $lbl.TextAlign = 'MiddleLeft'
    return $lbl
}

function New-StdButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 80, [int]$Height = 26)
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text      = $Text
    $btn.Location  = [System.Drawing.Point]::new($X, $Y)
    $btn.Size      = [System.Drawing.Size]::new($Width, $Height)
    $btn.FlatStyle = 'Flat'
    return $btn
}
