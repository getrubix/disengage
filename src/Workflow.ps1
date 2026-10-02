# The wizard: discover -> review -> plan -> confirm -> execute -> verify -> report.

function Read-DgDeviceQuery {
    $choice = Read-DgChoice -Prompt 'Look up the device by:' -Options 'Device name', 'Serial number'
    $by = @('Name', 'Serial')[$choice]
    $value = Read-DgText -Prompt (@('Device name', 'Serial number')[$choice])
    [pscustomobject]@{ By = $by; Value = $value }
}

function Invoke-DgDiscovery {
    param([Parameter(Mandatory)]$Query, [Parameter(Mandatory)][hashtable]$Config, [bool]$AdAvailable)
    $label = if ($Query.By -eq 'Name') { 'device name' } else { 'serial number' }
    Write-DgStatus Info "Searching for $label '$($Query.Value)'…"

    $intune = @(Find-DgIntuneDevice -By $Query.By -Value $Query.Value)
    $selected = $null
    if ($intune.Count -gt 1) {
        Write-DgStatus Warn "$($intune.Count) Intune devices match. Pick the one to offboard:"
        $options = $intune | ForEach-Object {
            '{0} · {1} · {2} · last sync {3}' -f $_.deviceName, $_.serialNumber, ($_.userPrincipalName ?? 'no primary user'), (Format-DgDate $_.lastSyncDateTime)
        }
        $selected = $intune[(Read-DgChoice -Prompt 'Intune device:' -Options $options -Default 0)]
    } elseif ($intune.Count -eq 1) {
        $selected = $intune[0]
    }

    $context = Get-DgDeviceContext -By $Query.By -Value $Query.Value -IntuneDevice $selected `
        -IncludeAD:$AdAvailable -ADServer $Config.ActiveDirectory.Server

    $entraCount = @($context.Entra).Count
    Write-DgStatus ($context.Intune ? 'Found' : 'NotPresent') ('Intune       ' + ($context.Intune ? "$($context.Intune.deviceName) ($($context.Intune.id))" : 'no managed device'))
    Write-DgStatus ($context.Autopilot ? 'Found' : 'NotPresent') ('Autopilot    ' + ($context.Autopilot ? "$(@($context.Autopilot).Count) identity · group tag '$($context.Autopilot[0].groupTag)'" : 'not registered'))
    Write-DgStatus ($entraCount ? 'Found' : 'NotPresent') ('Entra ID     ' + ($entraCount ? "$entraCount device object(s)" : 'no device objects'))
    if ($context.ADChecked) {
        Write-DgStatus ($context.AD ? 'Found' : 'NotPresent') ('AD           ' + ($context.AD ? $context.AD.Object.DistinguishedName : 'no computer object'))
    } else {
        Write-DgStatus Skipped 'AD           not checked'
    }

    if (-not (Test-DgDeviceFound $context)) {
        Write-DgStatus Warn "No records found for $label '$($Query.Value)' in any system."
        return $null
    }
    $context
}

function Show-DgDeviceSummary {
    param([Parameter(Mandatory)]$Context)
    $intune = $Context.Intune
    $primary = @($Context.Entra | Where-Object Linked | Select-Object -First 1).Object
    Write-DgKeyValue ([ordered]@{
            'Device name'  = $Context.DeviceName
            'Serial'       = $Context.SerialNumber
            'Model'        = (@($intune.manufacturer, $intune.model) + @($Context.Autopilot | Select-Object -First 1 | ForEach-Object { $_.manufacturer, $_.model }) | Where-Object { $_ } | Select-Object -First 2) -join ' '
            'Primary user' = $intune.userPrincipalName ?? @($Context.Autopilot)[0].userPrincipalName
            'Join type'    = if ($primary) { Get-DgJoinTypeLabel $primary.trustType } elseif ($Context.AD) { 'Domain joined' }
            'Ownership'    = $intune.managedDeviceOwnerType
            'Compliance'   = $intune.complianceState
            'Enrolled'     = if ($intune) { Format-DgDate $intune.enrolledDateTime }
            'Last activity' = Format-DgDate (Get-DgLastActivity $Context)
        })
}

# Name-only matches could be a different machine that reused the name, so the operator decides.
function Confirm-DgUncertainMatch {
    param([Parameter(Mandatory)]$Context)
    foreach ($entry in @($Context.Entra | Where-Object { -not $_.Linked })) {
        $o = $entry.Object
        Write-Host ''
        Write-DgStatus Warn ("Entra object '{0}' ({1}, {2}, last sign-in {3}) matched by display name only." -f `
                $o.displayName, (Get-DgJoinTypeLabel $o.trustType), ($o.accountEnabled ? 'enabled' : 'disabled'), (Format-DgDate $o.approximateLastSignInDateTime))
        $entry.Include = Read-DgYesNo -Prompt '  Include this object in the offboarding?' -Default $entry.Include
    }
    if ($Context.AD -and -not $Context.AD.Linked) {
        $o = $Context.AD.Object
        Write-Host ''
        Write-DgStatus Warn ("AD computer '{0}' (last logon {1}) matched by name only — its objectGUID doesn't match a hybrid Entra device." -f `
                $o.DistinguishedName, (Format-DgDate $o.LastLogonDate))
        $Context.AD.Include = Read-DgYesNo -Prompt '  Include this computer object?' -Default $Context.AD.Include
    }
}

function Get-DgRecordRow {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][hashtable]$Config, [bool]$Wipe)
    $rows = [System.Collections.Generic.List[object]]::new()
    $adRemoving = [bool]($Context.AD -and $Context.AD.Include)

    if ($Context.Intune) {
        $rows.Add([pscustomobject]@{ System = 'Intune'; Record = $Context.Intune.deviceName; 'Last seen' = Format-DgDate $Context.Intune.lastSyncDateTime; Action = ($Wipe ? 'Wipe, then delete' : 'Delete') })
    } else {
        $rows.Add([pscustomobject]@{ System = 'Intune'; Record = 'not found'; 'Last seen' = '—'; Action = '—' })
    }
    if ($Context.Autopilot) {
        foreach ($ap in $Context.Autopilot) {
            $rows.Add([pscustomobject]@{ System = 'Autopilot'; Record = "$($ap.serialNumber) · tag '$($ap.groupTag)'"; 'Last seen' = Format-DgDate $ap.lastContactedDateTime; Action = 'Delete' })
        }
    } else {
        $rows.Add([pscustomobject]@{ System = 'Autopilot'; Record = 'not found'; 'Last seen' = '—'; Action = '—' })
    }
    if ($Context.Entra) {
        foreach ($entry in $Context.Entra) {
            $o = $entry.Object
            $action = if (-not $entry.Include) { 'Leave in place' }
            elseif ($o.onPremisesSyncEnabled) { $adRemoving ? 'Removed by Entra Connect' : 'Cannot remove (synced from AD)' }
            else { $Config.EntraAction }
            $rows.Add([pscustomobject]@{ System = 'Entra ID'; Record = "$($o.displayName) · $(Get-DgJoinTypeLabel $o.trustType)"; 'Last seen' = Format-DgDate $o.approximateLastSignInDateTime; Action = $action })
        }
    } else {
        $rows.Add([pscustomobject]@{ System = 'Entra ID'; Record = 'not found'; 'Last seen' = '—'; Action = '—' })
    }
    if (-not $Context.ADChecked) {
        $rows.Add([pscustomobject]@{ System = 'AD'; Record = 'not checked'; 'Last seen' = '—'; Action = '—' })
    } elseif ($Context.AD) {
        $o = $Context.AD.Object
        $action = if (-not $Context.AD.Include) { 'Leave in place' } elseif ($o.ProtectedFromAccidentalDeletion) { 'Delete (clears protection)' } else { 'Delete' }
        $rows.Add([pscustomobject]@{ System = 'AD'; Record = $o.DistinguishedName; 'Last seen' = Format-DgDate $o.LastLogonDate; Action = $action })
    } else {
        $rows.Add([pscustomobject]@{ System = 'AD'; Record = 'not found'; 'Last seen' = '—'; Action = '—' })
    }
    $rows.ToArray()
}

function Show-DgWarning {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][hashtable]$Config)
    $warned = $false
    $last = Get-DgLastActivity $Context
    if ($last -and ([datetime]::UtcNow - $last).TotalHours -lt $Config.RecentActivityHours) {
        Write-DgStatus Warn "This device was active $(Format-DgDate $last). Make sure it is really being retired."
        $warned = $true
    }
    foreach ($note in $Context.Notes) { Write-DgStatus Warn $note; $warned = $true }
    $stuck = @($Context.Entra | Where-Object { $_.Include -and $_.Object.onPremisesSyncEnabled }) |
        Where-Object { -not ($Context.AD -and $Context.AD.Include) }
    if ($stuck) {
        Write-DgStatus Warn 'A selected Entra object is synced from AD, but the AD computer is not being removed. That object will stay until it leaves sync scope.'
        $warned = $true
    }
    $warned
}

# Builds the ordered list of steps. Each step's Action is a closure over the context and config.
function New-DgPlan {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][hashtable]$Config, [bool]$Wipe, [hashtable]$State)
    $plan = [System.Collections.Generic.List[object]]::new()
    $timeouts = $Config.Timeouts
    $adServer = $Config.ActiveDirectory.Server
    $entraIncluded = @($Context.Entra | Where-Object Include)
    $adIncluded = [bool]($Context.AD -and $Context.AD.Include)

    if ($entraIncluded -or $adIncluded) {
        $plan.Add([pscustomobject]@{ Kind = 'Backup'; Name = 'Back up BitLocker keys and LAPS passwords'; Action = {
                    $secrets = Get-DgRecoverySecret -Context $Context -ADServer $adServer
                    $State.BackupPath = Save-DgBackup -Context $Context -Secrets $secrets -Path $Config.Backup.Path -CertificateThumbprint $Config.Backup.CertificateThumbprint
                    foreach ($warning in $secrets.Warnings) { Write-DgStatus Warn $warning -Indent 6 }
                    $summary = "$($secrets.BitLocker.Count) BitLocker key(s), $($secrets.Laps.Count) LAPS password(s) → $($State.BackupPath)"
                    if ($secrets.Errors.Count) {
                        foreach ($problem in $secrets.Errors) { Write-DgStatus Failed $problem -Indent 6 }
                        New-DgResult -Status Warn -Detail "Incomplete: $summary" -Data $secrets.Errors
                    } else {
                        New-DgResult -Status Done -Detail $summary
                    }
                }.GetNewClosure()
            })
    }
    if ($Wipe -and $Context.Intune) {
        $plan.Add([pscustomobject]@{ Kind = 'Wipe'; Name = 'Remote wipe'; Action = {
                    $State.WipeSentUtc = Send-DgIntuneWipe -Context $Context
                    Write-DgStatus Info 'Wipe sent. Waiting for the device to check in and confirm…' -Indent 6
                    Wait-DgIntuneWipe -Context $Context -SentUtc $State.WipeSentUtc -TimeoutMinutes $timeouts.WipeMinutes -PollSeconds $timeouts.PollSeconds
                }.GetNewClosure()
                Resume = {
                    Wait-DgIntuneWipe -Context $Context -SentUtc $State.WipeSentUtc -TimeoutMinutes $timeouts.WipeMinutes -PollSeconds $timeouts.PollSeconds
                }.GetNewClosure()
            })
    }
    if ($Context.Intune) {
        $plan.Add([pscustomobject]@{ Kind = 'Intune'; Name = 'Delete Intune managed device'; Action = {
                    Remove-DgIntuneDevice -Context $Context -PollSeconds ([Math]::Min(10, $timeouts.PollSeconds))
                }.GetNewClosure()
            })
    }
    if ($Context.Autopilot) {
        $plan.Add([pscustomobject]@{ Kind = 'Autopilot'; Name = 'Delete Autopilot identity'; Action = {
                    Remove-DgAutopilotDevice -Context $Context -TimeoutMinutes $timeouts.AutopilotMinutes -PollSeconds $timeouts.PollSeconds
                }.GetNewClosure()
            })
    }
    if ($adIncluded) {
        $plan.Add([pscustomobject]@{ Kind = 'AD'; Name = 'Delete AD computer object'; Action = {
                    $result = Remove-DgAdComputer -Context $Context -Server $adServer
                    $State.ADRemoved = $result.Status -in 'Done', 'AlreadyGone'
                    $result
                }.GetNewClosure()
            })
        $synced = @($entraIncluded | Where-Object { $_.Object.onPremisesSyncEnabled })
        if ($synced -and $Config.ActiveDirectory.EntraConnectServer) {
            $syncServer = $Config.ActiveDirectory.EntraConnectServer
            $plan.Add([pscustomobject]@{ Kind = 'Sync'; Name = 'Trigger Entra Connect delta sync'; Action = {
                        Invoke-DgEntraConnectSync -Server $syncServer
                    }.GetNewClosure()
                })
        }
    }
    if ($entraIncluded) {
        $verb = if ($Config.EntraAction -eq 'Disable') { 'Disable' } else { 'Delete' }
        $plan.Add([pscustomobject]@{ Kind = 'Entra'; Name = "$verb Entra ID device object(s)"; Action = {
                    Remove-DgEntraDevice -Context $Context -Action $Config.EntraAction -ADRemoved ([bool]$State.ADRemoved) `
                        -SyncTimeoutMinutes $timeouts.EntraSyncMinutes -PollSeconds ([Math]::Max(15, $timeouts.PollSeconds))
                }.GetNewClosure()
            })
    }
    $plan.ToArray()
}

function Invoke-DgPlan {
    param([Parameter(Mandatory)][object[]]$Plan)
    $results = [System.Collections.Generic.List[object]]::new()
    $stopped = $false
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $step = $Plan[$i]
        if ($stopped) {
            $skipped = New-DgResult -Status NotRun
            $skipped.Step = $step.Name
            Write-DgStatus NotRun "[$($i + 1)/$($Plan.Count)] $($step.Name) — not run"
            $results.Add($skipped)
            continue
        }
        $result = Invoke-DgStep -Name $step.Name -Action $step.Action -Number ($i + 1) -Total $Plan.Count

        if ($step.Kind -eq 'Backup' -and $result.Status -eq 'Warn') {
            Write-DgStatus Warn 'Some secrets could not be read. Continuing will permanently destroy them.' -Indent 4
            if (-not (Confirm-DgTyped -Expected 'CONTINUE' -Prompt '  Type {0} to proceed without a complete backup, or anything else to stop')) {
                $result.Status = 'Failed'
                $result.Detail = "Stopped by operator: backup incomplete. $($result.Detail)"
            }
        }

        while ($step.Kind -eq 'Wipe' -and $result.Status -eq 'Pending') {
            $choice = Read-DgChoice -Prompt 'The device has not confirmed the wipe yet. What now?' -Options @(
                'Keep waiting'
                'Continue offboarding without confirmation (deleting the Intune record means a pending wipe will never run)'
                'Stop here and re-run later (nothing else is changed)'
            )
            if ($choice -eq 0) {
                $result = Invoke-DgStep -Name "$($step.Name) (still waiting)" -Action $step.Resume -Number ($i + 1) -Total $Plan.Count
            } elseif ($choice -eq 1) {
                $result.Status = 'Warn'
                $result.Detail = 'Continued without wipe confirmation'
            } else {
                $result.Status = 'Failed'
                $result.Detail = 'Stopped by operator while waiting for the wipe'
            }
        }

        $results.Add($result)
        if ($result.Status -eq 'Failed') {
            Write-DgStatus Failed 'Stopping: later steps depend on this one. Fix the problem and re-run; finished steps are skipped automatically.' -Indent 4
            $stopped = $true
        }
    }
    Write-Progress -Id 1 -Activity 'Offboarding' -Completed
    $results.ToArray()
}

function Show-DgOutcome {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Verification)
    Write-DgTable -Rows $Verification.Rows -Columns 'System', 'Status', 'Detail' -StatusColumn 'Status' -MaxColumnWidth 90
    $device = ($Context.DeviceName, $Context.SerialNumber | Where-Object { $_ }) -join ' / '
    Write-Host ''
    switch ($Verification.Outcome) {
        'Complete' { Write-DgStatus Done "$($PSStyle.Bold)$device has been fully offboarded.$($PSStyle.Reset)" }
        'Pending' { Write-DgStatus Pending "$($PSStyle.Bold)$device is offboarded; some deletions are still being processed by Microsoft. Re-run later to confirm.$($PSStyle.Reset)" }
        default { Write-DgStatus Failed "$($PSStyle.Bold)$device is NOT fully offboarded. Review the items above and re-run to retry.$($PSStyle.Reset)" }
    }
}

# Runs the full wizard for one device. Returns the process exit code.
function Invoke-DgOffboarding {
    param(
        [Parameter(Mandatory)]$Query,
        [Parameter(Mandatory)][hashtable]$Config,
        [bool]$AdAvailable,
        [switch]$DryRun
    )
    $log = Start-DgRunLog -Path $Config.Logging.Path -Label $Query.Value
    $context = $null; $results = @(); $verification = $null; $wipe = $false
    $state = @{ BackupPath = $null; ADRemoved = $false; WipeSentUtc = $null }
    try {
        Write-DgSection 'Discovery'
        $context = Invoke-DgDiscovery -Query $Query -Config $Config -AdAvailable $AdAvailable
        if (-not $context) { return 1 }

        Write-DgSection 'Review'
        Show-DgDeviceSummary $context
        Confirm-DgUncertainMatch $context
        Write-Host ''
        Write-DgTable -Rows (Get-DgRecordRow -Context $context -Config $Config) -Columns 'System', 'Record', 'Last seen', 'Action'
        Write-Host ''
        $null = Show-DgWarning -Context $context -Config $Config

        if ($context.Intune -and -not $DryRun) {
            Write-Host ''
            $wipe = Read-DgYesNo -Prompt 'Send a remote wipe (factory reset) before removing the records?' -Default $false
        }

        $plan = New-DgPlan -Context $context -Config $Config -Wipe $wipe -State $state
        if (-not $plan) {
            Write-DgStatus Warn 'Nothing selected to remove.'
            return 1
        }
        Write-DgSection 'Plan'
        for ($i = 0; $i -lt $plan.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $plan[$i].Name) }

        if ($DryRun) {
            Write-DgSection 'Dry run'
            if ($plan.Kind -contains 'Backup') {
                $secrets = Get-DgRecoverySecret -Context $context -ADServer $Config.ActiveDirectory.Server -MetadataOnly
                Write-DgStatus Info "$($secrets.BitLocker.Count) BitLocker key(s) and $($secrets.Laps.Count) LAPS password(s) would be backed up"
                foreach ($problem in $secrets.Errors) { Write-DgStatus Warn $problem }
            }
            Write-DgStatus Info 'No changes were made.'
            Save-DgReport -Path $log.Report -Context $context -Steps @() -Verification ([pscustomobject]@{ Outcome = 'DryRun'; Rows = @() }) -DryRun
            Write-DgStatus Info "Report: $($log.Report)"
            return 0
        }

        Write-Host ''
        $confirmAs = $context.DeviceName ?? $context.SerialNumber
        if (-not (Confirm-DgTyped -Expected $confirmAs -Prompt 'This cannot be undone. Type {0} to start offboarding')) {
            Write-DgStatus Warn 'Confirmation did not match. Nothing was changed.'
            return 1
        }

        Write-DgSection 'Offboarding'
        $results = Invoke-DgPlan -Plan $plan

        Write-DgSection 'Verification'
        $verification = Test-DgOffboardState -Context $context -EntraAction $Config.EntraAction -ADServer $Config.ActiveDirectory.Server
        Show-DgOutcome -Context $context -Verification $verification

        Save-DgReport -Path $log.Report -Context $context -Steps $results -Verification $verification -BackupPath $state.BackupPath -Wipe $wipe
        Write-Host ''
        if ($state.BackupPath) { Write-DgStatus Info "Secrets backup: $($state.BackupPath)" }
        Write-DgStatus Info "Report:         $($log.Report)"
        Write-DgStatus Info "Log:            $($log.Transcript)"

        switch ($verification.Outcome) { 'Complete' { 0 } 'Pending' { 2 } default { 1 } }
    } finally {
        Stop-DgRunLog
    }
}
