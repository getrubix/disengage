# Independent re-check of every system after the run. It looks up the records discovered earlier by ID,
# and searches Intune and Autopilot again by serial/name to catch a device that re-enrolled mid-run.

function Test-DgOffboardState {
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('Delete', 'Disable')][string]$EntraAction = 'Delete',
        [string]$ADServer
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $row = { param($System, $Status, $Detail) $rows.Add([pscustomobject]@{ System = $System; Status = $Status; Detail = $Detail }) }

    # Intune
    $fresh = if ($Context.SerialNumber) { Find-DgIntuneDevice -By Serial -Value $Context.SerialNumber }
    elseif ($Context.DeviceName) { Find-DgIntuneDevice -By Name -Value $Context.DeviceName }
    $fresh = @($fresh | Where-Object { $_ })
    if ($Context.Intune -and (Invoke-DgGraph -Uri "v1.0/deviceManagement/managedDevices/$($Context.Intune.id)" -AllowNotFound)) {
        & $row 'Intune' 'StillPresent' "Managed device $($Context.Intune.id) still exists"
    } elseif ($fresh) {
        & $row 'Intune' 'StillPresent' "New enrollment found: $($fresh[0].deviceName), enrolled $(Format-DgDate $fresh[0].enrolledDateTime)"
    } elseif ($Context.Intune) {
        & $row 'Intune' 'Removed' 'Managed device record deleted'
    } else {
        & $row 'Intune' 'NotPresent' 'No record existed'
    }

    # Autopilot
    $remaining = @($Context.Autopilot | Where-Object {
            Invoke-DgGraph -Uri "v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($_.id)" -AllowNotFound
        })
    $freshAutopilot = if ($Context.SerialNumber) { @(Find-DgAutopilotDevice -SerialNumber $Context.SerialNumber | Where-Object { $_.id -notin $Context.Autopilot.id }) }
    if ($remaining) {
        & $row 'Autopilot' 'Pending' "Identity for $($remaining[0].serialNumber) is still being deleted (can take up to an hour)"
    } elseif ($freshAutopilot) {
        & $row 'Autopilot' 'StillPresent' "Device was re-registered (identity $($freshAutopilot[0].id))"
    } elseif ($Context.Autopilot) {
        & $row 'Autopilot' 'Removed' 'Autopilot identity deleted'
    } else {
        & $row 'Autopilot' 'NotPresent' 'No record existed'
    }

    # Entra ID
    $included = @($Context.Entra | Where-Object Include)
    $leftAlone = @($Context.Entra | Where-Object { -not $_.Include }).Count
    $suffix = if ($leftAlone) { " · $leftAlone unrelated object(s) with the same name left in place" } else { '' }
    if (-not $included) {
        $status = if ($Context.Entra) { 'Skipped' } else { 'NotPresent' }
        & $row 'Entra ID' $status ("No device objects selected$suffix")
    } else {
        $states = foreach ($entry in $included) {
            $current = Invoke-DgGraph -Uri "v1.0/devices/$($entry.Object.id)" -AllowNotFound
            if (-not $current) { 'Removed' }
            elseif ($entry.Object.onPremisesSyncEnabled -and $Context.AD.Include) { 'Pending' }
            elseif ($EntraAction -eq 'Disable' -and -not $current.accountEnabled) { 'Disabled' }
            else { 'StillPresent' }
        }
        $states = @($states)
        $status = if ($states -contains 'StillPresent') { 'StillPresent' }
        elseif ($states -contains 'Pending') { 'Pending' }
        elseif ($states -contains 'Disabled') { 'Disabled' }
        else { 'Removed' }
        $detail = switch ($status) {
            'StillPresent' { 'One or more device objects still exist' }
            'Pending' { 'Synced object will be removed on the next Entra Connect sync' }
            'Disabled' { "$($states.Count) device object(s) disabled" }
            default { "$($states.Count) device object(s) deleted" }
        }
        & $row 'Entra ID' $status "$detail$suffix"
    }

    # Active Directory
    if (-not $Context.ADChecked) {
        $hybrid = $Context.Entra.Object.trustType -contains 'ServerAd'
        & $row 'Active Directory' ($hybrid ? 'Warn' : 'Skipped') ($hybrid ? 'Not checked — device is hybrid joined, remove the computer object manually' : 'Not checked')
    } elseif (-not $Context.AD) {
        & $row 'Active Directory' 'NotPresent' 'No computer object found'
    } elseif (-not $Context.AD.Include) {
        & $row 'Active Directory' 'Skipped' "Left in place: $($Context.AD.Object.DistinguishedName)"
    } else {
        $lookup = @{ Filter = "ObjectGUID -eq '$($Context.AD.Object.ObjectGUID)'" }
        if ($ADServer) { $lookup.Server = $ADServer }
        if (Get-ADComputer @lookup) { & $row 'Active Directory' 'StillPresent' "$($Context.AD.Object.DistinguishedName) still exists" }
        else { & $row 'Active Directory' 'Removed' 'Computer object deleted' }
    }

    $outcome = if ($rows.Status | Where-Object { $_ -in 'StillPresent', 'Failed', 'Warn' }) { 'Incomplete' }
    elseif ($rows.Status -contains 'Pending') { 'Pending' }
    else { 'Complete' }
    [pscustomobject]@{ Outcome = $outcome; Rows = $rows.ToArray() }
}
