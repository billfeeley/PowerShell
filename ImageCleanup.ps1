<#=====================================================================================================================
 Script Name: ImageCleanup.ps1
 Description: Cleans up a Windows PC after it's imaged
=======================================================================================================================#>


############ Log out all Users ############

$first = $true
quser | ForEach-Object {
    if ($first) {
        $userPos = $_.IndexOf("USERNAME")
        $sessionPos = $_.IndexOf("SESSIONNAME")
        $idPos = $_.IndexOf("ID")
        $statePos = $_.IndexOf("STATE")
        $first = $false
    } else {
        $user = $_.Substring($userPos, $sessionPos - $userPos).Trim()
        $session = $_.Substring($sessionPos, $idPos - $sessionPos).Trim()
        $id = $_.Substring($idPos, $statePos - $idPos).Trim()
        Write-Output "Logging off user: $user session: $session id: $id"
        logoff $id
    }
}

###### Hide last user ###############

$registryPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI"

$commands = @(
    "reg delete $registryPath /v LastLoggedOnUser /f",
    "reg delete $registryPath /v LastLoggedOnUserSID /f",
    "reg add $registryPath /v LastLoggedOnUser",
    "reg add $registryPath /v LastLoggedOnUserSID"
)

foreach ($command in $commands) {
    Invoke-Expression -Command $command
}

######################## Remove all Profiles ########################

### Find all the user profiles that are not system profiles #####
$localProfiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { -not $_.Special }
$userProfiles = $localProfiles | ForEach-Object { Split-Path -Path $_.LocalPath -Leaf }

### Find all the local users #####
$localUsers = Get-LocalUser

### Select ONLY the Domain account Profiles #####
$domainProfiles = Compare-Object $localUsers.Name $userProfiles | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject

# Remove each domain profile
foreach ($profile in $domainProfiles) {
    Write-Host "Removing profile of $profile"
    Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.LocalPath.Split('\')[-1] -eq $profile } | Remove-CimInstance
}
