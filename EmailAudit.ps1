Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------
# Helper Functions
# ----------------------------

function Write-Log {
    param(
        [string]$Message
    )

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
    catch {
        return $false
    }
}

function Test-IPPSConnection {
    try {
        Get-ComplianceSearch -ResultSize 1 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Build-ContentMatchQuery {
    param(
        [string[]]$Domains
    )

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
# Form Setup
# ----------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Terminated User Sent Items Audit"
$form.Size = New-Object System.Drawing.Size(920,700)
$form.StartPosition = "CenterScreen"
$form.Topmost = $false

$lblMailbox = New-Object System.Windows.Forms.Label
$lblMailbox.Location = New-Object System.Drawing.Point(20,20)
$lblMailbox.Size = New-Object System.Drawing.Size(180,20)
$lblMailbox.Text = "Mailbox Email Address:"
$form.Controls.Add($lblMailbox)

$txtMailbox = New-Object System.Windows.Forms.TextBox
$txtMailbox.Location = New-Object System.Drawing.Point(20,45)
$txtMailbox.Size = New-Object System.Drawing.Size(350,25)
$form.Controls.Add($txtMailbox)

$btnConnectEXO = New-Object System.Windows.Forms.Button
$btnConnectEXO.Location = New-Object System.Drawing.Point(400,42)
$btnConnectEXO.Size = New-Object System.Drawing.Size(180,30)
$btnConnectEXO.Text = "Connect Exchange Online"
$form.Controls.Add($btnConnectEXO)

$btnConnectIPPS = New-Object System.Windows.Forms.Button
$btnConnectIPPS.Location = New-Object System.Drawing.Point(600,42)
$btnConnectIPPS.Size = New-Object System.Drawing.Size(180,30)
$btnConnectIPPS.Text = "Connect IPPS Session"
$form.Controls.Add($btnConnectIPPS)

$lblDomains = New-Object System.Windows.Forms.Label
$lblDomains.Location = New-Object System.Drawing.Point(20,90)
$lblDomains.Size = New-Object System.Drawing.Size(280,20)
$lblDomains.Text = "Personal Email Domains (one per line):"
$form.Controls.Add($lblDomains)

$txtDomains = New-Object System.Windows.Forms.TextBox
$txtDomains.Location = New-Object System.Drawing.Point(20,115)
$txtDomains.Size = New-Object System.Drawing.Size(300,180)
$txtDomains.Multiline = $true
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
$form.Controls.Add($txtDomains)

$btnRunAudit = New-Object System.Windows.Forms.Button
$btnRunAudit.Location = New-Object System.Drawing.Point(350,115)
$btnRunAudit.Size = New-Object System.Drawing.Size(180,40)
$btnRunAudit.Text = "Run Audit"
$form.Controls.Add($btnRunAudit)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Location = New-Object System.Drawing.Point(350,170)
$btnClearLog.Size = New-Object System.Drawing.Size(180,35)
$btnClearLog.Text = "Clear Log"
$form.Controls.Add($btnClearLog)

$btnExportResults = New-Object System.Windows.Forms.Button
$btnExportResults.Location = New-Object System.Drawing.Point(350,220)
$btnExportResults.Size = New-Object System.Drawing.Size(180,35)
$btnExportResults.Text = "Export Results CSV"
$form.Controls.Add($btnExportResults)

$lblResults = New-Object System.Windows.Forms.Label
$lblResults.Location = New-Object System.Drawing.Point(20,320)
$lblResults.Size = New-Object System.Drawing.Size(100,20)
$lblResults.Text = "Results:"
$form.Controls.Add($lblResults)

$dgvResults = New-Object System.Windows.Forms.DataGridView
$dgvResults.Location = New-Object System.Drawing.Point(20,345)
$dgvResults.Size = New-Object System.Drawing.Size(860,140)
$dgvResults.AutoSizeColumnsMode = "Fill"
$dgvResults.AllowUserToAddRows = $false
$dgvResults.ReadOnly = $true
$form.Controls.Add($dgvResults)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Location = New-Object System.Drawing.Point(20,500)
$lblLog.Size = New-Object System.Drawing.Size(100,20)
$lblLog.Text = "Log:"
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20,525)
$txtLog.Size = New-Object System.Drawing.Size(860,120)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

# ----------------------------
# Results Table
# ----------------------------

$resultTable = New-Object System.Data.DataTable
[void]$resultTable.Columns.Add("Mailbox")
[void]$resultTable.Columns.Add("SearchName")
[void]$resultTable.Columns.Add("Status")
[void]$resultTable.Columns.Add("Items")
[void]$resultTable.Columns.Add("Size")
[void]$resultTable.Columns.Add("Query")

$dgvResults.DataSource = $resultTable

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
})

$btnConnectIPPS.Add_Click({
    try {
        Write-Log "Connecting to IPPS session..."
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
})

$btnRunAudit.Add_Click({
    try {
        $mailbox = $txtMailbox.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($mailbox)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a mailbox email address.","Missing Mailbox")
            return
        }

        if (-not (Test-ExchangeConnection)) {
            [System.Windows.Forms.MessageBox]::Show("Exchange Online is not connected.","Connection Required")
            return
        }

        if (-not (Test-IPPSConnection)) {
            [System.Windows.Forms.MessageBox]::Show("IPPS session is not connected.","Connection Required")
            return
        }

        $domains = $txtDomains.Lines
        $query = Build-ContentMatchQuery -Domains $domains

        $searchName = "TermAudit-$($mailbox.Replace('@','_').Replace('.','_'))-$(Get-Date -Format yyyyMMddHHmmss)"

        Write-Log "Starting audit for mailbox: $mailbox"
        Write-Log "Query: $query"
        Write-Log "Creating compliance search: $searchName"

        New-ComplianceSearch -Name $searchName -ExchangeLocation $mailbox -ContentMatchQuery $query -ErrorAction Stop | Out-Null
        Start-ComplianceSearch -Identity $searchName -ErrorAction Stop | Out-Null

        $searchResult = Wait-ComplianceSearchComplete -SearchName $searchName

        $row = $resultTable.NewRow()
        $row["Mailbox"]    = $mailbox
        $row["SearchName"] = $searchResult.Name
        $row["Status"]     = $searchResult.Status
        $row["Items"]      = $searchResult.Items
        $row["Size"]       = $searchResult.Size
        $row["Query"]      = $query
        $resultTable.Rows.Add($row)

        Write-Log "Audit complete. Items found: $($searchResult.Items) | Size: $($searchResult.Size)"
    }
    catch {
        Write-Log "Audit failed: $($_.Exception.Message)"
    }
})

$btnClearLog.Add_Click({
    $txtLog.Clear()
})

$btnExportResults.Add_Click({
    try {
        if ($resultTable.Rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("There are no results to export.","No Results")
            return
        }

        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter = "CSV files (*.csv)|*.csv"
        $saveDialog.Title = "Save audit results"
        $saveDialog.FileName = "TerminatedUserAuditResults_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

        if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $resultTable | Export-Csv -Path $saveDialog.FileName -NoTypeInformation -Encoding UTF8
            Write-Log "Results exported to: $($saveDialog.FileName)"
        }
    }
    catch {
        Write-Log "Export failed: $($_.Exception.Message)"
    }
})

# ----------------------------
# Launch Form
# ----------------------------

[void]$form.ShowDialog()
