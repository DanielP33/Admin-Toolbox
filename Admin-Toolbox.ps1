#Requires -Version 5.1

# Aesthetics
$host.UI.RawUI.BackgroundColor = 'Black'
$ProgressPreference = 'SilentlyContinue'   # progress rendering slows cmdlets down for no benefit here

# Warm the system-specs cache in the background at launch so option 1 opens instantly.
# Set to $false to only collect specs when you open them.
$script:PrefetchSpecs = $true

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Script-wide state
$script:Pool = $null
$script:Jobs = @{}
$script:BgData = @{}
$script:PsExe = $null
$script:ActivationStatus = 'Checking...'
$script:GpuCache = $null
$script:GpuDriverCache = $null
$script:SystemSpecsCache = $null
$script:CoreIsoUrlFile = $null
$script:ChangeLogPath = Join-Path $env:LOCALAPPDATA 'SystemToolbox\ChangeLog.txt'

### Change log ###
# Plain .NET append: no cmdlet overhead, creates the folder only if it's missing.
function Write-ToolChange {
    param([Parameter(Mandatory=$true)][string]$Change)
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ChangeLogPath))
        $line = '{0} | {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Change, [Environment]::NewLine
        [IO.File]::AppendAllText($script:ChangeLogPath, $line)
    } catch {
        Write-Verbose "Could not write toolbox change log: $_"
    }
}

### Elevation ###
# Least privilege is kept: the toolbox runs normally and only elevates the one action
# that needs it. Simple registry writes now go straight to reg.exe, which starts in a
# few milliseconds, instead of paying for a whole new PowerShell host every time.
function Invoke-Elevated {
    param(
        [Parameter(Mandatory=$true)][string]$File,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [Parameter(Mandatory=$true)][string]$Change
    )
    try {
        $splat = @{ FilePath = $File; ArgumentList = $Arguments; WindowStyle = 'Hidden'; Wait = $true; PassThru = $true }
        if (-not $script:IsAdmin) { $splat.Verb = 'RunAs' }
        $process = Start-Process @splat
        if ($process.ExitCode -ne 0) { throw "The operation failed (exit code $($process.ExitCode))." }
        Write-ToolChange $Change
        return $true
    } catch {
        Write-Host "The requested change could not be completed: $_" -ForegroundColor Red
        Start-Sleep -Milliseconds 1500   # the menu's Clear-Host would wipe this instantly
        return $false
    }
}

# For the few changes that genuinely need PowerShell (services, DNS).
function Invoke-AdminMutation {
    param([Parameter(Mandatory=$true)][string]$ScriptText, [Parameter(Mandatory=$true)][string]$Change)
    if ($script:IsAdmin) {
        try {
            $ErrorActionPreference = 'Stop'
            & ([scriptblock]::Create($ScriptText)) | Out-Null
            Write-ToolChange $Change
            return $true
        } catch {
            Write-Host "The requested change could not be completed: $_" -ForegroundColor Red
            Start-Sleep -Milliseconds 1500
            return $false
        }
    }
    $wrappedScript = @"
`$ErrorActionPreference = 'Stop'
try {
$ScriptText
    exit 0
} catch {
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedScript))
    if (-not $script:PsExe) { $script:PsExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    return (Invoke-Elevated -File $script:PsExe -Arguments "-NoProfile -NonInteractive -EncodedCommand $encoded" -Change $Change)
}

# I didn't know how to credit myself without being invasive, so I used the loading
# screen it's the one moment the user is just waiting anyway.
function Start-Loading {
    Clear-Host
    Write-Host "Loading, please wait..." -ForegroundColor Yellow
    Write-Host "By Daniel P. ~ Updated 2026" -ForegroundColor Green
}

### Background jobs ###
# One shared runspace pool. Slow queries (activation, hardware specs) run on worker
# threads while the menu is already on screen, and the finished data is picked up later.
function Start-BgJob {
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][scriptblock]$Work)
    if (-not $script:Pool) { return }
    try {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($Work.ToString())
        $script:Jobs[$Name] = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    } catch { }
}

# $null = no such job, $false = still running, $true = finished (data is in $script:BgData[$Name]).
# -Wait blocks on a wait handle, so there's no sleep/poll loop burning time.
function Update-BgJob {
    param([Parameter(Mandatory=$true)][string]$Name, [switch]$Wait)
    $job = $script:Jobs[$Name]
    if (-not $job) { return $null }
    if (-not $job.Handle.IsCompleted) {
        if (-not $Wait) { return $false }
        [void]$job.Handle.AsyncWaitHandle.WaitOne()
    }
    try { $script:BgData[$Name] = @($job.PS.EndInvoke($job.Handle)) } catch { $script:BgData[$Name] = @() }
    $job.PS.Dispose()
    $script:Jobs.Remove($Name)
    return $true
}

# Windows activation: SoftwareLicensingProduct is one of the slowest WMI classes, so the
# filter is pushed into the query and only the property we need is requested.
$script:ActivationQuery = {
    try {
        $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'"
        $hasWindowsLicense = $false
        $hasGracePeriod = $false
        foreach ($license in (Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -Property LicenseStatus)) {
            $hasWindowsLicense = $true
            if ($license.LicenseStatus -eq 1) { return 'Activated' }
            if ($license.LicenseStatus -in 2, 3, 4, 6) { $hasGracePeriod = $true }
        }
        if (-not $hasWindowsLicense) { return 'Unknown' }
        if ($hasGracePeriod) { return 'Grace period' }
        return 'Not activated'
    } catch {
        return 'Unknown'
    }
}

# Returns $true only when the status just changed (so the menu knows to repaint).
function Update-ActivationStatus {
    if ((Update-BgJob -Name 'Activation') -ne $true) { return $false }
    $value = @($script:BgData['Activation'])[0]
    $script:ActivationStatus = if ($value) { [string]$value } else { 'Unknown' }
    return $true
}

# Hardware specs. Self-contained so it can run on a worker thread. It skips the Storage
# module entirely (the slowest part of the old version) and talks to WMI directly:
#   - drive letter -> physical disk via Win32_LogicalDiskToPartition
#   - disk health via MSFT_PhysicalDisk (what Get-PhysicalDisk wraps)
$script:SpecsQuery = {
    $specs = New-Object 'System.Collections.Generic.List[object]'
    try {
        $specs.Add([pscustomobject]@{ Kind = 'Text'; Text = '==== System Specifications ====' })

        $board = Get-CimInstance -ClassName Win32_BaseBoard -Property Product | Select-Object -First 1
        $specs.Add([pscustomobject]@{ Kind = 'Field'; Label = 'Motherboard: '; Value = $board.Product })

        $cpu = Get-CimInstance -ClassName Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors | Select-Object -First 1
        $specs.Add([pscustomobject]@{
            Kind    = 'Cpu'
            Label   = 'CPU: '
            Name    = $cpu.Name.Trim()
            Cores   = $cpu.NumberOfCores
            Threads = $cpu.NumberOfLogicalProcessors
        })

        $ddrNames = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
        $mem = @(Get-CimInstance -ClassName Win32_PhysicalMemory -Property Capacity, ConfiguredClockSpeed, FormFactor, SMBIOSMemoryType, MemoryType, TypeDetail)
        $ramGB = [math]::Round(($mem | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
        $ramTypes = foreach ($stick in $mem) {
            $moduleType = if ([int]$stick.FormFactor -eq 12) { 'SODIMM' }
                          elseif (([int]$stick.TypeDetail -band 0x2000) -ne 0) { 'RDIMM' }
                          elseif (([int]$stick.TypeDetail -band 0x4000) -ne 0) { 'UDIMM' }
                          elseif ([int]$stick.FormFactor -eq 8) { 'DIMM' }
                          else { $null }
            $ddrType = $ddrNames[[int]$stick.SMBIOSMemoryType]
            if (-not $ddrType) { $ddrType = $ddrNames[[int]$stick.MemoryType] }
            (@($moduleType, $ddrType) -ne $null) -join ' '
        }
        $ramTypeSummary = @($ramTypes | Where-Object { $_ } | Select-Object -Unique) -join ', '
        $configuredSpeeds = @($mem | ForEach-Object { if ($_.ConfiguredClockSpeed) { [int]$_.ConfiguredClockSpeed } } | Select-Object -Unique)
        $configuredSpeedText = if ($configuredSpeeds.Count -eq 1) { "$($configuredSpeeds[0])MHz" }
                               elseif ($configuredSpeeds.Count -gt 1) { "$($configuredSpeeds -join '/')MHz" }
                               else { 'Unknown speed' }
        $ramDescription = "$ramGB GB ($($mem.Count) sticks | $configuredSpeedText"
        if ($ramTypeSummary) { $ramDescription += " | $ramTypeSummary" }
        $ramDescription += ')'
        $specs.Add([pscustomobject]@{ Kind = 'Field'; Label = 'RAM: '; Value = $ramDescription })

        # NVIDIA first, then AMD, then Intel, so laptops report the discrete card.
        $cards = @(Get-CimInstance -ClassName Win32_VideoController -Property Name, DriverVersion)
        $pick = $cards | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if (-not $pick) { $pick = $cards | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cards | Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cards | Select-Object -First 1 }
        $gpuName = if ($pick) { $pick.Name } else { 'Not Found' }
        $gpuDriver = if ($pick -and $pick.DriverVersion) { $pick.DriverVersion } else { 'Unknown' }
        $specs.Add([pscustomobject]@{ Kind = 'Gpu'; Label = 'GPU: '; Value = $gpuName })
        $specs.Add([pscustomobject]@{ Kind = 'Field'; Label = 'GPU Driver: '; Value = $gpuDriver })

        $specs.Add([pscustomobject]@{ Kind = 'Text'; Text = 'Disk Info:' })
        $driveToDisk = @{}
        try {
            foreach ($link in @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction Stop)) {
                $letter = [string]$link.Dependent.DeviceID
                $partition = [string]$link.Antecedent.DeviceID
                if (-not $letter -or $partition -notmatch 'Disk #(\d+)') { continue }
                $number = [int]$Matches[1]
                if (-not $driveToDisk.ContainsKey($letter)) { $driveToDisk[$letter] = New-Object 'System.Collections.Generic.List[int]' }
                if (-not $driveToDisk[$letter].Contains($number)) { $driveToDisk[$letter].Add($number) }
            }
        } catch { }
        $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -Property DeviceID, Size, FreeSpace | Sort-Object DeviceID
        foreach ($v in $volumes) {
            $diskIdentity = if ($driveToDisk.ContainsKey($v.DeviceID)) { " (Disk $($driveToDisk[$v.DeviceID] -join ', '))" } else { ' (Physical disk unknown)' }
            $specs.Add([pscustomobject]@{
                Kind  = 'Drive'
                Label = "Drive $($v.DeviceID)$diskIdentity | Total: "
                Total = ("{0:N2} GB" -f ($v.Size / 1GB))
                Used  = ("{0:N2} GB" -f (($v.Size - $v.FreeSpace) / 1GB))
                Free  = ("{0:N2} GB" -f ($v.FreeSpace / 1GB))
            })
        }

        try {
            $healthNames = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy'; 5 = 'Unknown' }
            $opNames = @{ 0 = 'Unknown'; 1 = 'Other'; 2 = 'OK'; 3 = 'Degraded'; 4 = 'Stressed'; 5 = 'Predictive Failure'; 6 = 'Error'; 7 = 'Non-Recoverable Error'
                          8 = 'Starting'; 9 = 'Stopping'; 10 = 'Stopped'; 11 = 'In Service'; 12 = 'No Contact'; 13 = 'Lost Communication'; 14 = 'Aborted'
                          15 = 'Dormant'; 16 = 'Supporting Entity in Error'; 17 = 'Completed' }
            $disks = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_PhysicalDisk `
                -Property DeviceId, FriendlyName, SerialNumber, UniqueId, HealthStatus, OperationalStatus -ErrorAction Stop |
                Sort-Object { [int]$_.DeviceId })
            foreach ($d in $disks) {
                $serial = if ($d.SerialNumber) { ([string]$d.SerialNumber).Trim() } elseif ($d.UniqueId) { [string]$d.UniqueId } else { 'ID unavailable' }
                $health = if ($healthNames.ContainsKey([int]$d.HealthStatus)) { $healthNames[[int]$d.HealthStatus] } else { "Status $($d.HealthStatus)" }
                $operational = @($d.OperationalStatus | ForEach-Object { if ($opNames.ContainsKey([int]$_)) { $opNames[[int]$_] } else { "Status $_" } }) -join ', '
                $specs.Add([pscustomobject]@{
                    Kind  = 'Field'
                    Label = "Disk $($d.DeviceId) Health: "
                    Value = "$($d.FriendlyName) | S/N: $serial | $health | $operational"
                })
            }
            if (-not $disks.Count) {
                $specs.Add([pscustomobject]@{ Kind = 'Field'; Label = 'Disk Health: '; Value = 'Not reported by this system' })
            }
        } catch {
            $specs.Add([pscustomobject]@{ Kind = 'Field'; Label = 'Disk Health: '; Value = 'Not available' })
        }

        $specs.Add([pscustomobject]@{ Kind = 'Text'; Text = '==============================' })
    } catch { }
    $specs
}

# Active, physical-looking adapters: must be Up and have a non-link-local IPv4. Virtual
# adapters (VMware, VirtualBox, Hyper-V, loopback) are skipped. Pure .NET, no module load.
function Get-ActiveNics {
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $type = $nic.NetworkInterfaceType.ToString()
        if ($type -notin 'Ethernet', 'GigabitEthernet', 'FastEthernet', 'Wireless80211') { continue }
        if ($nic.Name -match '^(VMware|VirtualBox|vEthernet|Loopback)') { continue }
        $props = $nic.GetIPProperties()
        $ipv4 = $null
        foreach ($unicast in $props.UnicastAddresses) {
            if ($unicast.Address.AddressFamily -eq 'InterNetwork' -and $unicast.Address.ToString() -notlike '169.*') {
                $ipv4 = $unicast.Address.ToString()
                break
            }
        }
        if (-not $ipv4) { continue }
        [pscustomobject]@{
            Nic         = $nic
            Name        = $nic.Name
            Description = $nic.Description
            IP          = $ipv4
            HasGateway  = ($props.GatewayAddresses.Count -gt 0)
            IsWired     = ($type -ne 'Wireless80211')
        }
    }
}

# The "real" interface: adapters with a gateway win, then wired beats Wi-Fi.
# (Gateway check catches VPN/virtual adapters better than matching on names.)
function Get-PrimaryNic {
    $best = $null
    foreach ($candidate in (Get-ActiveNics)) {
        if (-not $best -or
            ($candidate.HasGateway -and -not $best.HasGateway) -or
            ($candidate.HasGateway -eq $best.HasGateway -and $candidate.IsWired -and -not $best.IsWired)) {
            $best = $candidate
        }
    }
    return $best
}

function Get-PrimaryIPv4 {
    $nic = Get-PrimaryNic
    if ($nic) { return $nic.IP }
    return 'No IP'
}

### Shared helpers ###
# Windows respawns the shell on its own after it's killed. Only start it manually
# if it doesn't come back, otherwise you get a stray File Explorer window.
function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 150
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { return }
    }
    Start-Process explorer.exe
}

# One consistent look for short messages: cleared screen, cyan title, coloured message.
# With -Milliseconds it shows for that long and moves on; without, it waits for Enter.
function Show-Notice {
    param([string]$Title, [string]$Message, [ConsoleColor]$Color = 'White', [int]$Milliseconds = 0)
    Clear-Host
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ''
    Write-Host $Message -ForegroundColor $Color
    if ($Milliseconds -gt 0) { Start-Sleep -Milliseconds $Milliseconds }
    else { Write-Host ''; Read-Host 'Press Enter to return' | Out-Null }
}

# Every Write-Host call is a round trip to the console. Static screens are therefore
# pre-built once as a few multi-line, single-colour chunks and printed with one call each.
function Write-Batches {
    param($Batches)
    foreach ($batch in $Batches) {
        if ($batch.NoNewline) { Write-Host $batch.Text -ForegroundColor $batch.Color -NoNewline }
        else { Write-Host $batch.Text -ForegroundColor $batch.Color }
    }
}

# Reads a menu choice. While background work is still finishing it polls the keyboard,
# so the screen can repaint the moment the result arrives (the activation status fills
# in on its own) without losing what you've typed. When nothing is pending it simply
# blocks on the next key, using no CPU. Falls back to Read-Host if there's no real console.
function Read-MenuChoice {
    param([string]$Prompt = 'Select an option', [scriptblock]$Poll, [scriptblock]$Redraw)
    try {
        $buffer = New-Object System.Text.StringBuilder
        [void][Console]::KeyAvailable
        Write-Host -NoNewline "${Prompt}: "
        while ($true) {
            if (-not [Console]::KeyAvailable) {
                $state = if ($Poll) { & $Poll } else { $null }
                if ($state -eq $true -and $Redraw) {
                    & $Redraw
                    Write-Host -NoNewline ("${Prompt}: " + $buffer.ToString())
                }
                if ($null -ne $state) { Start-Sleep -Milliseconds 40; continue }
            }
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { Write-Host ''; return $buffer.ToString().Trim() }
            if ($key.Key -eq 'Backspace') {
                if ($buffer.Length -gt 0) { [void]$buffer.Remove($buffer.Length - 1, 1); [Console]::Write("`b `b") }
            } elseif ($key.KeyChar -ge ' ') {
                [void]$buffer.Append($key.KeyChar)
                [Console]::Write($key.KeyChar)
            }
        }
    } catch {
        return (Read-Host $Prompt).Trim()
    }
}

### Main Menu ###
function Write-MainMenuScreen {
    Clear-Host
    Write-Batches $script:MenuHead
    $statusColor = switch ($script:ActivationStatus) {
        'Activated'   { 'Green' }
        'Checking...' { 'Yellow' }
        default       { 'Red' }
    }
    Write-Host $script:OsPrefix -NoNewline -ForegroundColor Blue
    Write-Host $script:ActivationStatus -ForegroundColor $statusColor
    Write-Host $script:TimezoneLine -ForegroundColor DarkRed
    $uptime = (Get-Date) - $script:LastBoot
    Write-Host ("Uptime: {0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes) -ForegroundColor Cyan
    Write-Host ''
    Write-Batches $script:MenuBody
    Write-Host ''
}

function Show-MainMenu {
    $items = @(
        @{ Key='1';  Label='View System Specifications'; Column='System'; Group='System'; Action={ Show-SystemSpecifications } },
        @{ Key='2';  Label='View Activation Settings'; Column='System'; Group='System'; Action={ Start-Process 'ms-settings:activation' } },
        @{ Key='3';  Label='Computer Name Settings'; Column='System'; Group='System'; Action={ Start-Process 'SystemPropertiesComputerName.exe' } },
        @{ Key='4';  Label='Date & Time Settings'; Column='System'; Group='System'; Action={ Start-Process 'ms-settings:dateandtime' } },
        @{ Key='5';  Label='Core Isolation [W11]'; Column='System'; Group='System'; Action={ CreateAndOpenCoreIsolationURL } },
        @{ Key='6';  Label='Computer Management'; Column='System'; Group='System'; Action={ Start-Process 'compmgmt.msc' } },
        @{ Key='7';  Label='Network Adapters'; Column='System'; Group='System'; Action={ Start-Process 'ncpa.cpl' } },
        @{ Key='8';  Label='Energy Settings'; Column='System'; Group='System'; Action={ Start-Process 'powercfg.cpl' } },
        @{ Key='9';  Label='Task Scheduler'; Column='System'; Group='System'; Action={ Start-Process 'taskschd.msc' } },
        @{ Key='10'; Label='Mouse Settings'; Column='System'; Group='System'; Action={ Start-Process 'control.exe' -ArgumentList 'main.cpl,,2' } },
        @{ Key='11'; Label='Event Viewer'; Column='System'; Group='System'; Action={ Start-Process 'eventvwr.msc' } },
        @{ Key='12'; Label='Windows Update'; Column='System'; Group='System'; Action={ Start-Process 'ms-settings:windowsupdate' } },
        @{ Key='13'; Label='Task Manager'; Column='System'; Group='System'; Action={ Start-Process 'taskmgr.exe' } },
        @{ Key='14'; Label='Network Tools'; Column='System'; Group='System'; Action={ Show-NetworkTools } },
        @{ Key='15'; Label='Changelog'; Column='System'; Group='System'; Action={ Show-Changelog } },
        @{ Key='16'; Label='Windows Tweaks'; Column='Right'; Group='Tweaks'; Action={ WindowsTweaksMenu } },
        @{ Key='17'; Label='Nvidia Tweaks'; Column='Right'; Group='Tweaks'; Action={ NvidiaTweaksMenu } },
        @{ Key='18'; Label='Ninite app installer'; Column='Right'; Group='Setup'; Action={ Start-Process 'https://ninite.com' } },
        @{ Key='19'; Label='AMD Ryzen chipset drivers (TechPowerUp)'; Column='Right'; Group='Setup'; Action={ Start-Process 'https://www.techpowerup.com/download/amd-ryzen-chipset-drivers/' } },
        @{ Key='20'; Label='Visual C++ runtimes all-in-one (TechPowerUp)'; Column='Right'; Group='Setup'; Action={ Start-Process 'https://www.techpowerup.com/download/visual-c-redistributable-runtime-package-all-in-one/' } }
    )
    $itemsByKey = @{}
    foreach ($item in $items) { $itemsByKey[$item.Key] = $item }

    # Layout is static, so it is computed exactly once.
    $left = @($items | Where-Object { $_.Column -eq 'System' })
    $longestLeft = 0
    foreach ($item in $left) {
        $lineLength = ("{0}. {1}" -f $item.Key, $item.Label).Length
        if ($lineLength -gt $longestLeft) { $longestLeft = $lineLength }
    }
    $columnWidth = [Math]::Max(64, $longestLeft + 6)
    $rightDisplay = New-Object 'System.Collections.Generic.List[object]'
    foreach ($group in @('Tweaks', 'Setup')) {
        if ($group -eq 'Setup') {
            $rightDisplay.Add([pscustomobject]@{ IsSpacer = $true; IsHeader = $false; Text = '' })
            $rightDisplay.Add([pscustomobject]@{ IsSpacer = $false; IsHeader = $true; Text = '--- [First Setup Utilities] ---' })
        }
        foreach ($item in ($items | Where-Object { $_.Column -eq 'Right' -and $_.Group -eq $group })) {
            $rightDisplay.Add([pscustomobject]@{ IsSpacer = $false; IsHeader = $false; Text = ("{0}. {1}" -f $item.Key, $item.Label) })
        }
    }
    $rows = [Math]::Max($left.Count, $rightDisplay.Count)
    $newline = [Environment]::NewLine

    $head = New-Object 'System.Collections.Generic.List[object]'
    $head.Add(@{ Text = '==========================================================================='; Color = 'Yellow' })
    $head.Add(@{ Text = "Username: $userName | Hostname: $env:COMPUTERNAME | Domain: $domain | IP: $ip"; Color = 'Magenta' })
    $script:MenuHead = $head
    $script:OsPrefix = "Operating System: $osVersion | Activation: "
    $script:TimezoneLine = "Timezone: $timezoneDisplayName"

    $body = New-Object 'System.Collections.Generic.List[object]'
    $body.Add(@{ Text = ("--- [System Information] ---".PadRight($columnWidth) + "--- [Tweaks] ---"); Color = 'Yellow' })
    $white = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $rows; $i++) {
        $leftText = if ($i -lt $left.Count) { "{0}. {1}" -f $left[$i].Key, $left[$i].Label } else { '' }
        $rightRow = if ($i -lt $rightDisplay.Count) { $rightDisplay[$i] } else { $null }
        $padded = $leftText.PadRight($columnWidth)
        if ($rightRow -and $rightRow.IsHeader) {
            # The one row that mixes colours: white left column, yellow right-hand header.
            if ($white.Length) { $body.Add(@{ Text = $white.ToString(); Color = 'White' }); [void]$white.Clear() }
            $body.Add(@{ Text = $padded; Color = 'White'; NoNewline = $true })
            $body.Add(@{ Text = $rightRow.Text; Color = 'Yellow' })
        } else {
            $line = if ($rightRow -and -not $rightRow.IsSpacer) { $padded + $rightRow.Text } else { $padded.TrimEnd() }
            if ($white.Length) { [void]$white.Append($newline) }
            [void]$white.Append($line)
        }
    }
    if ($white.Length) { $body.Add(@{ Text = $white.ToString(); Color = 'White' }) }
    $script:MenuBody = $body

    $poll = {
        if (-not $script:Jobs.ContainsKey('Activation')) { return $null }
        return (Update-ActivationStatus)
    }
    $redraw = { Write-MainMenuScreen }

    while ($true) {
        Write-MainMenuScreen
        $selection = Read-MenuChoice -Prompt 'Select an option' -Poll $poll -Redraw $redraw
        if ($selection -match '^(q|quit)$') { return }
        $selectedItem = $itemsByKey[$selection]
        if ($selectedItem) {
            & $selectedItem.Action
        } else {
            Write-Host 'Invalid option.' -ForegroundColor Red
            Start-Sleep -Milliseconds 800
        }
    }
}

# Shared data-driven menu loop for submenus with the same title/options/selection pattern.
# The option list never changes, so it's rendered into a couple of multi-line chunks once;
# only the status block is re-evaluated on each pass.
function Invoke-DataMenu {
    param(
        [string]$Title,
        [array]$Items,
        [ConsoleColor]$Color = 'Cyan',
        [scriptblock]$StatusBlock,
        [string]$Prompt = 'Select an option'
    )
    $byKey = @{}
    $body = New-Object 'System.Collections.Generic.List[object]'
    $white = New-Object System.Text.StringBuilder
    $newline = [Environment]::NewLine
    foreach ($item in $Items) {
        if ($item.ContainsKey('Section')) {
            if ($white.Length) { $body.Add(@{ Text = $white.ToString(); Color = 'White' }); [void]$white.Clear() }
            $body.Add(@{ Text = $item.Section; Color = $Color })
        } else {
            $byKey[$item.Key] = $item
            if ($white.Length) { [void]$white.Append($newline) }
            [void]$white.Append(("{0}. {1}" -f $item.Key, $item.Label))
        }
    }
    if ($white.Length) { $body.Add(@{ Text = $white.ToString(); Color = 'White' }) }

    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor $Color
        if ($StatusBlock) { & $StatusBlock }
        Write-Batches $body
        $choice = (Read-Host $Prompt).Trim()
        if ($choice -match '^(q|quit)$') { return }
        $selected = $byKey[$choice]
        if (-not $selected) {
            Write-Host 'Invalid option.' -ForegroundColor Red
            Start-Sleep -Milliseconds 800
            continue
        }
        if ($selected.Action) { & $selected.Action }
        if ($selected.Exit) { return }
    }
}

function Show-Changelog {
    Clear-Host
    Write-Host '=== Changes Made by This Toolbox ===' -ForegroundColor Cyan
    Write-Host "Log file: $script:ChangeLogPath" -ForegroundColor DarkGray
    Write-Host ''
    $entries = @()
    if (Test-Path -LiteralPath $script:ChangeLogPath) {
        # Only the most recent entries: this stays instant however large the log grows.
        $entries = @(Get-Content -LiteralPath $script:ChangeLogPath -Tail 200 -ErrorAction SilentlyContinue)
    }
    if ($entries.Count) {
        Write-Host ($entries -join [Environment]::NewLine) -ForegroundColor White
    } else {
        Write-Host 'No changes have been recorded yet.' -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host 'Press Enter to return' | Out-Null
}

### Network tools ###
$script:DnsPresets = @(
    @{ Name = 'Cloudflare';  Servers = @('1.1.1.1', '1.0.0.1') },
    @{ Name = 'Google';      Servers = @('8.8.8.8', '8.8.4.4') },
    @{ Name = 'Quad9';       Servers = @('9.9.9.9', '149.112.112.112') },
    @{ Name = 'AdGuard DNS'; Servers = @('94.140.14.14', '94.140.15.15'); Note = 'blocks ads' }
)
$script:DnsTarget = $null
$script:DnsPick = $null
$script:DnsCandidates = @()

# Current DNS for one adapter. A NetworkInterface object is a snapshot, so the adapter is
# looked up again by id every time; that is what lets the screen show a change straight
# after it's applied. "Manual" means a DNS server is set by hand on the adapter (stored in
# the registry), otherwise it came from DHCP.
function Get-NicDnsInfo {
    param([string]$NicId)
    $servers = @()
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.Id -ne $NicId) { continue }
        foreach ($address in $nic.GetIPProperties().DnsAddresses) {
            if (-not $address.IsIPv6SiteLocal) { $servers += $address.ToString() }
        }
        break
    }
    $manual = $false
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$NicId")
        if ($key) { try { $manual = [bool]$key.GetValue('NameServer') } finally { $key.Close() } }
    } catch { }
    $provider = $null
    if ($servers.Count) {
        foreach ($preset in $script:DnsPresets) {
            if ($preset.Servers[0] -eq $servers[0]) { $provider = $preset.Name; break }
        }
    }
    [pscustomobject]@{ Servers = $servers; Manual = $manual; Provider = $provider }
}

function Write-NetworkStatus {
    param($NicInfo)
    $dns = Get-NicDnsInfo -NicId $NicInfo.Nic.Id
    Write-Host -NoNewline 'Adapter: ' -ForegroundColor Cyan
    Write-Host "$($NicInfo.Name) ($($NicInfo.IP))" -ForegroundColor White
    Write-Host -NoNewline 'DNS:     ' -ForegroundColor Cyan
    if ($dns.Servers.Count) {
        Write-Host -NoNewline ($dns.Servers -join ', ') -ForegroundColor Green
        $parts = @()
        if ($dns.Provider) { $parts += $dns.Provider }
        if ($dns.Manual) { $parts += 'manual' } else { $parts += 'automatic' }
        Write-Host " [$($parts -join ' | ')]" -ForegroundColor DarkGray
    } else {
        Write-Host 'none' -ForegroundColor Red
    }
}

function Show-PublicIp {
    Clear-Host
    Write-Host '=== Public IP ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Looking up...' -ForegroundColor DarkGray
    try {
        $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 7 -ErrorAction Stop).ToString().Trim()
        Write-Host "Public IP: $publicIp" -ForegroundColor Green
    } catch {
        Write-Host "Lookup failed: $_" -ForegroundColor Red
    }
    Write-Host ''
    Read-Host 'Press Enter to return' | Out-Null
}

function Invoke-DnsFlush {
    ipconfig.exe /flushdns | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-ToolChange 'Flushed the DNS cache'
        Show-Notice '=== Flush DNS Cache ===' 'DNS cache flushed.' Green 1200
    } else {
        Show-Notice '=== Flush DNS Cache ===' 'DNS cache flush failed.' Red 1600
    }
}

# Empty $Servers means "back to automatic (DHCP)". The adapter is addressed by name, so
# there's no index lookup, and the cache is flushed in the same elevated step.
function Set-DnsServers {
    param([string]$Name, [string[]]$Servers)
    $adapterName = $script:DnsTarget.Name
    $alias = $adapterName -replace "'", "''"
    if ($Servers.Count) {
        $list = (@($Servers | ForEach-Object { "'$_'" }) -join ', ')
        $scriptText = "Set-DnsClientServerAddress -InterfaceAlias '$alias' -ServerAddresses @($list) -ErrorAction Stop`nipconfig.exe /flushdns | Out-Null"
        $change = "Set DNS on adapter '$adapterName' to $($Servers -join ', ') ($Name)"
        $done = "Applied $Name to $adapterName."
    } else {
        $scriptText = "Set-DnsClientServerAddress -InterfaceAlias '$alias' -ResetServerAddresses -ErrorAction Stop`nipconfig.exe /flushdns | Out-Null"
        $change = "Restored automatic DNS (DHCP) on adapter '$adapterName'"
        $done = "Restored automatic DNS on $adapterName."
    }
    Write-Host "Applying $Name..." -ForegroundColor Yellow
    if (Invoke-AdminMutation -ScriptText $scriptText -Change $change) {
        Show-Notice '=== DNS Server ===' $done Green 1200
    }
}

function Set-DnsFromPreset {
    param([int]$Index)
    $preset = $script:DnsPresets[$Index]
    Set-DnsServers -Name $preset.Name -Servers $preset.Servers
}

function Read-CustomDns {
    Clear-Host
    Write-Host '=== Custom DNS ===' -ForegroundColor Cyan
    Write-Host "Adapter: $($script:DnsTarget.Name)" -ForegroundColor DarkGray
    Write-Host 'IPv4 or IPv6 addresses. Type Q to cancel.' -ForegroundColor DarkGray
    Write-Host ''
    $address = $null
    $primary = (Read-Host 'Primary DNS').Trim()
    if ($primary -match '^(q|quit)$') { return }
    if (-not [Net.IPAddress]::TryParse($primary, [ref]$address)) {
        Show-Notice '=== Custom DNS ===' 'That is not a valid IP address.' Red 1500
        return
    }
    $servers = @($primary)
    $secondary = (Read-Host 'Secondary DNS (optional)').Trim()
    if ($secondary -match '^(q|quit)$') { return }
    if ($secondary) {
        if (-not [Net.IPAddress]::TryParse($secondary, [ref]$address)) {
            Show-Notice '=== Custom DNS ===' 'That is not a valid IP address.' Red 1500
            return
        }
        $servers += $secondary
    }
    Set-DnsServers -Name 'Custom DNS' -Servers $servers
}

# One adapter: used straight away. Several: pick from a menu in the same style as the rest.
function Select-DnsAdapter {
    $nics = @(Get-ActiveNics)
    if (-not $nics.Count) {
        Show-Notice '=== DNS Server ===' 'No active network adapters found.' Yellow 1600
        return $null
    }
    if ($nics.Count -eq 1) { return $nics[0] }
    $script:DnsCandidates = $nics
    $script:DnsPick = $null
    $items = @()
    for ($i = 0; $i -lt $nics.Count; $i++) {
        $items += @{
            Key    = [string]($i + 1)
            Label  = ("{0} ({1}) - {2}" -f $nics[$i].Name, $nics[$i].IP, $nics[$i].Description)
            Exit   = $true
            Action = [scriptblock]::Create("`$script:DnsPick = `$script:DnsCandidates[$i]")
        }
    }
    $items += @{ Key = [string]($nics.Count + 1); Label = 'Return'; Exit = $true }
    Invoke-DataMenu -Title '=== Choose Network Adapter ===' -Items $items -Color Cyan
    return $script:DnsPick
}

function Show-DnsMenu {
    $target = Select-DnsAdapter
    if (-not $target) { return }
    $script:DnsTarget = $target
    $statusBlock = {
        Write-NetworkStatus $script:DnsTarget
        Write-Host '=================' -ForegroundColor Cyan
    }
    $items = @()
    for ($i = 0; $i -lt $script:DnsPresets.Count; $i++) {
        $preset = $script:DnsPresets[$i]
        $label = "{0,-12} {1}" -f $preset.Name, ($preset.Servers -join ' / ')
        if ($preset.Note) { $label += " ($($preset.Note))" }
        $items += @{ Key = [string]($i + 1); Label = $label; Action = [scriptblock]::Create("Set-DnsFromPreset -Index $i") }
    }
    $next = $script:DnsPresets.Count
    $items += @{ Key = [string]($next + 1); Label = 'Custom DNS addresses'; Action = { Read-CustomDns } }
    $items += @{ Key = [string]($next + 2); Label = 'Automatic (DHCP)'; Action = { Set-DnsServers -Name 'Automatic (DHCP)' -Servers @() } }
    $items += @{ Key = [string]($next + 3); Label = 'Return'; Exit = $true }
    Invoke-DataMenu -Title '=== DNS Server ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

function Show-NetworkTools {
    $statusBlock = {
        $primary = Get-PrimaryNic
        if ($primary) { Write-NetworkStatus $primary }
        else { Write-Host 'No active network adapter found.' -ForegroundColor Yellow }
        Write-Host '=====================' -ForegroundColor Cyan
    }
    $items = @(
        @{ Key='1'; Label='Show public IP'; Action={ Show-PublicIp } },
        @{ Key='2'; Label='Flush DNS cache'; Action={ Invoke-DnsFlush } },
        @{ Key='3'; Label='Change DNS server'; Action={ Show-DnsMenu } },
        @{ Key='4'; Label='Open Network Adapters'; Action={ Start-Process 'ncpa.cpl' } },
        @{ Key='5'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Network Tools ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

# GPU info for the Nvidia menus. Fetched once on demand and cached
# (the specs worker does its own query, so this never competes with startup).
# On laptops with an Intel iGPU plus a discrete card, NVIDIA is preferred, then AMD, then Intel.
function Get-GpuInformation {
    if (-not $script:GpuCache) {
        $cards = @(Get-CimInstance -ClassName Win32_VideoController -Property Name, DriverVersion)
        $pick = $cards | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
        if (-not $pick) { $pick = $cards | Where-Object { $_.Name -match 'AMD|Radeon' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cards | Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $cards | Select-Object -First 1 }
        $script:GpuCache = if ($pick) { $pick.Name } else { 'Not Found' }
        $script:GpuDriverCache = if ($pick -and $pick.DriverVersion) { $pick.DriverVersion } else { 'Unknown' }
    }
    return $script:GpuCache
}

### System specifications ###
# This exists purely to make the output look good. I wanted brand colors
# Intel blue, AMD red, NVIDIA green because the eye candy is always appreciated
# and it makes scanning the output much faster at a glance.
function Write-LabelValue {
    param (
        [string]$label,
        [string]$value,
        [ConsoleColor]$labelColor = "Cyan",
        [ConsoleColor]$valueColor = "White",
        [bool]$withPipe = $true
    )
    if ($withPipe) { Write-Host -NoNewline " | " -ForegroundColor $labelColor }
    Write-Host -NoNewline "$label" -ForegroundColor $labelColor
    Write-Host -NoNewline " $value" -ForegroundColor $valueColor
}

function Write-SystemSpecifications {
    Clear-Host
    foreach ($entry in $script:SystemSpecsCache) {
        switch ($entry.Kind) {
            'Text' { Write-Host $entry.Text -ForegroundColor Cyan }
            'Field' {
                Write-Host -NoNewline $entry.Label -ForegroundColor Cyan
                Write-Host $entry.Value -ForegroundColor White
            }
            'Cpu' {
                $cpuColor = "White"
                if ($entry.Name -match "Intel") { $cpuColor = "Blue" }
                elseif ($entry.Name -match "AMD") { $cpuColor = "Red" }
                Write-Host -NoNewline $entry.Label -ForegroundColor Cyan
                Write-Host -NoNewline $entry.Name -ForegroundColor $cpuColor
                Write-LabelValue -label "Cores:" -value $entry.Cores
                Write-LabelValue -label "Threads:" -value $entry.Threads
                Write-Host ""
            }
            'Gpu' {
                $gpuColor = "White"
                if ($entry.Value -match "NVIDIA") { $gpuColor = "Green" }
                elseif ($entry.Value -match "AMD|Radeon") { $gpuColor = "Red" }
                elseif ($entry.Value -match "INTEL") { $gpuColor = "Blue" }
                Write-Host -NoNewline $entry.Label -ForegroundColor Cyan
                Write-Host $entry.Value -ForegroundColor $gpuColor
            }
            'Drive' {
                Write-Host -NoNewline $entry.Label -ForegroundColor Cyan
                Write-Host -NoNewline $entry.Total -ForegroundColor White
                Write-LabelValue -label "Used:" -value $entry.Used
                Write-LabelValue -label "Free:" -value $entry.Free
                Write-Host ""
            }
        }
    }
}

# Specs come from the background prefetch. If it's still running we wait on it (with the
# loading screen); if it never started or failed, we collect them here instead.
function Initialize-SystemSpecs {
    if ($script:SystemSpecsCache) { return }
    $state = Update-BgJob -Name 'Specs'
    if ($state -eq $false) {
        Start-Loading
        $state = Update-BgJob -Name 'Specs' -Wait
    }
    if ($state -eq $true) {
        $data = @($script:BgData['Specs'])
        if ($data.Count) { $script:SystemSpecsCache = $data; return }
    }
    Start-Loading
    $script:SystemSpecsCache = @(& $script:SpecsQuery)
}

function Show-SystemSpecifications {
    Initialize-SystemSpecs
    while ($true) {
        Write-SystemSpecifications
        Write-Host ""
        Write-Host "1. Export to desktop"
        Write-Host "2. Return"
        Write-Host ""
        $choice = Read-Host "Choose an option"
        switch ($choice) {
            '1' {
                $exportPath = [IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "SystemSpecifications.txt")
                $linesToWrite = foreach ($e in $script:SystemSpecsCache) {
                    switch ($e.Kind) {
                        'Text'  { $e.Text }
                        { $_ -in 'Field', 'Gpu' } { "$($e.Label)$($e.Value)" }
                        'Cpu'   { "$($e.Label)$($e.Name) | Cores: $($e.Cores) | Threads: $($e.Threads)" }
                        'Drive' { "$($e.Label)$($e.Total) | Used: $($e.Used) | Free: $($e.Free)" }
                    }
                }
                try {
                    $linesToWrite | Out-File -FilePath $exportPath -Encoding UTF8 -ErrorAction Stop
                    Write-ToolChange "Exported system specifications to '$exportPath'"
                    Write-Host "`nExported to: $exportPath" -ForegroundColor Green
                } catch {
                    Write-Host "`nExport failed: $_" -ForegroundColor Red
                }
                Read-Host "Press Enter to return to specifications" | Out-Null
            }
            { $_ -in '2', 'q' } { return }
            default { Write-Host "Invalid option. Please select 1, 2 or Q." -ForegroundColor Red; Start-Sleep -Milliseconds 900 }
        }
    }
}

# Core Isolation lives behind a windowsdefender:// URI, which Windows won't open
# directly from a shortcut. A temporary .url file is the cleanest workaround I found.
# The file is removed when the toolbox exits (see the bottom of the script), so
# opening it no longer blocks the menu for a second.
function CreateAndOpenCoreIsolationURL {
    if ($osVersion -notlike "Windows 11*") {
        Write-Host "Core Isolation settings are only available in Windows 11." -ForegroundColor Red
        Start-Sleep -Milliseconds 1500   # the menu's Clear-Host used to wipe this instantly
        return
    }
    $script:CoreIsoUrlFile = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "Core Isolation.url"
    $urlContent = @"
[{000214A0-0000-0000-C000-000000000046}]
Prop3=19,0
[InternetShortcut]
IDList=
URL=windowsdefender://coreisolation/
"@
    Set-Content -Path $script:CoreIsoUrlFile -Value $urlContent -Encoding ASCII
    Start-Process $script:CoreIsoUrlFile
}

### DLSS ###
$script:DlssPath = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
$script:RegExe = Join-Path $env:windir 'System32\reg.exe'

function Get-DLSSIndicatorStatus {
    $value = (Get-ItemProperty -Path $script:DlssPath -Name "ShowDlssIndicator" -ErrorAction SilentlyContinue).ShowDlssIndicator
    if ($value -eq 0x400) { return "ENABLED" }
    return "DISABLED"
}

# reg.exe creates the key if it's missing and needs no PowerShell host to run.
function Set-DLSSIndicator {
    param([bool]$Enable)
    $value = if ($Enable) { 0x400 } else { 0 }
    $state = if ($Enable) { 'enabled' } else { 'disabled' }
    [void](Invoke-Elevated -File $script:RegExe `
        -Arguments "add `"HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore`" /v ShowDlssIndicator /t REG_DWORD /d $value /f" `
        -Change "Set NVIDIA DLSS indicator to $state")
}

function Show-DLSSMenu {
    $statusBlock = {
        $status = Get-DLSSIndicatorStatus
        $color = if ($status -eq "ENABLED") { "Green" } else { "Red" }
        Write-Host "Status: DLSS UI is currently $status." -ForegroundColor $color
        Write-Host "=======================" -ForegroundColor Cyan
    }
    $items = @(
        @{ Key='1'; Label='Enable DLSS UI'; Action={ Set-DLSSIndicator -Enable $true } },
        @{ Key='2'; Label='Disable DLSS UI'; Action={ Set-DLSSIndicator -Enable $false } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== DLSS UI Options ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

### NIS ###
# NVIDIA moved the EnableGR535 key between driver versions, so I check both
# locations and use whichever one already has the value. If neither does, writes
# default to the newer path. One resolver now serves both the status check and the setter.
$script:NisPrimary = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS"
$script:NisLegacy  = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
$script:NisProperty = "EnableGR535"

function Get-NISRegistryPath {
    foreach ($path in @($script:NisPrimary, $script:NisLegacy)) {
        if (Test-Path $path) {
            $props = Get-ItemProperty -Path $path -Name $script:NisProperty -ErrorAction SilentlyContinue
            if ($null -ne $props.($script:NisProperty)) { return $path }
        }
    }
    return $null
}

function Get-NISStatus {
    $path = Get-NISRegistryPath
    if (-not $path) { return "UNKNOWN (Key or Value Not Found)" }
    $value = (Get-ItemProperty -Path $path -Name $script:NisProperty).($script:NisProperty)
    switch ($value) {
        0 { return "OLD" }
        1 { return "NEW" }
        default { return "UNKNOWN ($value) at $path" }
    }
}

# The path is resolved here (reading HKLM needs no elevation), so the elevated part is a
# single reg.exe call.
function Set-NISMode {
    param([ValidateSet('New', 'Old')][string]$Mode)
    $value = if ($Mode -eq 'New') { 1 } else { 0 }
    $path = Get-NISRegistryPath
    if (-not $path) { $path = $script:NisPrimary }
    $regKey = $path -replace '^HKLM:\\', 'HKLM\'
    [void](Invoke-Elevated -File $script:RegExe `
        -Arguments "add `"$regKey`" /v $($script:NisProperty) /t REG_DWORD /d $value /f" `
        -Change "Set NVIDIA Image Scaling mode to $Mode")
}

function Show-NISMenu {
    $statusBlock = {
        $status = Get-NISStatus
        $color = switch ($status) {
            "NEW" { "Green" }
            "OLD" { "Yellow" }
            default { "Red" }
        }
        Write-Host "Status: NIS is currently set to $status." -ForegroundColor $color
        Write-Host "=========================================" -ForegroundColor Cyan
    }
    $items = @(
        @{ Key='1'; Label='Enable NEW NIS'; Action={ Set-NISMode -Mode New } },
        @{ Key='2'; Label='Enable OLD NIS'; Action={ Set-NISMode -Mode Old } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== NVIDIA Image Scaling (NIS) Options ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

### Nvidia Tweaks Menu ###
# The GPU name is cached after the first lookup, and gates features cleanly:
# no point offering DLSS to someone on a GTX.
function NvidiaTweaksMenu {
    $items = @(
        @{ Key='1'; Label='Toggle DLSS UI'; Action={
            $gpu = Get-GpuInformation
            if ($gpu -notlike 'NVIDIA GeForce RTX*') {
                Write-Host 'DLSS UI is not supported on your GPU.' -ForegroundColor Red
                Write-Host "Your GPU: $gpu" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 1850
            } else { Show-DLSSMenu }
        } },
        @{ Key='2'; Label='Toggle NVIDIA Image Scaling'; Action={
            $gpu = Get-GpuInformation
            if ($gpu -notlike 'NVIDIA*') {
                Write-Host 'NVIDIA Image Scaling is not supported on your GPU.' -ForegroundColor Red
                Write-Host "Your GPU: $gpu" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 1850
            } else { Show-NISMenu }
        } },
        @{ Key='3'; Label='Open NvidiaProfileInspector Releases'; Action={ Start-Process 'https://github.com/xHybred/NvidiaProfileInspectorRevamped/releases' } },
        @{ Key='4'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Nvidia Tweaks ===' -Items $items -Color Green
}

### Bluetooth ###
# Stays on PowerShell: stopping the service has to cope with dependent services,
# which Stop-Service -Force handles for us.
function Set-BluetoothService {
    param([bool]$Enable)
    if ($Enable) {
        $scriptText = "Set-Service -Name 'bthserv' -StartupType Manual -ErrorAction Stop`nStart-Service -Name 'bthserv' -ErrorAction Stop"
        $change = 'Enabled Bluetooth Support Service and set startup to Manual'
    } else {
        $scriptText = "Stop-Service -Name 'bthserv' -Force -ErrorAction Stop`nSet-Service -Name 'bthserv' -StartupType Disabled -ErrorAction Stop"
        $change = 'Stopped Bluetooth Support Service and set startup to Disabled'
    }
    [void](Invoke-AdminMutation -ScriptText $scriptText -Change $change)
}

function Show-Bluetooth-Discovery-Menu {
    $statusBlock = {
        $service = Get-Service -Name "bthserv" -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "Status: Bluetooth Support Service not found." -ForegroundColor Yellow
        } else {
            if ($service.Status -eq "Running") { Write-Host "Status: ENABLED" -ForegroundColor Green }
            else { Write-Host "Status: DISABLED" -ForegroundColor Red }
        }
    }
    $items = @(
        @{ Key='1'; Label='Enable Bluetooth Support Service (Start & Set to Manual)'; Action={ Set-BluetoothService -Enable $true } },
        @{ Key='2'; Label='Disable Bluetooth Support Service'; Action={ Set-BluetoothService -Enable $false } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Bluetooth Support Service ===' -Items $items -Color Cyan -Prompt 'Choose an option' -StatusBlock $statusBlock
}

### Wallpaper ###
function Export-DesktopWallpaper {
    # Profile-relative paths: the old hardcoded C:\Users\...\Desktop broke with
    # OneDrive-redirected desktops and profiles that don't live on C:.
    $wallpaperPath = Join-Path $env:APPDATA "Microsoft\Windows\Themes\TranscodedWallpaper"
    $desktopDir = [Environment]::GetFolderPath("Desktop")
    if (Test-Path $wallpaperPath) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $desktopPath = Join-Path $desktopDir "Wallpaper_$timestamp.jpg"
        try {
            Copy-Item -Path $wallpaperPath -Destination $desktopPath -ErrorAction Stop
            Write-ToolChange "Exported desktop wallpaper to '$desktopPath'"
            Write-Host "Wallpaper extracted successfully to $desktopPath" -ForegroundColor Green
        } catch {
            Write-Host "Could not export the wallpaper: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Wallpaper file not found at $wallpaperPath" -ForegroundColor Yellow
    }
    Read-Host "Press Enter to return" | Out-Null
}

# Windows compresses wallpapers by default, which is a bit annoying when you've
# set a carefully chosen image. The JPEGImportQuality value sets the JPEG quality to 100
# so what you see is actually what you set. Removing it restores the default behavior.
$script:WallpaperRegPath = 'Control Panel\Desktop'

function Get-WallpaperQuality {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:WallpaperRegPath)
    if (-not $key) { return $null }
    try { return $key.GetValue('JPEGImportQuality') } finally { $key.Close() }
}

function Set-WallpaperQuality {
    param([bool]$Uncompressed)
    $current = Get-WallpaperQuality
    $already = if ($Uncompressed) { $current -eq 100 } else { $null -eq $current }
    if ($already) {
        Show-Notice '=== Wallpaper Quality ===' 'Already set, nothing to change.' Yellow 1000
        return
    }
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:WallpaperRegPath, $true)
        try {
            if ($Uncompressed) { $key.SetValue('JPEGImportQuality', 100, [Microsoft.Win32.RegistryValueKind]::DWord) }
            else { $key.DeleteValue('JPEGImportQuality', $false) }
        } finally { $key.Close() }
    } catch {
        Show-Notice '=== Wallpaper Quality ===' "Failed to modify registry: $_" Red 2000
        return
    }
    if ($Uncompressed) { Write-ToolChange 'Set wallpaper JPEG import quality to 100 (uncompressed)' }
    else { Write-ToolChange 'Restored default wallpaper compression' }
    Clear-Host
    Write-Host '=== Wallpaper Quality ===' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Restarting Explorer...' -ForegroundColor Yellow
    Restart-Explorer
    Write-Host 'Done. Changes applied.' -ForegroundColor Green
    Start-Sleep -Milliseconds 900
}

function Show-WallpaperQualityMenu {
    $statusBlock = {
        $quality = Get-WallpaperQuality
        if ($quality -eq 100) { Write-Host 'Status: Wallpapers are currently Uncompressed.' -ForegroundColor Green }
        elseif ($null -eq $quality) { Write-Host 'Status: Wallpapers are currently Compressed (Windows default).' -ForegroundColor Red }
        else { Write-Host "Status: Wallpapers use a custom JPEG quality ($quality)." -ForegroundColor Yellow }
        Write-Host '=========================' -ForegroundColor Cyan
    }
    $items = @(
        @{ Key='1'; Label='Uncompressed (JPEG quality 100)'; Action={ Set-WallpaperQuality -Uncompressed $true } },
        @{ Key='2'; Label='Compressed [Default]'; Action={ Set-WallpaperQuality -Uncompressed $false } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Wallpaper Quality ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

### PowerShell History ###
function Remove-PowerShellHistory {
    $confirmation = Read-Host 'Delete the PowerShell history file and in-memory history? (Y/N)'
    if ($confirmation -notmatch '^(y|yes)$') {
        Write-Host "History deletion cancelled." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 900
        return
    }

    # Ask PSReadLine where the history really lives (works for Windows PowerShell and pwsh).
    $historyPath = $null
    try { $historyPath = (Get-PSReadLineOption).HistorySavePath } catch { }
    if (-not $historyPath) { $historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" }

    # Also drop the in-memory history so up-arrow can't bring it back this session.
    try { [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() } catch { }
    Clear-History -ErrorAction SilentlyContinue

    try {
        if (Test-Path $historyPath) {
            Remove-Item $historyPath -Force -ErrorAction Stop
            Write-Host "PowerShell history deleted." -ForegroundColor Green
        } else {
            Write-Host "PowerShell history file not found or already deleted" -ForegroundColor Yellow
        }
        Write-ToolChange 'Cleared in-memory PowerShell history and deleted the history file if it existed'
    } catch {
        Write-Host "Could not delete the history file: $_" -ForegroundColor Red
    }
    Start-Sleep -Seconds 1
}

### Context Menu ###
# HKCU only, so none of this needs elevation.
$script:ClassicMenuClsid = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"

function Get-ContextMenuStatus {
    if (Test-Path "$($script:ClassicMenuClsid)\InprocServer32") { return "Windows Classic" }
    return "Windows 11 Default"
}

function Enable-ContextMenu {
    $path = "$($script:ClassicMenuClsid)\InprocServer32"
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name "(Default)" -Value "" -ErrorAction Stop
    Write-ToolChange 'Enabled the classic Windows 11 context menu'
    Restart-Explorer
}

function Disable-ContextMenu {
    $wasEnabled = Test-Path "$($script:ClassicMenuClsid)\InprocServer32"
    Remove-Item -Path $script:ClassicMenuClsid -Recurse -Force -ErrorAction SilentlyContinue
    if ($wasEnabled) { Write-ToolChange 'Restored the default Windows 11 context menu' }
    Restart-Explorer
}

function Show-ContextMenu {
    if ($osVersion -notlike 'Windows 11*') {
        Write-Host "The Windows 11 context menu option is only available on Windows 11." -ForegroundColor Red
        Start-Sleep -Milliseconds 1600
        return
    }
    $statusBlock = {
        $status = Get-ContextMenuStatus
        $color = if ($status -eq "Windows Classic") { "Green" } else { "Red" }
        Write-Host "Status: Context menu is currently $status." -ForegroundColor $color
        Write-Host "===============================" -ForegroundColor Cyan
    }
    $items = @(
        @{ Key='1'; Label='Enable classic context menu'; Action={ Enable-ContextMenu } },
        @{ Key='2'; Label='Restore Windows 11 default'; Action={ Disable-ContextMenu } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Windows 11 Context Menu ===' -Items $items -Color Cyan -StatusBlock $statusBlock
}

### Spicetify ###
# Right-click entry on the desktop background that runs "spicetify update".
# The command is stored as -EncodedCommand, so the registry value has no quotes or pipe
# characters for the shell to mangle; -NoExit keeps the window open to read the output.
# The entry lives under HKCU (per-user, no admin needed). Older versions of this toolbox
# wrote a machine-wide copy under HKLM; that one can only be removed with admin rights,
# so it is detected separately and cleaned up (one UAC prompt) when you apply or remove.
# Registry access is plain .NET: no provider overhead and no quirks with the "(Default)" value.
$script:SpicetifySubKey = 'Software\Classes\DesktopBackground\Shell\SpicetifyUpdate'
$script:SpicetifyMachineKey = 'HKLM\SOFTWARE\Classes\DesktopBackground\Shell\SpicetifyUpdate'
$script:SpicetifyRunCmd = 'spicetify update'
$script:WinPowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:SpicetifyCommand = '"' + $script:WinPowerShell + '" -NoProfile -NoExit -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:SpicetifyRunCmd))

function Test-SpicetifyMachineEntry {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\DesktopBackground\Shell\SpicetifyUpdate')
    if (-not $key) { return $false }
    $key.Close()
    return $true
}

# APPLIED = current entry in place. OUTDATED = an older entry exists (different command,
# or the old machine-wide copy), and applying replaces it. NOT APPLIED = nothing there.
function Get-SpicetifyStatus {
    if (Test-SpicetifyMachineEntry) { return 'OUTDATED' }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$($script:SpicetifySubKey)\command")
    if (-not $key) { return 'NOT APPLIED' }
    try { $command = $key.GetValue('') } finally { $key.Close() }
    if ($command -eq $script:SpicetifyCommand) { return 'APPLIED' }
    return 'OUTDATED'
}

function Set-SpicetifyContextMenu {
    param([bool]$Apply)
    $before = Get-SpicetifyStatus
    if (-not $Apply -and $before -eq 'NOT APPLIED') {
        Show-Notice '=== Spicetify Context Menu ===' 'Nothing to remove.' Yellow 1000
        return
    }
    try {
        if (Test-SpicetifyMachineEntry) {
            $removed = Invoke-Elevated -File $script:RegExe `
                -Arguments "delete `"$($script:SpicetifyMachineKey)`" /f" `
                -Change 'Removed the old machine-wide Spicetify context-menu entry'
            if (-not $removed) { return }
        }
        $hkcu = [Microsoft.Win32.Registry]::CurrentUser
        $hkcu.DeleteSubKeyTree($script:SpicetifySubKey, $false)   # always start clean
        if ($Apply) {
            $key = $hkcu.CreateSubKey($script:SpicetifySubKey)
            try {
                $key.SetValue('MUIVerb', 'Update Spicetify')
                $icon = Join-Path $env:APPDATA 'Spotify\Spotify.exe'
                if ([IO.File]::Exists($icon)) { $key.SetValue('Icon', $icon) }
            } finally { $key.Close() }
            $commandKey = $hkcu.CreateSubKey("$($script:SpicetifySubKey)\command")
            try { $commandKey.SetValue('', $script:SpicetifyCommand) } finally { $commandKey.Close() }
            Write-ToolChange 'Added the Spicetify update desktop context-menu entry'
            Show-Notice '=== Spicetify Context Menu ===' 'Added. Right-click the desktop to use it.' Green 1200
        } else {
            Write-ToolChange 'Removed the Spicetify desktop context-menu entry'
            Show-Notice '=== Spicetify Context Menu ===' 'Removed.' Green 1000
        }
    } catch {
        Show-Notice '=== Spicetify Context Menu ===' "Could not update the entry: $_" Red 2000
    }
}

function Show-SpicetifyMenu {
    $statusBlock = {
        switch (Get-SpicetifyStatus) {
            'APPLIED'  { Write-Host 'Status: APPLIED' -ForegroundColor Green }
            'OUTDATED' { Write-Host 'Status: OUTDATED (old entry found, choose 1 to replace it)' -ForegroundColor Yellow }
            default    { Write-Host 'Status: NOT APPLIED' -ForegroundColor Red }
        }
        Write-Host "Runs: $($script:SpicetifyRunCmd)" -ForegroundColor DarkGray
        Write-Host '==============================' -ForegroundColor Green
    }
    $items = @(
        @{ Key='1'; Label='Add right-click entry (spicetify update)'; Action={ Set-SpicetifyContextMenu -Apply $true } },
        @{ Key='2'; Label='Remove right-click entry'; Action={ Set-SpicetifyContextMenu -Apply $false } },
        @{ Key='3'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '=== Spicetify Context Menu ===' -Items $items -Color Green -StatusBlock $statusBlock
}

### Wi-Fi ###
# One 'netsh wlan export' for every profile, then read the XML. That is a single
# call instead of one per profile, and it doesn't depend on Windows' display
# language (the old parser looked for the English "All User Profile" / "Key Content").
# The exported files sit in a throwaway temp folder that is deleted straight away.
function Show-WifiPasswords {
    Clear-Host
    Write-Host "=== Wi-Fi Passwords ===" -ForegroundColor Cyan
    Write-Host ""

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("wlan_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        netsh wlan export profile key=clear folder="$tmp" | Out-Null
        $files = @(Get-ChildItem -Path $tmp -Filter *.xml -ErrorAction SilentlyContinue)

        if ($files.Count -eq 0) {
            Write-Host "No Wi-Fi profiles found." -ForegroundColor Yellow
        } else {
            $rows = foreach ($f in $files) {
                $xml = New-Object System.Xml.XmlDocument
                $xml.Load($f.FullName)
                $shared = $xml.WLANProfile.MSM.security.sharedKey
                $password = if (-not $shared) { "No password / Open network" }
                            elseif ($shared.protected -eq 'true') { "(run as administrator to reveal)" }
                            else { $shared.keyMaterial }
                [pscustomobject]@{ Name = $xml.WLANProfile.name; Password = $password }
            }
            foreach ($row in ($rows | Sort-Object Name)) {
                Write-Host -NoNewline "$($row.Name)" -ForegroundColor White
                Write-Host -NoNewline " | " -ForegroundColor Cyan
                Write-Host "$($row.Password)" -ForegroundColor Green
            }
        }
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Read-Host "Press Enter to return" | Out-Null
}

### Windows Tweaks Menu ###
function WindowsTweaksMenu {
    $items = @(
        @{ Key='1'; Label='Toggle Bluetooth Discovery'; Action={ Show-Bluetooth-Discovery-Menu } },
        @{ Key='2'; Label='Export Desktop Wallpaper'; Action={ Export-DesktopWallpaper } },
        @{ Key='3'; Label='Delete PowerShell History'; Action={ Remove-PowerShellHistory } },
        @{ Key='4'; Label='Toggle Wallpaper Decompressor'; Action={ Show-WallpaperQualityMenu } },
        @{ Key='5'; Label='Toggle Windows 11 Context Menu Style [W11]'; Action={ Show-ContextMenu } },
        @{ Key='6'; Label='Spicetify update on right-click context menu'; Action={ Show-SpicetifyMenu } },
        @{ Key='7'; Label='Show saved Wi-Fi passwords'; Action={ Show-WifiPasswords } },
        @{ Key='8'; Label='Return'; Exit=$true }
    )
    Invoke-DataMenu -Title '--- [Windows Tweaks] ---' -Items $items -Color Blue
}

### Startup ###
# Everything above is only function definitions, so the loading screen appears right away.
# Order matters for speed: the worker threads are launched first, so the activation and
# specs queries overlap with the lookups the header needs instead of running after them.
try {
    Start-Loading

    try {
        $script:Pool = [RunspaceFactory]::CreateRunspacePool(1, 2)
        $script:Pool.Open()
    } catch { $script:Pool = $null }

    Start-BgJob -Name 'Activation' -Work $script:ActivationQuery
    if ($script:PrefetchSpecs) { Start-BgJob -Name 'Specs' -Work $script:SpecsQuery }
    if (-not $script:Jobs.ContainsKey('Activation')) { $script:ActivationStatus = 'Unknown' }

    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1]

    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption, LastBootUpTime
    $osVersion = $osInfo.Caption -replace '^Microsoft ', ''
    $script:LastBoot = $osInfo.LastBootUpTime   # Cached once, uptime is computed live from this

    $timezoneDisplayName = [TimeZoneInfo]::Local.DisplayName

    # Domain-joined machines report their DNS domain instantly via .NET.
    # Workgroup machines return nothing there, so only then do we fall back to CIM.
    $domain = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    if (-not $domain) { $domain = (Get-CimInstance -ClassName Win32_ComputerSystem -Property Domain).Domain }

    $ip = Get-PrimaryIPv4

    Show-MainMenu
} finally {
    # Clean up the temp shortcut from Core Isolation, if one was made.
    if ($script:CoreIsoUrlFile -and (Test-Path $script:CoreIsoUrlFile)) {
        Remove-Item -Path $script:CoreIsoUrlFile -Force -ErrorAction SilentlyContinue
    }
    # Ask any unfinished worker to stop without waiting for it, so exiting is never slowed
    # down by a WMI query that is still running.
    foreach ($job in @($script:Jobs.Values)) {
        try { [void]$job.PS.BeginStop($null, $null) } catch { }
    }
    if ($script:Pool) { try { [void]$script:Pool.BeginClose($null, $null) } catch { } }
}
