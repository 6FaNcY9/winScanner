# winScanner

A read-only Windows 10/11 diagnostic tool that checks whether a machine is
ready to run **Docker Desktop / WSL2**, and writes the results to a single
text report on the Desktop.

## What it does

`WinScanner.ps1` collects the following information:

- Windows edition, version, build number, and pending-reboot status
- CPU details and firmware virtualization support (VT-x / AMD-V)
- Status of the Hyper-V, WSL, Virtual Machine Platform, and Containers
  Windows features
- Total/free RAM and disk space
- WSL status, installed distributions, and WSL version
- Docker installation path, `docker version` / `docker info` output, and
  running Docker processes
- Active network adapters and IPv4 configuration
- Windows Defender / antivirus real-time protection status

It does **not**:

- Install, change, or remove anything on the machine
- Read emails, documents, browser data, or any personal files
- Send data anywhere over the network

The report is written to:

```
%USERPROFILE%\Desktop\WinScanner_Report_<timestamp>.txt
```

Review the file before sharing it with anyone.

## Usage

1. Copy `WinScanner.ps1` and `Run-WinScanner.cmd` to the target Windows
   machine.
2. Double-click `Run-WinScanner.cmd`.
3. Open the generated `WinScanner_Report_*.txt` on the Desktop.

Alternatively, run the PowerShell script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\WinScanner.ps1
```

## Requirements

- Windows 10 (1903+) or Windows 11
- PowerShell 5.1 or later (included by default)

Some checks (e.g. Hyper-V feature state, Defender status) require running
from an elevated (Administrator) PowerShell session to return full results;
the script will still run without elevation and report what it can.
