<#==============================================================
This version of the script deletes files older than 6 months
but not folders and  writes to a log file.
This is meant to run unattended
===============================================================#>

$path = "D:\Temp"
$thresholdDays = 180
$timestamp = Get-Date -Format "MMddyyyy_HHmmss"
$thresholdDate = (Get-Date).AddDays(-$thresholdDays)

# Log file paths w/ timestamp
$deletedItemsLog = "D:\Logs\Deleted_$timestamp.log"
$failedToDeleteLog = "D:\Logs\FailedtoDelete_$timestamp.log"

#Find files to delete and exclude folders
$filesToDelete = Get-ChildItem -Path $path -Recurse | Where-Object {
    -not $_.PSIsContainer -and
    $_.LastWriteTime -lt $thresholdDate
}

#Delete files and log results
foreach ($file in $filesToDelete) {
    try {
        Remove-Item $file.FullName -Force
        Add-Content -Path $deletedItemsLog -Value "Deleted: $($file.FullName)"
    } catch {
        $errorMessage = "Error deleting: $($file.FullName) - $_"
        Add-Content -Path $failedToDeleteLog -Value $errorMessage
    }
}

#Completed Logs
$completedLog = "D:\Logs\ScriptCompletion_$timestamp.log"
Add-Content -Path $completedLog -Value "Script completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
