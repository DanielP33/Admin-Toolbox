# Aesthetics
$host.UI.RawUI.BackgroundColor = 'Black'

# I didn't know how to credit myself without being invasive, so I used the loading
# screen it's the one moment the user is just waiting anyway.
function Start-Loading {
    Clear-Host
    Write-Host "Loading, please wait..." -ForegroundColor Yellow
    Write-Host "By Daniel P. ~ Updated 2026" -ForegroundColor Green
}
Start-Loading

# I collected everything upfront in as few CIM calls as possible.
# These values don't change while the script is running, so there's no reason
# to keep asking the system for them on every menu refresh.
$fullUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$userName = $fullUserName.Split('\')[-1]

$osInfo = Get-CimInstance -Class Win32_OperatingSystem
$osVersion = ($osInfo.Caption -replace '^Microsoft ', '')
$global:LastBoot = $osInfo.LastBootUpTime   # Cached once, uptime is computed live from this

$timezoneDisplayName = (Get-TimeZone).DisplayName
$domain = (Get-CimInstance Win32_ComputerSystem).Domain

# GPU is also cached globally here it never changes mid-session and
# I call it from multiple menus, so one CIM call is enough.
$global:GpuCache = $null

# I ordered this list by how "real" the interface is likely to be.
# Virtual adapters and secondary interfaces kept slipping through before I did this.
$interfacePriority = @('^Ethernet$', '^Ethernet ?\d+$', '^Wi-Fi$', '^Wi-Fi ?\d+$')

$validAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.IPAddress -notlike '169.*' -and
    $_.IPAddress -ne '127.0.0.1' -and
    $_.InterfaceAlias -notmatch '^(VMware|VirtualBox|vEthernet|Loopback)'
}

$ip = $null
foreach ($pattern in $interfacePriority) {
    $matchedInterfaces = $validAddresses | Where-Object { $_.InterfaceAlias -match $pattern }
    $sorted = $matchedInterfaces | Sort-Object {
        if ($_ -match '\d+') { [int]($_.InterfaceAlias -replace '\D+', '') } else { -1 }
    }
    $first = $sorted | Select-Object -First 1
    if ($first) { $ip = $first.IPAddress; break }
}
if (-not $ip) { $ip = "No IP" }

### Main Menu ###
function Show-MainMenu {
    while ($true) {
        Clear-Host

        # Uptime is computed fresh each loop from the cached boot time 
        # no extra system calls, just math.
        $uptime = (Get-Date) - $global:LastBoot
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
            'q'  { break }
            default { Write-Host "Invalid Option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

$global:SystemSpecsCache = $null

# GPU info is fetched once and stored globally. Every place that needs it
# calls this function if the cache is already there, it just returns it.
function Get-GpuInformation {
    if (-not $global:GpuCache) {
        $gpu = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -match "NVIDIA|AMD|Intel" } |
            Select-Object -First 1 -ExpandProperty Name
        $global:GpuCache = if ($gpu) { $gpu } else { "Not Found" }
    }
    return $global:GpuCache
}

function Get-SystemSpecifications {
    $specList = @()
    $specList += "==== System Specifications ===="

    $motherboard = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $specList += @{ label = "Motherboard: "; value = $motherboard.Product }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuInfo = "$($cpu.Name.Trim()) | Cores: $($cpu.NumberOfCores) | Threads: $($cpu.NumberOfLogicalProcessors)"
    $specList += @{ label = "CPU: "; value = $cpuInfo }

    $memModules = Get-CimInstance Win32_PhysicalMemory
    $ramGB = [math]::Round(($memModules | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
    $moduleCount = $memModules.Count
    $ramSpeed = ($memModules | Select-Object -First 1).Speed
    $ramLine = "$ramGB GB ($moduleCount sticks @ ${ramSpeed}MHz)"
    $specList += @{ label = "RAM: "; value = $ramLine }

    $gpu = Get-GpuInformation
    $specList += @{ label = "GPU: "; value = $gpu }

    $specList += "Disk Info:"
    $volumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $partitions = Get-Partition
    $disks = Get-Disk

    foreach ($disk in $disks) {
        $diskNumber = $disk.Number
        $relatedPartitions = $partitions | Where-Object { $_.DiskNumber -eq $diskNumber }
        foreach ($partition in $relatedPartitions) {
            if ($partition.DriveLetter) {
                $drive = $volumes | Where-Object { $_.DeviceID -eq "$($partition.DriveLetter):" }
                if ($drive) {
                    $used  = "{0:N2}" -f (($drive.Size - $drive.FreeSpace) / 1GB)
                    $free  = "{0:N2}" -f ($drive.FreeSpace / 1GB)
                    $sizeGB = "{0:N2}" -f ($disk.Size / 1GB)
                    $specList += @{
                        label = "Drive $($partition.DriveLetter): | Total: "
                        total = "$sizeGB GB"
                        used  = "$used GB"
                        free  = "$free GB"
                    }
                }
            }
        }
    }

    $specList += "=============================="
    return $specList
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
    foreach ($entry in $global:SystemSpecsCache) {
        if ($entry -is [System.Collections.Hashtable]) {
            if ($entry.ContainsKey('total') -and $entry.ContainsKey('used') -and $entry.ContainsKey('free')) {
                Write-Host -NoNewline $entry.label -ForegroundColor Cyan
                Write-Host -NoNewline $entry.total -ForegroundColor White
                Write-LabelValue -label "Used:" -value $entry.used
                Write-LabelValue -label "Free:" -value $entry.free
                Write-Host ""
            } elseif ($entry["label"] -eq "CPU: ") {
                $cpuInfo = $entry["value"]
                $parts = $cpuInfo -split '\|'
                $cpuName = $parts[0].Trim()
                $cpuColor = "White"
                if ($cpuName -match "Intel") { $cpuColor = "Blue" }
                elseif ($cpuName -match "AMD") { $cpuColor = "Red" }
                Write-Host -NoNewline $entry["label"] -ForegroundColor Cyan
                Write-Host -NoNewline $cpuName -ForegroundColor $cpuColor
                if ($parts.Count -gt 1) {
                    $cores = $parts[1].Trim() -replace '^Cores:\s*', ''
                    Write-LabelValue -label "Cores:" -value $cores -labelColor Cyan
                }
                if ($parts.Count -gt 2) {
                    $threads = $parts[2].Trim() -replace '^Threads:\s*', ''
                    Write-LabelValue -label "Threads:" -value $threads -labelColor Cyan
                }
                Write-Host ""
            } elseif ($entry["label"] -eq "GPU: ") {
                $gpuName = $entry["value"]
                $gpuColor = "White"
                if ($gpuName -match "NVIDIA") { $gpuColor = "Green" }
                elseif ($gpuName -match "AMD") { $gpuColor = "Red" }
                elseif ($gpuName -match "INTEL") { $gpuColor = "Blue" }
                Write-Host -NoNewline $entry["label"] -ForegroundColor Cyan
                Write-Host $gpuName -ForegroundColor $gpuColor
            } else {
                Write-Host -NoNewline $entry["label"] -ForegroundColor Cyan
                Write-Host $entry["value"] -ForegroundColor White
            }
        } elseif ($entry -is [string]) {
            Write-Host $entry -ForegroundColor Cyan
        }
    }
}

function Show-SystemSpecifications {
    # Specs are cached after the first load the hardware isn't going anywhere.
    # The loading screen only shows once per session.
    if (-not $global:SystemSpecsCache) {
        Start-Loading
        $global:SystemSpecsCache = Get-SystemSpecifications
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
                $exportPath = [System.IO.Path]::Combine(
                    [Environment]::GetFolderPath("Desktop"),
                    "SystemSpecifications.txt"
                )
                $linesToWrite = @()
                foreach ($entry in $global:SystemSpecsCache) {
                    if ($entry -is [System.Collections.Hashtable]) {
                        if ($entry.ContainsKey('total') -and $entry.ContainsKey('used') -and $entry.ContainsKey('free')) {
                            $linesToWrite += "$($entry.label)$($entry.total) | Used: $($entry.used) | Free: $($entry.free)"
                        } else {
                            $linesToWrite += "$($entry.label)$($entry.value)"
                        }
                    } elseif ($entry -is [string]) {
                        $linesToWrite += $entry
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
# directly from a shortcut. A temporary .url file is the cleanest workaround I found
# it opens, does its job, and gets deleted right after so it doesn't litter the temp folder.
function CreateAndOpenCoreIsolationURL {
    if ($osVersion -notlike "Windows 11*") {
        Write-Host "Core Isolation settings are only available in Windows 11." -ForegroundColor Red
        return
    }
    $tempDirectory = [System.IO.Path]::GetTempPath()
    $urlFilePath = Join-Path -Path $tempDirectory -ChildPath "Core Isolation.url"
    $urlContent = @"
[{000214A0-0000-0000-C000-000000000046}]
Prop3=19,0
[InternetShortcut]
IDList=
URL=windowsdefender://coreisolation/
"@
    Set-Content -Path $urlFilePath -Value $urlContent -Encoding ASCII
    Start-Process $urlFilePath
    Start-Sleep -Seconds 1
    Remove-Item -Path $urlFilePath -Force
}

### DLSS ###
function Get-DLSSIndicatorStatus {
    $path = "HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore"
    if (Test-Path $path) {
        $value = Get-ItemProperty -Path $path -Name "ShowDlssIndicator" -ErrorAction SilentlyContinue
        if ($value -and $value.ShowDlssIndicator -eq 0x400) { return "ENABLED" }
        else { return "DISABLED" }
    }
    return "DISABLED"
}

function Enable-DLSSIndicator {
    $script = @"
if (-not (Test-Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore')) {
    New-Item -Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore' -Force | Out-Null
}
Set-ItemProperty -Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore' -Name 'ShowDlssIndicator' -Type DWord -Value 0x400
"@
    Start-Process powershell -ArgumentList "-NoProfile -Command `$script = @'`n$script`n'@; Invoke-Expression `$script" -Verb RunAs
}

function Disable-DLSSIndicator {
    $script = @"
if (-not (Test-Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore')) {
    New-Item -Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore' -Force | Out-Null
}
Set-ItemProperty -Path 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NGXCore' -Name 'ShowDlssIndicator' -Type DWord -Value 0x000
"@
    Start-Process powershell -ArgumentList "-NoProfile -Command `$script = @'`n$script`n'@; Invoke-Expression `$script" -Verb RunAs
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
            '1' { Enable-DLSSIndicator; Start-Sleep -Milliseconds 599; continue }
            '2' { Disable-DLSSIndicator; Start-Sleep -Milliseconds 599; continue }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Seconds 1; continue }
        }
    }
}

### NIS ###
# NVIDIA moved the EnableGR535 key between driver versions, so I check both
# locations and write to whichever one already exists. If neither does, I default
# to the newer path. It's a bit defensive, but it saves confusion down the line.
function Get-NISStatus {
    $paths = @(
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
    )
    $propertyName = "EnableGR535"
    foreach ($path in $paths) {
        if (Test-Path $path) {
            $regProps = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
            if ($null -ne $regProps.$propertyName) {
                switch ($regProps.$propertyName) {
                    0 { return "OLD" }
                    1 { return "NEW" }
                    default { return "UNKNOWN ($($regProps.$propertyName)) at $path" }
                }
            }
        }
    }
    return "UNKNOWN (Key or Value Not Found)"
}

function Enable-NISNew {
    $script = @'
$primary = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS"
$legacy  = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
$property = "EnableGR535"
if ((Test-Path $primary) -and ((Get-ItemProperty -Path $primary -Name $property -ErrorAction SilentlyContinue).$property -ne $null)) {
    $path = $primary
} elseif ((Test-Path $legacy) -and ((Get-ItemProperty -Path $legacy -Name $property -ErrorAction SilentlyContinue).$property -ne $null)) {
    $path = $legacy
} else {
    $path = $primary
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}
Set-ItemProperty -Path $path -Name $property -Type DWord -Value 1
'@
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $encodedCommand = [Convert]::ToBase64String($bytes)
    Start-Process powershell -ArgumentList "-NoProfile -EncodedCommand $encodedCommand" -Verb RunAs
}

function Enable-NISOld {
    $script = @'
$primary = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS"
$legacy  = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
$property = "EnableGR535"
if ((Test-Path $primary) -and ((Get-ItemProperty -Path $primary -Name $property -ErrorAction SilentlyContinue).$property -ne $null)) {
    $path = $primary
} elseif ((Test-Path $legacy) -and ((Get-ItemProperty -Path $legacy -Name $property -ErrorAction SilentlyContinue).$property -ne $null)) {
    $path = $legacy
} else {
    $path = $primary
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}
Set-ItemProperty -Path $path -Name $property -Type DWord -Value 0
'@
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $encodedCommand = [Convert]::ToBase64String($bytes)
    Start-Process powershell -ArgumentList "-NoProfile -EncodedCommand $encodedCommand" -Verb RunAs
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
            '1' { Enable-NISNew; Start-Sleep -Milliseconds 599; continue }
            '2' { Enable-NISOld; Start-Sleep -Milliseconds 599; continue }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Milliseconds 1350; continue }
        }
    }
}

### Nvidia Tweaks Menu ###
# I cache the GPU name here rather than letting each sub-menu fetch it independently.
# It also lets me gate features cleanly no point offering DLSS to someone on a GTX.
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
                    continue
                }
                Show-DLSSMenu
            }
            '2' {
                Clear-Host
                if ($gpu -notlike "NVIDIA*") {
                    Write-Host "Nvidia Image Scaling is not supported on your GPU." -ForegroundColor Red
                    Write-Host "Your GPU: $gpu" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 1850
                    continue
                }
                Show-NISMenu
            }
            '3' { Start-Process "https://github.com/xHybred/NvidiaProfileInspectorRevamped/releases" }
            { $_ -in '4', 'q' } { return }
            default { Write-Host "Invalid Option." -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

### Bluetooth ###
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
                Write-Host "Enabling Bluetooth Support Service (elevated)..."
                $cmd = "Set-Service -Name 'bthserv' -StartupType Manual; Start-Service -Name 'bthserv' -ErrorAction SilentlyContinue"
                Start-Process powershell -ArgumentList "-NoProfile -Command $cmd" -Verb RunAs
                Start-Sleep -Seconds 1
            }
            '2' {
                Clear-Host
                Write-Host "Disabling Bluetooth Support Service (elevated)..."
                $cmd = "Stop-Service -Name 'bthserv' -Force -ErrorAction SilentlyContinue; Set-Service -Name 'bthserv' -StartupType Disabled"
                Start-Process powershell -ArgumentList "-NoProfile -Command $cmd" -Verb RunAs
                Start-Sleep -Seconds 1
            }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid choice. Please enter 1, 2, 3 or q."; Start-Sleep -Seconds 1 }
        }
    }
}

### Wallpaper ###
function Export-DesktopWallpaper {
    $wallpaperPath = "C:\Users\$env:USERNAME\AppData\Roaming\Microsoft\Windows\Themes\TranscodedWallpaper"
    $desktopDir = "C:\Users\$env:USERNAME\Desktop"
    if (Test-Path $wallpaperPath) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $desktopPath = Join-Path $desktopDir "Wallpaper_$timestamp.jpg"
        Copy-Item -Path $wallpaperPath -Destination $desktopPath
        Write-Host "Wallpaper extracted successfully to $desktopPath"
    } else {
        Write-Host "Wallpaper file not found at $wallpaperPath"
    }
    Write-Host "Press Enter to exit..."
    [void][System.Console]::ReadLine()
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
        switch ($choice) {
            "1" {
                $regValue = 100
                if (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue) {
                    Set-ItemProperty -Path $regPath -Name $regName -Value $regValue
                    Write-Host "Set $regName to $regValue (Uncompressed)."
                } else {
                    New-ItemProperty -Path $regPath -Name $regName -PropertyType DWord -Value $regValue
                    Write-Host "Created $regName with value $regValue (Uncompressed)."
                }
            }
            "2" {
                if (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty -Path $regPath -Name $regName
                    Write-Host "Removed $regName. Wallpaper compression set to default."
                } else {
                    Write-Host "$regName not set. Already at default compression."
                }
            }
            default { Write-Host "Invalid choice. Exiting..."; exit }
        }
        Start-Sleep -Milliseconds 15
        Write-Host "Restarting Explorer..."
        Stop-Process -Name explorer -Force
        Start-Process explorer
        Write-Host "Explorer restarted. Changes applied."
    } catch {
        Write-Error "Failed to modify registry: $_"
    }
}

### PowerShell History ###
function Remove-PowerShellHistory {
    $historyPath = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    if (Test-Path $historyPath) {
        Remove-Item $historyPath -Force
        Write-Host "PowerShell history deleted." -ForegroundColor Green
        Start-Sleep -Seconds 1
    } else {
        Write-Host "PowerShell history file not found or already deleted" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

### Context Menu ###
function Get-ContextMenuStatus {
    if (Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32") {
        return "Windows Classic"
    }
    return "Windows 11 Default"
}

function Enable-ContextMenu {
    $script = @'
$path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
Set-ItemProperty -Path $path -Name "(Default)" -Value ""
Stop-Process -Name explorer -Force
Start-Process explorer.exe
'@
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -EncodedCommand $encoded"
}

# Spicetify doesn't come with a convenient update shortcut, so I added one to the
# right-click desktop menu. It's a small quality-of-life thing that saves a few
# steps for anyone who uses Spicetify regularly.
function Show-SpicetifyMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Spicetify Context Menu ===" -ForegroundColor Green
        Write-Host @"
1. Apply context menu entry
2. Remove context menu entry
3. Return
"@ -ForegroundColor White

        if (-not (Test-Path "HKCR:\")) {
            New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -ErrorAction SilentlyContinue | Out-Null
        }
        $status = if (Test-Path "HKCR:\DesktopBackground\Shell\SpicetifyUpdate") { "APPLIED" } else { "NOT APPLIED" }
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

function Show-WifiPasswords {
    Clear-Host
    Write-Host "=== Wi-Fi Passwords ===" -ForegroundColor Cyan
    Write-Host ""

    $profiles = netsh wlan show profiles |
        Where-Object { $_ -match "All User Profile\s*:\s*(.+)" } |
        ForEach-Object { $matches[1].Trim() }

    if (-not $profiles) {
        Write-Host "No Wi-Fi profiles found." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "Press Enter to return"
        return
    }

    foreach ($profile in $profiles) {
        $details = netsh wlan show profile name="$profile" key=clear
        $passLine = $details | Where-Object { $_ -match "Key Content\s*:\s*(.+)" }
        $password = if ($passLine) { $matches[1].Trim() } else { "No password / Open network" }

        Write-Host -NoNewline "$profile" -ForegroundColor White
        Write-Host -NoNewline " | " -ForegroundColor Cyan
        Write-Host "$password" -ForegroundColor Green
    }

    Write-Host ""
    Read-Host "Press Enter to return"
}

function Invoke-SpicetifyContextMenu {
    param([switch]$Apply)

    $script = if ($Apply) { @'
if (-not (Test-Path "HKCR:\")) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}
$shellKey = "HKCR:\DesktopBackground\Shell\SpicetifyUpdate"
New-Item -Path $shellKey -Force | Out-Null
Set-ItemProperty -Path $shellKey -Name "MUIVerb"  -Value "Spicetify Update"
Set-ItemProperty -Path $shellKey -Name "Icon"     -Value "$env:APPDATA\Spotify\Spotify.exe"
Set-ItemProperty -Path $shellKey -Name "Position" -Value "Middle"
New-Item -Path "$shellKey\command" -Force | Out-Null
Set-ItemProperty -Path "$shellKey\command" -Name "(Default)" -Value "powershell -NoExit -Command `"spicetify update`""
'@
    } else { @'
if (-not (Test-Path "HKCR:\")) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}
Remove-Item -Path "HKCR:\DesktopBackground\Shell\SpicetifyUpdate" -Recurse -Force -ErrorAction SilentlyContinue
'@
    }

    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -EncodedCommand $encoded"
    Start-Sleep -Seconds 1
}


function Disable-ContextMenu {
    $script = @'
$path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
Stop-Process -Name explorer -Force
Start-Process explorer.exe
'@
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -EncodedCommand $encoded"
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
        $color = if ($status -eq "TWEAKED") { "Green" } else { "Red" }
        Write-Host "Status: Context menu is currently $status." -ForegroundColor $color
        Write-Host "===============================" -ForegroundColor Cyan
        $choice = Read-Host "Select an option"
        switch ($choice) {
            '1' { Enable-ContextMenu; Start-Sleep -Seconds 2 }
            '2' { Disable-ContextMenu; Start-Sleep -Seconds 2 }
            { $_ -in '3', 'q' } { return }
            default { Write-Host "Invalid option, please try again." -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
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
Show-MainMenu