# https://adventofcode.com/2023

$puzzleInput = @"
1000_lines_of_puzzle_input
"@

$arrayOfStrings = $puzzleInput -split "`r`n" # split huge string into individual array of strings by splitting by "line break"


$spelledNumbers = @("one","two","three","four","five","six","seven","eight","nine")
$finalSum = 0

foreach($string in $arrayOfStrings){
    $charArray = $string.ToCharArray() # char -> array
    $digits = New-Object System.Collections.ArrayList 

    foreach($number in $spelledNumbers){
        $firstIndex = $string.IndexOf($number) # the thing is this doesnt account for the string being there multiple times... e.g. eightninemfpxcbkzkj1ninelv
        # but first and last values are most important...                                                                                ^              ^
        # maybe if .LastIndexOf is a different index, we should store it also. Let's see if that is "good enough"
        $lastIndex = $string.LastIndexOf($number) 

        if($firstIndex -ne -1){
            $obj = [PSCustomObject]@{
                Value = $number.replace("one",1).replace("two",2).replace("three",3).replace("four",4).replace("five",5).replace("six",6).replace("seven",7).replace("eight",8).replace("nine",9)
                Index = $firstIndex # gonna use the stored indexes for sorting digits to get first/last
            }

            $digits.Add($obj) | Out-Null 
        }

        if(($lastIndex -ne -1) -and ($firstIndex -ne $lastIndex)){
            $obj = [PSCustomObject]@{
                Value = $number.replace("one",1).replace("two",2).replace("three",3).replace("four",4).replace("five",5).replace("six",6).replace("seven",7).replace("eight",8).replace("nine",9)
                Index = $lastIndex
            }

            $digits.Add($obj) | Out-Null 
        }
    }
    
    for($i = 0; $i -lt $string.Length; $i++){
        $char = $string[$i].ToString() # i dont know why this is needed but i cant get it to match in the expression below without doing this?

        switch($char){
            {$_ -in @(0..9)}{ 
                $obj = [PSCustomObject]@{
                    Value = $char
                    Index = $i
                }

                $digits.Add($obj) | Out-Null 
            }
        }
    }

    $orderedDigits = ($digits | Sort-Object -Property index).value

    [int]$firstAndLastDigits = "$($orderedDigits[0])$($orderedDigits[-1])"

    [int]$finalSum = ($finalSum + $firstAndLastDigits)
    
}

$finalSum
