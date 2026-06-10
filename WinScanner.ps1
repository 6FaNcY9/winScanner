#requires -Version 5.1
<#
    WinScanner - Windows 10/11 Docker & WSL2 readiness report

    Read-only diagnostic script. Collects system information relevant to
    running Docker Desktop / WSL2 and writes a single human-readable text
    report. Makes no changes to the system, installs nothing, and does not
    transmit data anywhere - the report stays on the local machine.
#>

$ErrorActionPreference = 'SilentlyContinue'

$timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputDir  = Join-Path $env:USERPROFILE "Desktop"
$reportPath = Join-Path $outputDir "WinScanner_Report_$timestamp.txt"

$lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Text = "")
    $lines.Add($Text)
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
    try {
        $result = & $Action
        if ($null -eq $result -or ($result | Measure-Object).Count -eq 0) {
            Add-Line "(no data returned)"
        } else {
            $result | Out-String -Width 200 | ForEach-Object {
                $_.TrimEnd() -split "`r?`n" | ForEach-Object { Add-Line $_ }
            }
        }
    } catch {
        Add-Line "ERROR: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------
# Header
# ------------------------------------------------------------------
Add-Line "WinScanner - Docker / WSL2 Readiness Report"
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

Run-Step "Disk Space" {
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name,
            @{N='UsedGB';E={[math]::Round($_.Used/1GB,2)}},
            @{N='FreeGB';E={[math]::Round($_.Free/1GB,2)}}
}

Run-Step "Physical Disk Type (SSD/HDD)" {
    Get-PhysicalDisk | Select-Object FriendlyName, MediaType, Size, HealthStatus
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
# Write report
# ------------------------------------------------------------------
$lines | Out-File -FilePath $reportPath -Encoding utf8

Write-Host ""
Write-Host "Report written to: $reportPath" -ForegroundColor Green
Write-Host "This file was created locally and was not sent anywhere." -ForegroundColor Green
