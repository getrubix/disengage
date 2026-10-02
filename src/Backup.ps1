# Escrow BitLocker recovery keys and LAPS passwords before anything is deleted.
# Deleting the Entra device deletes the keys and LAPS password stored on it; deleting the AD
# computer deletes the msFVE-RecoveryInformation children and the LAPS attributes with it.

function Get-DgRecoverySecret {
    param(
        [Parameter(Mandatory)]$Context,
        # Count what exists without reading the secret values (used by -DryRun).
        [switch]$MetadataOnly,
        [string]$ADServer
    )
    $bundle = [pscustomobject]@{
        BitLocker = [System.Collections.Generic.List[object]]::new()
        Laps      = [System.Collections.Generic.List[object]]::new()
        Errors    = [System.Collections.Generic.List[string]]::new()
        Warnings  = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($entry in $Context.Entra | Where-Object Include) {
        $deviceId = "$($entry.Object.deviceId)"
        $label = "$($entry.Object.displayName) ($deviceId)"
        try {
            $keysUri = New-DgGraphUri -Path 'v1.0/informationProtection/bitlocker/recoveryKeys' -Filter "deviceId eq $(ConvertTo-DgODataLiteral $deviceId)"
            foreach ($key in Invoke-DgGraph -Uri $keysUri -Headers $script:AuditHeaders -All) {
                $secret = if (-not $MetadataOnly) {
                    (Invoke-DgGraph -Uri ("v1.0/informationProtection/bitlocker/recoveryKeys/$($key.id)" + '?$select=key') -Headers $script:AuditHeaders).key
                }
                $bundle.BitLocker.Add([pscustomobject]@{
                        Source      = 'EntraID'
                        Device      = $label
                        KeyId       = $key.id
                        VolumeType  = $key.volumeType
                        Created     = $key.createdDateTime
                        RecoveryKey = $secret
                    })
            }
        } catch {
            $bundle.Errors.Add("BitLocker keys for Entra device $label`: $($_.Exception.Message)")
        }

        try {
            $lapsUri = "v1.0/directory/deviceLocalCredentials/$deviceId"
            if (-not $MetadataOnly) { $lapsUri += '?$select=credentials' }
            $laps = Invoke-DgGraph -Uri $lapsUri -Headers $script:AuditHeaders -AllowNotFound
            if ($laps) {
                if ($MetadataOnly) {
                    $bundle.Laps.Add([pscustomobject]@{ Source = 'EntraID'; Device = $label; Account = $null; BackupTime = $laps.lastBackupDateTime; Password = $null })
                }
                foreach ($credential in @($laps.credentials | Where-Object { $_ })) {
                    $bundle.Laps.Add([pscustomobject]@{
                            Source     = 'EntraID'
                            Device     = $label
                            Account    = $credential.accountName
                            BackupTime = $credential.backupDateTime
                            Password   = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($credential.passwordBase64))
                        })
                }
            }
        } catch {
            $bundle.Errors.Add("LAPS password for Entra device $label`: $($_.Exception.Message)")
        }
    }

    if ($Context.AD -and $Context.AD.Include) {
        $dn = $Context.AD.Object.DistinguishedName
        $server = @{}
        if ($ADServer) { $server.Server = $ADServer }
        try {
            $records = Get-ADObject -SearchBase $dn -Filter "objectClass -eq 'msFVE-RecoveryInformation'" -Properties 'msFVE-RecoveryPassword', 'whenCreated' @server
            foreach ($record in @($records)) {
                $bundle.BitLocker.Add([pscustomobject]@{
                        Source      = 'ActiveDirectory'
                        Device      = $dn
                        KeyId       = $record.Name
                        VolumeType  = $null
                        Created     = $record.whenCreated
                        RecoveryKey = if (-not $MetadataOnly) { $record.'msFVE-RecoveryPassword' }
                    })
            }
        } catch {
            $bundle.Errors.Add("BitLocker keys in AD for $dn`: $($_.Exception.Message)")
        }

        # Windows LAPS (AD-backed). Not every domain uses it, so failures are warnings, not errors.
        if (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue) {
            try {
                $windowsLaps = Get-LapsADPassword -Identity $dn -AsPlainText @server
                if ($windowsLaps -and $windowsLaps.Password) {
                    $bundle.Laps.Add([pscustomobject]@{
                            Source     = 'ActiveDirectory (Windows LAPS)'
                            Device     = $dn
                            Account    = $windowsLaps.Account
                            BackupTime = $windowsLaps.PasswordUpdateTime
                            Password   = if (-not $MetadataOnly) { $windowsLaps.Password }
                        })
                }
            } catch {
                $bundle.Warnings.Add("Windows LAPS lookup in AD: $($_.Exception.Message)")
            }
        }
        # Legacy Microsoft LAPS. The attribute only exists if the schema was extended for it.
        try {
            $legacy = Get-ADComputer -Identity $dn -Properties 'ms-Mcs-AdmPwd' @server
            if ($legacy.'ms-Mcs-AdmPwd') {
                $bundle.Laps.Add([pscustomobject]@{
                        Source     = 'ActiveDirectory (legacy LAPS)'
                        Device     = $dn
                        Account    = $null
                        BackupTime = $null
                        Password   = if (-not $MetadataOnly) { $legacy.'ms-Mcs-AdmPwd' }
                    })
            }
        } catch {
            Write-Verbose "Legacy LAPS attribute not available: $($_.Exception.Message)"
        }
    }
    $bundle
}

# Writes the secrets to an encrypted .dgbackup file and returns its path.
# Encryption: CMS to a document-encryption certificate when configured (recommended; anyone holding
# the private key can decrypt), otherwise DPAPI (only this Windows account on this machine can decrypt).
function Save-DgBackup {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Secrets,
        [Parameter(Mandatory)][string]$Path,
        [string]$CertificateThumbprint
    )
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $payload = [ordered]@{
        DeviceName   = $Context.DeviceName
        SerialNumber = $Context.SerialNumber
        BitLocker    = $Secrets.BitLocker
        Laps         = $Secrets.Laps
        Errors       = $Secrets.Errors
    } | ConvertTo-Json -Depth 6

    if ($CertificateThumbprint) {
        $encryption = 'Cms'
        $protected = Protect-CmsMessage -To $CertificateThumbprint -Content $payload
    } else {
        $encryption = 'Dpapi'
        $protected = ConvertTo-SecureString -String $payload -AsPlainText -Force | ConvertFrom-SecureString
    }

    $safeName = ("{0}_{1}" -f ($Context.DeviceName ?? 'unknown'), ($Context.SerialNumber ?? 'noserial')) -replace '[^\w\-]', '_'
    $file = Join-Path $Path ("{0}_{1:yyyyMMdd-HHmmss}.dgbackup" -f $safeName, (Get-Date))
    [ordered]@{
        Format       = 'Disengage.Backup/1'
        Encryption   = $encryption
        Recipient    = $CertificateThumbprint
        CreatedUtc   = [datetime]::UtcNow.ToString('o')
        CreatedBy    = "$env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"
        DeviceName   = $Context.DeviceName
        SerialNumber = $Context.SerialNumber
        BitLocker    = $Secrets.BitLocker.Count
        Laps         = $Secrets.Laps.Count
        Payload      = $protected
    } | ConvertTo-Json | Set-Content -Path $file -Encoding utf8

    # Prove the file is readable before we destroy the originals. CMS backups can only be checked
    # where the private key lives, which deliberately may not be this machine.
    if ($encryption -eq 'Dpapi') {
        $check = Read-DgBackup -Path $file
        if (@($check.BitLocker).Count -ne $Secrets.BitLocker.Count) { throw "Backup verification failed for $file" }
    }
    $file
}

function Read-DgBackup {
    param([Parameter(Mandatory)][string]$Path)
    $envelope = Get-Content -Raw -Path $Path | ConvertFrom-Json
    if ($envelope.Format -ne 'Disengage.Backup/1') { throw "$Path is not a Disengage backup file." }
    $json = switch ($envelope.Encryption) {
        'Cms' { Unprotect-CmsMessage -Content $envelope.Payload }
        'Dpapi' { ConvertTo-SecureString -String $envelope.Payload | ConvertFrom-SecureString -AsPlainText }
        default { throw "Unknown encryption '$($envelope.Encryption)'." }
    }
    $json | ConvertFrom-Json
}
