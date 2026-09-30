<#
.SYNOPSIS
    GUI tool to offboard an Active Directory user account.

.DESCRIPTION
    Searches AD for a user, then on confirmation:
      - Removes the user from every group except Domain Users
        (the prior group list is preserved in AD Notes before removal)
      - Records the user's current manager in AD Notes, then clears Manager
      - Resets the password to a random 30-character value and prevents
        the user from changing it (CannotChangePassword)
      - Disables the account
      - Moves the object to the configured Disabled Users OU
      - Optionally forces AD replication (repadmin /syncall) and/or an
        Azure AD Connect delta sync

    Nothing is changed until you click "Offboard User" AND confirm the
    summary dialog that follows.

.REQUIREMENTS
    - RSAT: Active Directory module (Import-Module ActiveDirectory)
    - Run as a user with rights to modify group membership, reset
      passwords, and move/disable objects in the target OUs
    - For the Azure AD Delta Sync option: WinRM access to the AAD Connect
      server, and the ADSync module installed there

.NOTES
    Edit the $Config block below for your environment before first use.
#>

#requires -Modules ActiveDirectory
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================================================================================
# Configuration - edit these for your environment
# ================================================================================
$Config = @{
    # Distinguished Name of the OU that disabled accounts get moved to
    DisabledOU       = "OU=Disabled Users,DC=contoso,DC=com"

    # Default Domain Controller to target (leave blank to auto-discover)
    DomainController = ""

    # Hostname of the server running Azure AD Connect (for delta sync)
    AADConnectServer = "AADCONNECT01"

    # Max length of the AD "info" (Notes) attribute
    NotesMaxLength   = 1024
}

# ================================================================================
# Helper Functions
# ================================================================================

function Write-Log {
    param($tb, [string]$msg)
    $tb.AppendText("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg`r`n")
    $tb.SelectionStart = $tb.TextLength
    $tb.ScrollToCaret()
}

function New-RandomPassword {
    <#
    .SYNOPSIS
    Generates a cryptographically random password of the given length,
    guaranteeing at least one upper, lower, digit, and symbol character.
    #>
    param([int]$Length = 30)

    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digit  = '23456789'
    $symbol = '!@#$%^&*()-_=+[]{}'
    $all    = $upper + $lower + $digit + $symbol

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 4

    function Get-RandomChar([string]$set) {
        $rng.GetBytes($bytes)
        $idx = [System.BitConverter]::ToUInt32($bytes, 0) % $set.Length
        return $set[$idx]
    }

    $chars = @(
        Get-RandomChar $upper
        Get-RandomChar $lower
        Get-RandomChar $digit
        Get-RandomChar $symbol
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += Get-RandomChar $all
    }

    # Shuffle (Fisher-Yates) so the guaranteed chars aren't always at the front
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($bytes)
        $j = [System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $rng.Dispose()
    return -join $chars
}

function Get-DomainUsersGroup {
    <#
    .SYNOPSIS
    Resolves the domain's "Domain Users" group by well-known RID (513)
    rather than by name, so this still works if the group was renamed.
    #>
    param([string]$Server)
    $params = @{ ErrorAction = 'Stop' }
    if ($Server) { $params.Server = $Server }
    $domain = Get-ADDomain @params
    return Get-ADGroup -Identity "$($domain.DomainSID.Value)-513" @params
}

function Get-ADUserSafe {
    param([string]$Identity, [string]$Server)
    $params = @{ Identity = $Identity; ErrorAction = 'Stop'; Properties = @('MemberOf','Manager','info','Enabled','DistinguishedName','PasswordLastSet','CanonicalName','primaryGroupID') }
    if ($Server) { $params.Server = $Server }
    try { return Get-ADUser @params } catch { return $null }
}

function Get-DisplayNameFromDN {
    param([string]$DN, [string]$Server)
    if ([string]::IsNullOrWhiteSpace($DN)) { return $null }
    try {
        $params = @{ Identity = $DN; ErrorAction = 'Stop'; Properties = @('DisplayName') }
        if ($Server) { $params.Server = $Server }
        $obj = Get-ADObject @params
        if ($obj.DisplayName) { return $obj.DisplayName }
        return $obj.Name
    } catch {
        return $DN
    }
}

# ================================================================================
# Build Form
# ================================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "AD User Offboarding"
$form.Size = New-Object System.Drawing.Size(940, 780)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font     = New-Object System.Drawing.Font("Segoe UI", 10)
$fontBold = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

# --- Search group ---
$grpSearch = New-Object System.Windows.Forms.GroupBox
$grpSearch.Text = "Find User"
$grpSearch.Font = $fontBold
$grpSearch.Location = New-Object System.Drawing.Point(15,10)
$grpSearch.Size = New-Object System.Drawing.Size(895,120)
$form.Controls.Add($grpSearch)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Name or username:"
$lblSearch.Font = $font
$lblSearch.Location = New-Object System.Drawing.Point(15,30)
$lblSearch.AutoSize = $true
$grpSearch.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Font = $font
$txtSearch.Location = New-Object System.Drawing.Point(160,27)
$txtSearch.Size = New-Object System.Drawing.Size(300,25)
$grpSearch.Controls.Add($txtSearch)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = "Search"
$btnSearch.Font = $font
$btnSearch.Location = New-Object System.Drawing.Point(470,25)
$btnSearch.Size = New-Object System.Drawing.Size(100,28)
$grpSearch.Controls.Add($btnSearch)

$lstResults = New-Object System.Windows.Forms.ListBox
$lstResults.Font = $font
$lstResults.Location = New-Object System.Drawing.Point(15,60)
$lstResults.Size = New-Object System.Drawing.Size(645,50)
$grpSearch.Controls.Add($lstResults)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load Selected User"
$btnLoad.Font = $font
$btnLoad.Location = New-Object System.Drawing.Point(680,60)
$btnLoad.Size = New-Object System.Drawing.Size(190,28)
$grpSearch.Controls.Add($btnLoad)

$txtSearch.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter') { $btnSearch.PerformClick(); $_.SuppressKeyPress = $true }
})

# --- Details group ---
$grpDetails = New-Object System.Windows.Forms.GroupBox
$grpDetails.Text = "User Details"
$grpDetails.Font = $fontBold
$grpDetails.Location = New-Object System.Drawing.Point(15,140)
$grpDetails.Size = New-Object System.Drawing.Size(895,220)
$form.Controls.Add($grpDetails)

function New-DetailLabel($x, $y, $text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Font = $font
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.AutoSize = $true
    $grpDetails.Controls.Add($lbl)
    return $lbl
}

New-DetailLabel 15 30 "Name:" | Out-Null
$lblName = New-DetailLabel 160 30 "-"
New-DetailLabel 15 55 "Username:" | Out-Null
$lblSam = New-DetailLabel 160 55 "-"
New-DetailLabel 15 80 "Current OU:" | Out-Null
$lblOU = New-DetailLabel 160 80 "-"
New-DetailLabel 15 105 "Manager:" | Out-Null
$lblManager = New-DetailLabel 160 105 "-"
New-DetailLabel 15 130 "Status:" | Out-Null
$lblStatus = New-DetailLabel 160 130 "-"

New-DetailLabel 470 30 "Group memberships to be removed:" | Out-Null
$lstGroups = New-Object System.Windows.Forms.ListBox
$lstGroups.Font = $font
$lstGroups.Location = New-Object System.Drawing.Point(470,55)
$lstGroups.Size = New-Object System.Drawing.Size(400,150)
$grpDetails.Controls.Add($lstGroups)

# --- Options group ---
$grpOptions = New-Object System.Windows.Forms.GroupBox
$grpOptions.Text = "Sync Options"
$grpOptions.Font = $fontBold
$grpOptions.Location = New-Object System.Drawing.Point(15,370)
$grpOptions.Size = New-Object System.Drawing.Size(895,110)
$form.Controls.Add($grpOptions)

$chkAdSync = New-Object System.Windows.Forms.CheckBox
$chkAdSync.Text = "Force AD replication (repadmin /syncall) after offboarding"
$chkAdSync.Font = $font
$chkAdSync.Location = New-Object System.Drawing.Point(15,25)
$chkAdSync.AutoSize = $true
$grpOptions.Controls.Add($chkAdSync)

$lblDC = New-Object System.Windows.Forms.Label
$lblDC.Text = "Domain Controller:"
$lblDC.Font = $font
$lblDC.Location = New-Object System.Drawing.Point(430,25)
$lblDC.AutoSize = $true
$grpOptions.Controls.Add($lblDC)

$txtDC = New-Object System.Windows.Forms.TextBox
$txtDC.Font = $font
$txtDC.Text = $Config.DomainController
$txtDC.Location = New-Object System.Drawing.Point(590,22)
$txtDC.Size = New-Object System.Drawing.Size(280,25)
$grpOptions.Controls.Add($txtDC)

$chkAzureSync = New-Object System.Windows.Forms.CheckBox
$chkAzureSync.Text = "Force Azure AD Connect delta sync after offboarding"
$chkAzureSync.Font = $font
$chkAzureSync.Location = New-Object System.Drawing.Point(15,65)
$chkAzureSync.AutoSize = $true
$grpOptions.Controls.Add($chkAzureSync)

$lblAAD = New-Object System.Windows.Forms.Label
$lblAAD.Text = "AAD Connect Server:"
$lblAAD.Font = $font
$lblAAD.Location = New-Object System.Drawing.Point(430,65)
$lblAAD.AutoSize = $true
$grpOptions.Controls.Add($lblAAD)

$txtAAD = New-Object System.Windows.Forms.TextBox
$txtAAD.Font = $font
$txtAAD.Text = $Config.AADConnectServer
$txtAAD.Location = New-Object System.Drawing.Point(590,62)
$txtAAD.Size = New-Object System.Drawing.Size(280,25)
$grpOptions.Controls.Add($txtAAD)

# --- Action buttons ---
$btnOffboard = New-Object System.Windows.Forms.Button
$btnOffboard.Text = "Offboard User"
$btnOffboard.Font = $fontBold
$btnOffboard.Location = New-Object System.Drawing.Point(15,490)
$btnOffboard.Size = New-Object System.Drawing.Size(200,38)
$btnOffboard.Enabled = $false
$btnOffboard.BackColor = [System.Drawing.Color]::MistyRose
$form.Controls.Add($btnOffboard)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Font = $font
$btnClose.Location = New-Object System.Drawing.Point(230,490)
$btnClose.Size = New-Object System.Drawing.Size(100,38)
$form.Controls.Add($btnClose)

# --- Log box ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Activity Log:"
$lblLog.Font = $fontBold
$lblLog.Location = New-Object System.Drawing.Point(15,540)
$lblLog.AutoSize = $true
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.Location = New-Object System.Drawing.Point(15,565)
$txtLog.Size = New-Object System.Drawing.Size(895,170)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

# ================================================================================
# State
# ================================================================================
$script:searchMap    = @{}   # index -> DistinguishedName
$script:selectedUser = $null # ADUser object once loaded
$script:groupsToRemove = @() # ADGroup objects

# ================================================================================
# Event Handlers
# ================================================================================

$btnSearch.Add_Click({
    $lstResults.Items.Clear()
    $script:searchMap.Clear()
    $btnOffboard.Enabled = $false

    $q = $txtSearch.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) {
        Write-Log $txtLog "Enter a name or username to search for."
        return
    }

    $dc = $txtDC.Text.Trim()
    $qEscaped = $q -replace "'", "''"
    try {
        $params = @{
            Filter     = "(Name -like '*$qEscaped*') -or (SamAccountName -like '*$qEscaped*') -or (DisplayName -like '*$qEscaped*')"
            Properties = @('DisplayName','SamAccountName','DistinguishedName','Enabled','CanonicalName')
            ErrorAction = 'Stop'
        }
        if ($dc) { $params.Server = $dc }
        $results = Get-ADUser @params | Sort-Object DisplayName

        if (-not $results) {
            Write-Log $txtLog "No users found matching '$q'."
            return
        }

        $i = 0
        foreach ($r in $results) {
            $stateTag = if ($r.Enabled) { "Enabled" } else { "Disabled" }
            $label = "$($r.DisplayName) ($($r.SamAccountName)) - $stateTag - $($r.CanonicalName)"
            [void]$lstResults.Items.Add($label)
            $script:searchMap[$i] = $r.DistinguishedName
            $i++
        }
        Write-Log $txtLog "Found $($results.Count) match(es) for '$q'."
    } catch {
        Write-Log $txtLog "SEARCH FAILED: $($_.Exception.Message)"
    }
})

$btnLoad.Add_Click({
    if ($lstResults.SelectedIndex -lt 0) {
        Write-Log $txtLog "Select a user from the search results first."
        return
    }

    $dn = $script:searchMap[$lstResults.SelectedIndex]
    $dc = $txtDC.Text.Trim()
    $user = Get-ADUserSafe -Identity $dn -Server $dc
    if (-not $user) {
        Write-Log $txtLog "Could not load the selected user. It may have been moved or deleted."
        return
    }

    $script:selectedUser = $user

    $lblName.Text   = $user.Name
    $lblSam.Text    = $user.SamAccountName
    $lblOU.Text     = ($user.DistinguishedName -split ',',2)[1]
    $lblStatus.Text = if ($user.Enabled) { "Enabled" } else { "Already Disabled" }

    $managerName = if ($user.Manager) { Get-DisplayNameFromDN -DN $user.Manager -Server $dc } else { "(none)" }
    $lblManager.Text = $managerName

    $lstGroups.Items.Clear()
    $script:groupsToRemove = @()
    try {
        $domainUsers = Get-DomainUsersGroup -Server $dc
        foreach ($groupDN in $user.MemberOf) {
            if ($groupDN -eq $domainUsers.DistinguishedName) { continue }
            $params = @{ Identity = $groupDN; ErrorAction = 'Stop' }
            if ($dc) { $params.Server = $dc }
            try {
                $g = Get-ADGroup @params
                $script:groupsToRemove += $g
                [void]$lstGroups.Items.Add($g.Name)
            } catch {
                [void]$lstGroups.Items.Add("(unresolved group: $groupDN)")
            }
        }
        if ($lstGroups.Items.Count -eq 0) {
            [void]$lstGroups.Items.Add("(only in Domain Users - nothing to remove)")
        }
    } catch {
        Write-Log $txtLog "Could not resolve group memberships: $($_.Exception.Message)"
    }

    $btnOffboard.Enabled = $true
    Write-Log $txtLog "Loaded $($user.SamAccountName)."
})

$btnOffboard.Add_Click({
    if (-not $script:selectedUser) {
        Write-Log $txtLog "Load a user first."
        return
    }

    $user = $script:selectedUser
    $dc   = $txtDC.Text.Trim()
    $doAdSync    = $chkAdSync.Checked
    $doAzureSync = $chkAzureSync.Checked
    $aadServer   = $txtAAD.Text.Trim()

    if ($doAzureSync -and [string]::IsNullOrWhiteSpace($aadServer)) {
        [System.Windows.Forms.MessageBox]::Show("Enter the Azure AD Connect server name, or uncheck the Azure AD Delta Sync option.","Missing Info","OK","Warning") | Out-Null
        return
    }

    $managerName = $lblManager.Text
    $groupNames  = if ($script:groupsToRemove.Count -gt 0) { ($script:groupsToRemove | ForEach-Object { $_.Name }) -join ", " } else { "(none)" }

    # --- Build confirmation summary ---
    $summary = @"
You are about to offboard: $($user.Name) ($($user.SamAccountName))

The following actions will be performed:
  1. Remove from $($script:groupsToRemove.Count) group(s): $groupNames
  2. Record prior groups and manager ($managerName) in AD Notes
  3. Clear the Manager field
  4. Reset password to a random 30-character value (user cannot change it)
  5. Disable the account
  6. Move the object to: $($Config.DisabledOU)
$(if ($doAdSync)    { "  7. Force AD replication (repadmin /syncall)`r`n" })$(if ($doAzureSync) { "  8. Force Azure AD Connect delta sync on $aadServer`r`n" })
This cannot be easily undone. Continue?
"@

    $confirm = [System.Windows.Forms.MessageBox]::Show($summary, "Confirm Offboarding", "YesNo", "Warning", "Button2")
    if ($confirm -ne "Yes") {
        Write-Log $txtLog "Offboarding cancelled by user."
        return
    }

    $btnOffboard.Enabled = $false
    $adParams = @{ ErrorAction = 'Stop' }
    if ($dc) { $adParams.Server = $dc }

    try {
        Write-Log $txtLog "=== Starting offboarding of $($user.SamAccountName) ==="

        # 1. Fix primary group so other groups can be removed cleanly
        $domainUsers = Get-DomainUsersGroup -Server $dc
        $fresh = Get-ADUserSafe -Identity $user.DistinguishedName -Server $dc
        if ($fresh.primaryGroupID -ne 513) {
            Write-Log $txtLog "Switching primary group to Domain Users..."
            Set-ADUser -Identity $fresh.DistinguishedName -Replace @{primaryGroupID = 513} @adParams
            try {
                Add-ADGroupMember -Identity $domainUsers.DistinguishedName -Members $fresh.DistinguishedName @adParams
            } catch { }
        }

        # 2. Remove from all other groups
        foreach ($g in $script:groupsToRemove) {
            try {
                Remove-ADGroupMember -Identity $g.DistinguishedName -Members $fresh.DistinguishedName -Confirm:$false @adParams
                Write-Log $txtLog "Removed from group: $($g.Name)"
            } catch {
                Write-Log $txtLog "WARNING: could not remove from '$($g.Name)': $($_.Exception.Message)"
            }
        }

        # 3. Record prior state in AD Notes (info attribute)
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $noteEntry = "[$timestamp] Offboarded by $env:USERDOMAIN\$env:USERNAME. Prior manager: $managerName. Prior groups: $groupNames."
        $existingNotes = (Get-ADUserSafe -Identity $fresh.DistinguishedName -Server $dc).info
        $newNotes = if ([string]::IsNullOrWhiteSpace($existingNotes)) { $noteEntry } else { "$existingNotes`r`n$noteEntry" }
        if ($newNotes.Length -gt $Config.NotesMaxLength) {
            $newNotes = $newNotes.Substring($newNotes.Length - $Config.NotesMaxLength)
            Write-Log $txtLog "NOTE: existing AD Notes were trimmed to fit the $($Config.NotesMaxLength)-character limit."
        }
        Set-ADUser -Identity $fresh.DistinguishedName -Replace @{info = $newNotes} @adParams
        Write-Log $txtLog "Recorded prior manager and group list in AD Notes."

        # 4. Clear manager
        if ($fresh.Manager) {
            Set-ADUser -Identity $fresh.DistinguishedName -Clear Manager @adParams
            Write-Log $txtLog "Cleared Manager field."
        }

        # 5. Reset password
        $newPassword = New-RandomPassword -Length 30
        $secure = ConvertTo-SecureString -String $newPassword -AsPlainText -Force
        Set-ADAccountPassword -Identity $fresh.DistinguishedName -NewPassword $secure -Reset @adParams
        Set-ADUser -Identity $fresh.DistinguishedName -CannotChangePassword $true -ChangePasswordAtLogon $false @adParams
        Write-Log $txtLog "Password reset to a random 30-character value; user cannot change it."

        # 6. Disable account
        Disable-ADAccount -Identity $fresh.DistinguishedName @adParams
        Write-Log $txtLog "Account disabled."

        # 7. Move to Disabled Users OU
        $currentParentOU = ($fresh.DistinguishedName -split ',',2)[1]
        if ($currentParentOU -eq $Config.DisabledOU) {
            Write-Log $txtLog "Object is already in the Disabled Users OU; skipping move."
        } else {
            Move-ADObject -Identity $fresh.DistinguishedName -TargetPath $Config.DisabledOU @adParams
            Write-Log $txtLog "Moved object to: $($Config.DisabledOU)"
        }

        # 8. Optional AD replication
        if ($doAdSync) {
            Write-Log $txtLog "Forcing AD replication (repadmin /syncall)..."
            $targetDc = if ($dc) { $dc } else {
                try { (Get-ADDomainController -Discover -Service PrimaryDC -ErrorAction Stop).HostName }
                catch { $env:LOGONSERVER.TrimStart('\') }
            }
            $repOutput = & repadmin /syncall $targetDc /AdeP 2>&1
            Write-Log $txtLog ($repOutput -join "`r`n")
        }

        # 9. Optional Azure AD Connect delta sync
        if ($doAzureSync) {
            Write-Log $txtLog "Triggering Azure AD Connect delta sync on $aadServer..."
            try {
                Invoke-Command -ComputerName $aadServer -ScriptBlock {
                    Import-Module ADSync -ErrorAction Stop
                    Start-ADSyncSyncCycle -PolicyType Delta
                } -ErrorAction Stop
                Write-Log $txtLog "Azure AD Connect delta sync triggered."
            } catch {
                Write-Log $txtLog "WARNING: Azure AD Connect delta sync failed: $($_.Exception.Message)"
            }
        }

        Write-Log $txtLog "=== Offboarding complete for $($user.SamAccountName) ==="

        try { Set-Clipboard -Value $newPassword } catch { }
        [System.Windows.Forms.MessageBox]::Show(
            "Offboarding complete for $($user.SamAccountName).`r`n`r`nNew password (copied to clipboard, not stored anywhere):`r`n$newPassword",
            "Done", "OK", "Information") | Out-Null

        # Reset state so the same user can't be re-processed by accident
        $script:selectedUser = $null
        $lstGroups.Items.Clear()
        $lblName.Text = $lblSam.Text = $lblOU.Text = $lblManager.Text = $lblStatus.Text = "-"
    }
    catch {
        Write-Log $txtLog "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Offboarding stopped due to an error:`r`n$($_.Exception.Message)`r`n`r`nCheck the activity log - some steps may have already completed.","Error","OK","Error") | Out-Null
        $btnOffboard.Enabled = $true
    }
})

$btnClose.Add_