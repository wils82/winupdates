#winupdates.ps1
#James Wilson

#Imports files and scheduled tasks required and installs updates on remote machines
#See readme for details

Param ( [Parameter(Mandatory=$true)][string]$serverlistpath )
if (-not (test-path $serverlistpath)) { echo "serverlist path doesn't exist";exit }

$SB = {

param(
        [Parameter(Position=0,mandatory=$true)]
        [string] $server
)

If (Test-Connection -computername $server -Quiet) {

#Copy PSWindowsupdate module, imports scheduled tasks and required files to target server
Robocopy.exe /MIR /SEC /IS "C:\winupdates\Scripts" "\\$server\c$\wuscripts" /NJH /NFL
Robocopy.exe "C:\winupdates\PSWindowsUpdate" "\\$server\c$\Windows\System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate" /NJH /NFL
C:\Windows\System32\schtasks.exe /Create /F /S $server /RU SYSTEM /XML "C:\winupdates\reboot.xml" /TN reboot
C:\Windows\System32\schtasks.exe /Create /F /S $server /RU SYSTEM /XML "C:\winupdates\disablereboot.xml" /TN disablereboot

}
Else {
Write-Output "$server failed to connect"
exit
}

#Download Windows Updates on target server and schedule overnight reboot
import-module pswindowsupdate
Set-Item WSMan:\localhost\Client\TrustedHosts -Concatenate –Value $server -Force
Invoke-Command -ComputerName $server -ScriptBlock {
set-service -name wuauserv -startuptype manual -status Running
}
Write-Output "$(get-date -format HH:mm) Getting windows updates on $server"
try {
Invoke-Command -ComputerName $server -ScriptBlock {
Import-Module PSWindowsUpdate
get-windowsupdate | format-table
}
} catch {
    write-output "Get-WindowsUpdate command failed:  $_ . `nEnabling task to schedule a reboot..."
    Invoke-Command -ComputerName $server -ScriptBlock {Enable-ScheduledTask -TaskName "reboot" }
    }
$updates = Invoke-Command -ComputerName $server -ScriptBlock {
get-windowsupdate
}

if ($updates -eq $null)
    {
    Write-Output "$(get-date -format HH:mm) No updates"
    }
    else
    {
    Write-Output "$(get-date -format HH:mm) Installing updates..."
    Invoke-Command -ComputerName $server -ScriptBlock {
    Remove-Item $env:UserProfile\AppData\Local\Microsoft\Windows\PowerShell\ScheduledJobs\getupdates -Recurse -ErrorAction Ignore #if previous update job exists, remove
    get-job | remove-job -force -ErrorAction Ignore
    Unregister-ScheduledJob -Name GetUpdates -Force
    Register-ScheduledJob -name GetUpdates -ScriptBlock {
    Import-Module PSWindowsupdate
    Get-WindowsUpdate -acceptall -install -IgnoreReboot
    } -RunNow
    }
    start-sleep -Seconds 5
    Invoke-Command -ComputerName $server -ScriptBlock {
    get-job | Wait-Job
    get-job | Receive-Job
    }
    Write-Output "$(get-date -format HH:mm) Enabling reboot task..."
    Invoke-Command -ComputerName $server -ScriptBlock {Enable-ScheduledTask -TaskName "reboot" }
    }

exit
}


$timeout = {
start-sleep -Seconds 23400 #if target hasn't complete update job by this time, we can mark it as hung
}

$date = get-date -format "dd-MM-yyyy"

#Create job for each server
Get-Content $serverlistpath | foreach-object { 
start-job -Name $_ -ArgumentList $_ -scriptblock $SB
}
$timeout = start-job -Name Timeout -ScriptBlock $timeout

#process jobs as they complete
do {
if ($timeout.state -eq "Completed") #clearup jobs that haven't completed by timeout
{
remove-job -Name timeout
$jobs = get-job
foreach ($job in $jobs)
{
$jobname = $job.name
write-output "$jobname hung"
stop-job -name $jobname
Receive-Job -Name $jobname > "c:\winupdates\logs\$jobname $date TIMEOUT FAILURE.txt"
get-job -name $jobname | remove-job -Force
invoke-command -ComputerName $jobname -ScriptBlock {
get-job | remove-job -force
Unregister-ScheduledJob -Name GetUpdates -Force
Enable-ScheduledTask -TaskName "reboot"
}
}
exit
}

$jobs = get-job -state completed

foreach ($job in $jobs)
{
$jobname = $job.name
write-output "$jobname completed"
Receive-Job -Name $jobname > "c:\winupdates\logs\$jobname $date.txt"
get-job -name $jobname | remove-job
}

$jobs = get-job -state Failed
foreach ($job in $jobs)
{
$jobname = $job.name
receive-job -Name $jobname > "c:\winupdates\logs\$job $date JOBFAILED.txt"
get-job -Name $jobname | remove-job
}

start-sleep -Seconds 1
} while ([bool](get-job))
