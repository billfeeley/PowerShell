<#
.NAME
    OSD Janitor
.SYNOPSIS
    Post-deployment validation and cleanup tool for freshly imaged Windows workstations.
.NOTES
    Standalone script - no external image/icon/audio files required.
    Deployment note: the "Finalize Cleanup" button still relies on PostImageCleanup.xml
    (in this same folder) and the scheduled task action inside that XML points to
    C:\ImageTemp\OSDJanitor\cleanup.ps1 - make sure cleanup.ps1 is deployed to that path.
#>

#region Configuration - review/update these before deploying
$Script:Config = [ordered]@{
    # BIOS setup password to apply on HP devices if one isn't already set.
    # CHANGE THIS before deploying - do not ship the placeholder value.
    BiosAdminPassword     = 'CHANGE-ME-Set-A-Real-Password!'

    # Text to strip off the end of the distinguishedName when displaying OUs
    OUSuffixToStrip        = ',OU=Proven Business Systems,DC=simplyproven,DC=com'

    # Security agent service names used for the Security Agents checklist
    CrowdStrikeServiceName = 'CSFalconService'
    NinjaServiceName       = 'NinjaRMMAgent'

    # AD security groups every workstation should be a member of (checked against the computer object)
    IntuneUpdatesGroup     = 'Intune - Windows Update'
    PatchMyPCGroup         = 'Patch My PC - Third Party Updates'

    # Microsoft Graph delegated scopes for "Assign Primary User".
    # Requires one-time tenant admin consent for these scopes before this will work.
    GraphScopes            = @('DeviceManagementManagedDevices.ReadWrite.All', 'User.Read.All')

    # Where the finalize scheduled task definition lives
    CleanupTaskXml         = Join-Path $PSScriptRoot 'PostImageCleanup.xml'
}
#endregion

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

#region UI helper functions
function New-FormLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [switch]$Bold,
        [int]$Size = 10,
        [System.Drawing.Color]$Color,
        [bool]$AutoSize = $true
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $AutoSize
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    if ($Color) { $label.ForeColor = $Color }
    return $label
}

function New-FormButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 190,
        [int]$Height = 32,
        [bool]$Enabled = $true
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = $Height
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $button.Enabled = $Enabled
    return $button
}

function Set-StatusLabel {
    param(
        [System.Windows.Forms.Label]$Label,
        [bool]$Ok,
        [string]$OkText = 'OK',
        [string]$FailText = 'Missing'
    )
    if ($Ok) {
        $Label.Text = $OkText
        $Label.ForeColor = [System.Drawing.Color]::ForestGreen
    }
    else {
        $Label.Text = $FailText
        $Label.ForeColor = [System.Drawing.Color]::Firebrick
    }
    $Label.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
}
#endregion

#region Build form
$Form = New-Object System.Windows.Forms.Form
$Form.ClientSize = New-Object System.Drawing.Point(920, 600)
$Form.Text = 'OSD Janitor'
$Form.TopMost = $false
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$Form.MaximizeBox = $false

$TitleLabel = New-FormLabel -Text 'OSD Janitor' -X 20 -Y 15 -Bold -Size 24

$VersionLabel = New-FormLabel -Text 'Version 3.0' -X 820 -Y 575 -Size 9

# --- Identity info block ---
$HostnameCaption = New-FormLabel -Text 'Hostname:' -X 20 -Y 65 -Bold -Size 11
$HostnameValue = New-FormLabel -Text '' -X 140 -Y 65 -Size 11

$TimezoneCaption = New-FormLabel -Text 'Time Zone:' -X 20 -Y 90 -Bold -Size 11
$TimezoneValue = New-FormLabel -Text '' -X 140 -Y 90 -Size 11

$CurrentOUCaption = New-FormLabel -Text 'Current OU:' -X 20 -Y 115 -Bold -Size 11
$CurrentOUValue = New-FormLabel -Text '' -X 140 -Y 115 -Size 11

$ReqOUCaption = New-FormLabel -Text 'Req. OU:' -X 20 -Y 140 -Bold -Size 11
$ReqOUValue = New-FormLabel -Text '' -X 140 -Y 140 -Size 11

$MFGCaption = New-FormLabel -Text 'MFG:' -X 20 -Y 170 -Bold -Size 11
$MFGValue = New-FormLabel -Text '' -X 80 -Y 170 -Size 11

$ModelCaption = New-FormLabel -Text 'Model:' -X 20 -Y 195 -Bold -Size 11
$ModelValue = New-FormLabel -Text '' -X 80 -Y 195 -Size 11

$AssetCaption = New-FormLabel -Text 'Asset Tag:' -X 20 -Y 220 -Bold -Size 11
$AssetValue = New-FormLabel -Text '' -X 100 -Y 220 -Size 11

# --- Device identity block (kept clear of the button column since these values are short) ---
$EntraCaption = New-FormLabel -Text 'Entra Joined:' -X 460 -Y 65 -Bold -Size 11
$EntraValue = New-FormLabel -Text 'Checking...' -X 590 -Y 65 -Size 11

$HybridCaption = New-FormLabel -Text 'Hybrid Joined:' -X 460 -Y 90 -Bold -Size 11
$HybridValue = New-FormLabel -Text 'Checking...' -X 590 -Y 90 -Size 11

$MDMCaption = New-FormLabel -Text 'MDM Enrolled:' -X 460 -Y 115 -Bold -Size 11
$MDMValue = New-FormLabel -Text 'Checking...' -X 590 -Y 115 -Size 11

$IntuneUpdatesCaption = New-FormLabel -Text 'Intune Updates:' -X 460 -Y 140 -Bold -Size 11
$IntuneUpdatesValue = New-FormLabel -Text 'Checking...' -X 590 -Y 140 -Size 11

$PatchMyPCCaption = New-FormLabel -Text 'Patch My PC:' -X 460 -Y 165 -Bold -Size 11
$PatchMyPCValue = New-FormLabel -Text 'Checking...' -X 590 -Y 165 -Size 11

# --- Post OSD Checklist panel ---
$ChecklistHeader = New-FormLabel -Text 'Post OSD Checklist' -X 20 -Y 258 -Bold -Size 14

$ChecklistPanel = New-Object System.Windows.Forms.Panel
$ChecklistPanel.Location = New-Object System.Drawing.Point(20, 290)
$ChecklistPanel.Width = 400
$ChecklistPanel.Height = 190
$ChecklistPanel.BorderStyle = 'FixedSingle'

$UpdatesCaption = New-FormLabel -Text 'Windows Updates' -X 20 -Y 15 -Size 10
$UpdatesStatus = New-FormLabel -Text 'Checking...' -X 250 -Y 15 -Size 10

$BiosPWCaption = New-FormLabel -Text 'BIOS Password Set' -X 20 -Y 57 -Size 10
$BiosPWStatus = New-FormLabel -Text 'Checking...' -X 250 -Y 57 -Size 10

$ProperOUCaption = New-FormLabel -Text 'Proper AD OU' -X 20 -Y 99 -Size 10
$ProperOUStatus = New-FormLabel -Text 'Checking...' -X 250 -Y 99 -Size 10

$BitlockerCaption = New-FormLabel -Text 'BitLocker Enabled' -X 20 -Y 141 -Size 10
$BitlockerStatus = New-FormLabel -Text 'Checking...' -X 250 -Y 141 -Size 10

$ChecklistPanel.Controls.AddRange(@($UpdatesCaption, $UpdatesStatus, $BiosPWCaption, $BiosPWStatus, $ProperOUCaption, $ProperOUStatus, $BitlockerCaption, $BitlockerStatus))

# --- Security Agents group ---
$SecurityGroup = New-Object System.Windows.Forms.GroupBox
$SecurityGroup.Text = 'Security Agents'
$SecurityGroup.Location = New-Object System.Drawing.Point(440, 290)
$SecurityGroup.Width = 210
$SecurityGroup.Height = 150

$CrowdStrikeCaption = New-FormLabel -Text 'CrowdStrike' -X 15 -Y 35 -Size 10
$CrowdStrikeStatus = New-FormLabel -Text 'Checking...' -X 130 -Y 35 -Size 10

$NinjaCaption = New-FormLabel -Text 'NinjaRMM' -X 15 -Y 75 -Size 10
$NinjaStatus = New-FormLabel -Text 'Checking...' -X 130 -Y 75 -Size 10

$SecurityGroup.Controls.AddRange(@($CrowdStrikeCaption, $CrowdStrikeStatus, $NinjaCaption, $NinjaStatus))

# --- Bottom action row ---
$Encrypt = New-FormButton -Text 'Encrypt' -X 20 -Y 500 -Width 110
$CLIUpdate = New-FormButton -Text 'CLI Updater' -X 140 -Y 500 -Width 140
$O365Update = New-FormButton -Text 'O365 Updates' -X 290 -Y 500 -Width 140
$Refresh = New-FormButton -Text 'Refresh' -X 440 -Y 500 -Width 110

$WaitMessage = New-FormLabel -Text 'Checking system, please wait...' -X 20 -Y 545 -Size 11
$WaitMessageStyle = [System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Italic
$WaitMessage.Font = New-Object System.Drawing.Font('Segoe UI', 11, $WaitMessageStyle)
$WaitMessage.Visible = $false

# --- Right-side action column ---
$CompanyPortalBtn = New-FormButton -Text 'Company Portal' -X 680 -Y 60 -Width 210
$SyncIntuneBtn = New-FormButton -Text 'Sync Intune' -X 680 -Y 105 -Width 210
$AssignPrimaryUserBtn = New-FormButton -Text 'Assign Primary User' -X 680 -Y 150 -Width 210
$GPUpdateBtn = New-FormButton -Text 'Group Policy Update' -X 680 -Y 195 -Width 210
$RebootBtn = New-FormButton -Text 'Force Reboot' -X 680 -Y 240 -Width 210
$FinalizeBtn = New-FormButton -Text 'Finalize Cleanup' -X 680 -Y 320 -Width 210 -Height 36
$FinalizeBtn.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#7ed321')

$Form.Controls.AddRange(@(
        $TitleLabel, $VersionLabel,
        $HostnameCaption, $HostnameValue, $TimezoneCaption, $TimezoneValue,
        $CurrentOUCaption, $CurrentOUValue, $ReqOUCaption, $ReqOUValue,
        $EntraCaption, $EntraValue, $HybridCaption, $HybridValue, $MDMCaption, $MDMValue,
        $IntuneUpdatesCaption, $IntuneUpdatesValue, $PatchMyPCCaption, $PatchMyPCValue,
        $MFGCaption, $MFGValue, $ModelCaption, $ModelValue, $AssetCaption, $AssetValue,
        $ChecklistHeader, $ChecklistPanel, $SecurityGroup,
        $Encrypt, $CLIUpdate, $O365Update, $Refresh, $WaitMessage,
        $CompanyPortalBtn, $SyncIntuneBtn, $AssignPrimaryUserBtn, $GPUpdateBtn, $RebootBtn, $FinalizeBtn
    ))

$CompanyPortalBtn.Add_Click({ ClickCompanyPortal })
$SyncIntuneBtn.Add_Click({ ClickSyncIntune })
$AssignPrimaryUserBtn.Add_Click({ ClickAssignPrimaryUser })
$GPUpdateBtn.Add_Click({ ClickGpupdate })
$RebootBtn.Add_Click({ ClickReboot })
$Encrypt.Add_Click({ ClickEncrypt })
$O365Update.Add_Click({ Click0365Updates })
$FinalizeBtn.Add_Click({ ClickFinalize })
$Refresh.Add_Click({ ClickRefresh })
$CLIUpdate.Add_Click({ ClickCLIUpdate })
#endregion

#region Logic
$Script:InstalledModules = Get-Module -ListAvailable | Select-Object Name, Version

function Get-BitlockerState {
    $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    if (-not $vol) { return 'Unknown' }
    if ($vol.ProtectionStatus -eq 'On' -and $vol.VolumeStatus -eq 'FullyEncrypted' -and $vol.EncryptionPercentage -eq 100) { return 'Encrypted' }
    if ($vol.ProtectionStatus -eq 'Off' -and $vol.VolumeStatus -eq 'FullyEncrypted' -and $vol.EncryptionPercentage -eq 100) { return 'Suspended' }
    if ($vol.VolumeStatus -like '*Decrypt*' -and $vol.EncryptionPercentage -lt 100 -and $vol.EncryptionPercentage -gt 0) { return 'Decrypting' }
    if ($vol.VolumeStatus -like '*Decrypt*' -and $vol.EncryptionPercentage -eq 0) { return 'FullyDecrypted' }
    if ($vol.VolumeStatus -like '*Encrypt*' -and $vol.EncryptionPercentage -lt 100) { return 'Encrypting' }
    return 'Unknown'
}

function Update-BasicInfo {
    $Script:HostnameText = hostname
    $HostnameValue.Text = $Script:HostnameText

    $TimezoneValue.Text = (Get-TimeZone).Id

    try {
        $ou = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\DataStore\Machine\0' -Name 'DNName' -ErrorAction Stop
        $ouMatch = [regex]::Match($ou, '(?=OU)(.*\n?)(?<=.)').Value
        $Script:CurrentOUText = $ouMatch.Replace($Script:Config.OUSuffixToStrip, '')
    }
    catch {
        $Script:CurrentOUText = 'Unavailable'
    }
    $CurrentOUValue.Text = $Script:CurrentOUText

    if (Test-Path 'C:\ImageTemp\DestinationOU.txt') {
        $desiredOU = Get-Content 'C:\ImageTemp\DestinationOU.txt'
        $desiredMatch = [regex]::Match($desiredOU, '(?=OU)(.*\n?)(?<=.)').Value
        $Script:ReqOUText = $desiredMatch.Replace($Script:Config.OUSuffixToStrip, '')
        $ReqOUValue.ForeColor = [System.Drawing.SystemColors]::ControlText
        $ReqOUValue.Text = $Script:ReqOUText
    }
    else {
        $Script:ReqOUText = $null
        $ReqOUValue.ForeColor = [System.Drawing.Color]::Firebrick
        $ReqOUValue.Text = 'Error: file not found'
    }

    Set-StatusLabel -Label $ProperOUStatus -Ok ($Script:ReqOUText -and ($Script:ReqOUText -eq $Script:CurrentOUText))

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $Script:MFGText = $cs.Manufacturer
    $MFGValue.Text = $Script:MFGText
    $ModelValue.Text = $cs.Model

    $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure
    $AssetValue.Text = $enclosure.SMBiosAssetTag

    if (-not (Test-Path 'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe')) {
        $O365Update.Enabled = $false
    }
}

function Update-SecurityAgents {
    $cs = Get-Service -Name $Script:Config.CrowdStrikeServiceName -ErrorAction SilentlyContinue
    Set-StatusLabel -Label $CrowdStrikeStatus -Ok ([bool]($cs -and $cs.Status -eq 'Running'))

    $ninja = Get-Service -Name $Script:Config.NinjaServiceName -ErrorAction SilentlyContinue
    Set-StatusLabel -Label $NinjaStatus -Ok ([bool]($ninja -and $ninja.Status -eq 'Running'))
}

function Update-DeviceIdentity {
    $dsreg = dsregcmd /status
    $azureAdJoined = [bool]($dsreg | Select-String 'AzureAdJoined\s*:\s*YES')
    $domainJoined = [bool]($dsreg | Select-String 'DomainJoined\s*:\s*YES')

    Set-StatusLabel -Label $EntraValue -Ok $azureAdJoined -OkText 'Yes' -FailText 'No'
    Set-StatusLabel -Label $HybridValue -Ok ($azureAdJoined -and $domainJoined) -OkText 'Yes' -FailText 'No'

    # Best-effort local check. This confirms the device has an active MDM enrollment record;
    # it does NOT confirm compliance policy state - verify that in Company Portal or the Intune console.
    $mdmEnrolled = $false
    $enrollmentsPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $enrollmentsPath) {
        $mdmEnrolled = [bool](Get-ChildItem $enrollmentsPath -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.EnrollmentState -eq 1 })
    }
    Set-StatusLabel -Label $MDMValue -Ok $mdmEnrolled -OkText 'Yes' -FailText 'No'

    Set-StatusLabel -Label $IntuneUpdatesValue -Ok (Test-ADGroupMembership -GroupName $Script:Config.IntuneUpdatesGroup) -OkText 'Yes' -FailText 'No'
    Set-StatusLabel -Label $PatchMyPCValue -Ok (Test-ADGroupMembership -GroupName $Script:Config.PatchMyPCGroup) -OkText 'Yes' -FailText 'No'
}

function Test-ADGroupMembership {
    param([string]$GroupName)
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$($env:COMPUTERNAME)$))"
        [void]$searcher.PropertiesToLoad.Add('memberOf')
        $result = $searcher.FindOne()
        if (-not $result) { return $false }

        foreach ($group in $result.Properties['memberof']) {
            if ($group -like "CN=$GroupName,*") { return $true }
        }
        return $false
    }
    catch {
        return $false
    }
}

function Update-BiosPasswordStatus {
    if ($Script:MFGText -eq 'HP') {
        if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
            try { Install-Module HPCMSL -Force -Scope AllUsers -AcceptLicense -ErrorAction Stop }
            catch { }
        }
        Import-Module HPCMSL -ErrorAction SilentlyContinue

        if (Get-Command Get-HPBIOSSetupPasswordIsSet -ErrorAction SilentlyContinue) {
            $isSet = Get-HPBIOSSetupPasswordIsSet
            if (-not $isSet) {
                try {
                    Set-HPBIOSSetupPasswordValue -NewPassword $Script:Config.BiosAdminPassword -ErrorAction Stop
                    $isSet = $true
                }
                catch {
                    $isSet = $false
                }
            }
            Set-StatusLabel -Label $BiosPWStatus -Ok $isSet
        }
        else {
            Set-StatusLabel -Label $BiosPWStatus -Ok $false -FailText 'HPCMSL unavailable'
        }
    }
    elseif ($Script:MFGText -like '*Dell*') {
        if (-not (Get-Module -ListAvailable -Name DellBIOSProvider)) {
            try { Install-Module DellBIOSProvider -Force -Scope AllUsers -ErrorAction Stop }
            catch { }
        }
        Import-Module DellBIOSProvider -ErrorAction SilentlyContinue
        $isSet = $false
        if (Test-Path 'DellSmbios:\Security') {
            $isSet = [bool](Get-Item -Path 'DellSmbios:\Security\IsAdminPasswordSet' -ErrorAction SilentlyContinue).CurrentValue
        }
        # Dell devices are detection-only for now - this tool does not set a Dell BIOS password.
        Set-StatusLabel -Label $BiosPWStatus -Ok $isSet -FailText 'Not set (Dell - set manually)'
    }
    else {
        Set-StatusLabel -Label $BiosPWStatus -Ok $false -FailText 'Unsupported MFG'
    }
}
#endregion

#region Buttons
function ClickAssignPrimaryUser {
    $upn = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the user's UPN (email) to set as this device's primary user:", 'Assign Primary User', '')
    if ([string]::IsNullOrWhiteSpace($upn)) { return }

    $requiredModules = 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.DeviceManagement'
    foreach ($m in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Install-Module $m -Force -Scope CurrentUser -ErrorAction SilentlyContinue
        }
        Import-Module $m -ErrorAction SilentlyContinue
    }

    try {
        Connect-MgGraph -Scopes $Script:Config.GraphScopes -NoWelcome -ErrorAction Stop

        $device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$($Script:HostnameText)'" -ErrorAction Stop | Select-Object -First 1
        if (-not $device) {
            Msg * "Device '$($Script:HostnameText)' was not found in Intune."
            return
        }

        $user = Get-MgUser -UserId $upn -ErrorAction Stop
        if (-not $user) {
            Msg * "User '$upn' was not found in Entra ID."
            return
        }

        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($user.Id)" }
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices('$($device.Id)')/users/`$ref" -Body $body

        Msg * "Primary user for '$($Script:HostnameText)' set to $upn."
    }
    catch {
        Msg * "Failed to assign primary user: $($_.Exception.Message)"
    }
}

function ClickSyncIntune {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -like '*EnterpriseMgmt*' -and $_.TaskName -eq 'PushLaunch' }
    if ($tasks) {
        $tasks | Start-ScheduledTask
        Msg * 'Intune sync triggered.'
    }
    else {
        Start-Process -FilePath "$env:windir\System32\deviceenroller.exe" -ArgumentList '/c', '/AutoEnrollMDM' -Wait
        Msg * 'No sync task was found on this device - re-triggered MDM enrollment instead.'
    }
}

function ClickCompanyPortal {
    $app = Get-StartApps | Where-Object { $_.Name -eq 'Company Portal' } | Select-Object -First 1
    if ($app) {
        Start-Process 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)"
    }
    else {
        Msg * 'Company Portal was not found on this device.'
    }
}

function ClickGpupdate { Start-Process cmd -ArgumentList '/c gpupdate' }

function ClickReboot { Shutdown /r /f /t 0 }

function ClickEncrypt {
    $state = Get-BitlockerState
    switch ($state) {
        'Suspended' { Resume-BitLocker -MountPoint 'C:' }
        'Decrypting' { manage-bde -on C: }
        'FullyDecrypted' { Enable-BitLocker -MountPoint 'C:' -EncryptionMethod XtsAes256 -RecoveryPasswordProtector -SkipHardwareTest }
        default { }
    }
    $pct = (Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue).EncryptionPercentage
    Msg * "BitLocker encryption is at $pct%"
}

function Start-VisibleUpdateWindow {
    param([string]$Command)
    $proc = Start-Process powershell -ArgumentList '-NoExit', '-Command', $Command -PassThru
    Start-Sleep -Milliseconds 750
    try { [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id) }
    catch { }
}

function ClickCLIUpdate {
    $modules = $Script:InstalledModules | Where-Object Name -eq 'PSWindowsUpdate'
    if ($modules) {
        Stop-Service -Name wuauserv
        Remove-Item 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv
        Start-Sleep 3
        Start-VisibleUpdateWindow -Command 'Install-WindowsUpdate -AcceptAll'
    }
    else {
        Install-PackageProvider NuGet -Force
        Install-PackageProvider PowerShellGet -Force
        Install-Module PSWindowsUpdate -Force
        Start-VisibleUpdateWindow -Command 'Install-WindowsUpdate -AcceptAll -MicrosoftUpdate'
    }
}

function Click0365Updates {
    $updateExe = 'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
    $updateArgs = '/update user updatepromptuser=False forceappshutdown=False displaylevel=False'
    Start-Process $updateExe $updateArgs
}

function Set-WaitMessage {
    param([string]$Text)
    $WaitMessage.Text = $Text
    # Pump the UI message queue so the window repaints and doesn't look frozen
    # during these longer checks (module installs, Windows Update search, LDAP lookups).
    [System.Windows.Forms.Application]::DoEvents()
}

function ClickRefresh {
    $WaitMessage.Visible = $true
    $Refresh.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    Set-WaitMessage 'Refreshing... checking for Windows updates'
    $modules = $Script:InstalledModules | Where-Object Name -eq 'PSWindowsUpdate'
    if ($modules) {
        $missing = (Get-WUList | Measure-Object).Count
    }
    else {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $missing = ($searcher.Search('IsHidden=0 and IsInstalled=0').Updates | Measure-Object).Count
    }
    Set-StatusLabel -Label $UpdatesStatus -Ok ($missing -eq 0) -OkText 'Up to date' -FailText "$missing missing"
    [System.Windows.Forms.Application]::DoEvents()

    Set-WaitMessage 'Refreshing... checking BIOS password'
    Update-BiosPasswordStatus
    [System.Windows.Forms.Application]::DoEvents()

    Set-WaitMessage 'Refreshing... checking BitLocker'
    $blOk = ((Get-BitlockerState) -eq 'Encrypted')
    Set-StatusLabel -Label $BitlockerStatus -Ok $blOk
    [System.Windows.Forms.Application]::DoEvents()

    Set-WaitMessage 'Refreshing... checking security agents'
    Update-SecurityAgents
    [System.Windows.Forms.Application]::DoEvents()

    Set-WaitMessage 'Refreshing... checking device identity'
    Update-DeviceIdentity
    [System.Windows.Forms.Application]::DoEvents()

    $Refresh.Enabled = $true
    $WaitMessage.Visible = $false
}

function ClickFinalize {
    if (-not (Test-Path $Script:Config.CleanupTaskXml)) {
        Msg * 'PostImageCleanup.xml was not found next to this script - cannot finalize.'
        return
    }

    Register-ScheduledTask -TaskName 'PostImageCleanup' -Xml (Get-Content $Script:Config.CleanupTaskXml -Raw) -Force | Out-Null

    $shortcut = "$env:Public\Desktop\OSD Janitor.lnk"
    if (Test-Path $shortcut) { Remove-Item $shortcut -Force -ErrorAction SilentlyContinue }

    $task = Get-ScheduledTask -TaskName 'PostImageCleanup' -ErrorAction SilentlyContinue
    if ($task) {
        Start-ScheduledTask -TaskName 'PostImageCleanup'
        Msg * 'Cleanup started - this PC will log off and restart shortly.'
    }
    else {
        Msg * 'Task creation failed.'
    }
}
#endregion

#region Startup
# Run the checks after the window is actually on screen instead of before ShowDialog(),
# so the GUI appears immediately instead of sitting invisible for however long the
# checks (module installs, Windows Update search, LDAP lookups) take to finish.
$Form.Add_Shown({
        Update-BasicInfo
        ClickRefresh
    })
[void]$Form.ShowDialog()
#endregion
