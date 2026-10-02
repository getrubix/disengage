#Requires -Version 7.2
<#
.SYNOPSIS
    Offboards a Windows device from Intune, Windows Autopilot, Entra ID and on-prem Active Directory.

.DESCRIPTION
    Interactive wizard. Looks the device up by name or serial number, shows every record it found
    and what will happen to each, backs up BitLocker recovery keys and LAPS passwords, optionally
    sends a remote wipe, removes the records in the order Microsoft requires, then re-checks every
    system and confirms whether the device is fully offboarded.

    Safe to re-run: steps that already completed are detected and skipped.

.PARAMETER DeviceName
    Skip the lookup prompt and search by device name.

.PARAMETER SerialNumber
    Skip the lookup prompt and search by serial number.

.PARAMETER ConfigPath
    Path to the config file. Defaults to config.json next to this script.

.PARAMETER DryRun
    Discover and show the plan, count the secrets that would be backed up, and change nothing.

.EXAMPLE
    ./Disengage.ps1

.EXAMPLE
    ./Disengage.ps1 -SerialNumber 5CG1234XYZ -DryRun

.NOTES
    Exit codes: 0 fully offboarded (or dry run) · 1 incomplete, cancelled or not found
                2 offboarded but Microsoft-side deletions still processing · 3 preflight failed
#>
[CmdletBinding(DefaultParameterSetName = 'Wizard')]
param(
    [Parameter(ParameterSetName = 'Name', Mandatory)][string]$DeviceName,
    [Parameter(ParameterSetName = 'Serial', Mandatory)][string]$SerialNumber,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Import-Module (Join-Path $PSScriptRoot 'src/Disengage.psm1') -Force

Write-DgBanner -Subtitle ($DryRun ? 'DRY RUN · nothing will be changed' : $null)

Write-DgSection 'Preflight'
try {
    $config = Import-DgConfig -Path $ConfigPath
} catch {
    Write-DgStatus Failed $_.Exception.Message
    exit 3
}
$preflight = Invoke-DgPreflight -Config $config
if (-not $preflight.Ready) {
    Write-Host ''
    Write-DgStatus Failed 'Preflight failed. Fix the items above and run again.'
    exit 3
}

$interactive = $PSCmdlet.ParameterSetName -eq 'Wizard'
do {
    Write-DgSection 'Device'
    $query = switch ($PSCmdlet.ParameterSetName) {
        'Name' { [pscustomobject]@{ By = 'Name'; Value = $DeviceName } }
        'Serial' { [pscustomobject]@{ By = 'Serial'; Value = $SerialNumber } }
        default { Read-DgDeviceQuery }
    }
    $exitCode = Invoke-DgOffboarding -Query $query -Config $config -AdAvailable $preflight.AdAvailable -DryRun:$DryRun
    Write-Host ''
    $again = $interactive -and (Read-DgYesNo -Prompt 'Offboard another device?' -Default $false)
} while ($again)

exit $exitCode
