Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------
# Helper Functions
# ----------------------------

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Test-ExchangeConnection {
    try {
        Get-EXOMailbox -ResultSize 1 -ErrorAction Stop | Out-Null
        return $true
    }
    catch { return $false }
}

function Test-IPPSConnection {
    try {
        Get-ComplianceSearch -ResultSize 1 -ErrorAction Stop | Out-Null
        return $true
    }
    catch { return $false }
}

function Update-ConnectionStatus {
    $exo  = Test-ExchangeConnection
    $ipps = Test-IPPSConnection

    if ($exo -and $ipps) {
        $lblConnStatus.Text      = "EXO + IPPS Connected"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::Green
    }
    elseif ($exo) {
        $lblConnStatus.Text      = "EXO Connected"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    elseif ($ipps) {
        $lblConnStatus.Text      = "IPPS Connected"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $lblConnStatus.Text      = "Not Connected"
        $lblConnStatus.ForeColor = [System.Drawing.Color]::Red
    }
}

function Build-ContentMatchQuery {
    param([string[]]$Domains)

    $cleanDomains = $Domains |
        ForEach-Object { $_.Trim().ToLower() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique

    if (-not $cleanDomains -or $cleanDomains.Count -eq 0) {
        throw "No domains were provided."
    }

    $domainQuery = ($cleanDomains | ForEach-Object { "participants:`"$_`"" }) -join " OR "
    return "(folderid:sentitems) AND ($domainQuery)"
}

function Wait-ComplianceSearchComplete {
    param(
        [string]$SearchName,
        [int]$PollSeconds = 5,
        [int]$TimeoutMinutes = 20
    )

    $start = Get-Date
    do {
        Start-Sleep -Seconds $PollSeconds
        $search = Get-ComplianceSearch -Identity $SearchName -ErrorAction Stop
        Write-Log "Search status: $($search.Status)"
        if ($search.Status -in @("Completed","PartiallySucceeded","Failed","Stopped")) {
            return $search
        }
    } while ((Get-Date) -lt $start.AddMinutes($TimeoutMinutes))

    throw "Timed out waiting for compliance search to finish."
}

# ----------------------------
# Main Form
# ----------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text        = "Microsoft 365 User Activity Audit"
$form.Size        = New-Object System.Drawing.Size(980, 840)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(980, 840)

# -----------------------------------------------
# TOP PANEL  --  shared user email + connections
# -----------------------------------------------

$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Location    = New-Object System.Drawing.Point(0, 0)
$pnlTop.Size        = New-Object System.Drawing.Size(980, 62)
$pnlTop.BorderStyle = "FixedSingle"
$pnlTop.BackColor   = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($pnlTop)

$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Location = New-Object System.Drawing.Point(10, 9)
$lblUser.Size     = New-Object System.Drawing.Size(115, 20)
$lblUser.Text     = "User Email Address:"
$pnlTop.Controls.Add($lblUser)

$txtUserEmail = New-Object System.Windows.Forms.TextBox
$txtUserEmail.Location = New-Object System.Drawing.Point(130, 6)
$txtUserEmail.Size     = New-Object System.Drawing.Size(270, 26)
$pnlTop.Controls.Add($txtUserEmail)

$btnConnectEXO = New-Object System.Windows.Forms.Button
$btnConnectEXO.Location = New-Object System.Drawing.Point(420, 5)
$btnConnectEXO.Size     = New-Object System.Drawing.Size(195, 28)
$btnConnectEXO.Text     = "Connect Exchange Online"
$pnlTop.Controls.Add($btnConnectEXO)

$btnConnectIPPS = New-Object System.Windows.Forms.Button
$btnConnectIPPS.Location = New-Object System.Drawing.Point(625, 5)
$btnConnectIPPS.Size     = New-Object System.Drawing.Size(200, 28)
$btnConnectIPPS.Text     = "Connect IPPS / Compliance"
$pnlTop.Controls.Add($btnConnectIPPS)

$lblConnStatus = New-Object System.Windows.Forms.Label
$lblConnStatus.Location  = New-Object System.Drawing.Point(835, 9)
$lblConnStatus.Size      = New-Object System.Drawing.Size(130, 20)
$lblConnStatus.Text      = "Not Connected"
$lblConnStatus.ForeColor = [System.Drawing.Color]::Red
$lblConnStatus.Font      = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$pnlTop.Controls.Add($lblConnStatus)

$lblIPPSNote = New-Object System.Windows.Forms.Label
$lblIPPSNote.Location  = New-Object System.Drawing.Point(625, 36)
$lblIPPSNote.Size      = New-Object System.Drawing.Size(340, 18)
$lblIPPSNote.Text      = "IPPS required for Email Audit only"
$lblIPPSNote.ForeColor = [System.Drawing.Color]::Gray
$lblIPPSNote.Font      = New-Object System.Drawing.Font("Segoe UI", 7.5)
$pnlTop.Controls.Add($lblIPPSNote)

# -----------------------------------------------
# TAB CONTROL
# -----------------------------------------------

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 72)
$tabControl.Size     = New-Object System.Drawing.Size(955, 610)
$tabControl.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($tabControl)

# =====================================================
#  TAB 1  --  EMAIL AUDIT
# =====================================================

$tabEmail      = New-Object System.Windows.Forms.TabPage
$tabEmail.Text = "  Email Audit  "
$tabControl.Controls.Add($tabEmail)

$lblMailboxNote = New-Object System.Windows.Forms.Label
$lblMailboxNote.Location = New-Object System.Drawing.Point(10, 14)
$lblMailboxNote.Size     = New-Object System.Drawing.Size(880, 20)
$lblMailboxNote.Text     = "Audits sent items in the mailbox entered above. Searches for messages sent to personal email domains listed below."
$lblMailboxNote.ForeColor = [System.Drawing.Color]::DimGray
$tabEmail.Controls.Add($lblMailboxNote)

$lblDomains = New-Object System.Windows.Forms.Label
$lblDomains.Location = New-Object System.Drawing.Point(10, 45)
$lblDomains.Size     = New-Object System.Drawing.Size(280, 20)
$lblDomains.Text     = "Personal Email Domains (one per line):"
$tabEmail.Controls.Add($lblDomains)

$txtDomains = New-Object System.Windows.Forms.TextBox
$txtDomains.Location   = New-Object System.Drawing.Point(10, 68)
$txtDomains.Size       = New-Object System.Drawing.Size(300, 185)
$txtDomains.Multiline  = $true
$txtDomains.ScrollBars = "Vertical"
$txtDomains.Text = @"
gmail.com
yahoo.com
outlook.com
hotmail.com
icloud.com
aol.com
live.com
msn.com
me.com
proton.me
protonmail.com
"@
$tabEmail.Controls.Add($txtDomains)

$btnRunAudit = New-Object System.Windows.Forms.Button
$btnRunAudit.Location = New-Object System.Drawing.Point(330, 68)
$btnRunAudit.Size     = New-Object System.Drawing.Size(165, 38)
$btnRunAudit.Text     = "Run Email Audit"
$btnRunAudit.BackColor = [System.Drawing.Color]::SteelBlue
$btnRunAudit.ForeColor = [System.Drawing.Color]::White
$btnRunAudit.FlatStyle = "Flat"
$tabEmail.Controls.Add($btnRunAudit)

$btnExportEmail = New-Object System.Windows.Forms.Button
$btnExportEmail.Location = New-Object System.Drawing.Point(330, 120)
$btnExportEmail.Size     = New-Object System.Drawing.Size(165, 35)
$btnExportEmail.Text     = "Export Results CSV"
$tabEmail.Controls.Add($btnExportEmail)

$lblEmailResults = New-Object System.Windows.Forms.Label
$lblEmailResults.Location = New-Object System.Drawing.Point(10, 270)
$lblEmailResults.Size     = New-Object System.Drawing.Size(100, 20)
$lblEmailResults.Text     = "Results:"
$tabEmail.Controls.Add($lblEmailResults)

$dgvEmailResults = New-Object System.Windows.Forms.DataGridView
$dgvEmailResults.Location            = New-Object System.Drawing.Point(10, 293)
$dgvEmailResults.Size                = New-Object System.Drawing.Size(925, 280)
$dgvEmailResults.AutoSizeColumnsMode = "Fill"
$dgvEmailResults.AllowUserToAddRows  = $false
$dgvEmailResults.ReadOnly            = $true
$dgvEmailResults.BackgroundColor     = [System.Drawing.Color]::White
$tabEmail.Controls.Add($dgvEmailResults)

$emailResultTable = New-Object System.Data.DataTable
[void]$emailResultTable.Columns.Add("Mailbox")
[void]$emailResultTable.Columns.Add("SearchName")
[void]$emailResultTable.Columns.Add("Status")
[void]$emailResultTable.Columns.Add("Items")
[void]$emailResultTable.Columns.Add("Size")
[void]$emailResultTable.Columns.Add("Query")
$dgvEmailResults.DataSource = $emailResultTable

# =====================================================
#  TAB 2  --  TEAMS / ONEDRIVE / SHAREPOINT AUDIT
# =====================================================

$tabFile      = New-Object System.Windows.Forms.TabPage
$tabFile.Text = "  Teams / OneDrive / SharePoint Audit  "
$tabControl.Controls.Add($tabFile)

$lblFileNote = New-Object System.Windows.Forms.Label
$lblFileNote.Location  = New-Object System.Drawing.Point(10, 14)
$lblFileNote.Size      = New-Object System.Drawing.Size(920, 20)
$lblFileNote.Text      = "Queries the Unified Audit Log for file uploads, downloads, and deletions. Requires Exchange Online connection. Audit logs may have up to a 24-hour delay."
$lblFileNote.ForeColor = [System.Drawing.Color]::DimGray
$tabFile.Controls.Add($lblFileNote)

# -- Date Range --
$lblStartDate = New-Object System.Windows.Forms.Label
$lblStartDate.Location = New-Object System.Drawing.Point(10, 46)
$lblStartDate.Size     = New-Object System.Drawing.Size(68, 20)
$lblStartDate.Text     = "Start Date:"
$tabFile.Controls.Add($lblStartDate)

$dtpStart = New-Object System.Windows.Forms.DateTimePicker
$dtpStart.Location = New-Object System.Drawing.Point(80, 43)
$dtpStart.Size     = New-Object System.Drawing.Size(175, 26)
$dtpStart.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpStart.Value    = (Get-Date).AddDays(-30)
$tabFile.Controls.Add($dtpStart)

$lblEndDate = New-Object System.Windows.Forms.Label
$lblEndDate.Location = New-Object System.Drawing.Point(270, 46)
$lblEndDate.Size     = New-Object System.Drawing.Size(62, 20)
$lblEndDate.Text     = "End Date:"
$tabFile.Controls.Add($lblEndDate)

$dtpEnd = New-Object System.Windows.Forms.DateTimePicker
$dtpEnd.Location = New-Object System.Drawing.Point(335, 43)
$dtpEnd.Size     = New-Object System.Drawing.Size(175, 26)
$dtpEnd.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpEnd.Value    = Get-Date
$tabFile.Controls.Add($dtpEnd)

# -- Services Group --
$grpServices = New-Object System.Windows.Forms.GroupBox
$grpServices.Location = New-Object System.Drawing.Point(10, 80)
$grpServices.Size     = New-Object System.Drawing.Size(220, 110)
$grpServices.Text     = "Services"
$tabFile.Controls.Add($grpServices)

$chkSharePoint = New-Object System.Windows.Forms.CheckBox
$chkSharePoint.Location = New-Object System.Drawing.Point(12, 24)
$chkSharePoint.Size     = New-Object System.Drawing.Size(160, 22)
$chkSharePoint.Text     = "SharePoint"
$chkSharePoint.Checked  = $true
$grpServices.Controls.Add($chkSharePoint)

$chkOneDrive = New-Object System.Windows.Forms.CheckBox
$chkOneDrive.Location = New-Object System.Drawing.Point(12, 50)
$chkOneDrive.Size     = New-Object System.Drawing.Size(160, 22)
$chkOneDrive.Text     = "OneDrive"
$chkOneDrive.Checked  = $true
$grpServices.Controls.Add($chkOneDrive)

$chkTeams = New-Object System.Windows.Forms.CheckBox
$chkTeams.Location = New-Object System.Drawing.Point(12, 76)
$chkTeams.Size     = New-Object System.Drawing.Size(160, 22)
$chkTeams.Text     = "Teams"
$chkTeams.Checked  = $true
$grpServices.Controls.Add($chkTeams)

# -- Activities Group --
$grpActivities = New-Object System.Windows.Forms.GroupBox
$grpActivities.Location = New-Object System.Drawing.Point(248, 80)
$grpActivities.Size     = New-Object System.Drawing.Size(220, 110)
$grpActivities.Text     = "Activity Types"
$tabFile.Controls.Add($grpActivities)

$chkUploads = New-Object System.Windows.Forms.CheckBox
$chkUploads.Location = New-Object System.Drawing.Point(12, 24)
$chkUploads.Size     = New-Object System.Drawing.Size(160, 22)
$chkUploads.Text     = "Uploads"
$chkUploads.Checked  = $true
$grpActivities.Controls.Add($chkUploads)

$chkDownloads = New-Object System.Windows.Forms.CheckBox
$chkDownloads.Location = New-Object System.Drawing.Point(12, 50)
$chkDownloads.Size     = New-Object System.Drawing.Size(160, 22)
$chkDownloads.Text     = "Downloads"
$chkDownloads.Checked  = $true
$grpActivities.Controls.Add($chkDownloads)

$chkDeletions = New-Object System.Windows.Forms.CheckBox
$chkDeletions.Location = New-Object System.Drawing.Point(12, 76)
$chkDeletions.Size     = New-Object System.Drawing.Size(160, 22)
$chkDeletions.Text     = "Deletions"
$chkDeletions.Checked  = $true
$grpActivities.Controls.Add($chkDeletions)

# -- Run / Export Buttons --
$btnRunFileAudit = New-Object System.Windows.Forms.Button
$btnRunFileAudit.Location  = New-Object System.Drawing.Point(490, 83)
$btnRunFileAudit.Size      = New-Object System.Drawing.Size(165, 38)
$btnRunFileAudit.Text      = "Run File Audit"
$btnRunFileAudit.BackColor = [System.Drawing.Color]::SteelBlue
$btnRunFileAudit.ForeColor = [System.Drawing.Color]::White
$btnRunFileAudit.FlatStyle = "Flat"
$tabFile.Controls.Add($btnRunFileAudit)

$btnExportFile = New-Object System.Windows.Forms.Button
$btnExportFile.Location = New-Object System.Drawing.Point(490, 135)
$btnExportFile.Size     = New-Object System.Drawing.Size(165, 35)
$btnExportFile.Text     = "Export Results CSV"
$tabFile.Controls.Add($btnExportFile)

# -- Record Count Label --
$lblRecordCount = New-Object System.Windows.Forms.Label
$lblRecordCount.Location  = New-Object System.Drawing.Point(680, 100)
$lblRecordCount.Size      = New-Object System.Drawing.Size(250, 20)
$lblRecordCount.Text      = ""
$lblRecordCount.ForeColor = [System.Drawing.Color]::DimGray
$tabFile.Controls.Add($lblRecordCount)

# -- Results Grid --
$lblFileResults = New-Object System.Windows.Forms.Label
$lblFileResults.Location = New-Object System.Drawing.Point(10, 202)
$lblFileResults.Size     = New-Object System.Drawing.Size(100, 20)
$lblFileResults.Text     = "Results:"
$tabFile.Controls.Add($lblFileResults)

$dgvFileResults = New-Object System.Windows.Forms.DataGridView
$dgvFileResults.Location            = New-Object System.Drawing.Point(10, 225)
$dgvFileResults.Size                = New-Object System.Drawing.Size(925, 350)
$dgvFileResults.AutoSizeColumnsMode = "Fill"
$dgvFileResults.AllowUserToAddRows  = $false
$dgvFileResults.ReadOnly            = $true
$dgvFileResults.BackgroundColor     = [System.Drawing.Color]::White
$tabFile.Controls.Add($dgvFileResults)

$fileResultTable = New-Object System.Data.DataTable
[void]$fileResultTable.Columns.Add("DateTime")
[void]$fileResultTable.Columns.Add("User")
[void]$fileResultTable.Columns.Add("Operation")
[void]$fileResultTable.Columns.Add("FileName")
[void]$fileResultTable.Columns.Add("FileExtension")
[void]$fileResultTable.Columns.Add("SiteUrl")
[void]$fileResultTable.Columns.Add("Workload")
[void]$fileResultTable.Columns.Add("ClientIP")
$dgvFileResults.DataSource = $fileResultTable

# -----------------------------------------------
# SHARED LOG  --  bottom of form
# -----------------------------------------------

$pnlLog = New-Object System.Windows.Forms.Panel
$pnlLog.Location = New-Object System.Drawing.Point(10, 688)
$pnlLog.Size     = New-Object System.Drawing.Size(955, 108)
$form.Controls.Add($pnlLog)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(0, 0)
$lblLog.Size     = New-Object System.Drawing.Size(40, 20)
$lblLog.Text     = "Log:"
$pnlLog.Controls.Add($lblLog)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Location = New-Object System.Drawing.Point(855, 0)
$btnClearLog.Size     = New-Object System.Drawing.Size(90, 22)
$btnClearLog.Text     = "Clear Log"
$pnlLog.Controls.Add($btnClearLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location   = New-Object System.Drawing.Point(0, 22)
$txtLog.Size       = New-Object System.Drawing.Size(955, 82)
$txtLog.Multiline  = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly   = $true
$txtLog.BackColor  = [System.Drawing.Color]::Black
$txtLog.ForeColor  = [System.Drawing.Color]::LimeGreen
$txtLog.Font       = New-Object System.Drawing.Font("Consolas", 8.5)
$pnlLog.Controls.Add($txtLog)

# ----------------------------
# Button Events
# ----------------------------

$btnConnectEXO.Add_Click({
    try {
        Write-Log "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false
        if (Test-ExchangeConnection) {
            Write-Log "Exchange Online connection successful."
        }
        else {
            Write-Log "Exchange Online connection test did not succeed."
        }
    }
    catch {
        Write-Log "Exchange Online connection failed: $($_.Exception.Message)"
    }
    Update-ConnectionStatus
})

$btnConnectIPPS.Add_Click({
    try {
        Write-Log "Connecting to IPPS / Compliance session..."
        Connect-IPPSSession -EnableSearchOnlySession
        if (Test-IPPSConnection) {
            Write-Log "IPPS connection successful."
        }
        else {
            Write-Log "IPPS connection test did not succeed."
        }
    }
    catch {
        Write-Log "IPPS connection failed: $($_.Exception.Message)"
    }
    Update-ConnectionStatus
})

# -- Email Audit Run --
$btnRunAudit.Add_Click({
    try {
        $mailbox = $txtUserEmail.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($mailbox)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a user email address at the top of the window.", "Missing Email")
            return
        }
        if (-not (Test-ExchangeConnection)) {
            [System.Windows.Forms.MessageBox]::Show("Exchange Online is not connected.", "Connection Required")
            return
        }
        if (-not (Test-IPPSConnection)) {
            [System.Windows.Forms.MessageBox]::Show("IPPS / Compliance session is not connected. This is required for the Email Audit.", "Connection Required")
            return
        }

        $domains    = $txtDomains.Lines
        $query      = Build-ContentMatchQuery -Domains $domains
        $searchName = "TermAudit-$($mailbox.Replace('@','_').Replace('.','_'))-$(Get-Date -Format yyyyMMddHHmmss)"

        Write-Log "Starting email audit for: $mailbox"
        Write-Log "Query: $query"
        Write-Log "Creating compliance search: $searchName"

        New-ComplianceSearch -Name $searchName -ExchangeLocation $mailbox -ContentMatchQuery $query -ErrorAction Stop | Out-Null
        Start-ComplianceSearch -Identity $searchName -ErrorAction Stop | Out-Null

        $searchResult = Wait-ComplianceSearchComplete -SearchName $searchName

        $row = $emailResultTable.NewRow()
        $row["Mailbox"]    = $mailbox
        $row["SearchName"] = $searchResult.Name
        $row["Status"]     = $searchResult.Status
        $row["Items"]      = $searchResult.Items
        $row["Size"]       = $searchResult.Size
        $row["Query"]      = $query
        $emailResultTable.Rows.Add($row)

        Write-Log "Email audit complete. Items found: $($searchResult.Items) | Size: $($searchResult.Size)"
    }
    catch {
        Write-Log "Email audit failed: $($_.Exception.Message)"
    }
})

# -- Email Audit Export --
$btnExportEmail.Add_Click({
    try {
        if ($emailResultTable.Rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("There are no results to export.", "No Results")
            return
        }
        $saveDialog          = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter   = "CSV files (*.csv)|*.csv"
        $saveDialog.Title    = "Save email audit results"
        $saveDialog.FileName = "EmailAuditResults_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

        if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $emailResultTable | Export-Csv -Path $saveDialog.FileName -NoTypeInformation -Encoding UTF8
            Write-Log "Email results exported to: $($saveDialog.FileName)"
        }
    }
    catch {
        Write-Log "Export failed: $($_.Exception.Message)"
    }
})

# -- File Activity Audit Run --
$btnRunFileAudit.Add_Click({
    try {
        $user = $txtUserEmail.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($user)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a user email address at the top of the window.", "Missing Email")
            return
        }
        if (-not (Test-ExchangeConnection)) {
            [System.Windows.Forms.MessageBox]::Show("Exchange Online is not connected. This is required to query the Unified Audit Log.", "Connection Required")
            return
        }
        if (-not ($chkSharePoint.Checked -or $chkOneDrive.Checked -or $chkTeams.Checked)) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one service.", "No Services Selected")
            return
        }

        # Build operations list from checkbox selections
        $operations = [System.Collections.Generic.List[string]]::new()
        if ($chkUploads.Checked) {
            $operations.AddRange([string[]]@(
                "FileUploaded",
                "FileCheckedIn",
                "FileSyncUploadedFull",
                "FileModified",
                "FileModifiedExtended"
            ))
        }
        if ($chkDownloads.Checked) {
            $operations.AddRange([string[]]@(
                "FileDownloaded",
                "FileCheckedOut",
                "FileSyncDownloadedFull",
                "FileAccessed",
                "FileAccessedExtended"
            ))
        }
        if ($chkDeletions.Checked) {
            $operations.AddRange([string[]]@(
                "FileDeleted",
                "FileRecycled",
                "FileDeletedFirstStageRecycleBin",
                "FileDeletedSecondStageRecycleBin",
                "FileVersionsAllDeleted"
            ))
        }

        if ($operations.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one activity type.", "No Activities Selected")
            return
        }

        $startDate = $dtpStart.Value.Date
        $endDate   = $dtpEnd.Value.Date.AddDays(1).AddSeconds(-1)

        if ($startDate -gt $endDate) {
            [System.Windows.Forms.MessageBox]::Show("Start date must be before end date.", "Invalid Date Range")
            return
        }

        $fileResultTable.Rows.Clear()
        $lblRecordCount.Text = ""
        $totalRecords        = 0
        $sessionId           = "FileAudit-$(Get-Date -Format yyyyMMddHHmmss)"
        $page                = 1

        Write-Log "Starting file activity audit for: $user"
        Write-Log "Date range: $($startDate.ToString('yyyy-MM-dd')) to $($dtpEnd.Value.Date.ToString('yyyy-MM-dd'))"
        Write-Log "Operations: $($operations -join ', ')"

        do {
            Write-Log "Fetching page $page of audit records..."

            $results = Search-UnifiedAuditLog `
                -StartDate  $startDate `
                -EndDate    $endDate `
                -UserIds    $user `
                -Operations $operations.ToArray() `
                -ResultSize 5000 `
                -SessionId  $sessionId `
                -SessionCommand ReturnLargeSet `
                -ErrorAction Stop

            if ($null -eq $results -or $results.Count -eq 0) { break }

            foreach ($record in $results) {
                try {
                    $auditData = $record.AuditData | ConvertFrom-Json
                    $workload  = [string]$auditData.Workload
                    $siteUrl   = [string]$auditData.SiteUrl

                    # Determine whether this record matches the selected services.
                    # OneDrive personal sites contain "-my.sharepoint.com" in the URL.
                    $isOneDrive    = ($workload -eq "OneDrive") -or
                                     ($workload -eq "SharePoint" -and $siteUrl -match "-my\.sharepoint\.com")
                    $isSharePoint  = ($workload -eq "SharePoint") -and ($siteUrl -notmatch "-my\.sharepoint\.com")
                    $isTeams       = ($workload -eq "MicrosoftTeams")

                    $include = ($chkOneDrive.Checked   -and $isOneDrive)  -or
                               ($chkSharePoint.Checked -and $isSharePoint) -or
                               ($chkTeams.Checked      -and $isTeams)

                    if ($include) {
                        $row = $fileResultTable.NewRow()
                        $row["DateTime"]      = $record.CreationDate.ToString("yyyy-MM-dd HH:mm:ss")
                        $row["User"]          = [string]$auditData.UserId
                        $row["Operation"]     = [string]$auditData.Operation
                        $row["FileName"]      = [string]$auditData.SourceFileName
                        $row["FileExtension"] = [string]$auditData.SourceFileExtension
                        $row["SiteUrl"]       = $siteUrl
                        $row["Workload"]      = $workload
                        $row["ClientIP"]      = [string]$auditData.ClientIP
                        $fileResultTable.Rows.Add($row)
                        $totalRecords++
                    }
                }
                catch {
                    Write-Log "Warning: Could not parse audit record -- $($_.Exception.Message)"
                }
            }

            $lblRecordCount.Text = "Records loaded: $totalRecords"
            [System.Windows.Forms.Application]::DoEvents()
            $page++

        } while ($results.Count -eq 5000)

        $lblRecordCount.Text = "Records found: $totalRecords"
        Write-Log "File activity audit complete. Records found: $totalRecords"

        if ($totalRecords -eq 0) {
            Write-Log "No records matched. Check date range, user email, and service selections."
            Write-Log "Note: The Unified Audit Log can have up to a 24-hour ingestion delay."
        }
    }
    catch {
        Write-Log "File audit failed: $($_.Exception.Message)"
    }
})

# -- File Activity Export --
$btnExportFile.Add_Click({
    try {
        if ($fileResultTable.Rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("There are no results to export.", "No Results")
            return
        }
        $saveDialog          = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter   = "CSV files (*.csv)|*.csv"
        $saveDialog.Title    = "Save file activity audit results"
        $saveDialog.FileName = "FileActivityAuditResults_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

        if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $fileResultTable | Export-Csv -Path $saveDialog.FileName -NoTypeInformation -Encoding UTF8
            Write-Log "File results exported to: $($saveDialog.FileName)"
        }
    }
    catch {
        Write-Log "Export failed: $($_.Exception.Message)"
    }
})

$btnClearLog.Add_Click({
    $txtLog.Clear()
})

# ----------------------------
# Launch Form
# ----------------------------

[void]$form.ShowDialog()
