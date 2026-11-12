#Requires -Version 5.1

# Aesthetics
$host.UI.RawUI.BackgroundColor = 'Black'

### Elevation ###
# Elevate once at launch instead of spawning a new elevated PowerShell for every toggle.
# If UAC is declined (or the script is piped in without a file path) we carry on
# unelevated, and admin-only actions explain themselves instead of failing silently.
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin -and $PSCommandPath) {
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        exit
    } catch { }
}

function Test-AdminOrWarn {
    if ($script:IsAdmin) { return $true }
    Write-Host "This action needs administrator rights. Restart the toolbox and accept the UAC prompt." -ForegroundColor Red
    Start-Sleep -Milliseconds 1800
    return $false
}

# I didn't know how to credit myself without being invasive, so I used the loading
# screen it's the one moment the user is just waiting anyway.
function Start-Loading {
    Clear-Host
    Write-Host "Loading, please wait..." -ForegroundColor Yellow
    Write-Host "By Daniel P. ~ Updated 2026" -ForegroundColor Green
}
Start-Loading

# Collected once up front. None of this changes while the script runs, so there's
# no reason to keep asking the system for it on every menu refresh.
# Plain .NET calls are used where possible: they skip the module-load cost that
# cmdlets like Get-NetIPAddress / Get-TimeZone pay on first use.
$userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1]

$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption, LastBootUpTime
$osVersion = $osInfo.Caption -replace '^Microsoft ', ''
$script:LastBoot = $osInfo.LastBootUpTime   # Cached once, uptime is computed live from this

$timezoneDisplayName = [TimeZoneInfo]::Local.DisplayName

# Domain-joined machines report their DNS domain instantly via .NET.
# Workgroup machines return nothing there, so only then do we fall back to CIM.
$domain = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
if (-not $domain) { $domain = (Get-CimInstance -ClassName Win32_ComputerSystem -Property Domain).Domain }

$script:GpuCache = $null
$script:SystemSpecsCache = $null
$script:CoreIsoUrlFile = $null

# Picks the "real" interface: must be Up, physical-looking, and have an IPv4 that
# isn't link-local. Adapters with a gateway win, then wired beats Wi-Fi.
# (Gateway check catches VPN/virtual adapters better than matching on names.)
function Get-PrimaryIPv4 {
    $candidates = foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $type = $nic.NetworkInterfaceType.ToString()
        if ($type -notin 'Ethernet', 'GigabitEthernet', 'FastEthernet', 'Wireless80211') { continue }
        if ($nic.Name -match '^(VMware|VirtualBox|vEthernet|Loopback)') { continue }
        $props = $nic.GetIPProperties()
        $addr = $props.UnicastAddresses |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -notlike '169.*' } |
            Select-Object -First 1
        if (-not $addr) { continue }
        [pscustomobject]@{
            IP      = $addr.Address.ToString()
            Gateway = [bool]$props.GatewayAddresses.Count
            Wired   = ($type -ne 'Wireless80211')
        }
    }
    $best = $candidates |
        Sort-Object @{ Expression = 'Gateway'; Descending = $true }, @{ Expression = 'Wired'; Descending = $true } |
        Select-Object -First 1
    if ($best) { return $best.IP }
    return 'No IP'
}
$ip = Get-PrimaryIPv4

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

### Main Menu ###
function Show-MainMenu {
    while ($true) {
        Clear-Host

        # Uptime is computed fresh each loop from the cached boot time
        # no extra system calls, just math.
        $uptime = (Get-Date) - $script:LastBoot
        $uptimeStr = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes

        Write-Host "===========================================================================" -ForegroundColor Yellow
        Write-Host ("Username: $userName | Hostname: $env:COMPUTERNAME | Domain: $domain | IP: $ip") -ForegroundColor Magenta
        Write-Host ("Operating System: $osVersion") -ForegroundColor Blue
        Write-Host ("Timezone: $timezoneDisplayName") -ForegroundColor DarkRed
        Write-Host ("Uptime: $uptimeStr") -ForegroundColor Cyan
        Write-Host ""
        Write-Host "--- [System Information] ---                               --- [Tweaks] ---" -ForegroundColor Yellow
        Write-Host @"
1.  View System Specifications                             12. Windows Tweaks
2.  Windows Activation Status                              13. Nvidia Tweaks
3.  Computer Name Settings
4.  Date & Time Settings
5.  Core Isolation [W11]
6.  Computer Management
7.  Network Adapters
8.  Energy Settings
9.  Task Scheduler
10. Mouse Settings
11. Event Viewer
"@ -ForegroundColor White
        Write-Host ""
        $selection = Read-Host "Select an option"
        switch ($selection) {
            '1'  { Show-SystemSpecifications }
            '2'  { Start-Process "ms-settings:activation" }
            '3'  { Start-Process "SystemPropertiesComputerName.exe" }
            '4'  { Start-Process "ms-settings:dateandtime" }
            '5'  { CreateAndOpenCoreIsolationURL }
            '6'  { Start-Process "compmgmt.msc" }
            '7'  { Start-Process "ncpa.cpl" }
            '8'  { Start-Process "powercfg.cpl" }
            '9'  { Start-Process "taskschd.msc" }
            '10' { Start-Process "control.exe" -ArgumentList "main.cpl,,2" }
            '11' { Start-Process "eventvwr.msc" }
            '12' { WindowsTweaksMenu }
            '13' { NvidiaTweaksMenu }
            'q'  { return }   # 'break' here only left the switch, so Q never quit
            default { Write-Host "Invalid Option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

# GPU info is fetched once and cached. On laptops with an Intel iGPU plus a discrete
# card, NVIDIA is preferred, then AMD, then whatever is left (Intel).
function Get-GpuInformation {
    if (-not $script:GpuCache) {
        $names = @(Get-CimInstance -ClassName Win32_VideoController -Property Name |
            Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Intel' } |
            ForEach-Object { $_.Name })
        $pick = $names | Where-Object { $_ -match 'NVIDIA' } | Select-Object -First 1
        if (-not $pick) { $pick = $names | Where-Object { $_ -match 'AMD|Radeon' } | Select-Object -First 1 }
        if (-not $pick) { $pick = $names | Select-Object -First 1 }
        $script:GpuCache = if ($pick) { $pick } else { "Not Found" }
    }
    return $script:GpuCache
}

# Specs are stored as small typed objects instead of strings that get re-parsed
# when printing. Only the CIM classes we actually need are queried, with only the
# properties we show. Drive sizes come from Win32_LogicalDisk, so each volume
# reports its own size (previously it reported the whole physical disk).
function Get-SystemSpecifications {
    $specs = New-Object 'System.Collections.Generic.List[object]'
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

    $mem = @(Get-CimInstance -ClassName Win32_PhysicalMemory -Property Capacity, Speed)
    $ramGB = [math]::Round(($mem | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
    $specs.Add([pscustomobject]@{
        Kind  = 'Field'
        Label = 'RAM: '
        Value = "$ramGB GB ($($mem.Count) sticks @ $($mem[0].Speed)MHz)"
    })

    $specs.Add([pscustomobject]@{ Kind = 'Gpu'; Label = 'GPU: '; Value = (Get-GpuInformation) })

    $specs.Add([pscustomobject]@{ Kind = 'Text'; Text = 'Disk Info:' })
    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -Property DeviceID, Size, FreeSpace |
        Sort-Object DeviceID
    foreach ($v in $volumes) {
        $specs.Add([pscustomobject]@{
            Kind  = 'Drive'
            Label = "Drive $($v.DeviceID) | Total: "
            Total = ("{0:N2} GB" -f ($v.Size / 1GB))
            Used  = ("{0:N2} GB" -f (($v.Size - $v.FreeSpace) / 1GB))
            Free  = ("{0:N2} GB" -f ($v.FreeSpace / 1GB))
        })
    }

    $specs.Add([pscustomobject]@{ Kind = 'Text'; Text = '==============================' })
    return $specs
}

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

function Show-SystemSpecifications {
    # Specs are cached after the first load the hardware isn't going anywhere.
    # The loading screen only shows once per session.
    if (-not $script:SystemSpecsCache) {
        Start-Loading
        $script:SystemSpecsCache = Get-SystemSpecifications
    }
    Write-SystemSpecifications
    while ($true) {
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
                $linesToWrite | Out-File -FilePath $exportPath -Encoding UTF8
                Write-Host "`nExported to: $exportPath" -ForegroundColor Green
            }
            { $_ -in '2', 'q' } { return }
            default { Write-Host "Invalid option. Please select 1, 2 or Q." -ForegroundColor Red }
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

function Get-DLSSIndicatorStatus {
    $value = (Get-ItemProperty -Path $script:DlssPath -Name "ShowDlssIndicator" -ErrorAction SilentlyContinue).ShowDlssIndicator
    if ($value -eq 0x400) { return "ENABLED" }
    return "DISABLED"
}

function Set-DLSSIndicator {
    param([bool]$Enable)
    if (-not (Test-AdminOrWarn)) { return }
    if (-not (Test-Path $script:DlssPath)) { New-Item -Path $script:DlssPath -Force | Out-Null }
    $value = if ($Enable) { 0x400 } else { 0 }
    Set-ItemProperty -Path $script:DlssPath -Name "ShowDlssIndicator" -Type DWord -Value $value
}

function Show-DLSSMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== DLSS UI Options ===" -ForegroundColor Cyan
        Write-Host @"
1. Enable DLSS UI
2. Disable DLSS UI
3. Return
"@ -ForegroundColor White
        $status = Get-DLSSIndicatorStatus
        $color = if ($status -eq "ENABLED") { "Green" } else { "Red" }
        Write-Host "Status: DLSS UI is currently $status." -ForegroundColor $color
        Write-Host "=======================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Set-DLSSIndicator -Enable $true }
            '2' { Set-DLSSIndicator -Enable $false }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
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

function Set-NISMode {
    param([ValidateSet('New', 'Old')][string]$Mode)
    if (-not (Test-AdminOrWarn)) { return }
    $path = Get-NISRegistryPath
    if (-not $path) {
        $path = $script:NisPrimary
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    }
    $value = if ($Mode -eq 'New') { 1 } else { 0 }
    Set-ItemProperty -Path $path -Name $script:NisProperty -Type DWord -Value $value
}

function Show-NISMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== NVIDIA Image Scaling (NIS) Options ===" -ForegroundColor Cyan
        Write-Host @"
1. Enable NEW NIS
2. Enable OLD NIS
3. Return
"@ -ForegroundColor White
        $status = Get-NISStatus
        $color = switch ($status) {
            "NEW" { "Green" }
            "OLD" { "Yellow" }
            default { "Red" }
        }
        Write-Host "Status: NIS is currently set to $status." -ForegroundColor $color
        Write-Host "=========================================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Set-NISMode -Mode New }
            '2' { Set-NISMode -Mode Old }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Milliseconds 1350 }
        }
    }
}

### Nvidia Tweaks Menu ###
# GPU name is cached once and passed to the gates below, so no sub-menu fetches it
# on its own. It also lets me gate features cleanly no point offering DLSS to someone on a GTX.
function NvidiaTweaksMenu {
    $gpu = Get-GpuInformation

    while ($true) {
        Clear-Host
        Write-Host "=== Nvidia Tweaks ===" -ForegroundColor Green
        Write-Host "1. Toggle DLSS UI" -ForegroundColor White
        Write-Host "2. Toggle Nvidia Image Scaling" -ForegroundColor White
        Write-Host "3. Open NvidiaProfileInspector Releases" -ForegroundColor White
        Write-Host "4. Return" -ForegroundColor White
        Write-Host "======================" -ForegroundColor Green

        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' {
                Clear-Host
                if ($gpu -notlike "NVIDIA GeForce RTX*") {
                    Write-Host "DLSS UI is not supported on your GPU." -ForegroundColor Red
                    Write-Host "Your GPU: $gpu" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 1850
                } else {
                    Show-DLSSMenu
                }
            }
            '2' {
                Clear-Host
                if ($gpu -notlike "NVIDIA*") {
                    Write-Host "Nvidia Image Scaling is not supported on your GPU." -ForegroundColor Red
                    Write-Host "Your GPU: $gpu" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 1850
                } else {
                    Show-NISMenu
                }
            }
            '3' { Start-Process "https://github.com/xHybred/NvidiaProfileInspectorRevamped/releases" }
            { $_ -in '4', 'q' } { return }
            default { Write-Host "Invalid Option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

### Bluetooth ###
function Set-BluetoothService {
    param([bool]$Enable)
    if (-not (Test-AdminOrWarn)) { return }
    if ($Enable) {
        Set-Service -Name 'bthserv' -StartupType Manual
        Start-Service -Name 'bthserv' -ErrorAction SilentlyContinue
    } else {
        Stop-Service -Name 'bthserv' -Force -ErrorAction SilentlyContinue
        Set-Service -Name 'bthserv' -StartupType Disabled
    }
}

function Show-Bluetooth-Discovery-Menu {
    while ($true) {
        Clear-Host
        Write-Host @"
1. Enable Bluetooth Support Service (Start & Set to Manual)
2. Disable Bluetooth Discoverability (Stop & Disable Bluetooth Support Service)
3. Return
"@ -ForegroundColor White
        $service = Get-Service -Name "bthserv" -ErrorAction SilentlyContinue
        Write-Host ""
        if ($null -eq $service) {
            Write-Host "Status: Bluetooth Support Service not found." -ForegroundColor Yellow
        } else {
            if ($service.Status -eq "Running") { Write-Host "Status: ENABLED" -ForegroundColor Green }
            else { Write-Host "Status: DISABLED" -ForegroundColor Red }
        }
        $choice = Read-Host "`nChoose an option"
        switch ($choice) {
            '1' {
                Clear-Host
                Write-Host "Enabling Bluetooth Support Service..."
                Set-BluetoothService -Enable $true
            }
            '2' {
                Clear-Host
                Write-Host "Disabling Bluetooth Support Service..."
                Set-BluetoothService -Enable $false
            }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid choice. Please enter 1, 2, 3 or q."; Start-Sleep -Seconds 1 }
        }
    }
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
        Copy-Item -Path $wallpaperPath -Destination $desktopPath
        Write-Host "Wallpaper extracted successfully to $desktopPath" -ForegroundColor Green
    } else {
        Write-Host "Wallpaper file not found at $wallpaperPath" -ForegroundColor Yellow
    }
    Read-Host "Press Enter to return" | Out-Null
}

# Windows compresses wallpapers by default, which is a bit annoying when you've
# set a carefully chosen image. This registry key sets the JPEG quality to 100
# so what you see is actually what you set. Removing the key restores the default behavior.
function Set-WallpaperDecompressor {
    Clear-Host
    $regPath = "HKCU:\Control Panel\Desktop"
    $regName = "JPEGImportQuality"
    Write-Host "Select mode:"
    Write-Host "1. Uncompressed"
    Write-Host "2. Compressed [Default]"
    $choice = Read-Host "Enter your choice 1 or 2"
    try {
        $changed = $true
        switch ($choice) {
            "1" {
                $existed = $null -ne (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue)
                Set-ItemProperty -Path $regPath -Name $regName -Type DWord -Value 100
                if ($existed) { Write-Host "Set $regName to 100 (Uncompressed)." }
                else { Write-Host "Created $regName with value 100 (Uncompressed)." }
            }
            "2" {
                if (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty -Path $regPath -Name $regName
                    Write-Host "Removed $regName. Wallpaper compression set to default."
                } else {
                    Write-Host "$regName not set. Already at default compression."
                    $changed = $false
                }
            }
            default {
                # This used to call 'exit', which closed the whole toolbox.
                Write-Host "Invalid choice." -ForegroundColor Red
                Start-Sleep -Milliseconds 800
                return
            }
        }
        if ($changed) {
            Write-Host "Restarting Explorer..."
            Restart-Explorer
            Write-Host "Explorer restarted. Changes applied."
        }
        Start-Sleep -Milliseconds 1200
    } catch {
        Write-Host "Failed to modify registry: $_" -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
}

### PowerShell History ###
function Remove-PowerShellHistory {
    # Ask PSReadLine where the history really lives (works for Windows PowerShell and pwsh).
    $historyPath = $null
    try { $historyPath = (Get-PSReadLineOption).HistorySavePath } catch { }
    if (-not $historyPath) { $historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" }

    # Also drop the in-memory history so up-arrow can't bring it back this session.
    try { [Microsoft.PowerShell.PSConsoleReadLine]::ClearHistory() } catch { }
    Clear-History -ErrorAction SilentlyContinue

    if (Test-Path $historyPath) {
        Remove-Item $historyPath -Force
        Write-Host "PowerShell history deleted." -ForegroundColor Green
    } else {
        Write-Host "PowerShell history file not found or already deleted" -ForegroundColor Yellow
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
    Set-ItemProperty -Path $path -Name "(Default)" -Value ""
    Restart-Explorer
}

function Disable-ContextMenu {
    Remove-Item -Path $script:ClassicMenuClsid -Recurse -Force -ErrorAction SilentlyContinue
    Restart-Explorer
}

function Show-ContextMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Windows 11 Context Menu ===" -ForegroundColor Cyan
        Write-Host @"
1. Enable classic context menu
2. Restore Windows 11 default
3. Return
"@ -ForegroundColor White
        $status = Get-ContextMenuStatus
        # This compared against "TWEAKED", which the status function never returns.
        $color = if ($status -eq "Windows Classic") { "Green" } else { "Red" }
        Write-Host "Status: Context menu is currently $status." -ForegroundColor $color
        Write-Host "===============================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Enable-ContextMenu }
            '2' { Disable-ContextMenu }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

### Spicetify ###
# Spicetify doesn't come with a convenient update shortcut, so I added one to the
# right-click desktop menu. It's a small quality-of-life thing that saves a few
# steps for anyone who uses Spicetify regularly.
# The entry now lives under HKCU\Software\Classes (per-user, no admin needed, and
# 'spicetify update' runs as you rather than elevated). The status check reads the
# merged HKCR view so entries from the old version are still detected.
$script:SpicetifyKey = "HKCU:\Software\Classes\DesktopBackground\Shell\SpicetifyUpdate"

function Get-SpicetifyStatus {
    if (Test-Path "Registry::HKEY_CLASSES_ROOT\DesktopBackground\Shell\SpicetifyUpdate") { return "APPLIED" }
    return "NOT APPLIED"
}

function Invoke-SpicetifyContextMenu {
    param([switch]$Apply)
    $key = $script:SpicetifyKey
    if ($Apply) {
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name "MUIVerb"  -Value "Spicetify Update"
        Set-ItemProperty -Path $key -Name "Icon"     -Value "$env:APPDATA\Spotify\Spotify.exe"
        Set-ItemProperty -Path $key -Name "Position" -Value "Middle"
        New-Item -Path "$key\command" -Force | Out-Null
        Set-ItemProperty -Path "$key\command" -Name "(Default)" -Value 'powershell -NoExit -Command "spicetify update"'
    } else {
        Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        # Entries made by the old version were machine-wide; clear those too when we can.
        if ($script:IsAdmin) {
            Remove-Item -Path "HKLM:\SOFTWARE\Classes\DesktopBackground\Shell\SpicetifyUpdate" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-SpicetifyMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Spicetify Context Menu ===" -ForegroundColor Green
        Write-Host @"
1. Apply context menu entry
2. Remove context menu entry
3. Return
"@ -ForegroundColor White

        $status = Get-SpicetifyStatus
        $color  = if ($status -eq "APPLIED") { "Green" } else { "Red" }
        Write-Host "Status: $status" -ForegroundColor $color
        Write-Host "==============================" -ForegroundColor Green

        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Invoke-SpicetifyContextMenu -Apply }
            '2' { Invoke-SpicetifyContextMenu }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
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
    while ($true) {
        Clear-Host
        Write-Host "--- [Windows Tweaks] ---" -ForegroundColor Blue
        Write-Host @"
1.  Toggle Bluetooth Discovery
2.  Export Desktop Wallpaper
3.  Delete PowerShell History
4.  Toggle Wallpaper Decompressor
5.  Toggle Windows 11 Context Menu Style
6.  Spicetify Updater on right click context menu (Requires Spotify)
7.  Show Wi-Fi passwords already discovered
8.  Return
"@ -ForegroundColor White
        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Show-Bluetooth-Discovery-Menu }
            '2' { Export-DesktopWallpaper }
            '3' { Remove-PowerShellHistory }
            '4' { Set-WallpaperDecompressor }
            '5' { Show-ContextMenu }
            '6' { Show-SpicetifyMenu }
            '7' { Show-WifiPasswords }
            { $_ -in '8', 'q' } { return }
            default { Write-Host "Invalid Option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

# Everything starts here.
try {
    Show-MainMenu
} finally {
    # Clean up the temp shortcut from Core Isolation, if one was made.
    if ($script:CoreIsoUrlFile -and (Test-Path $script:CoreIsoUrlFile)) {
        Remove-Item -Path $script:CoreIsoUrlFile -Force -ErrorAction SilentlyContinue
    }
}
