  <#

written by Joey Eckelbarger to support MSGraph cmdlet for email + recreated the email HTML completely 2024 + fixed the stock photo

.SYNOPSIS – Compose and send an HTML formatted email

.DESCRIPTION – This runbook crafts an email from inputs and some basic HTMl.  It uses authsmtp to send this email.   

.PARAMETER Sender - This is the account that will appear in the from field. 

.PARAMETER Recipients - This is a list of email accounts that will recieve the message

.PARAMETER Subject - This is what will appear in the subject of the message.

.PARAMETER Body - This is what will appear in the default body of the email

.PARAMETER Body2 - This is what will appear in a second optional section of the body of the email.

.PARAMETER Header - This is an optional header that can be added to the email above the body.  

.PARAMETER Attachment - String path to an attachment for the file.  

#>
 
 Param (

    [Parameter(mandatory=$false)]
    [string]$SenderUserEntraID = "a417acdb-5e30-472d-b3e5-a8409ea380a4", # Cloud-based service account UserID to send email from

    [Parameter(Mandatory=$true)]
    [array]$Recipients,

    [Parameter(Mandatory=$false)]
    [array]$ccRecipients,

    [Parameter(Mandatory=$true)]
    [string]$Subject,

    [Parameter(Mandatory=$false)]
    [string]$Header,

    [Parameter(Mandatory=$true)]
    [string]$Body,

    [Parameter(Mandatory=$false)]
    [string]$Header2,

    [Parameter(Mandatory=$false)]
    [string]$Body2,

    [Parameter(Mandatory=$false)]
    $Attachment

)

Write-Output "New-EmailMessage: Sending email as Entra User $($SenderUserEntraID)"

Connect-MgGraph -Identity -NoWelcome

# Build HTML for email
$html  = @() 
$html += @'
<!DOCTYPE html>
<html>
<head>
    <title>Automated IT Email</title>
    <style>
        body { font-family: Arial, sans-serif; font-size: 14px; color: #333; margin: 0; padding: 0; }
        .section { background: #f0f0f0; width: 80%; margin: auto; padding: 20px; box-sizing: border-box; }
        .body { background: #ffffff; width: 80%; box-sizing: border-box; }
        img.organization-image { max-width: 100%; height: auto; }
        .disclaimer, .signature { font-size: 12px; color: #666; font-style: italic; font-weight: bold;}
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
        /* Added styles for table layout */
        .logo-table { text-align: center; width: 100%; background: #f0f0f0; }
        .logo-table td { background: #f0f0f0; }
    </style>
</head>
<body>
    <div class="body">
'@

$Bodies  = @($body,$body2)
$Headers = @($header,$header2)

# insert headers/bodies to html
for ($i=0; $i -lt $Bodies.Count; $i++){
  $htmlToAdd = @"
    <div class="body-section">
      <h2>{0}</h2>
      <p>{1}</p>
    </div>
"@ -f $headers[$i], $bodies[$i] # format string: {0} is replaced with 1st arg, {1} replaced with 2nd arg, etc. 

  $html += $htmlToAdd
}

$html += @"
</div>
    <div class="section">
        <table class="logo-table">
            <p class="disclaimer">
                This inbox is not monitored. Please do not reply to this email.
                <br>
                Contact <a href="mailto:it_team_dl@domain.com">IT Team</a> for more information.
            </p>
            <tr>
                <td>
                    <img src="cid:image001.png" alt="Logo" class="organization-image">
                </td>
            </tr>
            <tr>
                <td>
                    Information Technology
                    <br>
                    Team Name
                </td>
            </tr>
            <br>
        </table>
    </div>
</body>
</html>
"@

# Convert all parts to single html block string
$htmlBody = $html -join "`n" # the `n is not necessary, but keeps html neat so we can take it into an editor for tweaking later if needed
                         # e.g. set-clipboard $html after executing the above and then paste into VSCode for previewing the email 

# loop through all params and build their objects for MS Graph

foreach($recipient in $Recipients){
  $hashtable = @{
    emailAddress = @{
      address = $recipient
    }
  } 
  [array]$toRecipientsBodyParam += $hashtable
}

foreach($recipient in $ccRecipients){
  $hashtable = @{
    emailAddress = @{
      address = $recipient
    }
  } 
  [array]$ccRecipientsBodyParam += $hashtable
}

foreach($file in $Attachment){
  if(Test-Path($file)){
    $fileName = (Get-Item -Path $file).Name
    $filePath = (Get-Item -Path $file).FullName

    $base64string = [Convert]::ToBase64String([IO.File]::ReadAllBytes($filePath))

    $hashtable = @{
      "@odata.type" = "#microsoft.graph.fileAttachment"
      name = $fileName
      contentBytes = $base64string
    } 
  
    [array]$attachmentsBodyParam += $hashtable
  } else {
    Write-Warning "Test-Path on $file returned false (file inaccessible); skipping attachment"
  }
}

# include stock photo vis base64 string rather than specifying a file path (much more flexible w/o relying on network or file shares, etc)
$emailPhotoBase64string = @"
<base_64_here>
"@

$hashtable = @{
  "@odata.type" = "#microsoft.graph.fileAttachment"
  name = "image001.png"
  contentBytes = $emailPhotoBase64string
} 

[array]$attachmentsBodyParam += $hashtable

$params = @{
	message = @{
		subject = $Subject

		body = @{
			contentType = "HTML"
			content = $htmlBody
		}

		toRecipients = @(
            $toRecipientsBodyParam
		)

        ccRecipients = @(
            $ccRecipientsBodyParam
		)

		attachments = @(
            $attachmentsBodyParam
		)
	}
}

Send-MgUserMail -UserId $SenderUserEntraID -BodyParameter $params
