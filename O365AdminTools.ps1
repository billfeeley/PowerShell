#requires -Modules ExchangeOnlineManagement
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================================================================================
# Helper Functions
# ================================================================================

function Test-MailAlias {
    param([string]$Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return $false }
    if ($Alias -match '[@\s]') { return $false }
    return $Alias -match '^[A-Za-z0-9][A-Za-z0-9\!\#\$\%\&''\*\+\-\/=\?\^_`\{\|\}~\.]*[A-Za-z0-9]$' -or $Alias.Length -eq 1
}

function Split-Entries {
    param([string]$Text)
    $raw = ($Text -split "(`r`n|`n|,|;)" | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
    return $raw | Select-Object -Unique
}

function Write-Log {
    param([string]$msg)
    $txtLog.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Get-RecipientSafe {
    param([string]$Identity)
    try { return Get-Recipient -Identity $Identity -ErrorAction Stop }
    catch { return $null }
}

function Get-CalendarIdentity {
    <#
    .SYNOPSIS
    Returns the mailbox folder path for the calendar (e.g. "user@domain.com:\Calendar").
    Falls back to folder statistics for non-English tenants where the folder name differs.
    #>
    param([string]$Mailbox)
    $defaultPath = "${Mailbox}:\Calendar"
    try {
        # Quick check — if this works we're done
        Get-MailboxFolderPermission -Identity $defaultPath -ErrorAction Stop | Out-Null
        return $defaultPath
    }
    catch {
        try {
            $calFolder = Get-MailboxFolderStatistics -Identity $Mailbox -FolderScope Calendar -ErrorAction Stop |
                         Where-Object { $_.FolderType -eq 'Calendar' } |
                         Select-Object -First 1
            if ($calFolder) {
                $fp = $calFolder.FolderPath.TrimStart('/').Replace('/', '\')
                return "${Mailbox}:\${fp}"
            }
        }
        catch { }
        return $defaultPath   # Let the caller surface the real error
    }
}

function Add-PlaceholderBehavior {
    <#
    .SYNOPSIS
    Simulates placeholder/watermark text on a TextBox without requiring .NET 4.7.1+.
    Stores the placeholder string in the control's Tag property.
    #>
    param(
        [System.Windows.Forms.TextBox]$TextBox,
        [string]$PlaceholderText
    )
    $TextBox.Tag       = $PlaceholderText
    $TextBox.Text      = $PlaceholderText
    $TextBox.ForeColor = [System.Drawing.Color]::Gray

    $TextBox.Add_GotFocus({
        if ($this.ForeColor -eq [System.Drawing.Color]::Gray -and $this.Text -eq $this.Tag) {
            $this.Text      = ''
            $this.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    })
    $TextBox.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text      = $this.Tag
            $this.ForeColor = [System.Drawing.Color]::Gray
        }
    })
}

function Get-ControlText {
    <#
    .SYNOPSIS
    Returns the trimmed text of a TextBox, or an empty string if it currently
    shows its placeholder (gray text matching the Tag property).
    #>
    param([System.Windows.Forms.TextBox]$TextBox)
    if ($TextBox.ForeColor -eq [System.Drawing.Color]::Gray -and
        $TextBox.Text      -eq $TextBox.Tag) { return '' }
    return $TextBox.Text.Trim()
}

function Invoke-LoadMbxPermissions {
    <#
    .SYNOPSIS
    Queries Full Access, Send As, and Send on Behalf permissions for a mailbox
    and populates the provided ListView with a unified row per user.
    #>
    param([string]$Mailbox, [System.Windows.Forms.ListView]$ListView)
    $ListView.Items.Clear()
    $permMap = @{}   # key = user string, value = hashtable {FA, SA, SOB}

    # Full Access
    try {
        $faPerms = Get-MailboxPermission -Identity $Mailbox -ErrorAction Stop |
                   Where-Object {
                       $_.AccessRights -contains 'FullAccess' -and
                       -not $_.IsInherited -and
                       $_.User -notmatch 'NT AUTHORITY|\\SELF|S-1-5'
                   }
        foreach ($p in $faPerms) {
            $uid = $p.User.ToString()
            if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
            $permMap[$uid].FA = $true
        }
    } catch { }

    # Send As
    try {
        $saPerms = Get-RecipientPermission -Identity $Mailbox -ErrorAction Stop |
                   Where-Object {
                       $_.AccessRights -contains 'SendAs' -and
                       $_.Trustee -notmatch 'NT AUTHORITY|\\SELF|S-1-5'
                   }
        foreach ($p in $saPerms) {
            $uid = $p.Trustee.ToString()
            if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
            $permMap[$uid].SA = $true
        }
    } catch { }

    # Send on Behalf
    try {
        $mbxForSOB = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
        foreach ($sob in $mbxForSOB.GrantSendOnBehalfTo) {
            $uid = $sob.ToString()
            if (-not $permMap.ContainsKey($uid)) { $permMap[$uid] = @{FA=$false; SA=$false; SOB=$false} }
            $permMap[$uid].SOB = $true
        }
    } catch { }

    foreach ($uid in ($permMap.Keys | Sort-Object)) {
        $p    = $permMap[$uid]
        $item = New-Object System.Windows.Forms.ListViewItem($uid)
        [void]$item.SubItems.Add($(if ($p.FA)  { 'Yes' } else { '' }))
        [void]$item.SubItems.Add($(if ($p.SA)  { 'Yes' } else { '' }))
        [void]$item.SubItems.Add($(if ($p.SOB) { 'Yes' } else { '' }))
        [void]$ListView.Items.Add($item)
    }
}

function Invoke-LoadAliases {
    <#
    .SYNOPSIS
    Populates an aliases ListView from a mailbox object's EmailAddresses collection.
    Primary SMTP is shown in blue; secondary aliases are shown normally.
    #>
    param($MbxObj, [System.Windows.Forms.ListView]$ListView)
    $ListView.Items.Clear()
    foreach ($addr in $MbxObj.EmailAddresses) {
        $addrStr = $addr.ToString()
        if ($addrStr -match '^[Ss][Mm][Tt][Pp]:(.+)$') {
            $email     = $Matches[1]
            $isPrimary = $addrStr -cmatch '^SMTP:'
            $type      = if ($isPrimary) { 'Primary' } else { 'Alias' }
            $item      = New-Object System.Windows.Forms.ListViewItem($email)
            [void]$item.SubItems.Add($type)
            if ($isPrimary) { $item.ForeColor = [System.Drawing.Color]::DarkBlue }
            [void]$ListView.Items.Add($item)
        }
    }
}

function Write-Status {
    param([string]$Message)
    Write-Log $Message
}

function Update-ConnectionLabels {
    $lblExoStatus.Text      = "EXO: "  + $(if ($script:ExoConnected)  { "Connected" } else { "Not Connected" })
    $lblExoStatus.ForeColor = if ($script:ExoConnected) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DimGray }
    $lblIppsStatus.Text     = "IPPS: " + $script:IppsMode
    $lblIppsStatus.ForeColor = if ($script:IppsMode -eq "SearchOnly") { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DimGray }
}

function Disconnect-ComplianceSessions {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch {}
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
        [System.Windows.Forms.MessageBox]::Show("Connect to IPPS Search Only first.",
            "Not Connected", "OK", "Warning") | Out-Null
        return $false
    }
    return $true
}

function Test-PurgeReady {
    if (-not $script:IppsConnected -or $script:IppsMode -ne "SearchOnly") {
        [System.Windows.Forms.MessageBox]::Show("Connect to IPPS Search Only first.",
            "Purge Not Available", "OK", "Warning") | Out-Null
        return $false
    }
    if (-not $script:LastSearchName) {
        [System.Windows.Forms.MessageBox]::Show("No completed search found to purge.",
            "Nothing To Purge", "OK", "Warning") | Out-Null
        return $false
    }
    if ($script:LastSearchItems -lt 1) {
        [System.Windows.Forms.MessageBox]::Show("The last search returned 0 items. Nothing to purge.",
            "Nothing To Purge", "OK", "Information") | Out-Null
        return $false
    }
    return $true
}

function Test-ExoReady {
    if (-not $script:ExoConnected) {
        [System.Windows.Forms.MessageBox]::Show("Connect to EXO first (Spam Cleanup tab).",
            "Not Connected", "OK", "Warning") | Out-Null
        return $false
    }
    return $true
}

function Get-QuotedKqlValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Build-ContentQuery {
    $clauses = New-Object System.Collections.Generic.List[string]
    $clauses.Add("kind:email")
    if (-not [string]::IsNullOrWhiteSpace($txtFrom.Text))      { $clauses.Add("from:"      + (Get-QuotedKqlValue $txtFrom.Text.Trim())) }
    if (-not [string]::IsNullOrWhiteSpace($txtSubject.Text))   { $clauses.Add("subject:"   + (Get-QuotedKqlValue $txtSubject.Text.Trim())) }
    if ($dtpStart.Checked) { $clauses.Add("received>=" + $dtpStart.Value.ToString("MM/dd/yyyy")) }
    if ($dtpEnd.Checked)   { $clauses.Add("received<"  + $dtpEnd.Value.Date.AddDays(1).ToString("MM/dd/yyyy")) }
    if (-not [string]::IsNullOrWhiteSpace($txtRecipient.Text)) {
        $rv = Get-QuotedKqlValue $txtRecipient.Text.Trim()
        $clauses.Add("(to:$rv OR recipients:$rv)")
    }
    return ($clauses -join " AND ")
}

function Get-ExchangeLocation {
    if ($cmbScope.SelectedItem -eq "Specific Mailbox") {
        if ([string]::IsNullOrWhiteSpace($txtMailbox.Text)) { throw "Mailbox is required when scope is 'Specific Mailbox'." }
        return $txtMailbox.Text.Trim()
    }
    return "All"
}

function Run-ComplianceSearch {
    try {
        if (-not (Test-SearchReady)) { return }
        $contentQuery     = Build-ContentQuery
        $exchangeLocation = Get-ExchangeLocation
        if ([string]::IsNullOrWhiteSpace($contentQuery) -or $contentQuery -eq "kind:email") {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "Your query is extremely broad and may return a huge number of items.`n`nContinue anyway?",
                "Broad Search Warning", "YesNo", "Warning")
            if ($r -ne 'Yes') { Write-Status "Search canceled due to broad query."; return }
        }
        $searchName = "SpamCleanup_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Write-Status "Creating compliance search: $searchName"
        Write-Status "ExchangeLocation: $exchangeLocation"
        Write-Status "Query: $contentQuery"
        New-ComplianceSearch -Name $searchName -ExchangeLocation $exchangeLocation `
            -ContentMatchQuery $contentQuery -AllowNotFoundExchangeLocationsEnabled $true `
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
            [System.Windows.Forms.MessageBox]::Show("Compliance search failed. Check Purview / Compliance Center for more detail.",
                "Search Failed", "OK", "Error") | Out-Null
            return
        }
        $script:LastSearchName  = $searchName
        $script:LastSearchItems = [int]$status.Items
        $txtSearchName.Text = $script:LastSearchName
        $txtItemCount.Text  = $script:LastSearchItems.ToString()
        Write-Status "Search completed. Matching items: $($script:LastSearchItems)"
        [System.Windows.Forms.MessageBox]::Show(
            "Search complete.`n`nSearch Name: $($script:LastSearchName)`nItems: $($script:LastSearchItems)",
            "Search Complete", "OK", "Information") | Out-Null
    }
    catch {
        Write-Status "Search error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Search Error", "OK", "Error") | Out-Null
    }
}

function Run-CompliancePurge {
    try {
        if (-not (Test-PurgeReady)) { return }
        $confirmText = "You are about to SOFT DELETE messages for:`n`nSearch Name: $($script:LastSearchName)`nItem Count: $($script:LastSearchItems)`n`nThis will move them into Recoverable Items.`n`nContinue?"
        $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, "Confirm Purge", "YesNo", "Warning")
        if ($confirm -ne 'Yes') { Write-Status "Purge canceled by user."; return }
        Write-Status "Submitting SoftDelete purge for: $($script:LastSearchName)"
        New-ComplianceSearchAction -SearchName $script:LastSearchName -Purge `
            -PurgeType SoftDelete -ErrorAction Stop | Out-Null
        Write-Status "Purge action submitted successfully."
        [System.Windows.Forms.MessageBox]::Show(
            "Purge submitted.`n`nMonitor in Microsoft Purview / Compliance Center.",
            "Purge Submitted", "OK", "Information") | Out-Null
    }
    catch {
        Write-Status "Purge error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Purge Error", "OK", "Error") | Out-Null
    }
}

function Get-InboxRuleSummary {
    param($Rule)
    $conditionProps = 'From','FromAddressContainsWords','SubjectContainsWords','SubjectOrBodyContainsWords',
                      'SentTo','MyNameInToBox','MyNameInCcBox','HasAttachment','FlaggedForAction'
    $actionProps    = 'MoveToFolder','CopyToFolder','DeleteMessage','ForwardTo','RedirectTo',
                      'MarkAsRead','StopProcessingRules'
    $conditions = foreach ($p in $conditionProps) { $val = $Rule.$p; if ($val) { "$p=$($val -join ',')" } }
    $actions    = foreach ($p in $actionProps)    { $val = $Rule.$p; if ($val) { "$p=$($val -join ',')" } }
    [PSCustomObject]@{
        Conditions = if ($conditions) { $conditions -join '; ' } else { '(none matched)' }
        Actions    = if ($actions)    { $actions    -join '; ' } else { '(none)' }
    }
}

function Invoke-MessageTraceSearch {
    $lvMfResults.Items.Clear()
    $params = @{ StartDate = $dtpMfStart.Value; EndDate = $dtpMfEnd.Value; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($txtMfSender.Text))    { $params.SenderAddress    = $txtMfSender.Text.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($txtMfRecipient.Text)) { $params.RecipientAddress = $txtMfRecipient.Text.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($txtMfSubject.Text))   { $params.Subject          = $txtMfSubject.Text.Trim() }
    if ($cmbMfStatus.SelectedItem -and $cmbMfStatus.SelectedItem -ne '(Any)') { $params.Status = $cmbMfStatus.SelectedItem }
    if (($dtpMfEnd.Value - $dtpMfStart.Value).TotalDays -gt 10) {
        Write-Status "WARNING: Date range > 10 days - Get-MessageTraceV2 max window is 10 days; results may be incomplete."
    }
    # Use Get-MessageTraceV2 (Get-MessageTrace deprecated Sept 2025)
    # Filter $null results — Exchange cmdlets can return $null when no results, and @($null).Count equals 1
    $results = @(Get-MessageTraceV2 @params | Where-Object { $null -ne $_ -and -not [string]::IsNullOrEmpty($_.SenderAddress) })
    foreach ($r in $results) {
        $item = New-Object System.Windows.Forms.ListViewItem($(if ($r.Received) { ([datetime]$r.Received).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }))
        [void]$item.SubItems.Add([string]$r.SenderAddress)
        [void]$item.SubItems.Add([string]$r.RecipientAddress)
        [void]$item.SubItems.Add([string]$r.Subject)
        [void]$item.SubItems.Add([string]$r.Status)
        $item.Tag = @{ MessageTraceId=$r.MessageTraceId; RecipientAddress=$r.RecipientAddress;
                       SenderAddress=$r.SenderAddress; Subject=$r.Subject; Received=$r.Received }
        [void]$lvMfResults.Items.Add($item)
    }
    Write-Status "Mail Flow: $($results.Count) message(s) found."
}

function Invoke-MessageTraceDetailLookup {
    param($SelectedTag)
    $lvMfDetail.Items.Clear()
    $details = @(Get-MessageTraceDetailV2 -MessageTraceId $SelectedTag.MessageTraceId `
        -RecipientAddress $SelectedTag.RecipientAddress -ErrorAction Stop)
    if ($details.Count -eq 0) { Write-Status "Mail Flow: no transport events returned."; return }
    $propNames  = $details[0].PSObject.Properties.Name
    $dateProp   = 'Date','ReceivedTime','TimeStamp'     | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $eventProp  = 'Event','MessageTraceDetailEvent'     | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $detailProp = 'Detail','Data','Comments'            | Where-Object { $propNames -contains $_ } | Select-Object -First 1
    $sorted = if ($dateProp) { $details | Sort-Object $dateProp } else { $details }
    foreach ($d in $sorted) {
        $item = New-Object System.Windows.Forms.ListViewItem($(if ($dateProp -and $d.$dateProp) { ([datetime]$d.$dateProp).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }))
        [void]$item.SubItems.Add($(if ($eventProp)  { [string]$d.$eventProp  } else { '' }))
        [void]$item.SubItems.Add($(if ($detailProp) { [string]$d.$detailProp } else { ($d | Out-String).Trim() }))
        [void]$lvMfDetail.Items.Add($item)
    }
    Write-Status "Mail Flow: $($details.Count) transport event(s) loaded."
}

function Invoke-MailboxActivityLookup {
    param($SelectedTag)
    $lvMfActivity.Items.Clear()
    $records = Search-UnifiedAuditLog -StartDate $SelectedTag.Received -EndDate (Get-Date) `
        -RecordType ExchangeItem -Operations Move,SoftDelete,HardDelete,MoveToDeletedItems `
        -UserIds $SelectedTag.RecipientAddress -ResultSize 500 -ErrorAction Stop
    $matchCount = 0
    foreach ($rec in $records) {
        try { $ad = $rec.AuditData | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $ad.Item -or $ad.Item.Subject -ne $SelectedTag.Subject) { continue }
        $matchCount++
        $item = New-Object System.Windows.Forms.ListViewItem(([datetime]$ad.CreationTime).ToString('yyyy-MM-dd HH:mm:ss'))
        [void]$item.SubItems.Add($ad.Operation)
        [void]$item.SubItems.Add("$($ad.Item.ParentFolder.Path)")
        [void]$item.SubItems.Add("Id=$($ad.Item.Id)")
        [void]$lvMfActivity.Items.Add($item)
    }
    Write-Status "Mail Flow: $matchCount matching mailbox activity record(s) out of $($records.Count) candidate(s) for $($SelectedTag.RecipientAddress)."
}

function Invoke-InboxRulesLookup {
    param($SelectedTag)
    $lvMfRules.Items.Clear()
    $rules = Get-InboxRule -Mailbox $SelectedTag.RecipientAddress -ErrorAction Stop
    foreach ($rule in $rules) {
        $summary = Get-InboxRuleSummary -Rule $rule
        $item = New-Object System.Windows.Forms.ListViewItem($rule.Name)
        [void]$item.SubItems.Add($(if ($rule.Enabled) { 'Yes' } else { 'No' }))
        [void]$item.SubItems.Add($rule.Priority.ToString())
        [void]$item.SubItems.Add($summary.Conditions)
        [void]$item.SubItems.Add($summary.Actions)
        [void]$lvMfRules.Items.Add($item)
    }
    Write-Status "Mail Flow: $($rules.Count) inbox rule(s) for $($SelectedTag.RecipientAddress)."
}

function Add-ListViewCopyMenu {
    <#
    .SYNOPSIS
    Adds a right-click "Copy" context menu and Ctrl+C support to a ListView.
    Rows are copied as tab-delimited text (paste-friendly into Excel/Notepad).
    #>
    param([System.Windows.Forms.ListView]$lv)

    $cms = New-Object System.Windows.Forms.ContextMenuStrip

    $miCopySelected = New-Object System.Windows.Forms.ToolStripMenuItem "Copy Selected Row(s)"
    $miCopySelected.ShortcutKeyDisplayString = "Ctrl+C"
    $miCopySelected.Add_Click({
        $listview = $this.GetCurrentParent().SourceControl
        if ($null -eq $listview -or $listview.SelectedItems.Count -eq 0) { return }
        $lines = foreach ($item in $listview.SelectedItems) {
            (@($item.Text) + @($item.SubItems | Select-Object -Skip 1 | ForEach-Object { $_.Text })) -join "`t"
        }
        [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
    })
    [void]$cms.Items.Add($miCopySelected)

    $miCopyAll = New-Object System.Windows.Forms.ToolStripMenuItem "Copy All Rows"
    $miCopyAll.Add_Click({
        $listview = $this.GetCurrentParent().SourceControl
        if ($null -eq $listview -or $listview.Items.Count -eq 0) { return }
        $lines = foreach ($item in $listview.Items) {
            (@($item.Text) + @($item.SubItems | Select-Object -Skip 1 | ForEach-Object { $_.Text })) -join "`t"
        }
        [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
    })
    [void]$cms.Items.Add($miCopyAll)

    $lv.ContextMenuStrip = $cms

    # Ctrl+C keyboard shortcut — $args[0]=sender, $args[1]=KeyEventArgs
    $lv.Add_KeyDown({
        $e = $args[1]
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
            $lv = $args[0]
            if ($lv.SelectedItems.Count -eq 0) { return }
            $lines = foreach ($item in $lv.SelectedItems) {
                (@($item.Text) + @($item.SubItems | Select-Object -Skip 1 | ForEach-Object { $_.Text })) -join "`t"
            }
            [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
            $e.Handled = $true
        }
    })
}

function Get-MailboxHoldWarning {
    param([Parameter(Mandatory)][string]$Mailbox)
    $warnings = @()
    try {
        $mbx = Get-Mailbox -Identity $Mailbox -ErrorAction Stop
    }
    catch {
        try {
            Get-Mailbox -Identity $Mailbox -InactiveMailboxOnly -ErrorAction Stop | Out-Null
            $warnings += "Mailbox is INACTIVE (soft-deleted). Remove-CalendarEvents cannot modify it - restore first."
        }
        catch { }
        return $warnings
    }
    if ($mbx.LitigationHoldEnabled -or ($mbx.InPlaceHolds -and $mbx.InPlaceHolds.Count -gt 0)) {
        $warnings += "Mailbox has a hold enabled (LitigationHold=$($mbx.LitigationHoldEnabled)" +
            $(if ($mbx.InPlaceHolds) { ", InPlaceHolds=$($mbx.InPlaceHolds -join ',')" }) +
            "). Remove-CalendarEvents often fails with a server-side error while a hold is active."
    }
    if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') {
        try {
            $stats     = Get-MailboxStatistics -Identity $Mailbox -ErrorAction Stop
            $sizeBytes = $stats.TotalItemSize.Value.ToBytes()
            if ($sizeBytes -gt 50GB) {
                $warnings += "Shared mailbox is $($stats.TotalItemSize.Value) - mailboxes over 50 GB need a license or they enter a restricted state that can break calendar cmdlets."
            }
        }
        catch { }
    }
    return $warnings
}

function Get-CalendarEventCancellationPreview {
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][int]$WindowDays,
        [switch]$PreviewOnly,
        [switch]$UseCustomRouting
    )
    $params = @{
        Identity                = $Mailbox
        CancelOrganizedMeetings = $true
        QueryStartDate          = $StartDate
        QueryWindowInDays       = $WindowDays
        Confirm                 = $false
        Verbose                 = $true
        ErrorAction             = 'SilentlyContinue'
        ErrorVariable           = 'cmdletNonTerminatingErrors'
    }
    if ($PreviewOnly)      { $params.PreviewOnly      = $true }
    if ($UseCustomRouting) { $params.UseCustomRouting = $true }
    $cmdletNonTerminatingErrors = $null
    $rawLines = @(Remove-CalendarEvents @params 4>&1 | ForEach-Object { $_.ToString() })
    if ($cmdletNonTerminatingErrors) {
        foreach ($e in $cmdletNonTerminatingErrors) { $rawLines += "[non-terminating, ignored] $($e.ToString())" }
    }
    $meetings = foreach ($line in $rawLines) {
        if ($line -match 'subject\s+"(?<Subject>.*?)"\s+and start date\s+"(?<StartDate>.*?)"') {
            [PSCustomObject]@{ Subject = $Matches.Subject; StartDate = $Matches.StartDate }
        }
    }
    [PSCustomObject]@{ Meetings = @($meetings); RawLines = $rawLines }
}

function Get-CalendarAttendeeCountsBySubject {
    param(
        [Parameter(Mandatory)][string]$Mailbox,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][datetime]$EndDate
    )
    $counts = @{}
    $events = Get-MgUserCalendarView -UserId $Mailbox `
        -StartDateTime $StartDate.ToString('yyyy-MM-ddTHH:mm:ss') `
        -EndDateTime   $EndDate.ToString('yyyy-MM-ddTHH:mm:ss') `
        -All -Property "Subject,Attendees,Organizer" -ErrorAction Stop
    foreach ($ev in $events) {
        if ([string]::IsNullOrWhiteSpace($ev.Subject)) { continue }
        $key            = $ev.Subject.Trim().ToLowerInvariant()
        $otherAttendees = @($ev.Attendees | Where-Object { $_.Type -ne 'resource' })
        $count          = $otherAttendees.Count
        if (-not $counts.ContainsKey($key) -or $count -lt $counts[$key]) { $counts[$key] = $count }
    }
    return $counts
}

# ================================================================================
# Form
# ================================================================================

$form                = New-Object System.Windows.Forms.Form
$form.Text           = "O365 Admin Tools"
$form.Size           = New-Object System.Drawing.Size(960, 1000)
$form.StartPosition  = "CenterScreen"
$form.MinimumSize    = New-Object System.Drawing.Size(960, 1000)

$font              = New-Object System.Drawing.Font("Segoe UI", 10)
$fontBold          = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$fontItalicSmall   = New-Object System.Drawing.Font("Segoe UI",  8, [System.Drawing.FontStyle]::Italic)

# ── Shared: TabControl ───────────────────────────────────────────────────────────
$tabs          = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size     = New-Object System.Drawing.Size(932, 790)
$tabs.Font     = $font
$form.Controls.Add($tabs)

# ── Shared: Connection buttons (EXO / IPPS / Disconnect) ─────────────────────────
$btnConnectEXO          = New-Object System.Windows.Forms.Button
$btnConnectEXO.Text     = "Connect EXO"
$btnConnectEXO.Location = New-Object System.Drawing.Point(20, 806)
$btnConnectEXO.Size     = New-Object System.Drawing.Size(130, 28)
$btnConnectEXO.Font     = $font
$form.Controls.Add($btnConnectEXO)

$btnConnectIPPS          = New-Object System.Windows.Forms.Button
$btnConnectIPPS.Text     = "Connect IPPS (Search Only)"
$btnConnectIPPS.Location = New-Object System.Drawing.Point(158, 806)
$btnConnectIPPS.Size     = New-Object System.Drawing.Size(210, 28)
$btnConnectIPPS.Font     = $font
$form.Controls.Add($btnConnectIPPS)

$btnDisconnectAll          = New-Object System.Windows.Forms.Button
$btnDisconnectAll.Text     = "Disconnect All"
$btnDisconnectAll.Location = New-Object System.Drawing.Point(376, 806)
$btnDisconnectAll.Size     = New-Object System.Drawing.Size(130, 28)
$btnDisconnectAll.Font     = $font
$form.Controls.Add($btnDisconnectAll)

$lblExoStatus          = New-Object System.Windows.Forms.Label
$lblExoStatus.Location = New-Object System.Drawing.Point(520, 813)
$lblExoStatus.Size     = New-Object System.Drawing.Size(200, 20)
$lblExoStatus.Font     = $font
$form.Controls.Add($lblExoStatus)

$lblIppsStatus          = New-Object System.Windows.Forms.Label
$lblIppsStatus.Location = New-Object System.Drawing.Point(728, 813)
$lblIppsStatus.Size     = New-Object System.Drawing.Size(200, 20)
$lblIppsStatus.Font     = $font
$form.Controls.Add($lblIppsStatus)

# ── Shared: Log box ──────────────────────────────────────────────────────────────
$txtLog          = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 842)
$txtLog.Size     = New-Object System.Drawing.Size(915, 95)
$txtLog.Multiline  = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly   = $true
$txtLog.Font       = $font
$form.Controls.Add($txtLog)

# ================================================================================
# TAB 1 — Shared Mailbox  (original functionality, adapted for tab layout)
# ================================================================================

$tabMailbox      = New-Object System.Windows.Forms.TabPage
$tabMailbox.Text = "Create Shared Mailbox"

# Display Name
$lblDisplay          = New-Object System.Windows.Forms.Label
$lblDisplay.Text     = "Display Name:"
$lblDisplay.Location = New-Object System.Drawing.Point(20, 22)
$lblDisplay.AutoSize = $true
$tabMailbox.Controls.Add($lblDisplay)

$txtDisplay          = New-Object System.Windows.Forms.TextBox
$txtDisplay.Location = New-Object System.Drawing.Point(155, 20)
$txtDisplay.Size     = New-Object System.Drawing.Size(310, 25)
$txtDisplay.Font     = $font
$tabMailbox.Controls.Add($txtDisplay)

# Alias
$lblAlias          = New-Object System.Windows.Forms.Label
$lblAlias.Text     = "Alias (no @):"
$lblAlias.Location = New-Object System.Drawing.Point(20, 62)
$lblAlias.AutoSize = $true
$tabMailbox.Controls.Add($lblAlias)

$txtAlias          = New-Object System.Windows.Forms.TextBox
$txtAlias.Location = New-Object System.Drawing.Point(155, 60)
$txtAlias.Size     = New-Object System.Drawing.Size(310, 25)
$txtAlias.Font     = $font
$tabMailbox.Controls.Add($txtAlias)

# Primary SMTP
$lblSmtp                  = New-Object System.Windows.Forms.Label
$lblSmtp.Text             = "Primary SMTP:"
$lblSmtp.Location         = New-Object System.Drawing.Point(20, 102)
$lblSmtp.AutoSize         = $true
$tabMailbox.Controls.Add($lblSmtp)

$txtSmtp                  = New-Object System.Windows.Forms.TextBox
$txtSmtp.Location         = New-Object System.Drawing.Point(155, 100)
$txtSmtp.Size             = New-Object System.Drawing.Size(310, 25)
$txtSmtp.Font             = $font
Add-PlaceholderBehavior $txtSmtp "e.g. alias@provenit.com"
$tabMailbox.Controls.Add($txtSmtp)

# Full Access
$lblFull          = New-Object System.Windows.Forms.Label
$lblFull.Text     = "Full Access (one per line):"
$lblFull.Location = New-Object System.Drawing.Point(20, 148)
$lblFull.AutoSize = $true
$tabMailbox.Controls.Add($lblFull)

$txtFull            = New-Object System.Windows.Forms.TextBox
$txtFull.Location   = New-Object System.Drawing.Point(20, 170)
$txtFull.Size       = New-Object System.Drawing.Size(450, 110)
$txtFull.Multiline  = $true
$txtFull.ScrollBars = "Vertical"
$txtFull.Font       = $font
$tabMailbox.Controls.Add($txtFull)

# Send As
$lblSendAs          = New-Object System.Windows.Forms.Label
$lblSendAs.Text     = "Send As (one per line):"
$lblSendAs.Location = New-Object System.Drawing.Point(20, 298)
$lblSendAs.AutoSize = $true
$tabMailbox.Controls.Add($lblSendAs)

$txtSendAs            = New-Object System.Windows.Forms.TextBox
$txtSendAs.Location   = New-Object System.Drawing.Point(20, 320)
$txtSendAs.Size       = New-Object System.Drawing.Size(450, 110)
$txtSendAs.Multiline  = $true
$txtSendAs.ScrollBars = "Vertical"
$txtSendAs.Font       = $font
$tabMailbox.Controls.Add($txtSendAs)

# Validate + Create buttons
$btnValidate          = New-Object System.Windows.Forms.Button
$btnValidate.Text     = "Validate"
$btnValidate.Location = New-Object System.Drawing.Point(20, 450)
$btnValidate.Size     = New-Object System.Drawing.Size(120, 35)
$btnValidate.Font     = $font
$tabMailbox.Controls.Add($btnValidate)

$btnCreate          = New-Object System.Windows.Forms.Button
$btnCreate.Text     = "Create Mailbox"
$btnCreate.Location = New-Object System.Drawing.Point(150, 450)
$btnCreate.Size     = New-Object System.Drawing.Size(140, 35)
$btnCreate.Font     = $font
$btnCreate.Enabled  = $false
$tabMailbox.Controls.Add($btnCreate)

# Validation ListView
$lvMailbox               = New-Object System.Windows.Forms.ListView
$lvMailbox.Location      = New-Object System.Drawing.Point(490, 20)
$lvMailbox.Size          = New-Object System.Drawing.Size(425, 465)
$lvMailbox.View          = "Details"
$lvMailbox.FullRowSelect = $true
$lvMailbox.GridLines     = $true
$lvMailbox.Font          = $font
[void]$lvMailbox.Columns.Add("Type",      100)
[void]$lvMailbox.Columns.Add("Identity",  220)
[void]$lvMailbox.Columns.Add("Status",     85)
$tabMailbox.Controls.Add($lvMailbox)

# ================================================================================
# TAB 2 — Mailbox Permissions & Settings (formerly TAB 3)
# ================================================================================

$tabMbxPerms      = New-Object System.Windows.Forms.TabPage
$tabMbxPerms.Text = "Mailbox Permissions"

# ── Mailbox lookup row ───────────────────────────────────────────────────────────
$lblMbxLookup          = New-Object System.Windows.Forms.Label
$lblMbxLookup.Text     = "Mailbox:"
$lblMbxLookup.Location = New-Object System.Drawing.Point(20, 16)
$lblMbxLookup.AutoSize = $true
$lblMbxLookup.Font     = $font
$tabMbxPerms.Controls.Add($lblMbxLookup)

$txtMbxLookup          = New-Object System.Windows.Forms.TextBox
$txtMbxLookup.Location = New-Object System.Drawing.Point(90, 14)
$txtMbxLookup.Size     = New-Object System.Drawing.Size(380, 25)
$txtMbxLookup.Font     = $font
Add-PlaceholderBehavior $txtMbxLookup "alias, UPN, or email address"
$tabMbxPerms.Controls.Add($txtMbxLookup)

$btnMbxLoad          = New-Object System.Windows.Forms.Button
$btnMbxLoad.Text     = "Load Mailbox"
$btnMbxLoad.Location = New-Object System.Drawing.Point(482, 12)
$btnMbxLoad.Size     = New-Object System.Drawing.Size(130, 30)
$btnMbxLoad.Font     = $font
$tabMbxPerms.Controls.Add($btnMbxLoad)

$lblMbxStatus           = New-Object System.Windows.Forms.Label
$lblMbxStatus.Text      = ""
$lblMbxStatus.Location  = New-Object System.Drawing.Point(622, 17)
$lblMbxStatus.AutoSize  = $true
$lblMbxStatus.Font      = $font
$lblMbxStatus.ForeColor = [System.Drawing.Color]::DimGray
$tabMbxPerms.Controls.Add($lblMbxStatus)

# ── Permissions label + ListView ─────────────────────────────────────────────────
$lblMbxPermsHdr          = New-Object System.Windows.Forms.Label
$lblMbxPermsHdr.Text     = "Mailbox Permissions:"
$lblMbxPermsHdr.Location = New-Object System.Drawing.Point(20, 52)
$lblMbxPermsHdr.AutoSize = $true
$lblMbxPermsHdr.Font     = $fontBold
$tabMbxPerms.Controls.Add($lblMbxPermsHdr)

$lvMbxPerms               = New-Object System.Windows.Forms.ListView
$lvMbxPerms.Location      = New-Object System.Drawing.Point(20, 72)
$lvMbxPerms.Size          = New-Object System.Drawing.Size(892, 180)
$lvMbxPerms.View          = "Details"
$lvMbxPerms.FullRowSelect = $true
$lvMbxPerms.GridLines     = $true
$lvMbxPerms.Font          = $font
[void]$lvMbxPerms.Columns.Add("User",            310)
[void]$lvMbxPerms.Columns.Add("Full Access",      130)
[void]$lvMbxPerms.Columns.Add("Send As",          120)
[void]$lvMbxPerms.Columns.Add("Send on Behalf",   200)
$tabMbxPerms.Controls.Add($lvMbxPerms)

# ── Grant / Revoke GroupBox ──────────────────────────────────────────────────────
$grpMbxGrant          = New-Object System.Windows.Forms.GroupBox
$grpMbxGrant.Text     = "Grant / Revoke Permissions"
$grpMbxGrant.Location = New-Object System.Drawing.Point(20, 260)
$grpMbxGrant.Size     = New-Object System.Drawing.Size(892, 68)
$grpMbxGrant.Font     = $fontBold
$tabMbxPerms.Controls.Add($grpMbxGrant)

$lblMbxGrantUser          = New-Object System.Windows.Forms.Label
$lblMbxGrantUser.Text     = "User:"
$lblMbxGrantUser.Location = New-Object System.Drawing.Point(12, 30)
$lblMbxGrantUser.AutoSize = $true
$lblMbxGrantUser.Font     = $font
$grpMbxGrant.Controls.Add($lblMbxGrantUser)

$txtMbxGrantUser          = New-Object System.Windows.Forms.TextBox
$txtMbxGrantUser.Location = New-Object System.Drawing.Point(52, 28)
$txtMbxGrantUser.Size     = New-Object System.Drawing.Size(190, 25)
$txtMbxGrantUser.Font     = $font
Add-PlaceholderBehavior $txtMbxGrantUser "user@domain.com"
$grpMbxGrant.Controls.Add($txtMbxGrantUser)

$chkFullAccess          = New-Object System.Windows.Forms.CheckBox
$chkFullAccess.Text     = "Full Access"
$chkFullAccess.Location = New-Object System.Drawing.Point(252, 30)
$chkFullAccess.AutoSize = $true
$chkFullAccess.Font     = $font
$grpMbxGrant.Controls.Add($chkFullAccess)

$chkAutoMap          = New-Object System.Windows.Forms.CheckBox
$chkAutoMap.Text     = "Auto-Map"
$chkAutoMap.Location = New-Object System.Drawing.Point(355, 30)
$chkAutoMap.AutoSize = $true
$chkAutoMap.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$chkAutoMap.Checked  = $true
$chkAutoMap.Enabled  = $false   # Only enabled when Full Access is checked
$grpMbxGrant.Controls.Add($chkAutoMap)

$chkSendAs          = New-Object System.Windows.Forms.CheckBox
$chkSendAs.Text     = "Send As"
$chkSendAs.Location = New-Object System.Drawing.Point(450, 30)
$chkSendAs.AutoSize = $true
$chkSendAs.Font     = $font
$grpMbxGrant.Controls.Add($chkSendAs)

$chkSendOnBehalf          = New-Object System.Windows.Forms.CheckBox
$chkSendOnBehalf.Text     = "Send on Behalf"
$chkSendOnBehalf.Location = New-Object System.Drawing.Point(525, 30)
$chkSendOnBehalf.AutoSize = $true
$chkSendOnBehalf.Font     = $font
$grpMbxGrant.Controls.Add($chkSendOnBehalf)

$btnMbxGrant          = New-Object System.Windows.Forms.Button
$btnMbxGrant.Text     = "Grant"
$btnMbxGrant.Location = New-Object System.Drawing.Point(692, 26)
$btnMbxGrant.Size     = New-Object System.Drawing.Size(90, 30)
$btnMbxGrant.Font     = $font
$grpMbxGrant.Controls.Add($btnMbxGrant)

$btnMbxRevoke          = New-Object System.Windows.Forms.Button
$btnMbxRevoke.Text     = "Revoke"
$btnMbxRevoke.Location = New-Object System.Drawing.Point(790, 26)
$btnMbxRevoke.Size     = New-Object System.Drawing.Size(90, 30)
$btnMbxRevoke.Font     = $font
$grpMbxGrant.Controls.Add($btnMbxRevoke)

# ── Forwarding GroupBox (bottom-left) ────────────────────────────────────────────
$grpFwd          = New-Object System.Windows.Forms.GroupBox
$grpFwd.Text     = "Forwarding"
$grpFwd.Location = New-Object System.Drawing.Point(20, 336)
$grpFwd.Size     = New-Object System.Drawing.Size(892, 90)
$grpFwd.Font     = $fontBold
$tabMbxPerms.Controls.Add($grpFwd)

$lblFwdTo          = New-Object System.Windows.Forms.Label
$lblFwdTo.Text     = "Forward to:"
$lblFwdTo.Location = New-Object System.Drawing.Point(12, 28)
$lblFwdTo.AutoSize = $true
$lblFwdTo.Font     = $font
$grpFwd.Controls.Add($lblFwdTo)

$txtFwdTo          = New-Object System.Windows.Forms.TextBox
$txtFwdTo.Location = New-Object System.Drawing.Point(92, 26)
$txtFwdTo.Size     = New-Object System.Drawing.Size(230, 25)
$txtFwdTo.Font     = $font
Add-PlaceholderBehavior $txtFwdTo "user@domain.com"
$grpFwd.Controls.Add($txtFwdTo)

$chkKeepCopy          = New-Object System.Windows.Forms.CheckBox
$chkKeepCopy.Text     = "Keep copy"
$chkKeepCopy.Location = New-Object System.Drawing.Point(330, 28)
$chkKeepCopy.AutoSize = $true
$chkKeepCopy.Font     = $font
$grpFwd.Controls.Add($chkKeepCopy)

$btnSetFwd          = New-Object System.Windows.Forms.Button
$btnSetFwd.Text     = "Set"
$btnSetFwd.Location = New-Object System.Drawing.Point(12, 57)
$btnSetFwd.Size     = New-Object System.Drawing.Size(80, 26)
$btnSetFwd.Font     = $font
$grpFwd.Controls.Add($btnSetFwd)

$btnClearFwd          = New-Object System.Windows.Forms.Button
$btnClearFwd.Text     = "Clear"
$btnClearFwd.Location = New-Object System.Drawing.Point(98, 57)
$btnClearFwd.Size     = New-Object System.Drawing.Size(80, 26)
$btnClearFwd.Font     = $font
$grpFwd.Controls.Add($btnClearFwd)

# ── Calendar Permissions GroupBox ────────────────────────────────────────────────
$grpCalPerms          = New-Object System.Windows.Forms.GroupBox
$grpCalPerms.Text     = "Calendar Permissions"
$grpCalPerms.Location = New-Object System.Drawing.Point(20, 434)
$grpCalPerms.Size     = New-Object System.Drawing.Size(892, 328)
$grpCalPerms.Font     = $fontBold
$tabMbxPerms.Controls.Add($grpCalPerms)

$btnRefreshCal          = New-Object System.Windows.Forms.Button
$btnRefreshCal.Text     = "Refresh"
$btnRefreshCal.Location = New-Object System.Drawing.Point(792, 18)
$btnRefreshCal.Size     = New-Object System.Drawing.Size(90, 26)
$btnRefreshCal.Font     = $font
$grpCalPerms.Controls.Add($btnRefreshCal)

$lvCalPerms               = New-Object System.Windows.Forms.ListView
$lvCalPerms.Location      = New-Object System.Drawing.Point(10, 48)
$lvCalPerms.Size          = New-Object System.Drawing.Size(870, 184)
$lvCalPerms.View          = "Details"
$lvCalPerms.FullRowSelect = $true
$lvCalPerms.GridLines     = $true
$lvCalPerms.Font          = $font
[void]$lvCalPerms.Columns.Add("User",          300)
[void]$lvCalPerms.Columns.Add("Access Rights", 220)
[void]$lvCalPerms.Columns.Add("Is Inherited",  130)
$grpCalPerms.Controls.Add($lvCalPerms)

$lblCalGrantUser          = New-Object System.Windows.Forms.Label
$lblCalGrantUser.Text     = "User:"
$lblCalGrantUser.Location = New-Object System.Drawing.Point(10, 242)
$lblCalGrantUser.AutoSize = $true
$lblCalGrantUser.Font     = $font
$grpCalPerms.Controls.Add($lblCalGrantUser)

$txtCalGrantUser          = New-Object System.Windows.Forms.TextBox
$txtCalGrantUser.Location = New-Object System.Drawing.Point(52, 240)
$txtCalGrantUser.Size     = New-Object System.Drawing.Size(200, 25)
$txtCalGrantUser.Font     = $font
Add-PlaceholderBehavior $txtCalGrantUser "user@domain.com"
$grpCalPerms.Controls.Add($txtCalGrantUser)

$lblCalLevel          = New-Object System.Windows.Forms.Label
$lblCalLevel.Text     = "Permission:"
$lblCalLevel.Location = New-Object System.Drawing.Point(265, 242)
$lblCalLevel.AutoSize = $true
$lblCalLevel.Font     = $font
$grpCalPerms.Controls.Add($lblCalLevel)

$cboCalLevel              = New-Object System.Windows.Forms.ComboBox
$cboCalLevel.Location     = New-Object System.Drawing.Point(345, 239)
$cboCalLevel.Size         = New-Object System.Drawing.Size(185, 25)
$cboCalLevel.Font         = $font
$cboCalLevel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
@('Owner','PublishingEditor','Editor','PublishingAuthor','Author',
  'NonEditingAuthor','Reviewer','AvailabilityOnly','LimitedDetails') |
    ForEach-Object { [void]$cboCalLevel.Items.Add($_) }
$cboCalLevel.SelectedIndex = 6
$grpCalPerms.Controls.Add($cboCalLevel)

$btnCalGrant          = New-Object System.Windows.Forms.Button
$btnCalGrant.Text     = "Grant / Update"
$btnCalGrant.Location = New-Object System.Drawing.Point(545, 237)
$btnCalGrant.Size     = New-Object System.Drawing.Size(130, 30)
$btnCalGrant.Font     = $font
$grpCalPerms.Controls.Add($btnCalGrant)

$lblCalRemoveUser          = New-Object System.Windows.Forms.Label
$lblCalRemoveUser.Text     = "Remove:"
$lblCalRemoveUser.Location = New-Object System.Drawing.Point(10, 284)
$lblCalRemoveUser.AutoSize = $true
$lblCalRemoveUser.Font     = $font
$grpCalPerms.Controls.Add($lblCalRemoveUser)

$txtCalRemoveUser          = New-Object System.Windows.Forms.TextBox
$txtCalRemoveUser.Location = New-Object System.Drawing.Point(75, 282)
$txtCalRemoveUser.Size     = New-Object System.Drawing.Size(200, 25)
$txtCalRemoveUser.Font     = $font
Add-PlaceholderBehavior $txtCalRemoveUser "user@domain.com"
$grpCalPerms.Controls.Add($txtCalRemoveUser)

$btnCalRemove          = New-Object System.Windows.Forms.Button
$btnCalRemove.Text     = "Remove"
$btnCalRemove.Location = New-Object System.Drawing.Point(285, 280)
$btnCalRemove.Size     = New-Object System.Drawing.Size(100, 28)
$btnCalRemove.Font     = $font
$grpCalPerms.Controls.Add($btnCalRemove)

$lblCalHint           = New-Object System.Windows.Forms.Label
$lblCalHint.Text      = "Click a row to fill both user fields."
$lblCalHint.Location  = New-Object System.Drawing.Point(400, 287)
$lblCalHint.AutoSize  = $true
$lblCalHint.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblCalHint.ForeColor = [System.Drawing.Color]::DimGray
$grpCalPerms.Controls.Add($lblCalHint)

# ================================================================================
# TAB 4 — Auto-Reply (Out of Office)
# ================================================================================

$tabOOO      = New-Object System.Windows.Forms.TabPage
$tabOOO.Text = "Auto-Reply"

# ── Mailbox lookup row ───────────────────────────────────────────────────────────
$lblOOOMbxLbl          = New-Object System.Windows.Forms.Label
$lblOOOMbxLbl.Text     = "Mailbox:"
$lblOOOMbxLbl.Location = New-Object System.Drawing.Point(20, 14)
$lblOOOMbxLbl.AutoSize = $true
$lblOOOMbxLbl.Font     = $font
$tabOOO.Controls.Add($lblOOOMbxLbl)

$txtOOOMbx          = New-Object System.Windows.Forms.TextBox
$txtOOOMbx.Location = New-Object System.Drawing.Point(90, 12)
$txtOOOMbx.Size     = New-Object System.Drawing.Size(360, 25)
$txtOOOMbx.Font     = $font
Add-PlaceholderBehavior $txtOOOMbx "alias, UPN, or email"
$tabOOO.Controls.Add($txtOOOMbx)

$btnOOOLoad          = New-Object System.Windows.Forms.Button
$btnOOOLoad.Text     = "Load"
$btnOOOLoad.Location = New-Object System.Drawing.Point(460, 10)
$btnOOOLoad.Size     = New-Object System.Drawing.Size(80, 28)
$btnOOOLoad.Font     = $font
$tabOOO.Controls.Add($btnOOOLoad)

$lblOOOCurrentMbx           = New-Object System.Windows.Forms.Label
$lblOOOCurrentMbx.Text      = ""
$lblOOOCurrentMbx.Location  = New-Object System.Drawing.Point(552, 15)
$lblOOOCurrentMbx.AutoSize  = $true
$lblOOOCurrentMbx.Font      = $font
$lblOOOCurrentMbx.ForeColor = [System.Drawing.Color]::DimGray
$tabOOO.Controls.Add($lblOOOCurrentMbx)

$lblOOOState          = New-Object System.Windows.Forms.Label
$lblOOOState.Text     = "Status:"
$lblOOOState.Location = New-Object System.Drawing.Point(20, 52)
$lblOOOState.AutoSize = $true
$lblOOOState.Font     = $font
$tabOOO.Controls.Add($lblOOOState)

$cboOOOState               = New-Object System.Windows.Forms.ComboBox
$cboOOOState.Location      = New-Object System.Drawing.Point(72, 49)
$cboOOOState.Size          = New-Object System.Drawing.Size(140, 25)
$cboOOOState.Font          = $font
$cboOOOState.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
@('Disabled', 'Enabled') | ForEach-Object { [void]$cboOOOState.Items.Add($_) }
$cboOOOState.SelectedIndex = 0
$tabOOO.Controls.Add($cboOOOState)

$lblOOOInternal          = New-Object System.Windows.Forms.Label
$lblOOOInternal.Text     = "Internal Reply Message:"
$lblOOOInternal.Location = New-Object System.Drawing.Point(20, 86)
$lblOOOInternal.AutoSize = $true
$lblOOOInternal.Font     = $fontBold
$tabOOO.Controls.Add($lblOOOInternal)

$txtOOOInternal            = New-Object System.Windows.Forms.TextBox
$txtOOOInternal.Location   = New-Object System.Drawing.Point(20, 108)
$txtOOOInternal.Size       = New-Object System.Drawing.Size(892, 175)
$txtOOOInternal.Multiline  = $true
$txtOOOInternal.Font       = $font
$txtOOOInternal.ScrollBars = "Vertical"
$tabOOO.Controls.Add($txtOOOInternal)

$lblOOOExternal          = New-Object System.Windows.Forms.Label
$lblOOOExternal.Text     = "External Reply Message:"
$lblOOOExternal.Location = New-Object System.Drawing.Point(20, 296)
$lblOOOExternal.AutoSize = $true
$lblOOOExternal.Font     = $fontBold
$tabOOO.Controls.Add($lblOOOExternal)

$txtOOOExternal            = New-Object System.Windows.Forms.TextBox
$txtOOOExternal.Location   = New-Object System.Drawing.Point(20, 318)
$txtOOOExternal.Size       = New-Object System.Drawing.Size(892, 175)
$txtOOOExternal.Multiline  = $true
$txtOOOExternal.Font       = $font
$txtOOOExternal.ScrollBars = "Vertical"
$tabOOO.Controls.Add($txtOOOExternal)

$btnSetOOO          = New-Object System.Windows.Forms.Button
$btnSetOOO.Text     = "Apply Auto-Reply"
$btnSetOOO.Location = New-Object System.Drawing.Point(792, 504)
$btnSetOOO.Size     = New-Object System.Drawing.Size(120, 35)
$btnSetOOO.Font     = $font
$tabOOO.Controls.Add($btnSetOOO)

# ================================================================================
# State
# ================================================================================

$script:validated   = $false
$script:validFull   = @()
$script:validSendAs = @()
$script:loadedMbx   = $null   # Currently loaded mailbox object for Tab 3

# ── Spam Cleanup / Mail Flow state ───────────────────────────────────────────────
$script:ExoConnected  = $false
$script:IppsConnected = $false
$script:IppsMode      = "Not Connected"
$script:LastSearchName  = $null
$script:LastSearchItems = 0
$script:recResult       = $null   # Last successful Recurring Events search params
$script:loadedOOOMbx    = $null   # Mailbox loaded from the Auto-Reply tab directly

# ================================================================================
# Event Handlers — Connect (shared)
# ================================================================================

# ================================================================================
# Event Handlers — Shared Mailbox tab
# ================================================================================

$btnValidate.Add_Click({
    $lvMailbox.Items.Clear()
    $script:validated   = $false
    $script:validFull   = @()
    $script:validSendAs = @()
    $btnCreate.Enabled  = $false

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()
    $ok      = $true

    if ([string]::IsNullOrWhiteSpace($display)) {
        Write-Log "Display Name is required."
        $ok = $false
    }

    if (-not (Test-MailAlias -Alias $alias)) {
        Write-Log "Alias is invalid - use alphanumeric only, no @ symbol."
        $ok = $false
    }

    if (-not [string]::IsNullOrWhiteSpace($smtp)) {
        if ($smtp -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Log "Primary SMTP doesn't look like a valid email address."
            $ok = $false
        }
    }

    foreach ($u in (Split-Entries $txtFull.Text)) {
        $r    = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("FullAccess")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validFull += $r.PrimarySmtpAddress.ToString()
        }
        else {
            [void]$item.SubItems.Add("NOT FOUND")
            $item.ForeColor = [System.Drawing.Color]::Red
            $ok = $false
        }
        [void]$lvMailbox.Items.Add($item)
    }

    foreach ($u in (Split-Entries $txtSendAs.Text)) {
        $r    = Get-RecipientSafe $u
        $item = New-Object System.Windows.Forms.ListViewItem("SendAs")
        [void]$item.SubItems.Add($u)
        if ($null -ne $r) {
            [void]$item.SubItems.Add("OK")
            $script:validSendAs += $r.PrimarySmtpAddress.ToString()
        }
        else {
            [void]$item.SubItems.Add("NOT FOUND")
            $item.ForeColor = [System.Drawing.Color]::Red
            $ok = $false
        }
        [void]$lvMailbox.Items.Add($item)
    }

    if ($ok) {
        $script:validated  = $true
        $btnCreate.Enabled = $true
        Write-Log "Validation passed - click Create Mailbox to proceed."
    }
    else {
        Write-Log "Validation failed. Fix NOT FOUND items and validate again."
    }
})

$btnCreate.Add_Click({
    if (-not $script:validated) { Write-Log "Please run Validate first."; return }

    $display = $txtDisplay.Text.Trim()
    $alias   = $txtAlias.Text.Trim()
    $smtp    = $txtSmtp.Text.Trim()

    try {
        Write-Log "Creating shared mailbox: DisplayName='$display'  Alias='$alias'  SMTP='$smtp'"

        $params = @{
            Shared      = $true
            Name        = $display
            DisplayName = $display
            Alias       = $alias
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($smtp)) { $params.PrimarySmtpAddress = $smtp }

        New-Mailbox @params | Out-Null
        Write-Log "Mailbox creation submitted - waiting for EXO propagation..."

        $idToFind = if ($smtp) { $smtp } else { $alias }
        $mbx = $null
        for ($i = 1; $i -le 12; $i++) {
            Start-Sleep -Seconds 5
            $mbx = Get-Mailbox -Identity $idToFind -ErrorAction SilentlyContinue
            if ($mbx) { break }
            Write-Log "  Waiting... attempt $i/12"
        }
        if (-not $mbx) {
            throw "Mailbox not found after waiting. Permissions can be applied manually once it appears."
        }

        $mailboxId = $mbx.PrimarySmtpAddress.ToString()
        Write-Log "Mailbox confirmed: $mailboxId"

        foreach ($u in $script:validFull) {
            Write-Log "  FullAccess  -> $u"
            Add-MailboxPermission -Identity $mailboxId -User $u `
                -AccessRights FullAccess -InheritanceType All -AutoMapping:$true `
                -ErrorAction Stop | Out-Null
        }

        foreach ($u in $script:validSendAs) {
            Write-Log "  SendAs      -> $u"
            Add-RecipientPermission -Identity $mailboxId -Trustee $u `
                -AccessRights SendAs -Confirm:$false -ErrorAction Stop | Out-Null
        }

        Write-Log "Done."
        [System.Windows.Forms.MessageBox]::Show(
            "Shared mailbox created and permissions applied.`r`n$mailboxId",
            "Success", "OK", "Information"
        ) | Out-Null
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", "OK", "Error") | Out-Null
    }
})

# ================================================================================
# Event Handlers — Calendar Permissions (embedded in Mailbox Permissions tab)
# ================================================================================

# Click a row -> auto-fill both user fields and match the permission level
$lvCalPerms.Add_SelectedIndexChanged({
    if ($lvCalPerms.SelectedItems.Count -eq 0) { return }
    $sel  = $lvCalPerms.SelectedItems[0]
    $user = $sel.Text
    if ($user -notin @('Default', 'Anonymous')) {
        $txtCalGrantUser.Text       = $user
        $txtCalGrantUser.ForeColor  = [System.Drawing.SystemColors]::WindowText
        $txtCalRemoveUser.Text      = $user
        $txtCalRemoveUser.ForeColor = [System.Drawing.SystemColors]::WindowText
    }
    $currentLevel = $sel.SubItems[1].Text.Trim()
    $idx = $cboCalLevel.Items.IndexOf($currentLevel)
    if ($idx -ge 0) { $cboCalLevel.SelectedIndex = $idx }
})

$btnRefreshCal.Add_Click({
    if ($null -eq $script:loadedMbx) {
        Write-Log "Calendar: Load a mailbox in the Mailbox Permissions section first."
        return
    }
    $mailbox = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $lvCalPerms.Items.Clear()
    try {
        Write-Log "Calendar: Loading permissions for $mailbox ..."
        $calPath = Get-CalendarIdentity -Mailbox $mailbox
        $perms   = Get-MailboxFolderPermission -Identity $calPath -ErrorAction Stop
        foreach ($p in $perms) {
            $item = New-Object System.Windows.Forms.ListViewItem($p.User.ToString())
            [void]$item.SubItems.Add(($p.AccessRights -join ', '))
            [void]$item.SubItems.Add($(if ($p.IsInherited) { 'Yes' } else { 'No' }))
            if ($p.User.ToString() -in @('Default', 'Anonymous')) {
                $item.ForeColor = [System.Drawing.Color]::Gray
            }
            [void]$lvCalPerms.Items.Add($item)
        }
        Write-Log "Calendar: $($perms.Count) permission entr$(if ($perms.Count -eq 1){'y'}else{'ies'}) loaded."
    }
    catch {
        Write-Log "Calendar ERROR (load): $($_.Exception.Message)"
    }
})

$btnCalGrant.Add_Click({
    if ($null -eq $script:loadedMbx) {
        Write-Log "Calendar: Load a mailbox first."
        return
    }
    $mailbox = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $user    = Get-ControlText $txtCalGrantUser
    $level   = $cboCalLevel.SelectedItem

    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Log "Calendar: Enter a user to grant/update."
        return
    }

    try {
        $calPath  = Get-CalendarIdentity -Mailbox $mailbox
        $existing = Get-MailboxFolderPermission -Identity $calPath -User $user -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Calendar: Updating $user -> $level on $mailbox ..."
            Set-MailboxFolderPermission -Identity $calPath -User $user `
                -AccessRights $level -ErrorAction Stop | Out-Null
            Write-Log "Calendar: Permission updated."
        }
        else {
            Write-Log "Calendar: Granting $user -> $level on $mailbox ..."
            Add-MailboxFolderPermission -Identity $calPath -User $user `
                -AccessRights $level -ErrorAction Stop | Out-Null
            Write-Log "Calendar: Permission granted."
        }
        $btnRefreshCal.PerformClick()
    }
    catch {
        Write-Log "Calendar ERROR (grant): $($_.Exception.Message)"
    }
})

$btnCalRemove.Add_Click({
    if ($null -eq $script:loadedMbx) {
        Write-Log "Calendar: Load a mailbox first."
        return
    }
    $mailbox = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $user    = Get-ControlText $txtCalRemoveUser

    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Log "Calendar: Enter a user to remove."
        return
    }
    if ($user -in @('Default', 'Anonymous')) {
        Write-Log "Calendar: '$user' is a system entry - use Grant/Update to change its level instead."
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Remove calendar permission for '$user' on '$mailbox'?",
        "Confirm Remove", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    try {
        $calPath = Get-CalendarIdentity -Mailbox $mailbox
        Write-Log "Calendar: Removing permission for $user on $mailbox ..."
        Remove-MailboxFolderPermission -Identity $calPath -User $user `
            -Confirm:$false -ErrorAction Stop
        Write-Log "Calendar: Permission removed."

        $txtCalRemoveUser.Text      = $txtCalRemoveUser.Tag
        $txtCalRemoveUser.ForeColor = [System.Drawing.Color]::Gray
        $txtCalGrantUser.Text       = $txtCalGrantUser.Tag
        $txtCalGrantUser.ForeColor  = [System.Drawing.Color]::Gray
        $btnRefreshCal.PerformClick()
    }
    catch {
        Write-Log "Calendar ERROR (remove): $($_.Exception.Message)"
    }
})

# ================================================================================
# Event Handlers — Mailbox Permissions tab
# ================================================================================

# Full Access checkbox enables/disables the Auto-Map sub-option
$chkFullAccess.Add_CheckedChanged({
    $chkAutoMap.Enabled = $chkFullAccess.Checked
    if ($chkFullAccess.Checked) { $chkAutoMap.Checked = $true }
    else                        { $chkAutoMap.Checked = $false }
})

# Click a row to auto-fill the user field and reflect current permissions
$lvMbxPerms.Add_SelectedIndexChanged({
    if ($lvMbxPerms.SelectedItems.Count -eq 0) { return }
    $sel = $lvMbxPerms.SelectedItems[0]
    $txtMbxGrantUser.Text      = $sel.Text
    $txtMbxGrantUser.ForeColor = [System.Drawing.SystemColors]::WindowText
    $chkFullAccess.Checked     = ($sel.SubItems[1].Text -eq 'Yes')
    $chkSendAs.Checked         = ($sel.SubItems[2].Text -eq 'Yes')
    $chkSendOnBehalf.Checked   = ($sel.SubItems[3].Text -eq 'Yes')
    # Auto-Map defaults to checked whenever Full Access is set; actual stored
    # value can't be queried, so the admin can adjust before re-granting.
    $chkAutoMap.Checked = $true
    $chkAutoMap.Enabled = $chkFullAccess.Checked
})

# Load Mailbox — fetches permissions, forwarding, aliases, and OOO in one pass
$btnMbxLoad.Add_Click({
    $identity = Get-ControlText $txtMbxLookup
    if ([string]::IsNullOrWhiteSpace($identity)) {
        Write-Log "Mbx Perms: Enter a mailbox identity first."
        return
    }

    try {
        Write-Log "Mbx Perms: Loading $identity ..."
        $mbxObj           = Get-Mailbox -Identity $identity -ErrorAction Stop
        $script:loadedMbx = $mbxObj
        $mbxSmtp          = $mbxObj.PrimarySmtpAddress.ToString()

        $lblMbxStatus.Text      = "$($mbxObj.DisplayName)  [$($mbxObj.RecipientTypeDetails)]"
        $lblMbxStatus.ForeColor = [System.Drawing.Color]::DarkGreen

        # Permissions
        Write-Log "Mbx Perms: Loading permissions for $mbxSmtp ..."
        Invoke-LoadMbxPermissions -Mailbox $mbxSmtp -ListView $lvMbxPerms
        Write-Log "Mbx Perms: $($lvMbxPerms.Items.Count) permission entr$(if ($lvMbxPerms.Items.Count -eq 1){'y'}else{'ies'}) loaded."

        # Forwarding
        $fwdSmtp = $mbxObj.ForwardingSmtpAddress
        $fwdInt  = $mbxObj.ForwardingAddress
        if ($fwdSmtp) {
            $txtFwdTo.Text      = $fwdSmtp.ToString() -replace '^smtp:', ''
            $txtFwdTo.ForeColor = [System.Drawing.SystemColors]::WindowText
        } elseif ($fwdInt) {
            $txtFwdTo.Text      = $fwdInt.ToString()
            $txtFwdTo.ForeColor = [System.Drawing.SystemColors]::WindowText
        } else {
            $txtFwdTo.Text      = $txtFwdTo.Tag
            $txtFwdTo.ForeColor = [System.Drawing.Color]::Gray
        }
        $chkKeepCopy.Checked = $mbxObj.DeliverToMailboxAndForward

        # Aliases (on the Aliases tab)
        Invoke-LoadAliases -MbxObj $mbxObj -ListView $lvAliases
        $lblAliasCurrentMbx.Text      = "$($mbxObj.DisplayName)  ($mbxSmtp)"
        $lblAliasCurrentMbx.ForeColor = [System.Drawing.Color]::DarkGreen

        # Auto-Reply — populate the dedicated OOO tab
        $txtOOOMbx.Text             = $mbxSmtp
        $txtOOOMbx.ForeColor        = [System.Drawing.SystemColors]::WindowText
        $lblOOOCurrentMbx.Text      = "$($mbxObj.DisplayName)  ($mbxSmtp)"
        $lblOOOCurrentMbx.ForeColor = [System.Drawing.Color]::DarkGreen
        $script:loadedOOOMbx        = $mbxObj
        try {
            $ooo = Get-MailboxAutoReplyConfiguration -Identity $mbxSmtp -ErrorAction Stop
            $cboOOOState.SelectedItem = if ($ooo.AutoReplyState -eq 'Enabled') { 'Enabled' } else { 'Disabled' }
            # Strip HTML tags so plain text is shown in the text boxes
            $txtOOOInternal.Text = [System.Text.RegularExpressions.Regex]::Replace(
                [string]$ooo.InternalMessage, '<[^>]+>', '')
            $txtOOOExternal.Text = [System.Text.RegularExpressions.Regex]::Replace(
                [string]$ooo.ExternalMessage,  '<[^>]+>', '')
        } catch {
            Write-Log "Mbx Perms: OOO settings unavailable: $($_.Exception.Message)"
        }

        # Calendar permissions (auto-refresh)
        $btnRefreshCal.PerformClick()

        Write-Log "Mbx Perms: Mailbox loaded successfully."
    }
    catch {
        $script:loadedMbx             = $null
        $lblMbxStatus.Text            = "Not found"
        $lblMbxStatus.ForeColor       = [System.Drawing.Color]::Red
        $lblOOOCurrentMbx.Text        = ""
        $lblOOOCurrentMbx.ForeColor   = [System.Drawing.Color]::DimGray
        $lblAliasCurrentMbx.Text      = "No mailbox loaded — load one from the Mailbox Permissions tab."
        $lblAliasCurrentMbx.ForeColor = [System.Drawing.Color]::DimGray
        $script:loadedOOOMbx          = $null
        Write-Log "Mbx Perms ERROR (load): $($_.Exception.Message)"
    }
})

# Grant — adds each checked permission for the user
$btnMbxGrant.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Mbx Perms: Load a mailbox first."; return }
    $mbx  = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $user = Get-ControlText $txtMbxGrantUser

    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Log "Mbx Perms: Enter a User to grant permissions to."
        return
    }
    if (-not $chkFullAccess.Checked -and -not $chkSendAs.Checked -and -not $chkSendOnBehalf.Checked) {
        Write-Log "Mbx Perms: Select at least one permission to grant."
        return
    }

    if ($chkFullAccess.Checked) {
        try {
            # Remove first (handles AutoMapping change gracefully); ignore error if not present
            Remove-MailboxPermission -Identity $mbx -User $user -AccessRights FullAccess `
                -InheritanceType All -Confirm:$false -ErrorAction SilentlyContinue
            Add-MailboxPermission -Identity $mbx -User $user -AccessRights FullAccess `
                -InheritanceType All -AutoMapping $chkAutoMap.Checked -ErrorAction Stop | Out-Null
            Write-Log "Mbx Perms: Full Access granted to $user on $mbx (AutoMap=$($chkAutoMap.Checked))."
        } catch {
            Write-Log "Mbx Perms ERROR (Full Access grant): $($_.Exception.Message)"
        }
    }

    if ($chkSendAs.Checked) {
        try {
            Add-RecipientPermission -Identity $mbx -Trustee $user -AccessRights SendAs `
                -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Log "Mbx Perms: Send As granted to $user on $mbx."
        } catch {
            Write-Log "Mbx Perms ERROR (Send As grant): $($_.Exception.Message)"
        }
    }

    if ($chkSendOnBehalf.Checked) {
        try {
            Set-Mailbox -Identity $mbx -GrantSendOnBehalfTo @{Add=$user} -ErrorAction Stop
            Write-Log "Mbx Perms: Send on Behalf granted to $user on $mbx."
        } catch {
            Write-Log "Mbx Perms ERROR (Send on Behalf grant): $($_.Exception.Message)"
        }
    }

    Invoke-LoadMbxPermissions -Mailbox $mbx -ListView $lvMbxPerms
})

# Revoke — removes each checked permission for the user
$btnMbxRevoke.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Mbx Perms: Load a mailbox first."; return }
    $mbx  = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $user = Get-ControlText $txtMbxGrantUser

    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Log "Mbx Perms: Enter a User to revoke permissions from."
        return
    }
    if (-not $chkFullAccess.Checked -and -not $chkSendAs.Checked -and -not $chkSendOnBehalf.Checked) {
        Write-Log "Mbx Perms: Select which permissions to revoke."
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Revoke selected permissions for '$user' on '$mbx'?",
        "Confirm Revoke", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    if ($chkFullAccess.Checked) {
        try {
            Remove-MailboxPermission -Identity $mbx -User $user -AccessRights FullAccess `
                -InheritanceType All -Confirm:$false -ErrorAction Stop
            Write-Log "Mbx Perms: Full Access revoked from $user on $mbx."
        } catch {
            Write-Log "Mbx Perms ERROR (Full Access revoke): $($_.Exception.Message)"
        }
    }

    if ($chkSendAs.Checked) {
        try {
            Remove-RecipientPermission -Identity $mbx -Trustee $user -AccessRights SendAs `
                -Confirm:$false -ErrorAction Stop
            Write-Log "Mbx Perms: Send As revoked from $user on $mbx."
        } catch {
            Write-Log "Mbx Perms ERROR (Send As revoke): $($_.Exception.Message)"
        }
    }

    if ($chkSendOnBehalf.Checked) {
        try {
            Set-Mailbox -Identity $mbx -GrantSendOnBehalfTo @{Remove=$user} -ErrorAction Stop
            Write-Log "Mbx Perms: Send on Behalf revoked from $user on $mbx."
        } catch {
            Write-Log "Mbx Perms ERROR (Send on Behalf revoke): $($_.Exception.Message)"
        }
    }

    Invoke-LoadMbxPermissions -Mailbox $mbx -ListView $lvMbxPerms
})

# Set Forwarding
$btnSetFwd.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Mbx Perms: Load a mailbox first."; return }
    $mbx     = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $fwdAddr = Get-ControlText $txtFwdTo

    if ([string]::IsNullOrWhiteSpace($fwdAddr)) {
        Write-Log "Mbx Perms: Enter a forwarding address."
        return
    }

    try {
        Set-Mailbox -Identity $mbx -ForwardingSmtpAddress "smtp:$fwdAddr" `
            -DeliverToMailboxAndForward $chkKeepCopy.Checked -ErrorAction Stop
        Write-Log "Mbx Perms: Forwarding -> $fwdAddr set on $mbx (KeepCopy=$($chkKeepCopy.Checked))."
    } catch {
        Write-Log "Mbx Perms ERROR (set forwarding): $($_.Exception.Message)"
    }
})

# Clear Forwarding
$btnClearFwd.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Mbx Perms: Load a mailbox first."; return }
    $mbx = $script:loadedMbx.PrimarySmtpAddress.ToString()

    try {
        Set-Mailbox -Identity $mbx -ForwardingSmtpAddress $null `
            -ForwardingAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
        $txtFwdTo.Text      = $txtFwdTo.Tag
        $txtFwdTo.ForeColor = [System.Drawing.Color]::Gray
        $chkKeepCopy.Checked = $false
        Write-Log "Mbx Perms: Forwarding cleared on $mbx."
    } catch {
        Write-Log "Mbx Perms ERROR (clear forwarding): $($_.Exception.Message)"
    }
})

# Load mailbox directly from Auto-Reply tab
$btnOOOLoad.Add_Click({
    $identity = Get-ControlText $txtOOOMbx
    if ([string]::IsNullOrWhiteSpace($identity)) { Write-Log "Auto-Reply: Enter a mailbox identity first."; return }
    try {
        $mbxObj  = Get-Mailbox -Identity $identity -ErrorAction Stop
        $mbxSmtp = $mbxObj.PrimarySmtpAddress.ToString()
        $lblOOOCurrentMbx.Text      = "$($mbxObj.DisplayName)  ($mbxSmtp)"
        $lblOOOCurrentMbx.ForeColor = [System.Drawing.Color]::DarkGreen
        $script:loadedOOOMbx        = $mbxObj
        $ooo = Get-MailboxAutoReplyConfiguration -Identity $mbxSmtp -ErrorAction Stop
        $cboOOOState.SelectedItem = if ($ooo.AutoReplyState -eq 'Enabled') { 'Enabled' } else { 'Disabled' }
        $txtOOOInternal.Text = [System.Text.RegularExpressions.Regex]::Replace([string]$ooo.InternalMessage, '<[^>]+>', '')
        $txtOOOExternal.Text = [System.Text.RegularExpressions.Regex]::Replace([string]$ooo.ExternalMessage,  '<[^>]+>', '')
        Write-Log "Auto-Reply: Loaded $mbxSmtp."
    }
    catch {
        $lblOOOCurrentMbx.Text      = "Not found"
        $lblOOOCurrentMbx.ForeColor = [System.Drawing.Color]::Red
        $script:loadedOOOMbx        = $null
        Write-Log "Auto-Reply ERROR (load): $($_.Exception.Message)"
    }
})

# Apply Auto-Reply settings
$btnSetOOO.Add_Click({
    $oooMbx = if ($script:loadedOOOMbx) { $script:loadedOOOMbx } else { $script:loadedMbx }
    if ($null -eq $oooMbx) { Write-Log "Auto-Reply: Load a mailbox first."; return }
    $mbx   = $oooMbx.PrimarySmtpAddress.ToString()
    $state = $cboOOOState.SelectedItem

    try {
        $params = @{
            Identity       = $mbx
            AutoReplyState = $state
            ErrorAction    = 'Stop'
        }
        if ($state -eq 'Enabled') {
            $params.InternalMessage  = $txtOOOInternal.Text
            $params.ExternalMessage  = $txtOOOExternal.Text
            $params.ExternalAudience = 'All'
        }
        Set-MailboxAutoReplyConfiguration @params
        Write-Log "Mbx Perms: Auto-reply set to '$state' on $mbx."
    } catch {
        Write-Log "Mbx Perms ERROR (auto-reply): $($_.Exception.Message)"
    }
})


# ================================================================================
# Launch
# ================================================================================

# ================================================================================
# TAB 5 — Email Investigation (outer tab with inner sub-tabs)
# ================================================================================

$tabEmailInv      = New-Object System.Windows.Forms.TabPage
$tabEmailInv.Text = "Email Investigation"

$subEmailTabs               = New-Object System.Windows.Forms.TabControl
$subEmailTabs.Location      = New-Object System.Drawing.Point(0, 0)
$subEmailTabs.Size          = New-Object System.Drawing.Size(932, 790)
$subEmailTabs.Font          = $font
$tabEmailInv.Controls.Add($subEmailTabs)

# ================================================================================
# TAB 5a — Email Investigation > Compliance Search (sub-tab)
# ================================================================================

$tabCompliance      = New-Object System.Windows.Forms.TabPage
$tabCompliance.Text = "Compliance Search"

# ── Search Criteria GroupBox ─────────────────────────────────────────────────────
$grpCriteria          = New-Object System.Windows.Forms.GroupBox
$grpCriteria.Text     = "Search Criteria"
$grpCriteria.Location = New-Object System.Drawing.Point(10, 10)
$grpCriteria.Size     = New-Object System.Drawing.Size(900, 220)
$grpCriteria.Font     = $fontBold
$tabCompliance.Controls.Add($grpCriteria)

$lblFrom          = New-Object System.Windows.Forms.Label
$lblFrom.Text     = "From Address:"
$lblFrom.Location = New-Object System.Drawing.Point(15, 30)
$lblFrom.Size     = New-Object System.Drawing.Size(110, 20)
$lblFrom.Font     = $font
$grpCriteria.Controls.Add($lblFrom)

$txtFrom          = New-Object System.Windows.Forms.TextBox
$txtFrom.Location = New-Object System.Drawing.Point(130, 28)
$txtFrom.Size     = New-Object System.Drawing.Size(280, 23)
$txtFrom.Font     = $font
$grpCriteria.Controls.Add($txtFrom)

$lblSubject          = New-Object System.Windows.Forms.Label
$lblSubject.Text     = "Subject Contains:"
$lblSubject.Location = New-Object System.Drawing.Point(440, 30)
$lblSubject.Size     = New-Object System.Drawing.Size(115, 20)
$lblSubject.Font     = $font
$grpCriteria.Controls.Add($lblSubject)

$txtSubject          = New-Object System.Windows.Forms.TextBox
$txtSubject.Location = New-Object System.Drawing.Point(560, 28)
$txtSubject.Size     = New-Object System.Drawing.Size(300, 23)
$txtSubject.Font     = $font
$grpCriteria.Controls.Add($txtSubject)

$lblRecipient          = New-Object System.Windows.Forms.Label
$lblRecipient.Text     = "Recipient (optional):"
$lblRecipient.Location = New-Object System.Drawing.Point(15, 65)
$lblRecipient.Size     = New-Object System.Drawing.Size(115, 20)
$lblRecipient.Font     = $font
$grpCriteria.Controls.Add($lblRecipient)

$txtRecipient          = New-Object System.Windows.Forms.TextBox
$txtRecipient.Location = New-Object System.Drawing.Point(130, 63)
$txtRecipient.Size     = New-Object System.Drawing.Size(280, 23)
$txtRecipient.Font     = $font
$grpCriteria.Controls.Add($txtRecipient)

$lblScope          = New-Object System.Windows.Forms.Label
$lblScope.Text     = "Scope:"
$lblScope.Location = New-Object System.Drawing.Point(440, 65)
$lblScope.Size     = New-Object System.Drawing.Size(50, 20)
$lblScope.Font     = $font
$grpCriteria.Controls.Add($lblScope)

$cmbScope              = New-Object System.Windows.Forms.ComboBox
$cmbScope.Location     = New-Object System.Drawing.Point(560, 63)
$cmbScope.Size         = New-Object System.Drawing.Size(180, 23)
$cmbScope.Font         = $font
$cmbScope.DropDownStyle = 'DropDownList'
[void]$cmbScope.Items.Add("All Mailboxes")
[void]$cmbScope.Items.Add("Specific Mailbox")
$cmbScope.SelectedIndex = 0
$grpCriteria.Controls.Add($cmbScope)

$lblMailbox          = New-Object System.Windows.Forms.Label
$lblMailbox.Text     = "Mailbox:"
$lblMailbox.Location = New-Object System.Drawing.Point(15, 100)
$lblMailbox.Size     = New-Object System.Drawing.Size(110, 20)
$lblMailbox.Font     = $font
$grpCriteria.Controls.Add($lblMailbox)

$txtMailbox          = New-Object System.Windows.Forms.TextBox
$txtMailbox.Location = New-Object System.Drawing.Point(130, 98)
$txtMailbox.Size     = New-Object System.Drawing.Size(280, 23)
$txtMailbox.Font     = $font
$txtMailbox.Enabled  = $false
$grpCriteria.Controls.Add($txtMailbox)

$lblStart          = New-Object System.Windows.Forms.Label
$lblStart.Text     = "Received Start:"
$lblStart.Location = New-Object System.Drawing.Point(440, 100)
$lblStart.Size     = New-Object System.Drawing.Size(100, 20)
$lblStart.Font     = $font
$grpCriteria.Controls.Add($lblStart)

$dtpStart          = New-Object System.Windows.Forms.DateTimePicker
$dtpStart.Location = New-Object System.Drawing.Point(560, 98)
$dtpStart.Size     = New-Object System.Drawing.Size(180, 23)
$dtpStart.Font     = $font
$dtpStart.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpStart.Value    = (Get-Date).Date.AddDays(-3)
$dtpStart.Checked  = $true
$dtpStart.ShowCheckBox = $true
$grpCriteria.Controls.Add($dtpStart)

$lblEnd          = New-Object System.Windows.Forms.Label
$lblEnd.Text     = "Received End:"
$lblEnd.Location = New-Object System.Drawing.Point(440, 135)
$lblEnd.Size     = New-Object System.Drawing.Size(100, 20)
$lblEnd.Font     = $font
$grpCriteria.Controls.Add($lblEnd)

$dtpEnd          = New-Object System.Windows.Forms.DateTimePicker
$dtpEnd.Location = New-Object System.Drawing.Point(560, 133)
$dtpEnd.Size     = New-Object System.Drawing.Size(180, 23)
$dtpEnd.Font     = $font
$dtpEnd.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpEnd.Value    = (Get-Date).Date
$dtpEnd.Checked  = $true
$dtpEnd.ShowCheckBox = $true
$grpCriteria.Controls.Add($dtpEnd)

$btnRunSearch          = New-Object System.Windows.Forms.Button
$btnRunSearch.Text     = "Run Search"
$btnRunSearch.Location = New-Object System.Drawing.Point(130, 170)
$btnRunSearch.Size     = New-Object System.Drawing.Size(140, 30)
$btnRunSearch.Font     = $font
$grpCriteria.Controls.Add($btnRunSearch)

$btnPurge          = New-Object System.Windows.Forms.Button
$btnPurge.Text     = "Soft Delete Purge"
$btnPurge.Location = New-Object System.Drawing.Point(285, 170)
$btnPurge.Size     = New-Object System.Drawing.Size(160, 30)
$btnPurge.Font     = $font
$grpCriteria.Controls.Add($btnPurge)

$btnClearSpam          = New-Object System.Windows.Forms.Button
$btnClearSpam.Text     = "Clear Fields"
$btnClearSpam.Location = New-Object System.Drawing.Point(460, 170)
$btnClearSpam.Size     = New-Object System.Drawing.Size(120, 30)
$btnClearSpam.Font     = $font
$grpCriteria.Controls.Add($btnClearSpam)

# ── Last Search Result GroupBox ──────────────────────────────────────────────────
$grpResults          = New-Object System.Windows.Forms.GroupBox
$grpResults.Text     = "Last Search Result"
$grpResults.Location = New-Object System.Drawing.Point(10, 240)
$grpResults.Size     = New-Object System.Drawing.Size(900, 90)
$grpResults.Font     = $fontBold
$tabCompliance.Controls.Add($grpResults)

$lblSearchName          = New-Object System.Windows.Forms.Label
$lblSearchName.Text     = "Search Name:"
$lblSearchName.Location = New-Object System.Drawing.Point(15, 30)
$lblSearchName.Size     = New-Object System.Drawing.Size(90, 20)
$lblSearchName.Font     = $font
$grpResults.Controls.Add($lblSearchName)

$txtSearchName          = New-Object System.Windows.Forms.TextBox
$txtSearchName.Location = New-Object System.Drawing.Point(110, 28)
$txtSearchName.Size     = New-Object System.Drawing.Size(560, 23)
$txtSearchName.Font     = $font
$txtSearchName.ReadOnly = $true
$grpResults.Controls.Add($txtSearchName)

$lblItemCount          = New-Object System.Windows.Forms.Label
$lblItemCount.Text     = "Item Count:"
$lblItemCount.Location = New-Object System.Drawing.Point(15, 58)
$lblItemCount.Size     = New-Object System.Drawing.Size(90, 20)
$lblItemCount.Font     = $font
$grpResults.Controls.Add($lblItemCount)

$txtItemCount          = New-Object System.Windows.Forms.TextBox
$txtItemCount.Location = New-Object System.Drawing.Point(110, 56)
$txtItemCount.Size     = New-Object System.Drawing.Size(120, 23)
$txtItemCount.Font     = $font
$txtItemCount.ReadOnly = $true
$grpResults.Controls.Add($txtItemCount)

# ================================================================================
# TAB 5b — Email Investigation > Message Trace (sub-tab)
# ================================================================================

$tabTrace      = New-Object System.Windows.Forms.TabPage
$tabTrace.Text = "Message Trace"

$lblMfSender          = New-Object System.Windows.Forms.Label
$lblMfSender.Text     = "Sender:"
$lblMfSender.Location = New-Object System.Drawing.Point(15, 18)
$lblMfSender.Size     = New-Object System.Drawing.Size(65, 20)
$lblMfSender.Font     = $font
$tabTrace.Controls.Add($lblMfSender)

$txtMfSender          = New-Object System.Windows.Forms.TextBox
$txtMfSender.Location = New-Object System.Drawing.Point(85, 16)
$txtMfSender.Size     = New-Object System.Drawing.Size(200, 23)
$txtMfSender.Font     = $font
$tabTrace.Controls.Add($txtMfSender)

$lblMfRecipient          = New-Object System.Windows.Forms.Label
$lblMfRecipient.Text     = "Recipient:"
$lblMfRecipient.Location = New-Object System.Drawing.Point(300, 18)
$lblMfRecipient.Size     = New-Object System.Drawing.Size(70, 20)
$lblMfRecipient.Font     = $font
$tabTrace.Controls.Add($lblMfRecipient)

$txtMfRecipient          = New-Object System.Windows.Forms.TextBox
$txtMfRecipient.Location = New-Object System.Drawing.Point(375, 16)
$txtMfRecipient.Size     = New-Object System.Drawing.Size(200, 23)
$txtMfRecipient.Font     = $font
$tabTrace.Controls.Add($txtMfRecipient)

$lblMfSubject          = New-Object System.Windows.Forms.Label
$lblMfSubject.Text     = "Subject contains:"
$lblMfSubject.Location = New-Object System.Drawing.Point(590, 18)
$lblMfSubject.Size     = New-Object System.Drawing.Size(105, 20)
$lblMfSubject.Font     = $font
$tabTrace.Controls.Add($lblMfSubject)

$txtMfSubject          = New-Object System.Windows.Forms.TextBox
$txtMfSubject.Location = New-Object System.Drawing.Point(695, 16)
$txtMfSubject.Size     = New-Object System.Drawing.Size(180, 23)
$txtMfSubject.Font     = $font
$tabTrace.Controls.Add($txtMfSubject)

$lblMfStart          = New-Object System.Windows.Forms.Label
$lblMfStart.Text     = "Start:"
$lblMfStart.Location = New-Object System.Drawing.Point(15, 53)
$lblMfStart.Size     = New-Object System.Drawing.Size(65, 20)
$lblMfStart.Font     = $font
$tabTrace.Controls.Add($lblMfStart)

$dtpMfStart          = New-Object System.Windows.Forms.DateTimePicker
$dtpMfStart.Location = New-Object System.Drawing.Point(85, 51)
$dtpMfStart.Size     = New-Object System.Drawing.Size(150, 23)
$dtpMfStart.Font     = $font
$dtpMfStart.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpMfStart.Value    = (Get-Date).AddDays(-2)
$tabTrace.Controls.Add($dtpMfStart)

$lblMfEnd          = New-Object System.Windows.Forms.Label
$lblMfEnd.Text     = "End:"
$lblMfEnd.Location = New-Object System.Drawing.Point(300, 53)
$lblMfEnd.Size     = New-Object System.Drawing.Size(70, 20)
$lblMfEnd.Font     = $font
$tabTrace.Controls.Add($lblMfEnd)

$dtpMfEnd          = New-Object System.Windows.Forms.DateTimePicker
$dtpMfEnd.Location = New-Object System.Drawing.Point(375, 51)
$dtpMfEnd.Size     = New-Object System.Drawing.Size(150, 23)
$dtpMfEnd.Font     = $font
$dtpMfEnd.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpMfEnd.Value    = (Get-Date)
$tabTrace.Controls.Add($dtpMfEnd)

$lblMfStatusFilter          = New-Object System.Windows.Forms.Label
$lblMfStatusFilter.Text     = "Status:"
$lblMfStatusFilter.Location = New-Object System.Drawing.Point(590, 53)
$lblMfStatusFilter.Size     = New-Object System.Drawing.Size(65, 20)
$lblMfStatusFilter.Font     = $font
$tabTrace.Controls.Add($lblMfStatusFilter)

$cmbMfStatus               = New-Object System.Windows.Forms.ComboBox
$cmbMfStatus.Location      = New-Object System.Drawing.Point(655, 49)
$cmbMfStatus.Size          = New-Object System.Drawing.Size(150, 23)
$cmbMfStatus.Font          = $font
$cmbMfStatus.DropDownStyle = 'DropDownList'
@('(Any)','Delivered','Failed','FilteredAsSpam','Quarantined','Pending','Expanded') |
    ForEach-Object { [void]$cmbMfStatus.Items.Add($_) }
$cmbMfStatus.SelectedIndex = 0
$tabTrace.Controls.Add($cmbMfStatus)

$btnMfSearch          = New-Object System.Windows.Forms.Button
$btnMfSearch.Text     = "Search Mail Flow"
$btnMfSearch.Location = New-Object System.Drawing.Point(695, 85)
$btnMfSearch.Size     = New-Object System.Drawing.Size(180, 28)
$btnMfSearch.Font     = $font
$tabTrace.Controls.Add($btnMfSearch)


$lblMfResultsHdr          = New-Object System.Windows.Forms.Label
$lblMfResultsHdr.Text     = "Results:"
$lblMfResultsHdr.Location = New-Object System.Drawing.Point(15, 118)
$lblMfResultsHdr.Size     = New-Object System.Drawing.Size(100, 18)
$lblMfResultsHdr.Font     = $fontBold
$tabTrace.Controls.Add($lblMfResultsHdr)

$lvMfResults               = New-Object System.Windows.Forms.ListView
$lvMfResults.Location      = New-Object System.Drawing.Point(15, 138)
$lvMfResults.Size          = New-Object System.Drawing.Size(870, 150)
$lvMfResults.View          = "Details"
$lvMfResults.FullRowSelect = $true
$lvMfResults.GridLines     = $true
$lvMfResults.Font          = $font
[void]$lvMfResults.Columns.Add("Received",  130)
[void]$lvMfResults.Columns.Add("Sender",    190)
[void]$lvMfResults.Columns.Add("Recipient", 190)
[void]$lvMfResults.Columns.Add("Subject",   230)
[void]$lvMfResults.Columns.Add("Status",    100)
$tabTrace.Controls.Add($lvMfResults)

$btnMfDetails          = New-Object System.Windows.Forms.Button
$btnMfDetails.Text     = "View Transport Detail"
$btnMfDetails.Location = New-Object System.Drawing.Point(15, 296)
$btnMfDetails.Size     = New-Object System.Drawing.Size(190, 28)
$btnMfDetails.Font     = $font
$tabTrace.Controls.Add($btnMfDetails)

$btnMfMailboxActivity          = New-Object System.Windows.Forms.Button
$btnMfMailboxActivity.Text     = "Check Mailbox Activity"
$btnMfMailboxActivity.Location = New-Object System.Drawing.Point(215, 296)
$btnMfMailboxActivity.Size     = New-Object System.Drawing.Size(190, 28)
$btnMfMailboxActivity.Font     = $font
$tabTrace.Controls.Add($btnMfMailboxActivity)

$btnMfInboxRules          = New-Object System.Windows.Forms.Button
$btnMfInboxRules.Text     = "Show Inbox Rules"
$btnMfInboxRules.Location = New-Object System.Drawing.Point(415, 296)
$btnMfInboxRules.Size     = New-Object System.Drawing.Size(170, 28)
$btnMfInboxRules.Font     = $font
$tabTrace.Controls.Add($btnMfInboxRules)

$lblMfDetailHdr          = New-Object System.Windows.Forms.Label
$lblMfDetailHdr.Text     = "Transport Detail (selected message):"
$lblMfDetailHdr.Location = New-Object System.Drawing.Point(15, 332)
$lblMfDetailHdr.Size     = New-Object System.Drawing.Size(300, 18)
$lblMfDetailHdr.Font     = $fontBold
$tabTrace.Controls.Add($lblMfDetailHdr)

$lvMfDetail               = New-Object System.Windows.Forms.ListView
$lvMfDetail.Location      = New-Object System.Drawing.Point(15, 352)
$lvMfDetail.Size          = New-Object System.Drawing.Size(870, 80)
$lvMfDetail.View          = "Details"
$lvMfDetail.FullRowSelect = $true
$lvMfDetail.GridLines     = $true
$lvMfDetail.Font          = $font
[void]$lvMfDetail.Columns.Add("Time",   130)
[void]$lvMfDetail.Columns.Add("Event",  110)
[void]$lvMfDetail.Columns.Add("Detail", 610)
$tabTrace.Controls.Add($lvMfDetail)

$lblMfActivityHdr           = New-Object System.Windows.Forms.Label
$lblMfActivityHdr.Text      = "Mailbox Activity - best-effort match by recipient + subject + time window after delivery. Audit log can take up to an hour to populate."
$lblMfActivityHdr.Location  = New-Object System.Drawing.Point(15, 436)
$lblMfActivityHdr.Size      = New-Object System.Drawing.Size(870, 16)
$lblMfActivityHdr.Font      = $fontItalicSmall
$lblMfActivityHdr.ForeColor = [System.Drawing.Color]::DimGray
$tabTrace.Controls.Add($lblMfActivityHdr)

$lvMfActivity               = New-Object System.Windows.Forms.ListView
$lvMfActivity.Location      = New-Object System.Drawing.Point(15, 454)
$lvMfActivity.Size          = New-Object System.Drawing.Size(870, 80)
$lvMfActivity.View          = "Details"
$lvMfActivity.FullRowSelect = $true
$lvMfActivity.GridLines     = $true
$lvMfActivity.Font          = $font
[void]$lvMfActivity.Columns.Add("Time",      130)
[void]$lvMfActivity.Columns.Add("Operation", 110)
[void]$lvMfActivity.Columns.Add("Folder",    180)
[void]$lvMfActivity.Columns.Add("Details",   430)
$tabTrace.Controls.Add($lvMfActivity)

$lblMfRulesHdr          = New-Object System.Windows.Forms.Label
$lblMfRulesHdr.Text     = "Recipient's Current Inbox Rules:"
$lblMfRulesHdr.Location = New-Object System.Drawing.Point(15, 538)
$lblMfRulesHdr.Size     = New-Object System.Drawing.Size(300, 18)
$lblMfRulesHdr.Font     = $fontBold
$tabTrace.Controls.Add($lblMfRulesHdr)

$lvMfRules               = New-Object System.Windows.Forms.ListView
$lvMfRules.Location      = New-Object System.Drawing.Point(15, 558)
$lvMfRules.Size          = New-Object System.Drawing.Size(870, 100)
$lvMfRules.View          = "Details"
$lvMfRules.FullRowSelect = $true
$lvMfRules.GridLines     = $true
$lvMfRules.Font          = $font
[void]$lvMfRules.Columns.Add("Name",       160)
[void]$lvMfRules.Columns.Add("Enabled",     60)
[void]$lvMfRules.Columns.Add("Priority",    55)
[void]$lvMfRules.Columns.Add("Conditions", 290)
[void]$lvMfRules.Columns.Add("Actions",    290)
$tabTrace.Controls.Add($lvMfRules)

# ── Wire sub-tabs into the Email Investigation tab ───────────────────────────────
[void]$subEmailTabs.TabPages.Add($tabCompliance)
[void]$subEmailTabs.TabPages.Add($tabTrace)

# ================================================================================
# Event Handlers — Spam Cleanup tab
# ================================================================================

$cmbScope.Add_SelectedIndexChanged({
    $txtMailbox.Enabled = ($cmbScope.SelectedItem -eq "Specific Mailbox")
    if (-not $txtMailbox.Enabled) { $txtMailbox.Text = "" }
})

$btnConnectEXO.Add_Click({
    try {
        Write-Status "Connecting to Exchange Online..."
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        $script:ExoConnected = $true
        Write-Status "Connected to Exchange Online."
    }
    catch {
        $script:ExoConnected = $false
        Write-Status "EXO connection error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "EXO Connection Error", "OK", "Error") | Out-Null
    }
    finally { Update-ConnectionLabels }
})

$btnConnectIPPS.Add_Click({
    try {
        Write-Status "Disconnecting existing compliance sessions..."
        Disconnect-ComplianceSessions
        Write-Status "Connecting to IPPS (SearchOnly)..."
        Connect-IPPSSession -EnableSearchOnlySession -ErrorAction Stop | Out-Null
        $script:IppsConnected = $true
        $script:IppsMode      = "SearchOnly"
        Write-Status "Connected to IPPS (SearchOnly)."
    }
    catch {
        $script:IppsConnected = $false
        $script:IppsMode      = "Not Connected"
        Write-Status "IPPS connection error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "IPPS Connection Error", "OK", "Error") | Out-Null
    }
    finally { Update-ConnectionLabels }
})

$btnDisconnectAll.Add_Click({
    Disconnect-ComplianceSessions
    $script:ExoConnected  = $false
    $script:IppsConnected = $false
    $script:IppsMode      = "Not Connected"
    Write-Status "Disconnected all sessions."
    Update-ConnectionLabels
})

$btnRunSearch.Add_Click({ Run-ComplianceSearch })

$btnPurge.Add_Click({ Run-CompliancePurge })

$btnClearSpam.Add_Click({
    $txtFrom.Text      = ""
    $txtSubject.Text   = ""
    $txtRecipient.Text = ""
    $cmbScope.SelectedIndex = 0
    $txtMailbox.Text   = ""
    $dtpStart.Value    = (Get-Date).Date.AddDays(-3)
    $dtpStart.Checked  = $true
    $dtpEnd.Value      = (Get-Date).Date
    $dtpEnd.Checked    = $true
    $txtSearchName.Text = ""
    $txtItemCount.Text  = ""
    $script:LastSearchName  = $null
    $script:LastSearchItems = 0
    Write-Status "Fields cleared."
})

# ================================================================================
# Event Handlers — Mail Flow tab
# ================================================================================

$lvMfResults.Add_SelectedIndexChanged({
    $lvMfDetail.Items.Clear()
    $lvMfActivity.Items.Clear()
    $lvMfRules.Items.Clear()
})

$btnMfSearch.Add_Click({
    if (-not (Test-ExoReady)) { return }
    try   { Write-Status "Mail Flow: searching..."; Invoke-MessageTraceSearch }
    catch { Write-Status "Mail Flow search error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Mail Flow Search Error", "OK", "Error") | Out-Null }
})

$btnMfDetails.Add_Click({
    if (-not (Test-ExoReady)) { return }
    if ($lvMfResults.SelectedItems.Count -eq 0) { Write-Status "Mail Flow: select a message first."; return }
    try   { Invoke-MessageTraceDetailLookup -SelectedTag $lvMfResults.SelectedItems[0].Tag }
    catch { Write-Status "Mail Flow detail error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Transport Detail Error", "OK", "Error") | Out-Null }
})

$btnMfMailboxActivity.Add_Click({
    if (-not (Test-ExoReady)) { return }
    if ($lvMfResults.SelectedItems.Count -eq 0) { Write-Status "Mail Flow: select a message first."; return }
    try   { Invoke-MailboxActivityLookup -SelectedTag $lvMfResults.SelectedItems[0].Tag }
    catch { Write-Status "Mail Flow mailbox activity error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Mailbox Activity Error", "OK", "Error") | Out-Null }
})

$btnMfInboxRules.Add_Click({
    if (-not (Test-ExoReady)) { return }
    if ($lvMfResults.SelectedItems.Count -eq 0) { Write-Status "Mail Flow: select a message first."; return }
    try   { Invoke-InboxRulesLookup -SelectedTag $lvMfResults.SelectedItems[0].Tag }
    catch { Write-Status "Mail Flow inbox rules error: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Inbox Rules Error", "OK", "Error") | Out-Null }
})

# ================================================================================
# TAB 6 — Alias Search
# ================================================================================

$tabAliasSearch      = New-Object System.Windows.Forms.TabPage
$tabAliasSearch.Text = "Aliases"

$lblAliasSearch           = New-Object System.Windows.Forms.Label
$lblAliasSearch.Text      = "Search:"
$lblAliasSearch.Location  = New-Object System.Drawing.Point(20, 18)
$lblAliasSearch.AutoSize  = $true
$lblAliasSearch.Font      = $font
$tabAliasSearch.Controls.Add($lblAliasSearch)

$txtAliasSearch           = New-Object System.Windows.Forms.TextBox
$txtAliasSearch.Location  = New-Object System.Drawing.Point(72, 16)
$txtAliasSearch.Size      = New-Object System.Drawing.Size(360, 25)
$txtAliasSearch.Font      = $font
Add-PlaceholderBehavior $txtAliasSearch "alias, partial email, or full address"
$tabAliasSearch.Controls.Add($txtAliasSearch)

$chkAliasPartial           = New-Object System.Windows.Forms.CheckBox
$chkAliasPartial.Text      = "Partial match"
$chkAliasPartial.Location  = New-Object System.Drawing.Point(448, 17)
$chkAliasPartial.AutoSize  = $true
$chkAliasPartial.Checked   = $true
$chkAliasPartial.Font      = $font
$tabAliasSearch.Controls.Add($chkAliasPartial)

$btnAliasSearch           = New-Object System.Windows.Forms.Button
$btnAliasSearch.Text      = "Search"
$btnAliasSearch.Location  = New-Object System.Drawing.Point(560, 14)
$btnAliasSearch.Size      = New-Object System.Drawing.Size(100, 28)
$btnAliasSearch.Font      = $font
$tabAliasSearch.Controls.Add($btnAliasSearch)

$lblAliasHint           = New-Object System.Windows.Forms.Label
$lblAliasHint.Text      = "Searches across all mailboxes, shared mailboxes, distribution groups, and mail users. Double-click a row to load that mailbox."
$lblAliasHint.Location  = New-Object System.Drawing.Point(20, 50)
$lblAliasHint.Size      = New-Object System.Drawing.Size(880, 18)
$lblAliasHint.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblAliasHint.ForeColor = [System.Drawing.Color]::DimGray
$tabAliasSearch.Controls.Add($lblAliasHint)

$lvAliasResults               = New-Object System.Windows.Forms.ListView
$lvAliasResults.Location      = New-Object System.Drawing.Point(20, 74)
$lvAliasResults.Size          = New-Object System.Drawing.Size(892, 256)
$lvAliasResults.View          = "Details"
$lvAliasResults.FullRowSelect = $true
$lvAliasResults.GridLines     = $true
$lvAliasResults.Font          = $font
[void]$lvAliasResults.Columns.Add("Display Name",    240)
[void]$lvAliasResults.Columns.Add("Primary SMTP",    280)
[void]$lvAliasResults.Columns.Add("Type",            160)
[void]$lvAliasResults.Columns.Add("Matched Address", 200)
$tabAliasSearch.Controls.Add($lvAliasResults)

# ── Manage Aliases GroupBox ───────────────────────────────────────────────────────
$grpAliases          = New-Object System.Windows.Forms.GroupBox
$grpAliases.Text     = "Manage Aliases"
$grpAliases.Location = New-Object System.Drawing.Point(20, 344)
$grpAliases.Size     = New-Object System.Drawing.Size(892, 412)
$grpAliases.Font     = $fontBold
$tabAliasSearch.Controls.Add($grpAliases)

$lblAliasCurrentMbx           = New-Object System.Windows.Forms.Label
$lblAliasCurrentMbx.Text      = "No mailbox loaded — load one from the Mailbox Permissions tab."
$lblAliasCurrentMbx.Location  = New-Object System.Drawing.Point(10, 22)
$lblAliasCurrentMbx.AutoSize  = $true
$lblAliasCurrentMbx.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblAliasCurrentMbx.ForeColor = [System.Drawing.Color]::DimGray
$grpAliases.Controls.Add($lblAliasCurrentMbx)

$lvAliases               = New-Object System.Windows.Forms.ListView
$lvAliases.Location      = New-Object System.Drawing.Point(10, 44)
$lvAliases.Size          = New-Object System.Drawing.Size(870, 284)
$lvAliases.View          = "Details"
$lvAliases.FullRowSelect = $true
$lvAliases.GridLines     = $true
$lvAliases.Font          = $font
[void]$lvAliases.Columns.Add("Address", 560)
[void]$lvAliases.Columns.Add("Type",    290)
$grpAliases.Controls.Add($lvAliases)

$lblAddAlias          = New-Object System.Windows.Forms.Label
$lblAddAlias.Text     = "Add Alias:"
$lblAddAlias.Location = New-Object System.Drawing.Point(10, 340)
$lblAddAlias.AutoSize = $true
$lblAddAlias.Font     = $font
$grpAliases.Controls.Add($lblAddAlias)

$txtAddAlias          = New-Object System.Windows.Forms.TextBox
$txtAddAlias.Location = New-Object System.Drawing.Point(82, 338)
$txtAddAlias.Size     = New-Object System.Drawing.Size(450, 25)
$txtAddAlias.Font     = $font
Add-PlaceholderBehavior $txtAddAlias "newalias@domain.com"
$grpAliases.Controls.Add($txtAddAlias)

$btnAddAlias          = New-Object System.Windows.Forms.Button
$btnAddAlias.Text     = "Add"
$btnAddAlias.Location = New-Object System.Drawing.Point(544, 336)
$btnAddAlias.Size     = New-Object System.Drawing.Size(120, 28)
$btnAddAlias.Font     = $font
$grpAliases.Controls.Add($btnAddAlias)

$btnRemoveAlias          = New-Object System.Windows.Forms.Button
$btnRemoveAlias.Text     = "Remove Selected"
$btnRemoveAlias.Location = New-Object System.Drawing.Point(10, 374)
$btnRemoveAlias.Size     = New-Object System.Drawing.Size(150, 28)
$btnRemoveAlias.Font     = $font
$grpAliases.Controls.Add($btnRemoveAlias)

# ================================================================================
# TAB 7 — Recurring Events
# ================================================================================

$tabRecurring      = New-Object System.Windows.Forms.TabPage
$tabRecurring.Text = "Recurring Events"

$lblRecInfo           = New-Object System.Windows.Forms.Label
$lblRecInfo.Text      = "Finds meetings the mailbox organizes (with attendees/resources) in the chosen date " +
                        "window, then cancels them. Recurring series with any occurrence in that window are cancelled in full."
$lblRecInfo.Location  = New-Object System.Drawing.Point(20, 16)
$lblRecInfo.Size      = New-Object System.Drawing.Size(892, 36)
$lblRecInfo.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblRecInfo.ForeColor = [System.Drawing.Color]::DimGray
$tabRecurring.Controls.Add($lblRecInfo)

$lblRecMbx          = New-Object System.Windows.Forms.Label
$lblRecMbx.Text     = "Mailbox:"
$lblRecMbx.Location = New-Object System.Drawing.Point(20, 62)
$lblRecMbx.AutoSize = $true
$lblRecMbx.Font     = $font
$tabRecurring.Controls.Add($lblRecMbx)

$txtRecMbx          = New-Object System.Windows.Forms.TextBox
$txtRecMbx.Location = New-Object System.Drawing.Point(90, 58)
$txtRecMbx.Size     = New-Object System.Drawing.Size(280, 25)
$txtRecMbx.Font     = $font
Add-PlaceholderBehavior $txtRecMbx "user@domain.com"
$tabRecurring.Controls.Add($txtRecMbx)

$lblRecStart          = New-Object System.Windows.Forms.Label
$lblRecStart.Text     = "Start Date:"
$lblRecStart.Location = New-Object System.Drawing.Point(390, 62)
$lblRecStart.AutoSize = $true
$lblRecStart.Font     = $font
$tabRecurring.Controls.Add($lblRecStart)

$dtpRecStart          = New-Object System.Windows.Forms.DateTimePicker
$dtpRecStart.Location = New-Object System.Drawing.Point(465, 58)
$dtpRecStart.Size     = New-Object System.Drawing.Size(120, 25)
$dtpRecStart.Font     = $font
$dtpRecStart.Format   = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpRecStart.Value    = (Get-Date)
$tabRecurring.Controls.Add($dtpRecStart)

$lblRecWindow          = New-Object System.Windows.Forms.Label
$lblRecWindow.Text     = "Window (days):"
$lblRecWindow.Location = New-Object System.Drawing.Point(600, 62)
$lblRecWindow.AutoSize = $true
$lblRecWindow.Font     = $font
$tabRecurring.Controls.Add($lblRecWindow)

$nudRecWindow          = New-Object System.Windows.Forms.NumericUpDown
$nudRecWindow.Location = New-Object System.Drawing.Point(710, 58)
$nudRecWindow.Size     = New-Object System.Drawing.Size(60, 25)
$nudRecWindow.Font     = $font
$nudRecWindow.Minimum  = 1
$nudRecWindow.Maximum  = 1825
$nudRecWindow.Value    = 1
$tabRecurring.Controls.Add($nudRecWindow)

$chkRecCustomRouting          = New-Object System.Windows.Forms.CheckBox
$chkRecCustomRouting.Text     = "Use Custom Routing (experimental - routes directly to the mailbox's backend server; may avoid a generic 'server side error')"
$chkRecCustomRouting.Location = New-Object System.Drawing.Point(90, 92)
$chkRecCustomRouting.AutoSize = $true
$chkRecCustomRouting.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRecurring.Controls.Add($chkRecCustomRouting)

$chkRecSingleAttendee          = New-Object System.Windows.Forms.CheckBox
$chkRecSingleAttendee.Text     = "Only show meetings with 0-1 other attendees (personal room bookings / 1:1 calls) - requires Graph connection"
$chkRecSingleAttendee.Location = New-Object System.Drawing.Point(90, 114)
$chkRecSingleAttendee.AutoSize = $true
$chkRecSingleAttendee.Font     = New-Object System.Drawing.Font("Segoe UI", 9)
$tabRecurring.Controls.Add($chkRecSingleAttendee)

$btnRecSearch          = New-Object System.Windows.Forms.Button
$btnRecSearch.Text     = "Search (Preview)"
$btnRecSearch.Location = New-Object System.Drawing.Point(20, 150)
$btnRecSearch.Size     = New-Object System.Drawing.Size(160, 32)
$btnRecSearch.Font     = $font
$tabRecurring.Controls.Add($btnRecSearch)

$lblRecStatus           = New-Object System.Windows.Forms.Label
$lblRecStatus.Text      = ""
$lblRecStatus.Location  = New-Object System.Drawing.Point(190, 158)
$lblRecStatus.AutoSize  = $true
$lblRecStatus.Font      = $font
$lblRecStatus.ForeColor = [System.Drawing.Color]::DimGray
$tabRecurring.Controls.Add($lblRecStatus)

$lblRecResultsHdr          = New-Object System.Windows.Forms.Label
$lblRecResultsHdr.Text     = "Meetings that would be cancelled:"
$lblRecResultsHdr.Location = New-Object System.Drawing.Point(20, 194)
$lblRecResultsHdr.AutoSize = $true
$lblRecResultsHdr.Font     = $fontBold
$tabRecurring.Controls.Add($lblRecResultsHdr)

$lvRecEvents               = New-Object System.Windows.Forms.ListView
$lvRecEvents.Location      = New-Object System.Drawing.Point(20, 218)
$lvRecEvents.Size          = New-Object System.Drawing.Size(892, 300)
$lvRecEvents.View          = "Details"
$lvRecEvents.FullRowSelect = $true
$lvRecEvents.GridLines     = $true
$lvRecEvents.Font          = $font
[void]$lvRecEvents.Columns.Add("Subject",    620)
[void]$lvRecEvents.Columns.Add("Start Date", 260)
$tabRecurring.Controls.Add($lvRecEvents)

$btnRecCancel          = New-Object System.Windows.Forms.Button
$btnRecCancel.Text     = "Cancel All Found Meetings"
$btnRecCancel.Location = New-Object System.Drawing.Point(20, 528)
$btnRecCancel.Size     = New-Object System.Drawing.Size(220, 34)
$btnRecCancel.Font     = $font
$btnRecCancel.Enabled  = $false
$tabRecurring.Controls.Add($btnRecCancel)

$lblRecWarn           = New-Object System.Windows.Forms.Label
$lblRecWarn.Text      = "Run Search first. Cancellation is immediate and emails attendees - this cannot be undone."
$lblRecWarn.Location  = New-Object System.Drawing.Point(255, 536)
$lblRecWarn.AutoSize  = $true
$lblRecWarn.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblRecWarn.ForeColor = [System.Drawing.Color]::DimGray
$tabRecurring.Controls.Add($lblRecWarn)

# ================================================================================
# Event Handlers — Alias Search tab
# ================================================================================

$btnAliasSearch.Add_Click({
    if (-not (Test-ExoReady)) { return }
    $term = Get-ControlText $txtAliasSearch
    if ([string]::IsNullOrWhiteSpace($term)) {
        Write-Log "Alias Search: Enter a search term first."
        return
    }

    $lvAliasResults.Items.Clear()
    Write-Log "Alias Search: Searching for '$term' ..."

    try {
        $filter = if ($chkAliasPartial.Checked) {
            "EmailAddresses -like '*$term*'"
        } else {
            "EmailAddresses -eq 'smtp:$term'"
        }

        $recipients = @(Get-Recipient -Filter $filter -ResultSize 200 -ErrorAction Stop |
            Where-Object { $null -ne $_ })

        foreach ($r in $recipients) {
            # Find which address(es) matched the search term
            $matched = @($r.EmailAddresses | Where-Object {
                $addr = $_.ToString() -replace '^smtp:','' -replace '^SMTP:',''
                if ($chkAliasPartial.Checked) { $addr -like "*$term*" }
                else                          { $addr -ieq $term }
            } | ForEach-Object { $_.ToString() -replace '^smtp:','' -replace '^SMTP:','' })

            $item = New-Object System.Windows.Forms.ListViewItem([string]$r.DisplayName)
            [void]$item.SubItems.Add([string]$r.PrimarySmtpAddress)
            [void]$item.SubItems.Add([string]$r.RecipientTypeDetails)
            [void]$item.SubItems.Add(($matched -join ', '))
            $item.Tag = [string]$r.PrimarySmtpAddress
            [void]$lvAliasResults.Items.Add($item)
        }

        Write-Log "Alias Search: $($recipients.Count) recipient(s) found."
    }
    catch {
        Write-Log "Alias Search ERROR: $($_.Exception.Message)"
    }
})

# Allow pressing Enter in the search box to trigger the search
$txtAliasSearch.Add_KeyDown({
    if ($args[1].KeyCode -eq [System.Windows.Forms.Keys]::Return) {
        $btnAliasSearch.PerformClick()
        $args[1].Handled = $true
        $args[1].SuppressKeyPress = $true
    }
})

# Double-click a result row -> load that mailbox in the Mailbox Permissions tab
$lvAliasResults.Add_DoubleClick({
    if ($lvAliasResults.SelectedItems.Count -eq 0) { return }
    $smtp = $lvAliasResults.SelectedItems[0].Tag
    if ([string]::IsNullOrEmpty($smtp)) { return }
    $txtMbxLookup.Text      = $smtp
    $txtMbxLookup.ForeColor = [System.Drawing.SystemColors]::WindowText
    $tabs.SelectedTab       = $tabMbxPerms
    $btnMbxLoad.PerformClick()
})

# Add Alias
$btnAddAlias.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Aliases: Load a mailbox from the Mailbox Permissions tab first."; return }
    $mbx   = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $alias = Get-ControlText $txtAddAlias

    if ([string]::IsNullOrWhiteSpace($alias)) {
        Write-Log "Aliases: Enter an alias address to add."
        return
    }
    if ($alias -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-Log "Aliases: '$alias' doesn't look like a valid email address."
        return
    }

    try {
        Set-Mailbox -Identity $mbx -EmailAddresses @{Add="smtp:$alias"} -ErrorAction Stop
        Write-Log "Aliases: $alias added to $mbx."
        $txtAddAlias.Text      = $txtAddAlias.Tag
        $txtAddAlias.ForeColor = [System.Drawing.Color]::Gray
        $script:loadedMbx = Get-Mailbox -Identity $mbx -ErrorAction Stop
        Invoke-LoadAliases -MbxObj $script:loadedMbx -ListView $lvAliases
    } catch {
        Write-Log "Aliases ERROR (add): $($_.Exception.Message)"
    }
})

# Remove Selected Alias
$btnRemoveAlias.Add_Click({
    if ($null -eq $script:loadedMbx) { Write-Log "Aliases: Load a mailbox from the Mailbox Permissions tab first."; return }
    if ($lvAliases.SelectedItems.Count -eq 0) {
        Write-Log "Aliases: Select an alias to remove."
        return
    }

    $sel  = $lvAliases.SelectedItems[0]
    if ($sel.SubItems[1].Text -eq 'Primary') {
        Write-Log "Aliases: Cannot remove the Primary SMTP address."
        return
    }

    $mbx   = $script:loadedMbx.PrimarySmtpAddress.ToString()
    $alias = $sel.Text

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Remove alias '$alias' from '$mbx'?",
        "Confirm Remove Alias", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    try {
        Set-Mailbox -Identity $mbx -EmailAddresses @{Remove="smtp:$alias"} -ErrorAction Stop
        Write-Log "Aliases: $alias removed from $mbx."
        $script:loadedMbx = Get-Mailbox -Identity $mbx -ErrorAction Stop
        Invoke-LoadAliases -MbxObj $script:loadedMbx -ListView $lvAliases
    } catch {
        Write-Log "Aliases ERROR (remove): $($_.Exception.Message)"
    }
})

# ================================================================================
# Event Handlers — Recurring Events tab
# ================================================================================

$txtRecMbx.Add_TextChanged({        $btnRecCancel.Enabled = $false; $script:recResult = $null })
$dtpRecStart.Add_ValueChanged({     $btnRecCancel.Enabled = $false; $script:recResult = $null })
$nudRecWindow.Add_ValueChanged({    $btnRecCancel.Enabled = $false; $script:recResult = $null })
$chkRecCustomRouting.Add_CheckedChanged({  $btnRecCancel.Enabled = $false; $script:recResult = $null })
$chkRecSingleAttendee.Add_CheckedChanged({ $btnRecCancel.Enabled = $false; $script:recResult = $null })

$btnRecSearch.Add_Click({
    $lvRecEvents.Items.Clear()
    $btnRecCancel.Enabled = $false
    $script:recResult     = $null

    $mailbox = Get-ControlText $txtRecMbx
    if ([string]::IsNullOrWhiteSpace($mailbox)) {
        Write-Log "Recurring Events: Enter a mailbox first."
        return
    }

    $startDate  = $dtpRecStart.Value.Date
    $windowDays = [int]$nudRecWindow.Value

    foreach ($w in (Get-MailboxHoldWarning -Mailbox $mailbox)) {
        Write-Log "Recurring Events WARNING: $w"
    }

    try {
        $lblRecStatus.Text      = "Searching..."
        $lblRecStatus.ForeColor = [System.Drawing.Color]::DimGray
        Write-Log "Recurring Events: Searching $mailbox from $($startDate.ToShortDateString()) + $windowDays day(s) ...$(if ($chkRecCustomRouting.Checked) { ' [Custom Routing]' })"

        $result     = Get-CalendarEventCancellationPreview -Mailbox $mailbox -StartDate $startDate `
                          -WindowDays $windowDays -PreviewOnly -UseCustomRouting:$chkRecCustomRouting.Checked
        $meetings   = $result.Meetings
        $totalFound = $meetings.Count

        if ($chkRecSingleAttendee.Checked -and $totalFound -gt 0) {
            try {
                $attendeeCounts = Get-CalendarAttendeeCountsBySubject -Mailbox $mailbox -StartDate $startDate -EndDate $startDate.AddDays($windowDays)
                $kept      = New-Object System.Collections.Generic.List[object]
                $unmatched = 0
                foreach ($m in $meetings) {
                    $key = $m.Subject.Trim().ToLowerInvariant()
                    if ($attendeeCounts.ContainsKey($key)) {
                        if ($attendeeCounts[$key] -le 1) { $kept.Add($m) }
                    } else { $unmatched++ }
                }
                $meetings = @($kept)
                Write-Log "Recurring Events: '0-1 other attendees' filter kept $($meetings.Count) of $totalFound meeting(s)$(if ($unmatched -gt 0) { " ($unmatched could not be matched - verify manually)" })."
            }
            catch {
                Write-Log "Recurring Events WARNING: Could not apply attendee filter ($($_.Exception.Message)) - showing all $totalFound meeting(s)."
            }
        }

        foreach ($m in $meetings) {
            $item = New-Object System.Windows.Forms.ListViewItem($m.Subject)
            [void]$item.SubItems.Add($m.StartDate)
            [void]$lvRecEvents.Items.Add($item)
        }

        if ($meetings.Count -gt 0) {
            $script:recResult = @{
                Mailbox       = $mailbox
                StartDate     = $startDate
                WindowDays    = $windowDays
                TotalFound    = $totalFound
                FilteredCount = $meetings.Count
                FilterApplied = ($chkRecSingleAttendee.Checked -and $totalFound -gt 0)
            }
            $btnRecCancel.Enabled   = $true
            $lblRecStatus.Text      = "$($meetings.Count) meeting(s) found."
            $lblRecStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            Write-Log "Recurring Events: $($meetings.Count) meeting(s) would be cancelled."
        } else {
            $lblRecStatus.Text      = "No matching meetings found."
            $lblRecStatus.ForeColor = [System.Drawing.Color]::DimGray
            Write-Log "Recurring Events: No organized meetings with attendees found in that window."
        }
    }
    catch {
        $lblRecStatus.Text      = "Search failed."
        $lblRecStatus.ForeColor = [System.Drawing.Color]::Red
        Write-Log "Recurring Events ERROR (search): $($_.Exception.Message)"
    }
})

$btnRecCancel.Add_Click({
    if ($null -eq $script:recResult) { Write-Log "Recurring Events: Run Search first."; return }

    $mailbox    = $script:recResult.Mailbox
    $startDate  = $script:recResult.StartDate
    $windowDays = $script:recResult.WindowDays

    $filterNote = ""
    if ($script:recResult.FilterApplied -and $script:recResult.TotalFound -gt $script:recResult.FilteredCount) {
        $filterNote = "`r`n`r`nNOTE: The attendee filter is showing $($script:recResult.FilteredCount) of $($script:recResult.TotalFound) meeting(s). " +
            "Exchange's cancel operation is NOT selective - it will cancel ALL $($script:recResult.TotalFound) organized meetings in this window."
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Cancel all $($script:recResult.TotalFound) meeting(s) organized by '$mailbox' in this window?`r`n" +
        "Attendees will receive cancellation notices. This cannot be undone.$filterNote",
        "Confirm Cancel Meetings", "YesNo", "Warning"
    )
    if ($confirm -ne 'Yes') { return }

    try {
        Write-Log "Recurring Events: Cancelling meetings for $mailbox ...$(if ($chkRecCustomRouting.Checked) { ' [Custom Routing]' })"
        $result = Get-CalendarEventCancellationPreview -Mailbox $mailbox -StartDate $startDate `
                      -WindowDays $windowDays -UseCustomRouting:$chkRecCustomRouting.Checked
        Write-Log "Recurring Events: Cancellation submitted for $($result.Meetings.Count) meeting(s) on $mailbox."
        [System.Windows.Forms.MessageBox]::Show(
            "$($result.Meetings.Count) meeting(s) cancelled on $mailbox.",
            "Done", "OK", "Information") | Out-Null
        $lvRecEvents.Items.Clear()
        $btnRecCancel.Enabled   = $false
        $script:recResult       = $null
        $lblRecStatus.Text      = "Cancellation complete."
        $lblRecStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    catch {
        Write-Log "Recurring Events ERROR (cancel): $($_.Exception.Message)"
    }
})

# ── Right-click copy menus for all ListViews ─────────────────────────────────────
Add-ListViewCopyMenu $lvMbxPerms
Add-ListViewCopyMenu $lvAliases
Add-ListViewCopyMenu $lvCalPerms
Add-ListViewCopyMenu $lvAliasResults
Add-ListViewCopyMenu $lvMailbox
Add-ListViewCopyMenu $lvMfResults
Add-ListViewCopyMenu $lvMfDetail
Add-ListViewCopyMenu $lvMfActivity
Add-ListViewCopyMenu $lvMfRules
Add-ListViewCopyMenu $lvRecEvents

# Tab order: Mailbox Permissions -> Alias Search -> Shared Mailbox -> Auto-Reply -> Email Investigation -> Recurring Events
[void]$tabs.TabPages.Add($tabMbxPerms)
[void]$tabs.TabPages.Add($tabAliasSearch)
[void]$tabs.TabPages.Add($tabMailbox)
[void]$tabs.TabPages.Add($tabOOO)
[void]$tabs.TabPages.Add($tabEmailInv)
[void]$tabs.TabPages.Add($tabRecurring)

# ── Form.Shown: initialise connection labels & greet ────────────────────────────
$form.Add_Shown({
    Update-ConnectionLabels
    Write-Status "O365 Admin Tools ready. Use the Connections buttons in the Spam Cleanup tab to connect to Exchange Online and/or IPPS."
    Write-Log "Session started."
})

[void]$form.ShowDialog()
