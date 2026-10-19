#requires -Version 5.1
<#
    WinScanner - Windows 10/11 Docker, WSL2 & Gaming readiness report

    Read-only diagnostic script. Collects system information relevant to
    running Docker Desktop / WSL2 and to gaming performance / stability, and
    writes a single human-readable text report. Makes no changes to the
    system, installs nothing, and does not transmit data anywhere - the
    report stays on the local machine. (The latency snapshot sends a few
    ICMP pings to the default gateway and public DNS resolvers.)

    Note: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less
    scripts as ANSI, so non-ASCII characters in strings would be garbled.
#>

$ErrorActionPreference = 'SilentlyContinue'

$timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputDir  = Join-Path $env:USERPROFILE "Desktop"
$reportPath = Join-Path $outputDir "WinScanner_Report_$timestamp.txt"

$lines = New-Object System.Collections.Generic.List[string]

# While a Run-Step action is executing, Add-Line writes into a per-step
# notes buffer that is flushed AFTER the step's returned objects, so notes
# appear below the table they describe instead of above it.
$script:StepNotes = $null

function Add-Line {
    param([string]$Text = "")
    if ($null -ne $script:StepNotes) {
        $script:StepNotes.Add($Text)
    } else {
        $lines.Add($Text)
    }
}

function Add-Header {
    param([string]$Title)
    Add-Line ""
    Add-Line "==================================================================="
    Add-Line " $Title"
    Add-Line "==================================================================="
}

function Run-Step {
    param(
        [string]$Title,
        [scriptblock]$Action
    )
    Add-Header $Title
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:StepNotes = New-Object System.Collections.Generic.List[string]
    try {
        $result = & $Action
        $notes = $script:StepNotes
        $script:StepNotes = $null
        if ($null -eq $result -or ($result | Measure-Object).Count -eq 0) {
            if ($notes.Count -eq 0) { Add-Line "(no data returned)" }
        } else {
            $result | Out-String -Width 200 | ForEach-Object {
                $_.TrimEnd() -split "`r?`n" | ForEach-Object { Add-Line $_ }
            }
        }
        foreach ($n in $notes) { Add-Line $n }
    } catch {
        $notes = $script:StepNotes
        $script:StepNotes = $null
        if ($notes) { foreach ($n in $notes) { Add-Line $n } }
        Add-Line "ERROR: $($_.Exception.Message)"
    } finally {
        $script:StepNotes = $null
        $sw.Stop()
        $script:StepTimings[$Title] = $sw.ElapsedMilliseconds
    }
}

# ------------------------------------------------------------------
# Helpers (all read-only, never throw)
# ------------------------------------------------------------------
function Get-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Default = ""
    )
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $value = $item.$Name
        if ($null -eq $value) { $Default } else { $value }
    } catch {
        $Default
    }
}

$script:InstalledApps = $null

function Get-UninstallEntries {
    # Registry-based enumeration only. Win32_Product is deliberately NOT used:
    # it is slow and triggers MSI consistency checks / reconfiguration.
    if ($null -ne $script:InstalledApps) { return $script:InstalledApps }
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, InstallLocation, Publisher
    }
    $script:InstalledApps = @($apps)
    return $script:InstalledApps
}

function Test-AppInstalled {
    param([string]$NamePattern)
    $apps = Get-UninstallEntries
    $pattern = if ($NamePattern -match '[\*\?]') { $NamePattern } else { "*$NamePattern*" }
    $match = $apps | Where-Object { $_.DisplayName -like $pattern } | Select-Object -First 1
    [PSCustomObject]@{
        Found   = [bool]$match
        Version = if ($match) { $match.DisplayVersion } else { $null }
        Path    = if ($match) { $match.InstallLocation } else { $null }
    }
}

$script:ProcSnapshot = @(Get-Process -ErrorAction SilentlyContinue)

function Test-ProcessRunning {
    param([string[]]$NamePattern)
    foreach ($np in $NamePattern) {
        $pattern = if ($np -match '[\*\?]') { $np } else { "*$np*" }
        if ($script:ProcSnapshot | Where-Object { $_.Name -like $pattern }) { return $true }
    }
    return $false
}

function Invoke-External {
    param(
        [string]$Exe,
        [string]$ArgumentString = "",
        [int]$TimeoutSec = 10
    )
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $spArgs = @{
            FilePath               = $Exe
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
            NoNewWindow            = $true
            PassThru               = $true
            ErrorAction            = 'Stop'
        }
        if ($ArgumentString) { $spArgs.ArgumentList = $ArgumentString }
        $proc = Start-Process @spArgs
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            return $null
        }
        $out = @(Get-Content -Path $outFile -ErrorAction SilentlyContinue | Where-Object { $_ -ne $null })
        if ($out.Count -eq 0) { return $null }
        return $out
    } catch {
        return $null
    } finally {
        Remove-Item -Path $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    [math]::Round([double]$Bytes / 1GB, 2)
}

function Get-DriverAgeDays {
    param($DriverDate)
    if (-not $DriverDate) { return $null }
    try {
        $date = if ($DriverDate -is [datetime]) {
            $DriverDate
        } else {
            [Management.ManagementDateTimeConverter]::ToDateTime([string]$DriverDate)
        }
        [int]((Get-Date) - $date).TotalDays
    } catch {
        $null
    }
}

$script:GamingFlags = [ordered]@{}
$script:StepTimings = [ordered]@{}

function Set-GamingFlag {
    param([string]$Name, $Value)
    $script:GamingFlags[$Name] = $Value
}

function Get-GamingFlag { param([string]$Name) $script:GamingFlags[$Name] }

function Get-EventSummary {
    param(
        [string]$LogName,
        [string]$ProviderName,
        [int[]]$Id,
        [int]$Days = 30
    )
    $filter = @{ LogName = $LogName; StartTime = (Get-Date).AddDays(-$Days) }
    if ($ProviderName) { $filter.ProviderName = $ProviderName }
    if ($Id) { $filter.Id = $Id }
    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 200 -ErrorAction SilentlyContinue)
    $recent = $events | Select-Object -First 3
    [PSCustomObject]@{
        Count    = $events.Count
        Latest   = if ($events.Count -gt 0) { $events[0].TimeCreated } else { $null }
        Messages = @($recent | ForEach-Object {
            $msg = ("$($_.Message)" -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 157) + "..." }
            "[$($_.TimeCreated)] $msg"
        })
    }
}

# ------------------------------------------------------------------
# Header
# ------------------------------------------------------------------
Add-Line "WinScanner - Docker / WSL2 / Gaming Readiness Report"
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Add-Line "Computer:  $env:COMPUTERNAME"
Add-Line "User:      $env:USERNAME"

# ------------------------------------------------------------------
# Operating system
# ------------------------------------------------------------------
Run-Step "Operating System" {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture, InstallDate
}

Run-Step "Windows Edition Details" {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object ProductName, EditionID, DisplayVersion, ReleaseId, CurrentBuild, UBR
}

Run-Step "System Uptime / Pending Reboot" {
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    [PSCustomObject]@{
        LastBootUpTime = $os.LastBootUpTime
        Uptime         = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        RebootPending  = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Auto Update\RebootRequired')
    }
}

Run-Step "Hardware Platform (BIOS / Motherboard / Chassis)" {
    $bios    = Get-CimInstance Win32_BIOS
    $board   = Get-CimInstance Win32_BaseBoard
    $sys     = Get-CimInstance Win32_ComputerSystem
    $chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
    $laptopTypes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = [bool]($chassis | Where-Object { $_ -in $laptopTypes })
    Set-GamingFlag "IsLaptop" $isLaptop
    $chassisText = $chassis -join ','
    [PSCustomObject]@{
        Manufacturer = $sys.Manufacturer
        Model        = $sys.Model
        FormFactor   = if ($isLaptop) { "Laptop/Portable (chassis $chassisText)" } else { "Desktop/Tower (chassis $chassisText)" }
        Baseboard    = "$($board.Manufacturer) $($board.Product)"
        BIOSVersion  = $bios.SMBIOSBIOSVersion
        BIOSDate     = $bios.ReleaseDate
        BIOSAgeDays  = if ($bios.ReleaseDate) { [int]((Get-Date) - $bios.ReleaseDate).TotalDays } else { $null }
    }
}

Run-Step "Current User Privileges" {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    [PSCustomObject]@{
        UserName       = $current.Name
        IsAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        IsDockerUsersMember = (Get-LocalGroupMember -Group 'docker-users' -ErrorAction SilentlyContinue |
            Where-Object { $current.Name -like "*$($_.Name -replace '^[^\\]+\\','')" }) -ne $null
    }
}

Run-Step "PowerShell Execution Policy" {
    Get-ExecutionPolicy -List
}

# ------------------------------------------------------------------
# CPU / virtualization
# ------------------------------------------------------------------
Run-Step "CPU & Virtualization Support" {
    Get-CimInstance Win32_Processor |
        Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, VirtualizationFirmwareEnabled, AddressWidth
}

Run-Step "Hyper-V / Virtualization Windows Features" {
    @(
        'Microsoft-Hyper-V-All',
        'Microsoft-Hyper-V',
        'VirtualMachinePlatform',
        'Microsoft-Windows-Subsystem-Linux',
        'Containers'
    ) | ForEach-Object {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $_
        [PSCustomObject]@{
            Feature = $_
            State   = if ($feature) { $feature.State } else { 'Not found on this SKU' }
        }
    }
}

Run-Step "Hyper-V Hypervisor Running" {
    [PSCustomObject]@{
        HypervisorPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    }
}

Run-Step "VBS / HVCI / Virtualization Gaming Impact" {
    $hvPresent   = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
    $hvciEnabled = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0) -eq 1
    $dg = try {
        Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    } catch { $null }
    $vbsStatus   = if ($dg) { $dg.VirtualizationBasedSecurityStatus } else { "N/A" }
    $hvciRunning = if ($dg) { @($dg.SecurityServicesRunning) -contains 2 } else { $null }
    Set-GamingFlag "VBSRunning" ($vbsStatus -eq 2)
    Set-GamingFlag "HypervisorPresent" $hvPresent
    [PSCustomObject]@{
        HypervisorPresent = $hvPresent
        VBSStatus         = switch ($vbsStatus) { 0 { "Disabled" } 1 { "Enabled, not running" } 2 { "Running" } default { "Unknown/$vbsStatus" } }
        HVCIEnabled       = $hvciEnabled
        HVCIRunning       = $hvciRunning
        GamingNote        = if ($hvPresent -or $hvciEnabled -or $vbsStatus -eq 2) {
                                "Hypervisor/VBS active - may reduce FPS 5-15% on some titles; some anti-cheat (Vanguard/FACEIT) configs are affected"
                            } else { "No hypervisor overhead detected" }
    }
    Add-Line ""
    Add-Line "Note: WSL2 / Docker Desktop require the hypervisor - disabling it for gaming will break them."
}

Run-Step "Secure Boot & TPM Status" {
    [PSCustomObject]@{
        SecureBootEnabled = (Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)
        FirmwareType      = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue |
                              ForEach-Object { if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'Legacy BIOS' } })
        TpmPresent        = (Get-Tpm -ErrorAction SilentlyContinue).TpmPresent
        TpmEnabled        = (Get-Tpm -ErrorAction SilentlyContinue).TpmEnabled
        TpmVersion        = (Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
    }
}

Run-Step "Group Policy Restrictions (Hyper-V / Containers / Sandbox)" {
    @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Virtualization Based Security'
    ) | ForEach-Object {
        if (Test-Path $_) {
            [PSCustomObject]@{ Path = $_; Settings = (Get-ItemProperty $_ | Out-String).Trim() }
        } else {
            [PSCustomObject]@{ Path = $_; Settings = 'No policy keys found' }
        }
    }
}

Run-Step "Conflicting Virtualization Software" {
    $names = 'VirtualBox|VMware|Parallels'
    Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $names } |
        Select-Object DisplayName, DisplayVersion
}

# ------------------------------------------------------------------
# Memory & disk
# ------------------------------------------------------------------
Run-Step "Memory" {
    $os = Get-CimInstance Win32_OperatingSystem
    [PSCustomObject]@{
        TotalMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        FreeMemoryGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    }
}

Run-Step "Physical Memory Modules (Channel / XMP / Speed)" {
    $modules   = @(Get-CimInstance Win32_PhysicalMemory)
    $array     = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
    $populated = @($modules | Where-Object { $_.Capacity -gt 0 })
    $first     = $populated | Select-Object -First 1
    $totalSlots = $array.MemoryDevices
    $usedSlots  = $populated.Count
    $memTypeCode = if ($first.SMBIOSMemoryType) { $first.SMBIOSMemoryType } else { $first.MemoryType }
    $ddrType = switch ($memTypeCode) { 24 { "DDR3" } 26 { "DDR4" } 34 { "DDR5" } 30 { "LPDDR4" } 35 { "LPDDR5" } default { "Unknown" } }
    $jedecBase = switch ($ddrType) { "DDR5" { 4800 } "DDR4" { 2133 } "DDR3" { 1333 } default { 0 } }
    $configuredSpeed = $first.ConfiguredClockSpeed
    $ratedSpeed      = $first.Speed
    # Heuristic: WMI cannot read the XMP/EXPO profile directly. A configured
    # speed well above the JEDEC baseline means a profile (or manual OC) is active.
    $xmpLikely = if ($configuredSpeed -and $jedecBase) { $configuredSpeed -gt ($jedecBase + 100) } else { $null }
    $singleChannel = $usedSlots -eq 1
    Set-GamingFlag "SingleChannel" $singleChannel
    Set-GamingFlag "XMPEnabled" $xmpLikely

    $populated | ForEach-Object {
        [PSCustomObject]@{
            Slot          = "$($_.BankLabel) / $($_.DeviceLocator)"
            CapacityGB    = ConvertTo-GB $_.Capacity
            Type          = $ddrType
            RatedSpeedMHz = $_.Speed
            ConfiguredMHz = $_.ConfiguredClockSpeed
            XMPExpoActive = $xmpLikely
            Manufacturer  = $_.Manufacturer
            PartNumber    = "$($_.PartNumber)".Trim()
        }
    }

    $channelText = if ($singleChannel) {
        "SINGLE-CHANNEL (significant FPS impact - add a matching stick)"
    } elseif ($usedSlots -eq 2 -or $usedSlots -eq 4) {
        "Likely dual-channel"
    } else {
        "Check BIOS / motherboard manual"
    }
    $xmpText = if ($xmpLikely -eq $true) {
        "Appears active ($configuredSpeed MHz vs JEDEC $jedecBase MHz)"
    } elseif ($xmpLikely -eq $false) {
        "NOT active - RAM running at JEDEC baseline ($configuredSpeed MHz); enable XMP/EXPO in BIOS (module rated $ratedSpeed MHz)"
    } else {
        "Unable to determine"
    }
    Add-Line ""
    Add-Line "Slots: $usedSlots / $totalSlots used | Channel config: $channelText"
    Add-Line "XMP/EXPO: $xmpText"
    if ((Get-GamingFlag "IsLaptop") -and $singleChannel) {
        Add-Line "Note: on laptops with soldered memory WMI may report a single module even when dual-channel."
    }
}

Run-Step "Pagefile / Virtual Memory" {
    $managed  = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
    $settings = Get-CimInstance Win32_PageFileSetting
    $usage    = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1
    [PSCustomObject]@{
        AutoManaged  = $managed
        PagefilePath = if ($usage) { $usage.Name } else { ($settings | Select-Object -First 1).Name }
        AllocatedGB  = if ($usage) { ConvertTo-GB ([double]$usage.AllocatedBaseSize * 1MB) } else { $null }
        CurrentUseGB = if ($usage) { ConvertTo-GB ([double]$usage.CurrentUsage * 1MB) } else { $null }
        PeakUsageGB  = if ($usage) { ConvertTo-GB ([double]$usage.PeakUsage * 1MB) } else { $null }
    }
    if (-not $usage) { Add-Line "WARNING: No pagefile in use - some games crash or stutter without one." }
}

Run-Step "Disk Space" {
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name,
            @{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}},
            @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}}
}

Run-Step "Physical Disk Type (SSD/HDD)" {
    Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Size, HealthStatus
}

Run-Step "Storage Gaming Detail (Drive Map / NVMe / Trim)" {
    $disks      = Get-Disk
    $partitions = Get-Partition
    $physDisks  = Get-PhysicalDisk
    foreach ($disk in $disks) {
        $parts    = $partitions | Where-Object { $_.DiskNumber -eq $disk.Number -and $_.DriveLetter }
        $physDisk = $physDisks | Where-Object { "$($_.DeviceId)" -eq "$($disk.Number)" } | Select-Object -First 1
        foreach ($part in $parts) {
            $vol   = Get-PSDrive -Name $part.DriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
            $total = if ($vol) { [double]$vol.Used + [double]$vol.Free } else { 0 }
            [PSCustomObject]@{
                Drive       = "$($part.DriveLetter):"
                Disk        = $disk.FriendlyName
                MediaType   = $physDisk.MediaType
                BusType     = $disk.BusType
                FreeGB      = if ($vol) { ConvertTo-GB $vol.Free } else { $null }
                FreePercent = if ($total -gt 0) { [math]::Round(100 * $vol.Free / $total, 1) } else { $null }
                LowSpace    = if ($total -gt 0) { ($vol.Free / $total) -lt 0.15 } else { $false }
                Health      = $physDisk.HealthStatus
            }
        }
    }
    $trimStatus = Invoke-External "fsutil" "behavior query DisableDeleteNotify" 5
    Add-Line ""
    Add-Line "TRIM Status (DisableDeleteNotify = 0 means TRIM enabled): $(if ($trimStatus) { ($trimStatus | Where-Object { $_.Trim() }) -join ' | ' } else { 'Unable to query (may require admin)' })"
    Add-Line "Note: install games on NVMe/SSD with >15% free space; HDD installs cause long loads and texture streaming stutter."
}

# ------------------------------------------------------------------
# GPU & display
# ------------------------------------------------------------------
Run-Step "GPU Hardware" {
    $gpus = @(Get-CimInstance Win32_VideoController)

    # Win32_VideoController.AdapterRAM is a uint32 and caps at 4 GB, so read
    # the 64-bit VRAM size the driver publishes in the display class key.
    $vramMap = @{}
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            $raw = $p.'HardwareInformation.qwMemorySize'
            if ($null -eq $raw) { $raw = $p.'HardwareInformation.MemorySize' }
            if ($p.DriverDesc -and $null -ne $raw) {
                $val = if ($raw -is [byte[]]) {
                    if ($raw.Length -ge 8) { [BitConverter]::ToUInt64($raw, 0) } elseif ($raw.Length -ge 4) { [BitConverter]::ToUInt32($raw, 0) } else { 0 }
                } else { [uint64]$raw }
                if ($val -gt 0) { $vramMap[$p.DriverDesc] = $val }
            }
        }

    $virtualPattern = 'Basic Display|Basic Render|Remote|Virtual|Citrix|Parsec|VirtualBox|VMware|Hyper-V|Mirror'
    # Integrated GPUs: Intel (except Arc A/B discrete cards) and AMD APU graphics.
    $integratedPattern = '^(?!.*Arc\(TM\) [AB]\d).*Intel|AMD Radeon\(TM\) Graphics|Radeon\(TM\) \d+M Graphics|Vega \d+ Graphics|Radeon Vega'

    $primary = $null
    foreach ($gpu in $gpus) {
        $vendor = switch -Regex ("$($gpu.AdapterCompatibility) $($gpu.Name)") {
            'NVIDIA'             { 'NVIDIA'; break }
            'AMD|Advanced Micro' { 'AMD'; break }
            'Intel'              { 'Intel'; break }
            default              { $gpu.AdapterCompatibility }
        }
        $driverDays = Get-DriverAgeDays $gpu.DriverDate
        $vramBytes  = $vramMap[$gpu.Name]
        $vram = if ($vramBytes) {
            "$(ConvertTo-GB $vramBytes) GB"
        } elseif ($gpu.AdapterRAM -ge 4293918720) {
            ">=4 GB (WMI cap; check vendor tool)"
        } elseif ($gpu.AdapterRAM) {
            "$(ConvertTo-GB $gpu.AdapterRAM) GB"
        } else { "Unknown" }
        $isVirtual    = $gpu.Name -match $virtualPattern
        $isIntegrated = $gpu.Name -match $integratedPattern
        if (-not $isVirtual -and ($null -eq $primary -or ($primary.IsIntegrated -and -not $isIntegrated))) {
            $primary = [PSCustomObject]@{ Vendor = $vendor; DriverDays = $driverDays; IsIntegrated = $isIntegrated }
        }
        [PSCustomObject]@{
            Name              = $gpu.Name
            Vendor            = $vendor
            Type              = if ($isVirtual) { "Virtual/Remote" } elseif ($isIntegrated) { "Integrated" } else { "Discrete" }
            VRAM              = $vram
            DriverVersion     = $gpu.DriverVersion
            DriverDate        = $gpu.DriverDate
            DriverAgeDays     = $driverDays
            DriverStale       = ($null -ne $driverDays -and $driverDays -gt 180)
            CurrentResolution = "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)"
            CurrentRefreshHz  = $gpu.CurrentRefreshRate
            Status            = $gpu.Status
        }
    }
    if ($primary) {
        Set-GamingFlag "GPUVendor" $primary.Vendor
        Set-GamingFlag "DriverAgeDays" $primary.DriverDays
    }
    $discreteCount = @($gpus | Where-Object { $_.Name -notmatch $virtualPattern -and $_.Name -notmatch $integratedPattern }).Count
    $iGPUOnly = $gpus.Count -gt 0 -and $discreteCount -eq 0
    Set-GamingFlag "iGPUOnly" $iGPUOnly
    if ($iGPUOnly) { Add-Line ""; Add-Line "WARNING: No discrete GPU detected - integrated graphics only" }
    if (@($gpus | Where-Object { $_.Name -match 'Basic Display|Basic Render' }).Count -gt 0) {
        Add-Line "WARNING: Microsoft Basic Display Adapter in use - the GPU driver is missing or failed to load"
    }
}

Run-Step "GPU Driver Source (Vendor Control Panel)" {
    Get-UninstallEntries | Out-Null  # ensure cache populated
    @(
        @{ Pattern = "NVIDIA App";          Alt = $null }
        @{ Pattern = "GeForce Experience";  Alt = $null }
        @{ Pattern = "NVIDIA Graphics Driver*"; Alt = $null }
        @{ Pattern = "AMD Software*";       Alt = "AMD Radeon Software*" }
        @{ Pattern = "Intel* Graphics*";    Alt = "Intel* Arc Control*" }
    ) | ForEach-Object {
        $found = Test-AppInstalled $_.Pattern
        if (-not $found.Found -and $_.Alt) { $found = Test-AppInstalled $_.Alt }
        [PSCustomObject]@{
            Software  = $_.Pattern
            Installed = $found.Found
            Version   = $found.Version
        }
    }
    Add-Line ""
    Add-Line "Note: drivers delivered by Windows Update are often older than vendor releases."
}

Run-Step "Display Configuration" {
    $isRDP = ($env:SESSIONNAME -like 'RDP*')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if ([System.Windows.Forms.SystemInformation]::TerminalServerSession) { $isRDP = $true }
        [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            [PSCustomObject]@{
                Name         = $_.DeviceName
                Primary      = $_.Primary
                Width        = $_.Bounds.Width
                Height       = $_.Bounds.Height
                BitsPerPixel = $_.BitsPerPixel
            }
        }
    } catch {
        Add-Line "Unable to enumerate displays: $($_.Exception.Message)"
    }
    if ($isRDP) { Add-Line "(RDP session detected - display data may reflect a virtual display, not the physical monitor)" }

    $modes = @(Get-CimInstance CIM_VideoControllerResolution)
    $refreshRates = $modes |
        Group-Object { "$($_.HorizontalResolution)x$($_.VerticalResolution)" } |
        ForEach-Object { [PSCustomObject]@{ Resolution = $_.Name; MaxRefreshHz = ($_.Group | Measure-Object -Property RefreshRate -Maximum).Maximum } } |
        Sort-Object MaxRefreshHz -Descending | Select-Object -First 10
    Add-Line ""
    Add-Line "Supported resolutions (top by refresh rate, as reported by the driver):"
    $refreshRates | ForEach-Object { Add-Line "  $($_.Resolution) @ max $($_.MaxRefreshHz) Hz" }

    $active = Get-CimInstance Win32_VideoController |
        Where-Object { $_.CurrentRefreshRate -and $_.CurrentHorizontalResolution } | Select-Object -First 1
    $currentHz  = $active.CurrentRefreshRate
    $currentRes = "$($active.CurrentHorizontalResolution)x$($active.CurrentVerticalResolution)"
    $atCurrent  = $refreshRates | Where-Object { $_.Resolution -eq $currentRes } | Select-Object -First 1
    $maxSupported = if ($atCurrent) { $atCurrent.MaxRefreshHz } else { ($refreshRates | Select-Object -First 1).MaxRefreshHz }
    if (-not $isRDP -and $maxSupported -and $currentHz -and $currentHz -lt $maxSupported) {
        Set-GamingFlag "MonitorUnderRefresh" $true
        Add-Line ""
        Add-Line "WARNING: Running at $currentHz Hz ($currentRes) but up to $maxSupported Hz is supported - change it in Settings > Display > Advanced display"
    } else {
        Set-GamingFlag "MonitorUnderRefresh" $false
    }
}

Run-Step "Graphics Settings (HAGS / Game Mode / Game DVR)" {
    $hags          = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 0
    $gameModeAuto  = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' $null
    $gameModeAllow = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' $null
    $gameDVR       = Get-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' $null
    $appCapture    = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' $null
    $gameDVRPolicy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' $null
    $winGamesOpt   = Get-RegValue 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' ''
    $dvrOn = ($gameDVR -eq 1 -or $appCapture -eq 1) -and ($gameDVRPolicy -ne 0)
    Set-GamingFlag "HAGSOn" ($hags -eq 2)
    # Game Mode defaults to On when the values are absent.
    Set-GamingFlag "GameModeOn" ($gameModeAuto -ne 0 -and $gameModeAllow -ne 0)
    Set-GamingFlag "GameDVROn" $dvrOn
    [PSCustomObject]@{
        HAGS_HwSchMode          = switch ($hags) { 1 { "Off" } 2 { "On (recommended)" } default { "Unknown (key missing - likely Off/unsupported)" } }
        GameMode_Auto           = if ($null -ne $gameModeAuto) { [bool]$gameModeAuto } else { "Not set (default On)" }
        GameMode_Allow          = if ($null -ne $gameModeAllow) { [bool]$gameModeAllow } else { "Not set" }
        GameDVR_Enabled         = if ($null -ne $gameDVR) { [bool]$gameDVR } else { "Not set" }
        AppCapture_Enabled      = if ($null -ne $appCapture) { [bool]$appCapture } else { "Not set" }
        GameDVR_PolicyAllow     = if ($null -ne $gameDVRPolicy) { [bool]$gameDVRPolicy } else { "No policy" }
        WindowedGameOpt_Setting = if ($winGamesOpt) { $winGamesOpt } else { "Not configured" }
    }
    if ($dvrOn) { Add-Line ""; Add-Line "Note: Game DVR / background recording enabled - disabling it may improve FPS/stability" }
    if ($hags -ne 2) { Add-Line "Note: HAGS off - enabling it in Settings > Display > Graphics > Change default graphics settings may help on modern GPUs" }
}

# ------------------------------------------------------------------
# Power
# ------------------------------------------------------------------
Run-Step "Power Plan" {
    $active   = Invoke-External "powercfg" "/getactivescheme" 10
    $allPlans = Invoke-External "powercfg" "/list" 10
    $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highGuid     = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    $balancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
    $activeLine = "$($active -join ' ')"
    $activeName = if ($activeLine -match '\(([^)]+)\)\s*\*?\s*$') { $Matches[1] } else { $activeLine }
    $ultimateAvail = @($allPlans | Where-Object { $_ -match $ultimateGuid -or $_ -match 'Ultimate Performance' }).Count -gt 0
    $isUltimate = $activeLine -match "$ultimateGuid|Ultimate Performance"
    $isHighPerf = $activeLine -match "$highGuid|High performance"
    $isBalanced = $activeLine -match $balancedGuid
    $isLaptop   = [bool](Get-GamingFlag "IsLaptop")
    if ($active) { Set-GamingFlag "PowerPlanOptimal" ($isHighPerf -or $isUltimate) }
    [PSCustomObject]@{
        ActivePlan           = if ($activeName) { $activeName.Trim() } else { "Unable to query" }
        IsBalanced           = $isBalanced
        IsHighPerformance    = $isHighPerf
        IsUltimate           = $isUltimate
        IsUltimateAvailable  = $ultimateAvail
        GamingRecommendation = if ($isUltimate) { "Ultimate Performance - optimal" }
                               elseif ($isHighPerf) { "High Performance - good" }
                               elseif ($isLaptop) { "Balanced is OK on battery; switch to High Performance when plugged in for gaming" }
                               else { "Change to High Performance or Ultimate Performance for gaming" }
    }
    if ($allPlans) {
        Add-Line ""
        Add-Line "All plans:"
        $allPlans | Where-Object { $_ -match 'GUID' } | ForEach-Object { Add-Line "  $($_.Trim())" }
    }
}

# ------------------------------------------------------------------
# Input / peripherals
# ------------------------------------------------------------------
Run-Step "Audio & Input Devices" {
    # Two differently shaped tables: pre-render each so they don't collapse into list view.
    (Get-CimInstance Win32_SoundDevice | Select-Object @{N='AudioDevice';E={$_.Name}}, Status |
        Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
    (Get-CimInstance Win32_PointingDevice | Select-Object @{N='PointingDevice';E={$_.Name}}, Manufacturer |
        Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
    @("Nahimic", "Sonic Studio", "iCUE", "Razer Synapse", "Logitech G HUB", "SteelSeries GG", "Armoury Crate") | ForEach-Object {
        $found = Test-AppInstalled "*$_*"
        if ($found.Found) { Add-Line "Overlay/audio/RGB software detected: $_ v$($found.Version) - known stutter/latency source in some configs" }
    }
}

Run-Step "Controllers / Gamepads" {
    $controllers = @(Get-PnpDevice -PresentOnly -Class "HIDClass", "XnaComposite", "XboxComposite", "USB", "Bluetooth" -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match 'Xbox|DualSense|DualShock|Wireless Controller|game controller|Gamepad|Joystick|Pro Controller' } |
        Select-Object FriendlyName, Status, Class)
    if ($controllers.Count -eq 0) {
        "(no controllers detected)"
    } else {
        $controllers
    }
}

# ------------------------------------------------------------------
# WSL
# ------------------------------------------------------------------
Run-Step "WSL Status" {
    wsl.exe --status 2>&1
}

Run-Step "WSL Distributions (verbose)" {
    wsl.exe -l -v 2>&1
}

Run-Step "WSL Version Info" {
    wsl.exe --version 2>&1
}

Run-Step "WSL Configuration File (.wslconfig)" {
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    if (Test-Path $wslConfigPath) {
        Get-Content $wslConfigPath
    } else {
        "(no .wslconfig found - WSL2 using default resource limits)"
    }
}

Run-Step "WSL Disk Usage (vhdx files)" {
    $wslDataPath = Join-Path $env:LOCALAPPDATA "Packages"
    Get-ChildItem -Path $wslDataPath -Filter "ext4.vhdx" -Recurse -ErrorAction SilentlyContinue |
        Select-Object @{N='Path';E={$_.FullName}}, @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}}
}

# ------------------------------------------------------------------
# Docker
# ------------------------------------------------------------------
Run-Step "Docker Installation" {
    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($docker) {
        [PSCustomObject]@{ DockerPath = $docker.Source }
    } else {
        [PSCustomObject]@{ DockerPath = 'docker.exe not found in PATH' }
    }
}

Run-Step "Docker Version" {
    docker version 2>&1
}

Run-Step "Docker Info" {
    docker info 2>&1
}

Run-Step "Docker Desktop Service / Process" {
    Get-Process -Name '*docker*' -ErrorAction SilentlyContinue |
        Select-Object Name, Id, StartTime
}

Run-Step "Existing Docker Images" {
    docker images 2>&1
}

Run-Step "Existing Docker Containers (all)" {
    docker ps -a 2>&1
}

Run-Step "Docker Compose Version" {
    docker compose version 2>&1
}

# ------------------------------------------------------------------
# Networking
# ------------------------------------------------------------------
Run-Step "Network Gaming Detail (Wi-Fi / Ethernet)" {
    # Decide by the interface that carries the default route, so a machine
    # with both Ethernet and Wi-Fi up is judged by what it actually uses.
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    $adapter = if ($route) { Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue } else { $null }
    $isWifi = $adapter -and ($adapter.PhysicalMediaType -match '802\.11' -or $adapter.NdisPhysicalMedium -eq 9 -or $adapter.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')

    $wifiInfo = Invoke-External "netsh" "wlan show interfaces" 10
    $getField = {
        param($pattern)
        (($wifiInfo | Where-Object { $_ -match $pattern } | Select-Object -First 1) -replace '^[^:]+:\s*', '').Trim()
    }

    if ($isWifi) {
        Set-GamingFlag "WiFiOnly" $true
        [PSCustomObject]@{
            Connection = "Wi-Fi ($($adapter.Name))"
            SSID       = & $getField '^\s+SSID\s+:'
            RadioType  = & $getField 'Radio type'
            Band       = & $getField '^\s+Band\s+:'
            Signal     = & $getField 'Signal'
            RxMbps     = & $getField 'Receive rate'
            TxMbps     = & $getField 'Transmit rate'
            LinkSpeed  = $adapter.LinkSpeed
            GamingNote = "Ethernet recommended for lowest latency gaming - Wi-Fi adds jitter"
        }
    } elseif ($adapter) {
        Set-GamingFlag "WiFiOnly" $false
        [PSCustomObject]@{
            Connection = "Wired/other ($($adapter.Name))"
            Adapter    = $adapter.InterfaceDescription
            LinkSpeed  = $adapter.LinkSpeed
            GamingNote = if ("$($adapter.LinkSpeed)" -match '^(10|100) Mbps') { "Link negotiated below 1 Gbps - check cable/port" } else { "OK" }
        }
    } else {
        "(no default route found - offline?)"
    }
}

Run-Step "Latency Snapshot (gateway / DNS)" {
    $gw = (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
    $targets = @(
        @{ Host = $gw;        Label = "Default Gateway" }
        @{ Host = "1.1.1.1";  Label = "Cloudflare DNS" }
        @{ Host = "8.8.8.8";  Label = "Google DNS" }
    ) | Where-Object { $_.Host }
    foreach ($t in $targets) {
        $sent = 4
        $ping = @(Test-Connection -ComputerName $t.Host -Count $sent -ErrorAction SilentlyContinue)
        # PS 5.1 returns Win32_PingStatus (ResponseTime/StatusCode); PS 7 returns
        # PingStatus objects (Latency/Status) - normalize both.
        $ok = @($ping | Where-Object {
            ($null -ne $_.StatusCode -and $_.StatusCode -eq 0) -or ("$($_.Status)" -eq 'Success')
        })
        $times = @($ok | ForEach-Object { if ($null -ne $_.ResponseTime) { $_.ResponseTime } else { $_.Latency } })
        if ($times.Count -gt 0) {
            $m = $times | Measure-Object -Average -Minimum -Maximum
            [PSCustomObject]@{
                Target = "$($t.Label) ($($t.Host))"
                AvgMs  = [math]::Round($m.Average, 1)
                MinMs  = $m.Minimum
                MaxMs  = $m.Maximum
                Jitter = $m.Maximum - $m.Minimum
                Loss   = "$([math]::Round(100 * ($sent - $times.Count) / $sent, 0))%"
            }
        } else {
            [PSCustomObject]@{ Target = "$($t.Label) ($($t.Host))"; AvgMs = "Unreachable"; MinMs = $null; MaxMs = $null; Jitter = $null; Loss = "100%" }
        }
    }
    Add-Line ""
    Add-Line "Note: some networks block ICMP; 'Unreachable' does not always mean no connectivity."
}

Run-Step "Teredo / NAT State (Xbox / Game Pass)" {
    $teredo = Invoke-External "netsh" "interface teredo show state" 10
    if ($teredo) {
        $teredo | Where-Object { $_.Trim() } | ForEach-Object { Add-Line $_ }
        Add-Line ""
        Add-Line "Note: Teredo 'qualified' / 'dormant' is fine; 'offline' or 'disabled' can cause Xbox party chat / multiplayer NAT errors."
    } else {
        Add-Line "(Unable to query Teredo state)"
    }
}

Run-Step "Network Adapters (up)" {
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
        Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress
}

Run-Step "IP Configuration" {
    Get-NetIPAddress -AddressFamily IPv4 |
        Select-Object InterfaceAlias, IPAddress, PrefixLength
}

Run-Step "Network Proxy Configuration" {
    Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
        Select-Object ProxyEnable, ProxyServer, AutoConfigURL
}

Run-Step "Windows Firewall Profiles" {
    Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
}

# ------------------------------------------------------------------
# Security software (can interfere with Docker performance)
# ------------------------------------------------------------------
Run-Step "Windows Defender / AV Status" {
    Get-MpComputerStatus |
        Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled
}

Run-Step "Registered Antivirus Products" {
    Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
        Select-Object displayName, productState
}

# ------------------------------------------------------------------
# Gaming software & background load
# ------------------------------------------------------------------
Run-Step "Game Launchers / Platforms" {
    Get-UninstallEntries | Out-Null
    @("Steam", "Epic Games Launcher", "GOG Galaxy", "EA app", "Ubisoft Connect", "Battle.net", "Riot Client", "Rockstar Games Launcher") | ForEach-Object {
        $found = Test-AppInstalled "*$_*"
        [PSCustomObject]@{ Platform = $_; Installed = $found.Found; Version = $found.Version; Path = $found.Path }
    }
    $steamPath = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath' ''
    $vdf = if ($steamPath) { Join-Path $steamPath 'steamapps\libraryfolders.vdf' } else { $null }
    if ($vdf -and (Test-Path $vdf)) {
        Add-Line ""
        Add-Line "Steam library paths:"
        Get-Content $vdf | Where-Object { $_ -match '"path"' } | ForEach-Object {
            Add-Line "  $(($_ -replace '.*"path"\s+"', '' -replace '".*', '') -replace '\\\\', '\')"
        }
    }
    $xboxApp = Get-AppxPackage -Name "Microsoft.GamingApp" -ErrorAction SilentlyContinue
    if ($xboxApp) { Add-Line ""; Add-Line "Xbox app (Microsoft.GamingApp): $($xboxApp.Version)" }
    $gamingServices = Get-AppxPackage -Name "Microsoft.GamingServices" -ErrorAction SilentlyContinue
    if ($gamingServices) { Add-Line "Gaming Services (Microsoft.GamingServices): $($gamingServices.Version)" }
}

Run-Step "Overlays & Capture Software" {
    @(
        @{ Name = "Discord";         Proc = @("Discord") }
        @{ Name = "OBS Studio";      Proc = @("obs64", "obs32") }
        @{ Name = "NVIDIA App";      Proc = @("NVIDIA Overlay", "NVIDIA app") }
        @{ Name = "AMD Software";    Proc = @("RadeonSoftware", "AMDRSServ") }
        @{ Name = "MSI Afterburner"; Proc = @("MSIAfterburner") }
        @{ Name = "RivaTuner";       Proc = @("RTSS") }
        @{ Name = "Medal";           Proc = @("Medal") }
        @{ Name = "Overwolf";        Proc = @("Overwolf") }
        @{ Name = "Steam";           Proc = @("steamwebhelper") }
    ) | ForEach-Object {
        $installed = Test-AppInstalled "*$($_.Name)*"
        $running   = Test-ProcessRunning $_.Proc
        if ($installed.Found -or $running) {
            [PSCustomObject]@{ Software = $_.Name; Installed = $installed.Found; Running = $running; Note = "Stacked overlays can cause stutter/crashes" }
        }
    }
    $xboxOverlay = Get-AppxPackage -Name "Microsoft.XboxGamingOverlay" -ErrorAction SilentlyContinue
    if ($xboxOverlay) { Add-Line ""; Add-Line "Xbox Game Bar: $($xboxOverlay.Version)" }
}

Run-Step "Gaming-Relevant Services" {
    @("SysMain", "WSearch", "DiagTrack", "XblAuthManager", "XblGameSave", "XboxNetApiSvc", "XboxGipSvc",
      "GamingServices", "GamingServicesNet", "Spooler", "wuauserv", "NVDisplay.ContainerLocalSystem",
      "AMD External Events Utility", "BEService", "EasyAntiCheat", "EasyAntiCheat_EOS", "vgc") |
    ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($svc) {
            [PSCustomObject]@{
                Service     = $svc.Name
                DisplayName = $svc.DisplayName
                Status      = $svc.Status
                StartType   = $svc.StartType
            }
        }
    }
}

Run-Step "Startup Programs" {
    $startup = @(Get-CimInstance Win32_StartupCommand |
        Select-Object Name,
            @{N='Command';E={ $c = "$($_.Command)" -replace '"', ''; if ($c.Length -gt 120) { $c.Substring(0, 117) + "..." } else { $c } }},
            Location, User)
    $startup
    Add-Line ""
    Add-Line "Total startup items: $($startup.Count)"
}

Run-Step "Background Process Load (Top 10 by RAM)" {
    $script:ProcSnapshot | Where-Object { $_.Name -notmatch '^(Idle|System|Memory Compression)$' } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 10 |
        Select-Object Name, Id,
            @{N='RAMMB';E={[int][math]::Round($_.WorkingSet64 / 1MB, 0)}},
            @{N='CPU_s';E={ if ($_.TotalProcessorTime) { [math]::Round($_.TotalProcessorTime.TotalSeconds, 1) } else { $null } }}
    Add-Line ""
    Add-Line "Total running processes: $(@($script:ProcSnapshot).Count)"
}

Run-Step "Visual Effects / Mouse Acceleration" {
    $vfx          = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' $null
    $mouseSpeed   = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseSpeed' $null
    $mouseThresh1 = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' $null
    $mouseThresh2 = Get-RegValue 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' $null
    $accelOff = ("$mouseSpeed" -eq '0' -and "$mouseThresh1" -eq '0' -and "$mouseThresh2" -eq '0')
    $transparency = Get-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' $null
    if ($null -ne $mouseSpeed) { Set-GamingFlag "MouseAccelOff" $accelOff }
    [PSCustomObject]@{
        VisualFXSetting   = switch ($vfx) { 0 { "Let Windows decide" } 1 { "Best appearance" } 2 { "Best performance" } 3 { "Custom" } default { "Not set (Let Windows decide)" } }
        Transparency      = if ($null -ne $transparency) { [bool]$transparency } else { "Not set (default On)" }
        MouseAccelEnabled = -not $accelOff
        MouseAccelNote    = if ($accelOff) { "Disabled - correct for competitive/FPS gaming" } else { "Enabled - disable 'Enhance pointer precision' for consistent aim" }
    }
}

Run-Step "Runtime Dependencies (DirectX / VC++ / .NET)" {
    Get-UninstallEntries | Out-Null
    $vcRedists = @($script:InstalledApps | Where-Object { $_.DisplayName -match 'Visual C\+\+.*(20\d\d|Redistributable)' } |
        Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName -Unique)
    if ($vcRedists.Count -gt 0) { $vcRedists } else { Add-Line "No Visual C++ redistributables found in registry - many games will fail to launch" }

    $dxVersion = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\DirectX' 'Version' 'Unknown'
    $d3dx9 = Test-Path (Join-Path $env:WINDIR 'System32\d3dx9_43.dll')
    Add-Line ""
    Add-Line "DirectX version (registry, legacy field - DX12 is built into Windows 10/11): $dxVersion"
    Add-Line "Legacy DirectX 9 June 2010 runtime (d3dx9_43.dll): $(if ($d3dx9) { 'Present' } else { 'Not installed (older games may need it)' })"

    $dotnet = [int](Get-RegValue 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release' 0)
    $dotnetVer = if ($dotnet -ge 533320) { "4.8.1 or later" }
                 elseif ($dotnet -ge 528040) { "4.8" }
                 elseif ($dotnet -ge 461808) { "4.7.2" }
                 elseif ($dotnet -ge 394802) { "4.6.2" }
                 elseif ($dotnet -gt 0) { "Below 4.6.2 - update recommended" }
                 else { "Not detected" }
    Add-Line ".NET Framework: $dotnetVer (release key: $dotnet)"
    $net35 = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' 'Install' 0
    Add-Line ".NET Framework 3.5 (needed by some older games/tools): $(if ($net35 -eq 1) { 'Installed' } else { 'Not installed' })"
}

# ------------------------------------------------------------------
# Stability & thermals
# ------------------------------------------------------------------
Run-Step "Thermal Snapshot" {
    $thermalZones = Get-CimInstance -Namespace root\WMI -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
    if ($thermalZones) {
        $thermalZones | ForEach-Object {
            [PSCustomObject]@{
                Zone        = $_.InstanceName
                TempCelsius = [math]::Round($_.CurrentTemperature / 10 - 273.15, 1)
            }
        }
        Add-Line ""
        Add-Line "Note: ACPI thermal zones are usually motherboard/chipset sensors, not CPU core temperature."
    } else {
        Add-Line "(Thermal zones not exposed by firmware or not readable without admin - common on many OEM systems)"
    }
    $smiQuery = "--query-gpu=name,temperature.gpu,clocks.sm,power.draw,utilization.gpu --format=csv,noheader"
    $nvidiaSmi = $null
    foreach ($exe in @((Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'),
                       (Join-Path $env:WINDIR 'System32\nvidia-smi.exe'))) {
        if (-not $nvidiaSmi -and (Test-Path $exe)) { $nvidiaSmi = Invoke-External $exe $smiQuery 10 }
    }
    if ($nvidiaSmi) {
        Add-Line ""
        Add-Line "nvidia-smi (name, temp C, SM clock, power, utilization):"
        $nvidiaSmi | ForEach-Object { Add-Line "  $_" }
    }
}

Run-Step "Event Log: Crashes & Stability (last 30 days)" {
    $allMessages = New-Object System.Collections.Generic.List[string]
    @(
        @{ Label = "Unexpected Shutdown (Kernel-Power 41)";   Log = "System";      Provider = "Microsoft-Windows-Kernel-Power"; Id = @(41) }
        @{ Label = "GPU Driver Timeout / TDR (Display 4101)"; Log = "System";      Provider = "Display";                        Id = @(4101) }
        @{ Label = "Hardware Error (WHEA-Logger)";            Log = "System";      Provider = "Microsoft-Windows-WHEA-Logger";  Id = @(1, 17, 18, 19, 47) }
        @{ Label = "Bugcheck / BSOD (BugCheck 1001)";         Log = "System";      Provider = "Microsoft-Windows-WER-SystemErrorReporting"; Id = @(1001) }
        @{ Label = "Application Crash (Application Error 1000)"; Log = "Application"; Provider = "Application Error";        Id = @(1000) }
    ) | ForEach-Object {
        $summary = Get-EventSummary -LogName $_.Log -ProviderName $_.Provider -Id $_.Id -Days 30
        if ($summary.Count -gt 0) {
            $allMessages.Add("$($_.Label):")
            $summary.Messages | ForEach-Object { $allMessages.Add("  $_") }
        }
        [PSCustomObject]@{
            EventType = $_.Label
            Count30d  = if ($summary.Count -ge 200) { "200+" } else { $summary.Count }
            Latest    = $summary.Latest
        }
    }
    if ($allMessages.Count -gt 0) {
        Add-Line ""
        Add-Line "Most recent events (up to 3 per type):"
        $allMessages | ForEach-Object { Add-Line "  $_" }
    }
    $dumps = @(Get-ChildItem (Join-Path $env:WINDIR 'Minidump\*.dmp') -ErrorAction SilentlyContinue)
    Add-Line ""
    Add-Line "Minidump files in $env:WINDIR\Minidump: $($dumps.Count)"
    if ($dumps.Count -gt 0) { Add-Line "  Newest: $(($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)" }
}

# ------------------------------------------------------------------
# Gaming summary (derived from flags set by the steps above)
# ------------------------------------------------------------------
Run-Step "Gaming Readiness Summary" {
    $flags = $script:GamingFlags
    # Only warn when a step actually determined the value (missing flag = step
    # failed or data unavailable -> no warning).
    $is    = { param($k) $flags.Contains($k) -and $flags[$k] -eq $true }
    $isNot = { param($k) $flags.Contains($k) -and $flags[$k] -eq $false }
    $warnings = @()
    if (& $is 'iGPUOnly')               { $warnings += "No discrete GPU - integrated graphics only" }
    if ($flags.Contains('DriverAgeDays') -and $null -ne $flags['DriverAgeDays'] -and $flags['DriverAgeDays'] -gt 180) {
        $warnings += "GPU driver is $($flags['DriverAgeDays']) days old - update from the vendor site"
    }
    if (& $is 'MonitorUnderRefresh')    { $warnings += "Monitor not running at max refresh rate - fix in Display Settings" }
    if (& $is 'SingleChannel')          { $warnings += "RAM in single-channel - add a matching stick for a significant FPS gain" }
    if ((& $isNot 'XMPEnabled') -and -not (Get-GamingFlag 'IsLaptop')) {
        $warnings += "XMP/EXPO not active - RAM running at JEDEC speed; enable it in BIOS"
    }
    if (& $isNot 'HAGSOn')              { $warnings += "HAGS off - enable in Windows Graphics Settings (modern GPU/driver)" }
    if (& $is 'GameDVROn')              { $warnings += "Game DVR (background recording) on - disable for better performance" }
    if (& $isNot 'PowerPlanOptimal')    { $warnings += "Power plan not High/Ultimate Performance - change before a gaming session" }
    if (& $is 'WiFiOnly')               { $warnings += "Using Wi-Fi - switch to Ethernet for lower latency" }
    if (& $is 'VBSRunning')             { $warnings += "VBS running - may reduce FPS; check anti-cheat compatibility" }
    if (& $is 'HypervisorPresent')      { $warnings += "Hyper-V hypervisor running (needed for WSL2/Docker) - may cost some FPS; confirm anti-cheat titles work" }
    if (& $isNot 'MouseAccelOff')       { $warnings += "Mouse acceleration enabled - disable 'Enhance pointer precision' for FPS games" }
    [PSCustomObject]@{
        TotalWarnings = $warnings.Count
        Status        = if ($warnings.Count -eq 0) { "No issues detected" } elseif ($warnings.Count -le 3) { "Minor issues" } else { "Multiple issues - review warnings" }
    }
    Add-Line ""
    if ($warnings.Count -eq 0) {
        Add-Line "  No gaming-related issues detected."
    } else {
        Add-Line "  Actionable items:"
        $warnings | ForEach-Object { Add-Line "    - $_" }
    }
    Add-Line ""
    Add-Line "  Detected flags:"
    $flags.GetEnumerator() | ForEach-Object { Add-Line ("    {0,-22} {1}" -f $_.Key, $_.Value) }
}

# ------------------------------------------------------------------
# Scan timing
# ------------------------------------------------------------------
Add-Header "Scan Timing (ms per step)"
$script:StepTimings.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Add-Line ("  {0,-60} {1,6} ms" -f $_.Key, $_.Value)
}
$totalMs = ($script:StepTimings.Values | Measure-Object -Sum).Sum
Add-Line ("  {0,-60} {1,6} ms" -f "TOTAL", $totalMs)

# ------------------------------------------------------------------
# Write report
# ------------------------------------------------------------------
$lines | Out-File -FilePath $reportPath -Encoding utf8

Write-Host ""
Write-Host "Report written to: $reportPath" -ForegroundColor Green
Write-Host "This file was created locally and was not sent anywhere." -ForegroundColor Green
