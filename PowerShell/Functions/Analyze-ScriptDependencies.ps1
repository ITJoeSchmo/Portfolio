<#
.SYNOPSIS
    Analyzes all PowerShell scripts in a specified directory and identifies unique command dependencies used in each script.

.DESCRIPTION
    This runbook scans through all `.ps1` script files in a user-specified directory.
    It parses each script's Abstract Syntax Tree (AST) to extract unique command names used.
    It then retrieves the associated module source and required modules for each command.
    The identified dependencies are compiled, displayed, and exported to a CSV file for reporting or auditing purposes.

.PARAMETER scriptsPath
    The full path to the directory containing the PowerShell (.ps1) scripts to analyze.
    This is an interactive input prompted from the user using Read-Host.

.EXAMPLE
    PS C:\> .\Analyze-ScriptDependencies.ps1
    Input full path to folder containing .ps1 files to analyze: C:\Scripts
    Dependencies identified:
    Microsoft.PowerShell.Utility
    Az.Accounts
    ...

    This example prompts the user to input a path and then analyzes all `.ps1` files in that folder.

.NOTES
    Author: Joey Eckelbarger
    Output File: ps1_dependencies.csv
    Purpose: Supports auditing and dependency tracking for PowerShell automation scripts.
#>


$scriptsPath = Read-Host "Input full path to folder containing .ps1 files to analyze"
$scripts = Get-ChildItem -Path $scriptsPath -Filter "*.ps1"

$dependenciesUsed = foreach($script in $scripts){
    $scriptFile = $script.FullName
    $scriptblock = [scriptblock]::Create((Get-Content -raw -Path $scriptFile))

    $ast = $scriptblock.Ast

    $commands = $ast.FindAll( { $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)
    $commandText = foreach ($command in $commands) {
        $command.CommandElements[0].Extent.Text
    }

    $commandText | 
        Select-Object -Unique | 
        Sort-Object |
        Select-Object @{
            Label      = "Environment"
            Expression = { "AzureAutomation " }
        },
        @{
            Label      = "Script"
            Expression = {$script.Name}
        },
        @{
            Label      = "CommandName"
            Expression = { $_ } 
        },   
        @{
            Label      = "Source"
            Expression = { 
                (Get-Command $_).Source
            } 
        },
        @{
            Label      = "RequiredModules"
            Expression = { 
                (Get-Module $((Get-Command $_).Source)).RequiredModules
            } 
        }
}

Write-output "Dependencies identified:"
$($dependenciesUsed.Source + $dependenciesUsed.RequiredModules.Name) | Sort-Object -Unique

$dependenciesUsed = $dependenciesUsed | Sort -unique
$dependenciesUsed | Export-csv "ps1_dependencies.csv" -NoTypeInformation
