<#
.SYNOPSIS
    Generates a cryptographically secure random password and returns a PSCredential object.

.DESCRIPTION
    The New-SecurePassword function generates a cryptographically secure random password using the .NET [System.Security.Cryptography.RandomNumberGenerator]::Create() method.
    It returns a PSCredential object containing the generated password. The function allows customization of the password length, character set, and minimum character count per type (e.g., uppercase, lowercase, numbers, special characters).
    Additionally, it can include a username for which the credential is being created.

.PARAMETER length
    Specifies the length of the generated password.
	Default:  65
    Type:     Int
    Required: True
    Position: 0

.PARAMETER characterSet
    Specifies the set of characters to use when generating the password.
	Default:  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?',
    Type:     String
    Required: False
    Position: 1

.PARAMETER minimumCharacterCountPerType
    Specifies the minimum number of each character type (e.g., uppercase, lowercase, numbers, special characters) that must be included in the password.
    Default:  3
	Type:     Integer
    Required: False
    Position: 2

.PARAMETER username
    Specifies the username for which the PSCredential object is being created.
	Default:  " "
    Type:     String
    Required: False
    Position: 3
	
.EXAMPLE
    New-SecurePassword -length 16 -username 'admin'
    Description: Generates a 16-character long password using the default character set for the user 'admin' containing at least 3 of each character type.

.NOTES
    Author: Joey Eckelbarger
#>

function New-SecurePassword {
    [CmdletBinding()]
    param (
        [int]$length = 65,
        [string]$characterSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?',
        [int]$minCharCountPerType = 3, # minimum uppercase, lowercase, number, and symbols a generated pwd should have,
        [string]$userName = " "        # you can set a username for the returned PSCredential, may be helpful in some cases
    )                                  # it is easier to decrypt a password from a [PSCredential] than it is from a [SecureString]
                                       # $credential.GetNetworkCredential().Password 

    # labeled continue allows re-generation if criteria is not met
    :retry while($true){

        # initialize byte array sized for desired pwd length
        $bytes = [byte[]]::new($length)

        # System.Security.Cryptography.RandomNumberGenerator ensures cryptographically secure randomness to follow best practice

        # Cryptographically secure randomness: generation of random values in such a way that it's infeasible to predict future values
        # based on past or present ones, even with knowledge of the system's state. This level of randomness is crucial for 
        # security-related tasks, such as generating encryption keys, tokens, or secure passwords where predictability could lead to vulnerabilities.

        # There is a built-in Method within .NET [System.Web.Security.Membership]::GeneratePassword() but it is not available in .NET Core which is why I chose this route. 
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes) # populate the byte array w/ random values 

        # Convert each byte to a character from the character set to form the password
        $password = ($bytes | ForEach-Object { $CharacterSet[$_ % $CharacterSet.Length] }) -join ''

        # Define character classes
        $lowerCasePattern = "[a-z]"
        $upperCasePattern = "[A-Z]"
        $numberPattern    = "\d"
        $symbolPattern    = "[\W_]"

        # evaluate # of each char in the generated password to ensure it meets our criteria
        # logic is: after removing the specified chars, the string length should be less than the password length minus the minimum char count ($minCharCountPerType)
        # e.g. evaluate p4$$w0rd for a minimum of 2 numbers: p4$$w0rd (8 char) -> p$$wrd (6 char) = 2 char difference, so there are 2 numbers -> $true
        $Lower   = ($Password -creplace $lowerCasePattern,'').Length -le ($Password.Length - $minCharCountPerType)
        $Upper   = ($Password -creplace $upperCasePattern,'').Length -le ($Password.Length - $minCharCountPerType)
        $Number = ($Password -replace $numberPattern,    '').Length -le ($Password.Length - $minCharCountPerType)
        $Symbol = ($Password -replace $symbolPattern,    '').Length -le ($Password.Length - $minCharCountPerType)

        $passwordMeetsAllCriteria = $Lower -and $Upper -and $Number -and $Symbol

        if(-Not $passwordMeetsAllCriteria){
            Write-Output "Generated password did not contain the minimum of $($minCharCountPerType) of each character types: lower, special, and numerical. Regenerating..."
            continue retry # restart loop; this jumps back to :retry 
        }
        
        $password = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($userName, $password)
        $password = $null

        return $credential
    }
}
