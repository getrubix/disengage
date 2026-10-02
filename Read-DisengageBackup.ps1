#Requires -Version 7.2
<#
.SYNOPSIS
    Decrypts a .dgbackup file written by Disengage and shows the BitLocker keys and LAPS passwords in it.

.DESCRIPTION
    CMS backups decrypt on any machine holding the private key of the escrow certificate.
    DPAPI backups decrypt only for the Windows account, on the machine, that created them.

.EXAMPLE
    ./Read-DisengageBackup.ps1 -Path ./Backups/DESKTOP-ABC_5CG1234XYZ_20261001-142233.dgbackup
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/Disengage.psm1') -Force

$backup = Read-DgBackup -Path $Path
Write-DgSection "Backup for $($backup.DeviceName) / $($backup.SerialNumber)"
if ($backup.BitLocker) {
    Write-Host ''
    Write-DgTable -Rows $backup.BitLocker -Columns 'Source', 'KeyId', 'VolumeType', 'RecoveryKey' -MaxColumnWidth 60
}
if ($backup.Laps) {
    Write-Host ''
    Write-DgTable -Rows $backup.Laps -Columns 'Source', 'Account', 'BackupTime', 'Password'
}
if (-not $backup.BitLocker -and -not $backup.Laps) { Write-DgStatus Info 'This backup contains no secrets.' }
foreach ($problem in $backup.Errors) { Write-DgStatus Warn "Not captured at backup time: $problem" }
