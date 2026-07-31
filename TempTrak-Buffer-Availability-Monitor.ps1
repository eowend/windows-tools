#Requires -Version 5.1

<#
.SYNOPSIS
    Monitors the ICMP availability of up to four TempTrak buffer devices.

.DESCRIPTION
    TempTrak Buffer Availability Monitor provides a simple Windows graphical
    interface for continuous ICMP monitoring. The tool checks each configured
    IPv4 address once per second and declares an outage after two consecutive
    failed probes.

    A separate CSV report is created for each target. Reports are written and
    flushed as events occur, so confirmed outages and recoveries remain on disk
    even if the monitoring computer is later restarted or loses power.

    The report records state changes instead of every individual probe. It also
    records monitoring gaps, session stop information, probe totals, outage
    counts, and calculated ICMP availability.

.NOTES
    Product: TempTrak Buffer Availability Monitor
    Version: 1.0.3
    Author: To Connect
    Requires: Windows PowerShell 5.1 or PowerShell 7+ on Windows
    Platform: Windows 11 or another supported Windows desktop release

    ICMP reachability confirms that a target answered ping. It does not prove
    that the TempTrak application or every service on the device is healthy.

.EXAMPLE
    powershell.exe -NoProfile -STA -File .\TempTrak-Buffer-Availability-Monitor.ps1

    Opens the graphical monitor using Windows PowerShell.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProductName = 'TempTrak Buffer Availability Monitor'
$script:ProductVersion = '1.0.3'
$script:DefaultOutputFolder = 'C:\IT_tools'
$script:MaximumTargets = 4
$script:ProbeIntervalMs = 1000
$script:PingTimeoutMs = 800
$script:FailureThreshold = 2

$script:IsMonitoring = $false
$script:IsStopping = $false
$script:MonitorJobs = New-Object System.Collections.ArrayList
$script:TargetRows = @{}
$script:EventQueue = $null
$script:StopSignal = $null
$script:SessionId = $null
$script:CurrentOutputFolder = $null

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "$($script:ProductName) requires Windows because it uses Windows Forms."
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Start this script from a saved .ps1 file by using PowerShell with the -STA option.'
    }

    $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
        (Get-Process -Id $PID).Path
    }
    else {
        Join-Path $PSHOME 'powershell.exe'
    }

    Start-Process -FilePath $powerShellExecutable -ArgumentList @(
        '-NoProfile',
        '-STA',
        '-File',
        ('"{0}"' -f $PSCommandPath)
    )
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Enable themed Windows controls before constructing the form.
# Avoid changing the process-wide text-rendering mode because the PowerShell
# host may already have created a window before this script starts.
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-NormalizedTargets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText
    )

    $rawTargets = @(
        $InputText -split '[,;\s]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($rawTargets.Count -eq 0) {
        throw 'Enter at least one IPv4 address.'
    }

    $normalizedTargets = New-Object System.Collections.Generic.List[string]
    $seenTargets = @{}

    foreach ($rawTarget in $rawTargets) {
        $parsedAddress = $null
        $isValidAddress = [System.Net.IPAddress]::TryParse($rawTarget, [ref]$parsedAddress)

        if (-not $isValidAddress -or $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "'$rawTarget' is not a valid IPv4 address."
        }

        $normalizedAddress = $parsedAddress.ToString()
        if (-not $seenTargets.ContainsKey($normalizedAddress)) {
            $seenTargets[$normalizedAddress] = $true
            $normalizedTargets.Add($normalizedAddress)
        }
    }

    if ($normalizedTargets.Count -gt $script:MaximumTargets) {
        throw "Enter no more than $($script:MaximumTargets) unique IPv4 addresses."
    }

    return $normalizedTargets.ToArray()
}

function Confirm-OutputFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Select an output folder.'
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    $fullPath = [System.IO.Path]::GetFullPath($expandedPath)

    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        [void](New-Item -Path $fullPath -ItemType Directory -Force)
    }

    $writeTestPath = Join-Path $fullPath ('.TempTrakWriteTest_{0}_{1}.tmp' -f $PID, [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($writeTestPath, 'write test')
    }
    finally {
        if (Test-Path -LiteralPath $writeTestPath) {
            Remove-Item -LiteralPath $writeTestPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $fullPath
}

function New-TargetReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,

        [Parameter(Mandatory = $true)]
        [string]$SessionId
    )

    $safeTarget = $Target -replace '[^0-9A-Za-z._-]', '_'
    $fileName = 'TempTrak_Buffer_{0}_{1}.csv' -f $safeTarget, $SessionId
    $reportPath = Join-Path $OutputFolder $fileName
    $suffix = 1
    while (Test-Path -LiteralPath $reportPath) {
        $fileName = 'TempTrak_Buffer_{0}_{1}_{2}.csv' -f $safeTarget, $SessionId, $suffix
        $reportPath = Join-Path $OutputFolder $fileName
        $suffix++
    }

    $header = 'Timestamp,Event,Target,Status,Duration,ConsecutiveFailures,LatencyMs,TotalProbes,SuccessfulProbes,FailedProbes,OutageCount,AvailabilityPercent,Details'
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
    [System.IO.File]::WriteAllText($reportPath, $header + [Environment]::NewLine, $encoding)

    return $reportPath
}

function Set-StatusMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $statusLabel.Text = $Message
}

function Set-RowStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Update
    )

    if (-not $script:TargetRows.ContainsKey($Update.Target)) {
        return
    }

    $row = $script:TargetRows[$Update.Target]
    $row.SubItems[1].Text = [string]$Update.Status
    $row.SubItems[2].Text = [string]$Update.LastCheck
    $row.SubItems[3].Text = if ($null -eq $Update.LatencyMs -or [string]::IsNullOrWhiteSpace([string]$Update.LatencyMs)) {
        '-'
    }
    else {
        '{0} ms' -f $Update.LatencyMs
    }
    $row.SubItems[4].Text = [string]$Update.ConsecutiveFailures
    $row.SubItems[5].Text = [string]$Update.OutageCount

    switch ([string]$Update.Status) {
        'Online' {
            $row.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        'Warning' {
            $row.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        'Offline' {
            $row.ForeColor = [System.Drawing.Color]::DarkRed
        }
        'Error' {
            $row.ForeColor = [System.Drawing.Color]::DarkRed
        }
        'Stopped' {
            $row.ForeColor = [System.Drawing.SystemColors]::GrayText
        }
        default {
            $row.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    }
}

function Close-MonitorJob {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job
    )

    if ($Job.Completed) {
        return
    }

    try {
        if ($null -ne $Job.AsyncResult) {
            [void]$Job.PowerShell.EndInvoke($Job.AsyncResult)
        }
    }
    catch {
        if ($script:TargetRows.ContainsKey($Job.Target)) {
            $row = $script:TargetRows[$Job.Target]
            $row.SubItems[1].Text = 'Error'
            $row.ForeColor = [System.Drawing.Color]::DarkRed
        }
        Set-StatusMessage ("Monitoring error for {0}: {1}" -f $Job.Target, $_.Exception.Message)
    }
    finally {
        try { $Job.PowerShell.Dispose() } catch { }
        try { $Job.Runspace.Close() } catch { }
        try { $Job.Runspace.Dispose() } catch { }
        $Job.Completed = $true
    }
}

function Complete-MonitoringSession {
    $script:IsMonitoring = $false
    $script:IsStopping = $false

    $targetsTextBox.Enabled = $true
    $outputFolderTextBox.Enabled = $true
    $browseButton.Enabled = $true
    $startStopButton.Enabled = $true
    $startStopButton.Text = 'Start Monitoring'
    $openReportsButton.Enabled = Test-Path -LiteralPath $script:CurrentOutputFolder -PathType Container

    if ($null -ne $script:StopSignal) {
        try { $script:StopSignal.Dispose() } catch { }
    }

    Set-StatusMessage ("Monitoring stopped. Reports saved in {0}" -f $script:CurrentOutputFolder)
}

function Stop-Monitoring {
    if (-not $script:IsMonitoring -or $script:IsStopping) {
        return
    }

    $script:IsStopping = $true
    $startStopButton.Enabled = $false
    $startStopButton.Text = 'Stopping...'
    Set-StatusMessage 'Stopping monitoring and finalizing reports...'

    if ($null -ne $script:StopSignal) {
        $script:StopSignal.Set()
    }
}

$script:WorkerScript = {
    param(
        [string]$Target,
        [string]$LogPath,
        [string]$SessionId,
        [System.Threading.ManualResetEventSlim]$StopSignal,
        [System.Collections.Concurrent.ConcurrentQueue[object]]$Queue,
        [int]$IntervalMs,
        [int]$TimeoutMs,
        [int]$FailureThreshold,
        [string]$ProductVersion
    )

    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    function ConvertTo-CsvField {
        param([AllowNull()][object]$Value)

        $text = if ($null -eq $Value) { '' } else { [string]$Value }
        return '"' + $text.Replace('"', '""') + '"'
    }

    function Format-EventDuration {
        param([TimeSpan]$Duration)

        if ($Duration.TotalDays -ge 1) {
            return '{0}.{1:00}:{2:00}:{3:00}.{4:000}' -f [math]::Floor($Duration.TotalDays), $Duration.Hours, $Duration.Minutes, $Duration.Seconds, $Duration.Milliseconds
        }

        return '{0:00}:{1:00}:{2:00}.{3:000}' -f $Duration.Hours, $Duration.Minutes, $Duration.Seconds, $Duration.Milliseconds
    }

    function Get-AvailabilityPercent {
        param(
            [long]$SuccessfulProbes,
            [long]$TotalProbes
        )

        if ($TotalProbes -le 0) {
            return ''
        }

        return ([math]::Round(($SuccessfulProbes / [double]$TotalProbes) * 100, 4)).ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture)
    }

    function Write-ReportEvent {
        param(
            [System.IO.StreamWriter]$Writer,
            [DateTimeOffset]$Timestamp,
            [string]$EventName,
            [string]$Status,
            [string]$Duration,
            [int]$ConsecutiveFailures,
            [AllowNull()][object]$LatencyMs,
            [long]$TotalProbes,
            [long]$SuccessfulProbes,
            [long]$FailedProbes,
            [int]$OutageCount,
            [string]$Details
        )

        $availability = Get-AvailabilityPercent -SuccessfulProbes $SuccessfulProbes -TotalProbes $TotalProbes
        $fields = @(
            $Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'),
            $EventName,
            $Target,
            $Status,
            $Duration,
            $ConsecutiveFailures,
            $LatencyMs,
            $TotalProbes,
            $SuccessfulProbes,
            $FailedProbes,
            $OutageCount,
            $availability,
            $Details
        )

        $line = (($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
        $Writer.WriteLine($line)
        $Writer.Flush()
        try {
            $Writer.BaseStream.Flush($true)
        }
        catch {
            $Writer.BaseStream.Flush()
        }
    }

    function Publish-Status {
        param(
            [string]$Status,
            [DateTimeOffset]$Timestamp,
            [AllowNull()][object]$LatencyMs,
            [int]$ConsecutiveFailures,
            [int]$OutageCount,
            [string]$Message
        )

        $Queue.Enqueue([pscustomobject]@{
            Type                = 'Status'
            Target              = $Target
            Status              = $Status
            LastCheck           = $Timestamp.ToString('yyyy-MM-dd HH:mm:ss')
            LatencyMs           = $LatencyMs
            ConsecutiveFailures = $ConsecutiveFailures
            OutageCount         = $OutageCount
            Message             = $Message
        })
    }

    $ping = $null
    $fileStream = $null
    $writer = $null
    $totalProbes = [long]0
    $successfulProbes = [long]0
    $failedProbes = [long]0
    $consecutiveFailures = 0
    $outageCount = 0
    $isOutage = $false
    $firstFailureTime = $null
    $lastProbeStart = $null
    $lastFailureStatus = ''
    $outageContainsMonitoringGap = $false

    try {
        $fileStream = New-Object -TypeName System.IO.FileStream -ArgumentList @(
            $LogPath,
            [System.IO.FileMode]::Append,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
        $writer = New-Object -TypeName System.IO.StreamWriter -ArgumentList @($fileStream, $encoding)
        $writer.AutoFlush = $true

        $startedAt = [DateTimeOffset]::Now
        $computerName = [Environment]::MachineName
        $details = ('Session {0}; monitor computer {1}; PowerShell {2}; interval {3} ms; timeout {4} ms; outage threshold {5} consecutive failures; tool version {6}.' -f
            $SessionId, $computerName, $PSVersionTable.PSVersion.ToString(), $IntervalMs, $TimeoutMs, $FailureThreshold, $ProductVersion)

        Write-ReportEvent -Writer $writer -Timestamp $startedAt -EventName 'MONITOR_STARTED' -Status 'Checking' -Duration '' -ConsecutiveFailures 0 -LatencyMs $null -TotalProbes 0 -SuccessfulProbes 0 -FailedProbes 0 -OutageCount 0 -Details $details
        Publish-Status -Status 'Checking' -Timestamp $startedAt -LatencyMs $null -ConsecutiveFailures 0 -OutageCount 0 -Message 'Waiting for the first probe result.'

        $ping = New-Object System.Net.NetworkInformation.Ping

        while (-not $StopSignal.IsSet) {
            $cycleStartedAt = [DateTimeOffset]::Now

            if ($null -ne $lastProbeStart) {
                $monitoringGap = $cycleStartedAt - $lastProbeStart
                $gapThresholdMs = [math]::Max(5000, ($IntervalMs * 3))

                if ($monitoringGap.TotalMilliseconds -gt $gapThresholdMs) {
                    $gapText = Format-EventDuration -Duration $monitoringGap
                    Write-ReportEvent -Writer $writer -Timestamp $cycleStartedAt -EventName 'MONITORING_GAP' -Status 'Unknown' -Duration $gapText -ConsecutiveFailures $consecutiveFailures -LatencyMs $null -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details 'The monitoring computer did not execute probes during this period. The computer may have slept, hibernated and resumed, or been paused. Target availability during the gap is unknown.'

                    if ($isOutage) {
                        $outageContainsMonitoringGap = $true
                    }
                    else {
                        $consecutiveFailures = 0
                        $firstFailureTime = $null
                    }

                    $Queue.Enqueue([pscustomobject]@{
                        Type    = 'Notice'
                        Target  = $Target
                        Message = "Monitoring gap detected for $($Target): $gapText"
                    })
                }
            }

            $lastProbeStart = $cycleStartedAt
            $cycleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $probeSucceeded = $false
            $latencyMs = $null
            $failureStatus = ''

            try {
                $reply = $ping.Send($Target, $TimeoutMs)
                if ($null -ne $reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $probeSucceeded = $true
                    $latencyMs = [long]$reply.RoundtripTime
                }
                elseif ($null -ne $reply) {
                    $failureStatus = $reply.Status.ToString()
                }
                else {
                    $failureStatus = 'NoReply'
                }
            }
            catch {
                $failureStatus = $_.Exception.Message
            }

            $probeTimestamp = [DateTimeOffset]::Now
            $totalProbes++

            if ($probeSucceeded) {
                $successfulProbes++

                if ($isOutage) {
                    $outageDuration = $probeTimestamp - [DateTimeOffset]$firstFailureTime
                    $outageDurationText = Format-EventDuration -Duration $outageDuration
                    $durationQualification = if ($outageContainsMonitoringGap) {
                        ' A local monitoring gap occurred during this outage, so the exact target recovery time inside that gap cannot be proven.'
                    }
                    else {
                        ''
                    }
                    $details = ('Connectivity restored after {0}. The first failed probe occurred at {1}. The last observed failure status was {2}.{3}' -f
                        $outageDurationText, ([DateTimeOffset]$firstFailureTime).ToString('yyyy-MM-dd HH:mm:ss.fff zzz'), $lastFailureStatus, $durationQualification)

                    Write-ReportEvent -Writer $writer -Timestamp $probeTimestamp -EventName 'OUTAGE_ENDED' -Status 'Online' -Duration $outageDurationText -ConsecutiveFailures 0 -LatencyMs $latencyMs -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details $details
                }

                $isOutage = $false
                $firstFailureTime = $null
                $consecutiveFailures = 0
                $lastFailureStatus = ''
                $outageContainsMonitoringGap = $false
                Publish-Status -Status 'Online' -Timestamp $probeTimestamp -LatencyMs $latencyMs -ConsecutiveFailures 0 -OutageCount $outageCount -Message 'Target replied to ICMP.'
            }
            else {
                $failedProbes++
                $consecutiveFailures++
                $lastFailureStatus = if ([string]::IsNullOrWhiteSpace($failureStatus)) { 'Unknown failure' } else { $failureStatus }

                if ($consecutiveFailures -eq 1) {
                    $firstFailureTime = $probeTimestamp
                }

                if (-not $isOutage -and $consecutiveFailures -ge $FailureThreshold) {
                    $isOutage = $true
                    $outageContainsMonitoringGap = $false
                    $outageCount++
                    $confirmedAt = $probeTimestamp
                    $details = ('Outage started with the first failed probe at {0} and was confirmed at {1} after {2} consecutive failed probes. Last failure status: {3}.' -f
                        ([DateTimeOffset]$firstFailureTime).ToString('yyyy-MM-dd HH:mm:ss.fff zzz'), $confirmedAt.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'), $FailureThreshold, $lastFailureStatus)

                    Write-ReportEvent -Writer $writer -Timestamp ([DateTimeOffset]$firstFailureTime) -EventName 'OUTAGE_STARTED' -Status 'Offline' -Duration '' -ConsecutiveFailures $consecutiveFailures -LatencyMs $null -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details $details
                }

                $displayStatus = if ($isOutage) { 'Offline' } else { 'Warning' }
                Publish-Status -Status $displayStatus -Timestamp $probeTimestamp -LatencyMs $null -ConsecutiveFailures $consecutiveFailures -OutageCount $outageCount -Message $lastFailureStatus
            }

            $cycleStopwatch.Stop()
            $remainingDelayMs = $IntervalMs - [int]$cycleStopwatch.ElapsedMilliseconds
            if ($remainingDelayMs -gt 0) {
                if ($StopSignal.Wait($remainingDelayMs)) {
                    break
                }
            }
        }

        $stoppedAt = [DateTimeOffset]::Now

        if ($isOutage -and $null -ne $firstFailureTime) {
            $openOutageDuration = $stoppedAt - [DateTimeOffset]$firstFailureTime
            $openOutageDurationText = Format-EventDuration -Duration $openOutageDuration
            $openOutageDetails = if ($outageContainsMonitoringGap) {
                'Monitoring stopped while the target was still classified as offline. No recovery time was observed. A local monitoring gap occurred during the outage, so the exact continuous outage duration cannot be proven.'
            }
            else {
                'Monitoring stopped while the target was still classified as offline. No recovery time was observed.'
            }
            Write-ReportEvent -Writer $writer -Timestamp $stoppedAt -EventName 'OUTAGE_OPEN_AT_STOP' -Status 'Offline' -Duration $openOutageDurationText -ConsecutiveFailures $consecutiveFailures -LatencyMs $null -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details $openOutageDetails
        }

        $availabilityAtStop = Get-AvailabilityPercent -SuccessfulProbes $successfulProbes -TotalProbes $totalProbes
        $availabilityDisplay = if ([string]::IsNullOrWhiteSpace($availabilityAtStop)) { 'N/A' } else { $availabilityAtStop + '%' }
        $stopDetails = ('Monitoring stopped by the operator. Total probes: {0}; successful probes: {1}; failed probes: {2}; confirmed outages: {3}; ICMP availability: {4}.' -f
            $totalProbes, $successfulProbes, $failedProbes, $outageCount, $availabilityDisplay)

        Write-ReportEvent -Writer $writer -Timestamp $stoppedAt -EventName 'MONITOR_STOPPED' -Status 'Stopped' -Duration '' -ConsecutiveFailures $consecutiveFailures -LatencyMs $null -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details $stopDetails
        Publish-Status -Status 'Stopped' -Timestamp $stoppedAt -LatencyMs $null -ConsecutiveFailures $consecutiveFailures -OutageCount $outageCount -Message $stopDetails
    }
    catch {
        $errorTimestamp = [DateTimeOffset]::Now
        $errorMessage = $_.Exception.Message

        if ($null -ne $writer) {
            try {
                Write-ReportEvent -Writer $writer -Timestamp $errorTimestamp -EventName 'MONITOR_ERROR' -Status 'Error' -Duration '' -ConsecutiveFailures $consecutiveFailures -LatencyMs $null -TotalProbes $totalProbes -SuccessfulProbes $successfulProbes -FailedProbes $failedProbes -OutageCount $outageCount -Details $errorMessage
            }
            catch { }
        }

        $Queue.Enqueue([pscustomobject]@{
            Type                = 'Status'
            Target              = $Target
            Status              = 'Error'
            LastCheck           = $errorTimestamp.ToString('yyyy-MM-dd HH:mm:ss')
            LatencyMs           = $null
            ConsecutiveFailures = $consecutiveFailures
            OutageCount         = $outageCount
            Message             = $errorMessage
        })

        throw
    }
    finally {
        if ($null -ne $ping) {
            try { $ping.Dispose() } catch { }
        }
        if ($null -ne $writer) {
            try { $writer.Flush() } catch { }
            try { $writer.Dispose() } catch { }
        }
        elseif ($null -ne $fileStream) {
            try { $fileStream.Dispose() } catch { }
        }
    }
}

function Start-Monitoring {
    try {
        $targets = @(Get-NormalizedTargets -InputText $targetsTextBox.Text)
        $outputFolder = Confirm-OutputFolder -Path $outputFolderTextBox.Text

        $script:SessionId = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $script:CurrentOutputFolder = $outputFolder
        $script:EventQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:StopSignal = New-Object -TypeName System.Threading.ManualResetEventSlim -ArgumentList $false
        $script:MonitorJobs.Clear()
        $script:TargetRows = @{}
        $resultsListView.Items.Clear()

        foreach ($target in $targets) {
            $reportPath = New-TargetReport -Target $target -OutputFolder $outputFolder -SessionId $script:SessionId

            $row = New-Object -TypeName System.Windows.Forms.ListViewItem -ArgumentList $target
            [void]$row.SubItems.Add('Checking')
            [void]$row.SubItems.Add('-')
            [void]$row.SubItems.Add('-')
            [void]$row.SubItems.Add('0')
            [void]$row.SubItems.Add('0')
            $row.ToolTipText = $reportPath
            [void]$resultsListView.Items.Add($row)
            $script:TargetRows[$target] = $row

            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.ApartmentState = [Threading.ApartmentState]::MTA
            $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $runspace.Open()

            $powerShell = [System.Management.Automation.PowerShell]::Create()
            $powerShell.Runspace = $runspace
            [void]$powerShell.AddScript($script:WorkerScript.ToString())
            [void]$powerShell.AddArgument($target)
            [void]$powerShell.AddArgument($reportPath)
            [void]$powerShell.AddArgument($script:SessionId)
            [void]$powerShell.AddArgument($script:StopSignal)
            [void]$powerShell.AddArgument($script:EventQueue)
            [void]$powerShell.AddArgument($script:ProbeIntervalMs)
            [void]$powerShell.AddArgument($script:PingTimeoutMs)
            [void]$powerShell.AddArgument($script:FailureThreshold)
            [void]$powerShell.AddArgument($script:ProductVersion)

            $asyncResult = $powerShell.BeginInvoke()
            $job = [pscustomobject]@{
                Target      = $target
                LogPath     = $reportPath
                PowerShell  = $powerShell
                Runspace    = $runspace
                AsyncResult = $asyncResult
                Completed   = $false
            }
            [void]$script:MonitorJobs.Add($job)
        }

        $script:IsMonitoring = $true
        $script:IsStopping = $false
        $targetsTextBox.Enabled = $false
        $outputFolderTextBox.Enabled = $false
        $browseButton.Enabled = $false
        $startStopButton.Text = 'Stop Monitoring'
        $startStopButton.Enabled = $true
        $openReportsButton.Enabled = $true

        Set-StatusMessage ("Monitoring {0} target(s). Reports are being written to {1}" -f $targets.Count, $outputFolder)
    }
    catch {
        if ($null -ne $script:StopSignal) {
            try { $script:StopSignal.Set() } catch { }
        }

        foreach ($job in @($script:MonitorJobs)) {
            try { $job.PowerShell.Stop() } catch { }
            Close-MonitorJob -Job $job
        }

        $script:IsMonitoring = $false
        $script:IsStopping = $false
        $startStopButton.Text = 'Start Monitoring'
        $startStopButton.Enabled = $true
        $targetsTextBox.Enabled = $true
        $outputFolderTextBox.Enabled = $true
        $browseButton.Enabled = $true

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            $script:ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

# Main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "$($script:ProductName) v$($script:ProductVersion)"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 920, 620
$form.MinimumSize = New-Object -TypeName System.Drawing.Size -ArgumentList 920, 620
$form.MaximizeBox = $false
$form.Font = [System.Drawing.Font]::new(
    'Calibri',
    [single]10,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Point
)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$brandBlue = [System.Drawing.ColorTranslator]::FromHtml('#2491D0')

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$headerPanel.Height = 82
$headerPanel.BackColor = $brandBlue
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $script:ProductName
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = [System.Drawing.Font]::new(
    'Calibri',
    [single]18,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Point
)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 22, 14
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Continuous ICMP monitoring with event-based CSV reporting'
$subtitleLabel.ForeColor = [System.Drawing.Color]::White
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 25, 50
$headerPanel.Controls.Add($subtitleLabel)

$instructionLabel = New-Object System.Windows.Forms.Label
$instructionLabel.Text = 'Enter up to four IPv4 addresses. Separate addresses with commas, semicolons, spaces, or new lines. The tool checks each address once per second and confirms an outage after two consecutive failed probes.'
$instructionLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 98
$instructionLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 850, 44
$form.Controls.Add($instructionLabel)

$targetsLabel = New-Object System.Windows.Forms.Label
$targetsLabel.Text = 'IPv4 addresses'
$targetsLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 150
$targetsLabel.AutoSize = $true
$form.Controls.Add($targetsLabel)

$targetsTextBox = New-Object System.Windows.Forms.TextBox
$targetsTextBox.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 174
$targetsTextBox.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 850, 52
$targetsTextBox.Multiline = $true
$targetsTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$form.Controls.Add($targetsTextBox)

$outputFolderLabel = New-Object System.Windows.Forms.Label
$outputFolderLabel.Text = 'Report folder'
$outputFolderLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 240
$outputFolderLabel.AutoSize = $true
$form.Controls.Add($outputFolderLabel)

$outputFolderTextBox = New-Object System.Windows.Forms.TextBox
$outputFolderTextBox.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 264
$outputFolderTextBox.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 690, 26
$outputFolderTextBox.Text = $script:DefaultOutputFolder
$form.Controls.Add($outputFolderTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = 'Browse...'
$browseButton.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 724, 261
$browseButton.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 150, 32
$form.Controls.Add($browseButton)

$settingsLabel = New-Object System.Windows.Forms.Label
$settingsLabel.Text = 'Fixed settings: 1-second probe interval | 800 ms timeout | Outage after 2 consecutive failed probes'
$settingsLabel.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 302
$settingsLabel.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 850, 24
$settingsLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
$form.Controls.Add($settingsLabel)

$startStopButton = New-Object System.Windows.Forms.Button
$startStopButton.Text = 'Start Monitoring'
$startStopButton.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 334
$startStopButton.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 190, 40
$startStopButton.BackColor = $brandBlue
$startStopButton.ForeColor = [System.Drawing.Color]::White
$startStopButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$form.Controls.Add($startStopButton)

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Text = 'Open Reports Folder'
$openReportsButton.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 224, 334
$openReportsButton.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 190, 40
$openReportsButton.Enabled = Test-Path -LiteralPath $script:DefaultOutputFolder -PathType Container
$form.Controls.Add($openReportsButton)

$resultsListView = New-Object System.Windows.Forms.ListView
$resultsListView.Location = New-Object -TypeName System.Drawing.Point -ArgumentList 24, 390
$resultsListView.Size = New-Object -TypeName System.Drawing.Size -ArgumentList 850, 150
$resultsListView.View = [System.Windows.Forms.View]::Details
$resultsListView.FullRowSelect = $true
$resultsListView.GridLines = $true
$resultsListView.ShowItemToolTips = $true
[void]$resultsListView.Columns.Add('Target', 150)
[void]$resultsListView.Columns.Add('Status', 120)
[void]$resultsListView.Columns.Add('Last Check', 180)
[void]$resultsListView.Columns.Add('Latency', 110)
[void]$resultsListView.Columns.Add('Consecutive Losses', 150)
[void]$resultsListView.Columns.Add('Outages', 90)
$form.Controls.Add($resultsListView)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.Text = 'Ready. Reports default to C:\IT_tools.'
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
$folderBrowser.Description = 'Select the folder where monitoring reports will be saved.'
$folderBrowser.ShowNewFolderButton = $true

$browseButton.Add_Click({
    if (Test-Path -LiteralPath $outputFolderTextBox.Text -PathType Container) {
        $folderBrowser.SelectedPath = $outputFolderTextBox.Text
    }

    if ($folderBrowser.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputFolderTextBox.Text = $folderBrowser.SelectedPath
    }
})

$openReportsButton.Add_Click({
    try {
        $folderToOpen = if ($script:IsMonitoring -and -not [string]::IsNullOrWhiteSpace($script:CurrentOutputFolder)) {
            $script:CurrentOutputFolder
        }
        else {
            Confirm-OutputFolder -Path $outputFolderTextBox.Text
        }

        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folderToOpen)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            $script:ProductName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$startStopButton.Add_Click({
    if ($script:IsMonitoring) {
        Stop-Monitoring
    }
    else {
        Start-Monitoring
    }
})

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 250
$uiTimer.Add_Tick({
    if ($null -ne $script:EventQueue) {
        $update = $null
        while ($script:EventQueue.TryDequeue([ref]$update)) {
            if ($null -eq $update) {
                continue
            }

            switch ([string]$update.Type) {
                'Status' {
                    Set-RowStatus -Update $update
                    if (-not [string]::IsNullOrWhiteSpace([string]$update.Message)) {
                        Set-StatusMessage ("{0}: {1}" -f $update.Target, $update.Message)
                    }
                }
                'Notice' {
                    Set-StatusMessage ([string]$update.Message)
                }
            }

            $update = $null
        }
    }

    if ($script:MonitorJobs.Count -gt 0) {
        foreach ($job in @($script:MonitorJobs)) {
            if (-not $job.Completed -and $job.AsyncResult.IsCompleted) {
                Close-MonitorJob -Job $job
            }
        }

        $incompleteJobs = @($script:MonitorJobs | Where-Object { -not $_.Completed })
        if ($script:IsMonitoring -and $incompleteJobs.Count -eq 0) {
            Complete-MonitoringSession
        }
    }
})
$uiTimer.Start()

$form.Add_FormClosing({
    param($sender, $eventArgs)

    if ($script:IsMonitoring -and -not $script:IsStopping) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Monitoring is active. Stop monitoring and close the application?',
            $script:ProductName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }

        Stop-Monitoring
    }

    if ($script:IsMonitoring) {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()

            foreach ($job in @($script:MonitorJobs)) {
                if (-not $job.Completed -and $job.AsyncResult.IsCompleted) {
                    Close-MonitorJob -Job $job
                }
            }

            if (@($script:MonitorJobs | Where-Object { -not $_.Completed }).Count -eq 0) {
                break
            }

            Start-Sleep -Milliseconds 50
        }

        foreach ($job in @($script:MonitorJobs | Where-Object { -not $_.Completed })) {
            try { $job.PowerShell.Stop() } catch { }
            Close-MonitorJob -Job $job
        }
    }

    $uiTimer.Stop()
    $uiTimer.Dispose()
})

[void]$form.ShowDialog()
