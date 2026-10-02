# The destructive steps. Each returns a Disengage.Result and treats "already gone" as success,
# so a partially completed run can simply be re-run.
#
# Order (enforced by New-DgPlan): wipe -> Intune -> Autopilot -> AD -> Entra.
# Autopilot refuses deletion while the device is still enrolled in Intune, and a hybrid device's
# Entra object is recreated by Entra Connect unless the AD computer goes first.

function Send-DgIntuneWipe {
    param([Parameter(Mandatory)]$Context)
    Invoke-DgGraph -Method POST -Uri "v1.0/deviceManagement/managedDevices/$($Context.Intune.id)/wipe" `
        -Body @{ keepEnrollmentData = $false; keepUserData = $false } | Out-Null
    [datetime]::UtcNow
}

function Get-DgWipeState {
    param([Parameter(Mandatory)][string]$ManagedDeviceId, [datetime]$SentUtc)
    # deviceActionResults is only reliably populated on the beta endpoint.
    $device = Invoke-DgGraph -Uri ("beta/deviceManagement/managedDevices/$ManagedDeviceId" + '?$select=id,deviceActionResults') -AllowNotFound
    if (-not $device) { return 'gone' }
    # Ignore results from earlier wipes of the same record.
    $wipe = @($device.deviceActionResults |
            Where-Object { $_.actionName -eq 'wipe' -and (ConvertTo-DgUtc $_.startDateTime) -ge $SentUtc.AddMinutes(-5) } |
            Sort-Object { ConvertTo-DgUtc $_.startDateTime } -Descending)[0]
    if ($wipe) { "$($wipe.actionState)" } else { 'pending' }
}

function Wait-DgIntuneWipe {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][datetime]$SentUtc,
        [double]$TimeoutMinutes,
        [int]$PollSeconds
    )
    $id = $Context.Intune.id
    $terminal = 'done', 'gone', 'failed', 'canceled', 'notSupported'
    $null = Wait-DgCondition -Activity "Waiting for $($Context.DeviceName) to check in and wipe" -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -Condition {
        (Get-DgWipeState -ManagedDeviceId $id -SentUtc $SentUtc) -in $terminal
    }
    $state = Get-DgWipeState -ManagedDeviceId $id -SentUtc $SentUtc
    switch ($state) {
        { $_ -in 'done', 'gone' } { New-DgResult -Status Done -Detail 'Device confirmed the wipe' }
        { $_ -in 'pending', 'active', 'none' } { New-DgResult -Status Pending -Detail "Wipe is '$state' — the device has not confirmed it yet" -Data @{ SentUtc = $SentUtc } }
        default { New-DgResult -Status Failed -Detail "Intune reports wipe state '$state'" }
    }
}

function Remove-DgIntuneDevice {
    param([Parameter(Mandatory)]$Context, [int]$PollSeconds = 10)
    $uri = "v1.0/deviceManagement/managedDevices/$($Context.Intune.id)"
    if ((Remove-DgGraphResource -Uri $uri) -eq 'NotFound') {
        return New-DgResult -Status AlreadyGone -Detail 'Intune record was already removed'
    }
    $gone = Wait-DgCondition -Activity 'Waiting for Intune to remove the record' -TimeoutMinutes 3 -PollSeconds $PollSeconds -Condition {
        -not (Invoke-DgGraph -Uri $uri -AllowNotFound)
    }
    if ($gone) { New-DgResult -Status Done -Detail "Deleted managed device $($Context.Intune.id)" }
    else { New-DgResult -Status Pending -Detail 'Delete accepted but the record is still visible' }
}

function Remove-DgAutopilotDevice {
    param(
        [Parameter(Mandatory)]$Context,
        [double]$TimeoutMinutes = 15,
        [int]$PollSeconds = 15
    )
    $removed = 0; $already = 0; $pending = @()
    foreach ($identity in $Context.Autopilot) {
        $uri = "v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($identity.id)"
        $outcome = $null
        # Autopilot rejects the delete for a short while after the Intune record goes; retry through that.
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try {
                $outcome = Remove-DgGraphResource -Uri $uri
                break
            } catch {
                if ((Get-DgHttpStatus $_) -in 400, 409 -and $attempt -lt 6) {
                    Write-DgStatus Info 'Autopilot is not ready to release the device yet (Intune removal still propagating). Retrying in 30s…' -Indent 6
                    Start-Sleep -Seconds 30
                    continue
                }
                throw
            }
        }
        if ($outcome -eq 'NotFound') { $already++; continue }

        $gone = Wait-DgCondition -Activity "Waiting for Autopilot to release $($identity.serialNumber)" -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -Condition {
            -not (Invoke-DgGraph -Uri $uri -AllowNotFound)
        }
        if ($gone) { $removed++ } else { $pending += $identity.serialNumber }
    }
    if ($pending) {
        return New-DgResult -Status Pending -Detail "Deletion still processing for $($pending -join ', '); it usually completes within the hour"
    }
    if ($removed -eq 0 -and $already -gt 0) { return New-DgResult -Status AlreadyGone -Detail 'Autopilot identity was already removed' }
    New-DgResult -Status Done -Detail "Removed $removed Autopilot identit$(if ($removed -eq 1) { 'y' } else { 'ies' })"
}

function Remove-DgAdComputer {
    param([Parameter(Mandatory)]$Context, [string]$Server)
    $dn = $Context.AD.Object.DistinguishedName
    $target = @{ Identity = $dn }
    if ($Server) { $target.Server = $Server }
    try {
        $current = Get-ADObject @target -Properties ProtectedFromAccidentalDeletion
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or $_.Exception.GetType().Name -like '*NotFound*') {
            return New-DgResult -Status AlreadyGone -Detail 'Computer object was already removed'
        }
        throw
    }
    $detail = "Deleted $dn"
    if ($current.ProtectedFromAccidentalDeletion) {
        Set-ADObject @target -ProtectedFromAccidentalDeletion $false
        $detail += ' (cleared accidental-deletion protection first)'
    }
    # -Recursive is required: BitLocker recovery info is stored as child objects of the computer.
    Remove-ADObject @target -Recursive -Confirm:$false
    New-DgResult -Status Done -Detail $detail
}

function Invoke-DgEntraConnectSync {
    param([Parameter(Mandatory)][string]$Server)
    Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
        Import-Module ADSync
        Start-ADSyncSyncCycle -PolicyType Delta
    } | Out-Null
    New-DgResult -Status Done -Detail "Delta sync started on $Server"
}

function Remove-DgEntraDevice {
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('Delete', 'Disable')][string]$Action = 'Delete',
        [bool]$ADRemoved,
        [double]$SyncTimeoutMinutes = 40,
        [int]$PollSeconds = 30
    )
    $outcomes = foreach ($entry in $Context.Entra | Where-Object Include) {
        $object = $entry.Object
        $uri = "v1.0/devices/$($object.id)"
        $name = "$($object.displayName) ($(Get-DgJoinTypeLabel $object.trustType))"

        if ($object.onPremisesSyncEnabled) {
            # Synced objects are read-only in Graph; Entra Connect removes them once the AD object is gone.
            if (-not $ADRemoved) {
                [pscustomobject]@{ Status = 'Pending'; Text = "$name is synced from AD — remove the AD computer or take it out of sync scope" }
                continue
            }
            $gone = Wait-DgCondition -Activity "Waiting for Entra Connect to remove $($object.displayName)" -TimeoutMinutes $SyncTimeoutMinutes -PollSeconds $PollSeconds -Condition {
                -not (Invoke-DgGraph -Uri $uri -AllowNotFound)
            }
            if ($gone) { [pscustomobject]@{ Status = 'Done'; Text = "$name removed by Entra Connect" } }
            else { [pscustomobject]@{ Status = 'Pending'; Text = "$name will be removed on the next Entra Connect sync" } }
            continue
        }

        if ($Action -eq 'Disable') {
            if (-not (Invoke-DgGraph -Uri $uri -AllowNotFound)) {
                [pscustomobject]@{ Status = 'AlreadyGone'; Text = "$name already removed" }
                continue
            }
            Invoke-DgGraph -Method PATCH -Uri $uri -Body @{ accountEnabled = $false } | Out-Null
            [pscustomobject]@{ Status = 'Done'; Text = "$name disabled" }
        } elseif ((Remove-DgGraphResource -Uri $uri) -eq 'NotFound') {
            [pscustomobject]@{ Status = 'AlreadyGone'; Text = "$name already removed" }
        } else {
            [pscustomobject]@{ Status = 'Done'; Text = "$name deleted" }
        }
    }
    $outcomes = @($outcomes)
    $status = if ($outcomes.Status -contains 'Pending') { 'Pending' }
    elseif (@($outcomes | Where-Object Status -ne 'AlreadyGone').Count -eq 0) { 'AlreadyGone' }
    else { 'Done' }
    New-DgResult -Status $status -Detail ($outcomes.Text -join '; ')
}
