# this snippet schedules a reboot at 1 AM; the task also deletes itself once it finishes executing 
# used to quickly/remotely schedule a reboot after resolving patch issues on an endpoint

$1amTomorrow = (Get-Date -Hour 1 -Minute 0 -Second 0 -Millisecond 0).AddDays(1)
$actions = (New-ScheduledTaskAction -Execute "shutdown" -Argument "/r /t 120"), (New-ScheduledTaskAction -Execute "schtasks" -Argument '/delete /tn "Adhoc Reboot" /f') # 2 minute delay on shut down so the task can delete itself after scheduling shutdown
$trigger = New-ScheduledTaskTrigger -Once -At $1amTomorrow
Register-ScheduledTask -Action $actions -Trigger $trigger -TaskName "Adhoc Reboot" -Description "Adhoc Reboot" -User "SYSTEM" -RunLevel Highest | Out-Null
