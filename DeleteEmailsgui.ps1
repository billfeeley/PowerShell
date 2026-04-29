Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------
# Module Check
# ----------------------------
$exoModule = Get-Module -ListAvailable ExchangeOnlineManagement |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $exoModule) {
    [System.Windows.Forms.MessageBox]::Show(
        "ExchangeOnlineManagement module not found.`n`nInstall with:`nInstall-Module ExchangeOnlineManagement",
        "Missing Module",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    return
}

if ($exoModule.Version -lt [version]"3.9.0") {
    [System.Windows.Forms.MessageBox]::Show(
        "ExchangeOnlineManagement 3.9.0 or later is required.`n`nInstalled version: $($exoModule.Version)",
        "Module Version Too Old",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    return
}

Import-Module ExchangeOnlineManagement -ErrorAction Stop

# ----------------------------
# Globals
# ----------------------------
$script:ExoConnected = $false
$script:IppsConnected = $false
$script:IppsMode = "Not Connected"
$script:LastSearchName = $null
$script:LastSearchItems = 0

# ----------------------------
# Helper Functions
# ----------------------------
function Write-Status {
    param(
        [string]$Message
    )
    $txtStatus.AppendText("[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message`r`n")
    $txtStatus.SelectionStart = $txtStatus.TextLength
    $txtStatus.ScrollToCaret()
    $form.Refresh()
}

function Update-ConnectionLabels {
    $lblExoStatus.Text = "EXO: " + ($(if ($script:ExoConnected) { "Connected" } else { "Not Connected" }))
    $lblIppsStatus.Text = "IPPS: " + $script:IppsMode

    if ($script:IppsMode -eq "SearchOnly") {
        $lblPurgeWarning.Text = "Search session connected"
        $lblPurgeWarning.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $lblPurgeWarning.Text = "Not connected to IPPS"
        $lblPurgeWarning.ForeColor = [System.Drawing.Color]::DarkRed
    }
}

function Disconnect-ComplianceSessions {
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}

    try {
        Get-PSSession | Where-Object {
            $_.ComputerName -like "*ps.compliance.protection.outlook.com*" -or
            $_.ConfigurationName -like "Microsoft.Exchange*" -or
            $_.Name -like "*Exchange*"
        } | Remove-PSSession -ErrorAction SilentlyContinue
    } catch {}
}

function Test-SearchReady {
    if (-not $script:IppsConnected -or $script:IppsMode -ne "SearchOnly") {
        [System.Windows.Forms.MessageBox]::Show(
            "Connect to IPPS Search Only first.",
            "Not Connected",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return $false
    }
    return $true
}

function Test-PurgeReady {
    if (-not $script:IppsConnected -or $script:IppsMode -ne "SearchOnly") {
        [System.Windows.Forms.MessageBox]::Show(
            "Connect to IPPS Search Only first.",
            "Purge Not Available",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return $false
    }

    if (-not $script:LastSearchName) {
        [System.Windows.Forms.MessageBox]::Show(
            "No completed search found to purge.",
            "Nothing To Purge",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return $false
    }

    if ($script:LastSearchItems -lt 1) {
        [System.Windows.Forms.MessageBox]::Show(
            "The last search returned 0 items. Nothing to purge.",
            "Nothing To Purge",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return $false
    }

    return $true
}

function Get-QuotedKqlValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $escaped = $Value.Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Build-ContentQuery {
    $clauses = New-Object System.Collections.Generic.List[string]

    $clauses.Add("kind:email")

    if (-not [string]::IsNullOrWhiteSpace($txtFrom.Text)) {
        $clauses.Add("from:" + (Get-QuotedKqlValue -Value $txtFrom.Text.Trim()))
    }

    if (-not [string]::IsNullOrWhiteSpace($txtSubject.Text)) {
        $clauses.Add("subject:" + (Get-QuotedKqlValue -Value $txtSubject.Text.Trim()))
    }

    if ($dtpStart.Checked) {
        $clauses.Add("received>=" + $dtpStart.Value.ToString("MM/dd/yyyy"))
    }

    if ($dtpEnd.Checked) {
        $endPlusOne = $dtpEnd.Value.Date.AddDays(1)
        $clauses.Add("received<" + $endPlusOne.ToString("MM/dd/yyyy"))
    }

    if (-not [string]::IsNullOrWhiteSpace($txtRecipient.Text)) {
        $recipientValue = Get-QuotedKqlValue -Value $txtRecipient.Text.Trim()
        $clauses.Add("(to:$recipientValue OR recipients:$recipientValue)")
    }

    return ($clauses -join " AND ")
}

function Get-ExchangeLocation {
    if ($cmbScope.SelectedItem -eq "Specific Mailbox") {
        if ([string]::IsNullOrWhiteSpace($txtMailbox.Text)) {
            throw "Mailbox is required when scope is 'Specific Mailbox'."
        }
        return $txtMailbox.Text.Trim()
    }

    return "All"
}

function Run-ComplianceSearch {
    try {
        if (-not (Test-SearchReady)) { return }

        $contentQuery = Build-ContentQuery
        $exchangeLocation = Get-ExchangeLocation

        if ([string]::IsNullOrWhiteSpace($contentQuery) -or $contentQuery -eq "kind:email") {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "Your query is extremely broad and may return a huge number of items.`n`nContinue anyway?",
                "Broad Search Warning",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Status "Search canceled due to broad query."
                return
            }
        }

        $searchName = "SpamCleanup_{0:yyyyMMdd_HHmmss}" -f (Get-Date)

        Write-Status "Creating compliance search: $searchName"
        Write-Status "ExchangeLocation: $exchangeLocation"
        Write-Status "Query: $contentQuery"

        New-ComplianceSearch `
            -Name $searchName `
            -ExchangeLocation $exchangeLocation `
            -ContentMatchQuery $contentQuery `
            -AllowNotFoundExchangeLocationsEnabled $true `
            -ErrorAction Stop | Out-Null

        Write-Status "Starting compliance search..."
        Start-ComplianceSearch -Identity $searchName -ErrorAction Stop | Out-Null

        do {
            Start-Sleep -Seconds 5
            $status = Get-ComplianceSearch -Identity $searchName -ErrorAction Stop
            Write-Status "Search status: $($status.Status)"
            [System.Windows.Forms.Application]::DoEvents()
        } while ($status.Status -notin @("Completed","Failed"))

        if ($status.Status -eq "Failed") {
            Write-Status "Search failed."
            [System.Windows.Forms.MessageBox]::Show(
                "Compliance search failed. Check Purview / Compliance Center for more detail.",
                "Search Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }

        $script:LastSearchName = $searchName
        $script:LastSearchItems = [int]$status.Items

        $txtSearchName.Text = $script:LastSearchName
        $txtItemCount.Text = $script:LastSearchItems.ToString()

        Write-Status "Search completed successfully."
        Write-Status "Matching items: $($script:LastSearchItems)"

        [System.Windows.Forms.MessageBox]::Show(
            "Search complete.`n`nSearch Name: $($script:LastSearchName)`nItems: $($script:LastSearchItems)",
            "Search Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        Write-Status "Search error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Search Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Run-CompliancePurge {
    try {
        if (-not (Test-PurgeReady)) { return }

        $confirmText = @"
You are about to SOFT DELETE messages for:

Search Name: $($script:LastSearchName)
Item Count: $($script:LastSearchItems)

This will remove them from user-visible folders and move them into Recoverable Items.

Do you want to continue?
"@

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $confirmText,
            "Confirm Purge",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Status "Purge canceled by user."
            return
        }

        Write-Status "Submitting SoftDelete purge for search: $($script:LastSearchName)"

        New-ComplianceSearchAction `
            -SearchName $script:LastSearchName `
            -Purge `
            -PurgeType SoftDelete `
            -ErrorAction Stop | Out-Null

        Write-Status "Purge action submitted successfully."

        [System.Windows.Forms.MessageBox]::Show(
            "Purge submitted successfully.`n`nMonitor the action in Microsoft Purview / Compliance Center.",
            "Purge Submitted",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        Write-Status "Purge error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Purge Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

# ----------------------------
# Form
# ----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Spam Cleanup / Malicious Email Removal"
$form.Size = New-Object System.Drawing.Size(940, 730)
$form.StartPosition = "CenterScreen"
$form.Topmost = $false

# Connection section
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = "Connections"
$grpConn.Location = New-Object System.Drawing.Point(10, 10)
$grpConn.Size = New-Object System.Drawing.Size(900, 100)
$form.Controls.Add($grpConn)

$btnConnectEXO = New-Object System.Windows.Forms.Button
$btnConnectEXO.Text = "Connect EXO"
$btnConnectEXO.Location = New-Object System.Drawing.Point(15, 30)
$btnConnectEXO.Size = New-Object System.Drawing.Size(130, 30)
$grpConn.Controls.Add($btnConnectEXO)

$btnConnectIPPS = New-Object System.Windows.Forms.Button
$btnConnectIPPS.Text = "Connect IPPS (Search Only)"
$btnConnectIPPS.Location = New-Object System.Drawing.Point(160, 30)
$btnConnectIPPS.Size = New-Object System.Drawing.Size(210, 30)
$grpConn.Controls.Add($btnConnectIPPS)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "Disconnect All"
$btnDisconnect.Location = New-Object System.Drawing.Point(385, 30)
$btnDisconnect.Size = New-Object System.Drawing.Size(130, 30)
$grpConn.Controls.Add($btnDisconnect)

$lblExoStatus = New-Object System.Windows.Forms.Label
$lblExoStatus.Location = New-Object System.Drawing.Point(15, 68)
$lblExoStatus.Size = New-Object System.Drawing.Size(220, 20)
$grpConn.Controls.Add($lblExoStatus)

$lblIppsStatus = New-Object System.Windows.Forms.Label
$lblIppsStatus.Location = New-Object System.Drawing.Point(240, 68)
$lblIppsStatus.Size = New-Object System.Drawing.Size(220, 20)
$grpConn.Controls.Add($lblIppsStatus)

$lblPurgeWarning = New-Object System.Windows.Forms.Label
$lblPurgeWarning.Location = New-Object System.Drawing.Point(470, 68)
$lblPurgeWarning.Size = New-Object System.Drawing.Size(250, 20)
$grpConn.Controls.Add($lblPurgeWarning)

# Search Criteria section
$grpCriteria = New-Object System.Windows.Forms.GroupBox
$grpCriteria.Text = "Search Criteria"
$grpCriteria.Location = New-Object System.Drawing.Point(10, 120)
$grpCriteria.Size = New-Object System.Drawing.Size(900, 220)
$form.Controls.Add($grpCriteria)

$lblFrom = New-Object System.Windows.Forms.Label
$lblFrom.Text = "From Address:"
$lblFrom.Location = New-Object System.Drawing.Point(15, 30)
$lblFrom.Size = New-Object System.Drawing.Size(100, 20)
$grpCriteria.Controls.Add($lblFrom)

$txtFrom = New-Object System.Windows.Forms.TextBox
$txtFrom.Location = New-Object System.Drawing.Point(130, 28)
$txtFrom.Size = New-Object System.Drawing.Size(280, 23)
$grpCriteria.Controls.Add($txtFrom)

$lblSubject = New-Object System.Windows.Forms.Label
$lblSubject.Text = "Subject Contains:"
$lblSubject.Location = New-Object System.Drawing.Point(440, 30)
$lblSubject.Size = New-Object System.Drawing.Size(110, 20)
$grpCriteria.Controls.Add($lblSubject)

$txtSubject = New-Object System.Windows.Forms.TextBox
$txtSubject.Location = New-Object System.Drawing.Point(560, 28)
$txtSubject.Size = New-Object System.Drawing.Size(300, 23)
$grpCriteria.Controls.Add($txtSubject)

$lblRecipient = New-Object System.Windows.Forms.Label
$lblRecipient.Text = "Recipient (optional):"
$lblRecipient.Location = New-Object System.Drawing.Point(15, 65)
$lblRecipient.Size = New-Object System.Drawing.Size(110, 20)
$grpCriteria.Controls.Add($lblRecipient)

$txtRecipient = New-Object System.Windows.Forms.TextBox
$txtRecipient.Location = New-Object System.Drawing.Point(130, 63)
$txtRecipient.Size = New-Object System.Drawing.Size(280, 23)
$grpCriteria.Controls.Add($txtRecipient)

$lblScope = New-Object System.Windows.Forms.Label
$lblScope.Text = "Scope:"
$lblScope.Location = New-Object System.Drawing.Point(440, 65)
$lblScope.Size = New-Object System.Drawing.Size(50, 20)
$grpCriteria.Controls.Add($lblScope)

$cmbScope = New-Object System.Windows.Forms.ComboBox
$cmbScope.Location = New-Object System.Drawing.Point(560, 63)
$cmbScope.Size = New-Object System.Drawing.Size(180, 23)
$cmbScope.DropDownStyle = 'DropDownList'
[void]$cmbScope.Items.Add("All Mailboxes")
[void]$cmbScope.Items.Add("Specific Mailbox")
$cmbScope.SelectedIndex = 0
$grpCriteria.Controls.Add($cmbScope)

$lblMailbox = New-Object System.Windows.Forms.Label
$lblMailbox.Text = "Mailbox:"
$lblMailbox.Location = New-Object System.Drawing.Point(15, 100)
$lblMailbox.Size = New-Object System.Drawing.Size(100, 20)
$grpCriteria.Controls.Add($lblMailbox)

$txtMailbox = New-Object System.Windows.Forms.TextBox
$txtMailbox.Location = New-Object System.Drawing.Point(130, 98)
$txtMailbox.Size = New-Object System.Drawing.Size(280, 23)
$txtMailbox.Enabled = $false
$grpCriteria.Controls.Add($txtMailbox)

$lblStart = New-Object System.Windows.Forms.Label
$lblStart.Text = "Received Start:"
$lblStart.Location = New-Object System.Drawing.Point(440, 100)
$lblStart.Size = New-Object System.Drawing.Size(100, 20)
$grpCriteria.Controls.Add($lblStart)

$dtpStart = New-Object System.Windows.Forms.DateTimePicker
$dtpStart.Location = New-Object System.Drawing.Point(560, 98)
$dtpStart.Size = New-Object System.Drawing.Size(180, 23)
$dtpStart.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpStart.Value = (Get-Date).Date.AddDays(-3)
$dtpStart.Checked = $true
$dtpStart.ShowCheckBox = $true
$grpCriteria.Controls.Add($dtpStart)

$lblEnd = New-Object System.Windows.Forms.Label
$lblEnd.Text = "Received End:"
$lblEnd.Location = New-Object System.Drawing.Point(440, 135)
$lblEnd.Size = New-Object System.Drawing.Size(100, 20)
$grpCriteria.Controls.Add($lblEnd)

$dtpEnd = New-Object System.Windows.Forms.DateTimePicker
$dtpEnd.Location = New-Object System.Drawing.Point(560, 133)
$dtpEnd.Size = New-Object System.Drawing.Size(180, 23)
$dtpEnd.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpEnd.Value = (Get-Date).Date
$dtpEnd.Checked = $true
$dtpEnd.ShowCheckBox = $true
$grpCriteria.Controls.Add($dtpEnd)

$btnRunSearch = New-Object System.Windows.Forms.Button
$btnRunSearch.Text = "Run Search"
$btnRunSearch.Location = New-Object System.Drawing.Point(130, 170)
$btnRunSearch.Size = New-Object System.Drawing.Size(140, 30)
$grpCriteria.Controls.Add($btnRunSearch)

$btnPurge = New-Object System.Windows.Forms.Button
$btnPurge.Text = "Soft Delete Purge"
$btnPurge.Location = New-Object System.Drawing.Point(285, 170)
$btnPurge.Size = New-Object System.Drawing.Size(160, 30)
$grpCriteria.Controls.Add($btnPurge)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Clear Fields"
$btnClear.Location = New-Object System.Drawing.Point(460, 170)
$btnClear.Size = New-Object System.Drawing.Size(120, 30)
$grpCriteria.Controls.Add($btnClear)

# Results section
$grpResults = New-Object System.Windows.Forms.GroupBox
$grpResults.Text = "Last Search Result"
$grpResults.Location = New-Object System.Drawing.Point(10, 350)
$grpResults.Size = New-Object System.Drawing.Size(900, 90)
$form.Controls.Add($grpResults)

$lblSearchName = New-Object System.Windows.Forms.Label
$lblSearchName.Text = "Search Name:"
$lblSearchName.Location = New-Object System.Drawing.Point(15, 30)
$lblSearchName.Size = New-Object System.Drawing.Size(90, 20)
$grpResults.Controls.Add($lblSearchName)

$txtSearchName = New-Object System.Windows.Forms.TextBox
$txtSearchName.Location = New-Object System.Drawing.Point(110, 28)
$txtSearchName.Size = New-Object System.Drawing.Size(560, 23)
$txtSearchName.ReadOnly = $true
$grpResults.Controls.Add($txtSearchName)

$lblItemCount = New-Object System.Windows.Forms.Label
$lblItemCount.Text = "Item Count:"
$lblItemCount.Location = New-Object System.Drawing.Point(15, 58)
$lblItemCount.Size = New-Object System.Drawing.Size(90, 20)
$grpResults.Controls.Add($lblItemCount)

$txtItemCount = New-Object System.Windows.Forms.TextBox
$txtItemCount.Location = New-Object System.Drawing.Point(110, 56)
$txtItemCount.Size = New-Object System.Drawing.Size(120, 23)
$txtItemCount.ReadOnly = $true
$grpResults.Controls.Add($txtItemCount)

# Status section
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = "Status / Log"
$grpStatus.Location = New-Object System.Drawing.Point(10, 450)
$grpStatus.Size = New-Object System.Drawing.Size(900, 230)
$form.Controls.Add($grpStatus)

$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Location = New-Object System.Drawing.Point(15, 25)
$txtStatus.Size = New-Object System.Drawing.Size(870, 190)
$txtStatus.Multiline = $true
$txtStatus.ScrollBars = "Vertical"
$txtStatus.ReadOnly = $true
$txtStatus.Font = New-Object System.Drawing.Font("Consolas", 9)
$grpStatus.Controls.Add($txtStatus)

# ----------------------------
# Events
# ----------------------------
$cmbScope.Add_SelectedIndexChanged({
    if ($cmbScope.SelectedItem -eq "Specific Mailbox") {
        $txtMailbox.Enabled = $true
    }
    else {
        $txtMailbox.Enabled = $false
        $txtMailbox.Text = ""
    }
})

$btnConnectEXO.Add_Click({
    try {
        Write-Status "Disconnecting any existing sessions first..."
        Disconnect-ComplianceSessions

        Write-Status "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        $script:ExoConnected = $true
        Write-Status "Connected to Exchange Online."
    }
    catch {
        $script:ExoConnected = $false
        Write-Status "EXO connection error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "EXO Connection Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    finally {
        Update-ConnectionLabels
    }
})

$btnConnectIPPS.Add_Click({
    try {
        Write-Status "Disconnecting any existing compliance sessions first..."
        Disconnect-ComplianceSessions

        Write-Status "Connecting to IPPS with -EnableSearchOnlySession..."
        Connect-IPPSSession -EnableSearchOnlySession -ErrorAction Stop | Out-Null
        $script:IppsConnected = $true
        $script:IppsMode = "SearchOnly"
        Write-Status "Connected to IPPS (SearchOnly)."
    }
    catch {
        $script:IppsConnected = $false
        $script:IppsMode = "Not Connected"
        Write-Status "IPPS connection error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "IPPS Connection Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    finally {
        Update-ConnectionLabels
    }
})

$btnDisconnect.Add_Click({
    Disconnect-ComplianceSessions
    $script:ExoConnected = $false
    $script:IppsConnected = $false
    $script:IppsMode = "Not Connected"
    Write-Status "Disconnected sessions."
    Update-ConnectionLabels
})

$btnRunSearch.Add_Click({
    Run-ComplianceSearch
})

$btnPurge.Add_Click({
    Run-CompliancePurge
})

$btnClear.Add_Click({
    $txtFrom.Text = ""
    $txtSubject.Text = ""
    $txtRecipient.Text = ""
    $cmbScope.SelectedIndex = 0
    $txtMailbox.Text = ""
    $dtpStart.Value = (Get-Date).Date.AddDays(-3)
    $dtpStart.Checked = $true
    $dtpEnd.Value = (Get-Date).Date
    $dtpEnd.Checked = $true
    $txtSearchName.Text = ""
    $txtItemCount.Text = ""
    $script:LastSearchName = $null
    $script:LastSearchItems = 0
    Write-Status "Fields cleared."
})

$form.Add_Shown({
    Update-ConnectionLabels
    Write-Status "GUI loaded."
    Write-Status "Use Connect EXO first, then Connect IPPS (Search Only)."
})

# ----------------------------
# Launch
# ----------------------------
[void]$form.ShowDialog()
