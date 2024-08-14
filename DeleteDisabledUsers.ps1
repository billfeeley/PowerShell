<#=====================================================================================================================
 Script Name: DisabledUserCleanup.ps1
 Author: Bill Feeley
 Description: Finds all disabled accounts older than 1 year and will purge them from Active Directory
 Requirements: Active Directory Module must be installed
=======================================================================================================================#>

$oneYearAgo = (Get-Date).AddDays(-365)
$oldUsers = Get-ADUser -Filter "Enabled -eq 'False' -and WhenChanged -le '$oneYearAgo'" -SearchBase "OU=Users Disabled,OU=Proven Business Systems,DC=simplyproven,DC=com" -Properties Name

foreach ($user in $oldUsers) {
    Remove-ADUser -Identity $user.DistinguishedName -Confirm:$false -Force -Verbose
}
