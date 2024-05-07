# https://adventofcode.com/2023

$puzzleInput = @"
1000_lines_of_puzzle_input
"@

$arrayOfStrings = $puzzleInput -split "`r`n" # split huge string into individual array of strings by splitting by "line break"

$finalSum = 0

foreach($string in $arrayOfStrings)
{
    $charArray = $string.ToCharArray() # char -> array
    $digits = New-Object System.Collections.ArrayList 
     
    foreach($char in $charArray)
    {
        $char = $char.ToString() # i dont know why this is needed but i cant get it to match in the expression below without doing this?

        switch($char)
        {
            {$_ -in @(0..9)} { $digits.Add($char) | Out-Null }
        }
    }

    [int]$firstAndLastDigits = "$($digits[0])$($digits[-1])"

    [int]$finalSum = ($finalSum + $firstAndLastDigits)
    
}

$finalSum
