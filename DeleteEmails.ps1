<#=====================================================================================================================
 Script Name: DelEmails.ps1
 Description: Logs into the Security & Compliance portal, creates a Compliance Search, then deletes emails that match
      Inputs: From, Subject
       Notes: This script will delete an email from any mailbox that has it. It can be recovered if the user needs it.
=======================================================================================================================
Variable List - in the section following this one, edit these variables with your preferences:
   VARIABLE NAME    DESCRIPTION
   ---------------  ----------------------------------------------------------------------------------------------------
   $UserCredential  Stores the password for this user
   $Date            Looks 2 days back for email. Edit the number if you need to go back more: (get-date).adddays(-2);
   $SearchFrom      What was the Sender Email Address
   $SearchSubject   What was the Email Subject
   $SearchName      Creates a name for the search using "$SearchFrom $SearchSubject"
   $User            Office 365 Global Admin account or one with sufficient rights to run script
=====================================================================================================================#>
$User = "bfeeley@provenit.com"
$UserCredential = Get-Credential -Message "Security and Compliance Center Credentials" -User $User
Connect-ExchangeOnline -UserPrincipalName $User
Connect-IPPSSession -Credential $UserCredential

$Date = (get-date).adddays(-5);
$Date = $Date.ToShortDateString();
$Date = [scriptblock]::create($Date);

Do {
	CLEAR

	Write-Host "Compliance Search Criteria" -ForegroundColor Green
	$SearchFrom = Read-Host "Enter Sender Email Address"
	$SearchSubject = Read-Host "Enter Email Subject"
	$SearchName = "$SearchFrom $SearchSubject"

	Write-Host "Creating a new Compliance Search using the following:"
	Write-Host "Search name: " -NoNewLine
	Write-Host "$SearchName" -ForegroundColor Green

	Write-Host "Searching for an email from: " -NoNewLine
	Write-Host "$SearchFrom" -ForegroundColor Green

	Write-Host "With the subject: " -NoNewLine
	Write-Host "$SearchSubject" -ForegroundColor Green

	Write-Host "Sent on or after: " -NoNewLine
	Write-Host "$Date" -ForegroundColor Green

	New-ComplianceSearch -name $SearchName -ExchangeLocation all -ContentMatchQuery "(Subject:$SearchSubject) AND (From:$SearchFrom) AND (Received >= $Date)"
	Start-ComplianceSearch -Identity $SearchName

#Check search status until completed
	While ( $true ) 
    {
		$Search = Get-ComplianceSearch -Identity $SearchName
		If ( $Search.status -eq 'Completed' ) 
            {
			    Write-Host "The search is completed."
			    BREAK
			}
			Else 
            {
			    Write-Host "Waiting 30 seconds to check if the search is complete..."
			    Start-Sleep -s 30
		    }
	}

#Review search results
	$ComplianceSearch = Get-ComplianceSearch -Identity $SearchName
	$FoundResults = $ComplianceSearch.SuccessResults
	$Array = $FoundResults.Split([Environment]::NewLine,[System.StringSplitOptions]::RemoveEmptyEntries) | Where {$_ -notlike "*Item count: 0*"}

Write-host "`Search results:"
If ($Array.Count -eq 0) 
    {
        Write-Host "0 items have been found."
    }
Else {
        $Array
    }

	$DelMatchingEmails = Read-Host "`Ready to purge the offending emails? Y/N"
	If ( $DelMatchingEmails -eq "Y" )
		{
            Write-Host "Purging... One moment please..."
			New-ComplianceSearchAction -SearchName $SearchName -Purge -PurgeType SoftDelete

#Check purge status
		while ( $true ) {
			$SearchPurge = Get-ComplianceSearchAction -Identity $SearchName'_Purge'
			If ( $SearchPurge.status -eq 'Completed' ) 
            {
				Write-Host "The email has been deleted."
				BREAK
			}
			Else 
                {
				    Write-Host "Pausing for 30 seconds then checking email purge status..."
				    Start-Sleep -s 30
				}
		                }
		}
	Else
		{
        	Write-Host "As soon as possible, run this command to delete the offending emails as needed:"
        	Write-Host "New-ComplianceSearchAction -SearchName ""$SearchName"" -Purge -PurgeType SoftDelete"
	    }

$RunAgain = Read-Host "`Run this again? Y/N"
} While ($RunAgain -ne "N")

Write-Host "`Ending session..."
Get-PSSession | Remove-PSSession