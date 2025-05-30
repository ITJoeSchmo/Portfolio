
<#
.SYNOPSIS
    Creates a new temporary directory with an optional suffix and subdirectories.

.DESCRIPTION
    The New-TemporaryDirectory function generates a temporary directory in the system's temporary folder using a GUID as the base name. You can optionally append a suffix to the directory name and create multiple subdirectories inside it.

.PARAMETER suffix
    An optional string that will be appended as a suffix to the directory name. If not provided, the directory will be named solely using the GUID.

.PARAMETER subdirectories
    An optional array of subdirectory names. These directories will be created inside the newly generated temporary directory. If no subdirectories are specified, only the base temporary directory is created.

.EXAMPLE
    PS C:\> New-TemporaryDirectory -suffix "test"
    
    Creates a temporary directory with a GUID as the base name and ".test" as the suffix. For example: C:\Users\User\AppData\Local\Temp\1234abcd.test

.EXAMPLE
    PS C:\> New-TemporaryDirectory -subdirectories "logs", "data"
    
    Creates a temporary directory and two subdirectories, "logs" and "data", within it. For example:
    C:\Users\User\AppData\Local\Temp\1234abcd\logs
    C:\Users\User\AppData\Local\Temp\1234abcd\data

.EXAMPLE
    PS C:\> New-TemporaryDirectory -suffix "backup" -subdirectories "config", "scripts"
    
    Creates a temporary directory with the suffix ".backup" and two subdirectories "config" and "scripts" inside it.

.RETURNS
    System.IO.DirectoryInfo object representing the parent folder.

.NOTES
    Author: https://stackoverflow.com/users/27581/michael-kropat found @ https://stackoverflow.com/questions/34559553/create-a-temporary-directory-in-powershell
    
    9-20-2024 Joey Eckelbarger: Added suffix,subdirectories params 
#>

function New-TemporaryDirectory {
    param(
        [string]$suffix,
        [string[]]$subdirectories
    )

    $tmp = [System.IO.Path]::GetTempPath() # Not $env:TEMP, see https://stackoverflow.com/a/946017
    $name = (New-Guid).ToString("N")
    if($suffix){
        $name = $name + "." + $suffix
    }
    $parentFolder = New-Item -ItemType Directory -Path (Join-Path $tmp $name)

    foreach($subdirectory in $subdirectories){
        $subdir = New-Item -ItemType Directory -Path (Join-Path $parentFolder.FullName $subdirectory)
    }
    return $parentFolder
}
