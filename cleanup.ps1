del c:\imagetemp -recurse
del C:\SMSTSLog -recurse -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "PostImageCleanup" -Confirm:$false

############ Log out all Users ############

$first = 1
quser | ForEach-Object {
    if ($first -eq 1) {
        $userPos = $_.IndexOf("USERNAME")
        $sessionPos = $_.IndexOf("SESSIONNAME")
        $idPos = $_.IndexOf("ID")
        $statePos = $_.IndexOf("STATE")
        $first = 0
    }
    else {
        $user = $_.substring($userPos,$sessionPos-$userPos).Trim()
        $session = $_.substring($sessionPos,$idPos-$sessionPos).Trim()
        $id = $_.substring($idPos,$statePos-$idPos).Trim()
        Write-Output "Logging off user:$user session:$session id:$id"
        logoff $id
    }
}

###### Hide last user ###############

$command =  "reg delete HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI /v LastLoggedOnUser /f"
invoke-expression -command $command

$command =  "reg delete HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI /v LastLoggedOnUserSID /f"
invoke-expression -command $command

$command =  "reg add HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI /v LastLoggedOnUser"
invoke-expression -command $command

$command =  "reg add HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI /v LastLoggedOnUserSID"
invoke-expression -command $command

########################  Remove all Profiles  ################################

### Find all the user profiles not system #####
$localProfiles = Get-CimInstance -ClassName Win32_UserProfile |where special -like "$False"
$userprofiles = split-path -path $localprofiles.LocalPath -leaf

### Find all the local users#####
$localusers = get-localuser

####   Select ONLY the Domain account Profiles
$DomainProfiles = diff $localusers.name $Userprofiles | where-object SideIndicator -eq "=>" |select InputObject -expandproperty InputObject

#remove each domain profile
foreach ($profile in $DomainProfiles) { write-host "Removing profile of $profile"
Get-CimInstance -Class Win32_UserProfile | Where-Object { $_.LocalPath.split('\')[-1] -eq $profile } | Remove-CimInstance}


Remove-Item –path C:\ImageTemp –recurse -force
stop-computer -force