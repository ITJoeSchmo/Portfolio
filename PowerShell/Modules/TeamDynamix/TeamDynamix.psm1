<#
.SYNOPSIS
    Establishes a connection to the Team Dynamix API.

.DESCRIPTION
    The Connect-TDX function initiates a connection to the Team Dynamix API by authenticating with the provided URI and credentials. This connection is essential for performing further actions on the API, including retrieving and modifying data.

.PARAMETER URI
    The base URI of the Team Dynamix authentication API.

.PARAMETER Credential
    A PSCredential object containing the username and password for authentication with the Team Dynamix API.

.EXAMPLE
    PS C:\> Connect-TDX -URI "https://subdomain.teamdynamix.com/TDWebApi/api/auth" -Credential (Get-Credential)
    Establishes a session with the Team Dynamix API at the specified URI using the provided credentials.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 11/8/2024
#>
function Connect-TDX {
    param(
        [string]$URI = "https://services.ku.edu/TDWebApi/api/auth",
        [PSCredential]$Credential
    )

    $body = @{
        UserName = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json

    
    try {
        $script:TDXToken = Invoke-RestMethod -Method POST -Uri $URI -ContentType "application/json; charset=utf-8" -Body $Body -ErrorAction Stop | ConvertTo-SecureString -AsPlainText -Force
    } catch {
        Out-Error $_
    } finally {
        $body = $null
    }
}

<#
.SYNOPSIS
    Invokes a REST API method on the Team Dynamix API using a stored TDX token from Connect-TDX

.DESCRIPTION
    The Invoke-TDXRestMethod function allows for sending HTTP requests to the Team Dynamix API, supporting a variety of HTTP methods such as GET, POST, PUT, DELETE, PATCH, HEAD, and OPTIONS.
    It facilitates interaction with API endpoints and allows headers and body data to be specified as needed.

.PARAMETER URI
    The full URI for the API endpoint to which the request is sent.

.PARAMETER Method
    The HTTP method for the API request. Accepted values are GET, POST, PUT, DELETE, PATCH, HEAD, and OPTIONS.

.PARAMETER Headers
    A hashtable containing any headers required for the API request, such as authorization headers.

.PARAMETER Body
    Optional data to be included in the body of the request, such as JSON-formatted data for POST and PUT requests.

.EXAMPLE
    PS C:\> Invoke-TDXRestMethod -URI "https://teamdynamix.com/api/tickets" -Method GET
    Sends a GET request to the tickets endpoint with the provided authorization header.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 11/8/2024
#>
function Invoke-TDXRestMethod {
    param(
        [string]$URI,
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS")]
        [string]$Method,
        [hashtable]$Headers,
        $Body,
        [String]$ContentType = "application/json; charset=utf-8"
    )

    Test-AuthStatus

    if($Headers){
        $Headers.Add("Authorization", "Bearer $([PSCredential]::new("token", $($script:TDXToken)).GetNetworkCredential().Password)")
    } else {
        $Headers = @{"Authorization" = "Bearer $([PSCredential]::new("token", $($script:TDXToken)).GetNetworkCredential().Password)"}
    }

    Try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body -ContentType $ContentType -ErrorAction Stop 
    } Catch {
        Throw $_
    }
}

<#
.SYNOPSIS
    Updates a ticket in the Team Dynamix system with specified status, comments, and notifications.

.DESCRIPTION
    The Update-TDXTicket function allows for updating a Team Dynamix ticket's status, adding comments, setting notification recipients, and specifying various ticket options like privacy and communication settings. This function uses the Team Dynamix API to apply updates directly to the specified ticket.

.PARAMETER TicketID
    The unique identifier of the ticket to be updated.

.PARAMETER AppID
    The unique identifier of the application within Team Dynamix to which the ticket belongs.

.PARAMETER NewStatusID
    (Optional) The ID of the new status to set for the ticket. Leave blank or set to 0 if no status change is desired.

.PARAMETER CascadeStatus
    Specifies whether the status update should cascade to related entities. Defaults to `$false`.

.PARAMETER Comments
    Text comments to be added to the ticket's feed entry.

.PARAMETER Notify
    An array of strings specifying the email addresses to notify or special placeholders: 
    - "Requestor"   - The individual for whom the ticket is opened.
    - "Created"     - The user who opened the ticket.
    - "Responsible" - The group assigned to the ticket.
    - "Reviewer"    - The user assigned to the ticket
    If "Requestor", "Created", "Responsible", or "Reviewer" are provided, they will be replaced with the respective emails from the ticket data.

.PARAMETER IsPrivate
    Specifies whether the feed entry should be marked as private.

.PARAMETER IsRichHtml
    Indicates if the feed entry text is rich HTML or plain text.

.PARAMETER IsCommunication
    Marks the feed entry as a communication record if set to `$true`.

.EXAMPLE
    PS C:\> Update-TDXTicket -TicketID "12345" -AppID "67890" -NewStatusID 10 -CascadeStatus $true -Comments "Updated status and added notes" -Notify @("Requestor", "otheremail@example.com") -IsPrivate $false -IsRichHtml $true -IsCommunication $true

    Updates ticket 12345 with a new status ID, adds a comment, notifies the Requestor and an additional email, marks the entry as rich HTML, and sets it as a communication record.

.EXAMPLE
    PS C:\> Update-TDXTicket -TicketID "54321" -AppID "09876" -Comments "General update on ticket progress" -Notify @("Created", "Responsible") -IsPrivate $true

    Adds a private comment to ticket 54321, notifying the ticket creator and the responsible group.

.NOTES
    Author: Joey Eckelbarger
    Last Edit: 11/8/2024
#>
function Update-TDXTicket {
    param(
        [Parameter(Mandatory = $true)][string]$TicketID,
        [Parameter(Mandatory = $true)][string]$AppID,
        [String]$apiURI = "https://teamdynamix.com/TDWebApi/api",
        [Int32]$NewStatusID,
        [Boolean]$CascadeStatus = $false,
        [string]$Comments,
        [string[]]$Notify, # Requestor = who ticket is for, Created = who opened ticket, Responsible = group assigned to ticket -- will be replaced with the email for each from the ticket 
        [Boolean]$IsPrivate,
        [Boolean]$IsRichHtml,
        [Boolean]$IsCommunication
    )

    Test-AuthStatus

    if(($notify -contains "Requestor") -or ($notify -contains "Created") -or ($notify -contains "Responsible") -or ($notify -contains "Reviewer")){
        $replaceableStrings = "Requestor", "Created", "Responsible", "Reviewer"
        
        $ticket = Invoke-TDXRestMethod -uri "$apiURI/$AppID/tickets/$TicketID" -method GET
        foreach($user in $notify){
            if($user -in $replaceableStrings){
                $notify = $notify.Replace($user, $ticket."$($user)Email")
            }
        }
        # remove potential dupes 
        $notify = $notify | Sort-Object -unique
    }

    $Body = @{
        NewStatusID     = $NewStatusID
        CascadeStatus   = $CascadeStatus
        Comments        = $Comments
        Notify          = $Notify
        IsPrivate       = $IsPrivate
        IsRichHtml      = $IsRichHtml
        IsCommunication = $IsCommunication
    } | ConvertTo-Json

    Invoke-TDXRestMethod -URI "$apiURI/$AppID/tickets/$TicketID/feed" -Method POST -Body $Body
}


<#
 .Description
   Used to verify authentication has occured when a function is ran, and automatically auth if identified as in one of our platforms
#>
function Test-AuthStatus {
    # if not auth'd + we are in an automation environment 
    if(-Not $script:TDXToken -and ($env:PSPrivateMetadata -or $PSPrivateMetadata.JobId -or $sessionvars.ProcessLoggingHelper.ScriptPath)){
        $tdxCredential = Get-VaultSecret -enginepath "it_infra/kv" -secretpath "teamdynamix/tdx/tdx-it-infra-api" -KeyName "tdx-it-infra-api"

        Connect-TDX -Credential $tdxCredential
    }

    # if both vars are now populated, break out of func w/o error and continue execution
    if($script:TDXToken){
        return
    } else { 
        Write-Warning "No authentication detected; please authenticate TDX w/ Connect-TDX"
    }
}
