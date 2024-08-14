<#=====================================================================================================================
 Script Name: IISLogCleanup.ps1
 Description: Will cleanup all but last 30 days of logs on IIS server.  Time frame can be adjusted to 
 meet your needs
=====================================================================================================================#>

#$OutputPath = "C:\IIS\Cleanup_Old_logs.log"
$LogPath = "C:\inetpub\logs"
$maxDaystoKeep = -30
Get-ChildItem -Path $LogPath -Recurse  | Where-Object { ! $_.PSIsContainer } | Where-Object LastWriteTime -lt ((get-date).AddDays($MaxDaystoKeep)) | Remove-Item
