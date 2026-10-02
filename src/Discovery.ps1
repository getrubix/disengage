# Finds every record for one physical device across Intune, Autopilot, Entra ID and AD.
#
# Records are tied together by hard identifiers wherever possible:
#   Intune.azureADDeviceId / Autopilot.azureActiveDirectoryDeviceId -> Entra device.deviceId
#   Entra device.deviceId (hybrid joined)                           -> AD computer objectGUID
# Anything matched only by display name is flagged (Linked = $false) so the operator decides.

$script:IntuneSelect = @(
    'id', 'deviceName', 'serialNumber', 'azureADDeviceId', 'userPrincipalName', 'lastSyncDateTime',
    'enrolledDateTime', 'managedDeviceOwnerType', 'complianceState', 'operatingSystem', 'model', 'manufacturer'
)
$script:EntraSelect = @(
    'id', 'deviceId', 'displayName', 'trustType', 'accountEnabled', 'approximateLastSignInDateTime',
    'onPremisesSyncEnabled', 'operatingSystem', 'physicalIds'
)

function Find-DgIntuneDevice {
    param(
        [Parameter(Mandatory)][ValidateSet('Name', 'Serial')][string]$By,
        [Parameter(Mandatory)][string]$Value
    )
    $field = if ($By -eq 'Name') { 'deviceName' } else { 'serialNumber' }
    $uri = New-DgGraphUri -Path 'v1.0/deviceManagement/managedDevices' -Filter "$field eq $(ConvertTo-DgODataLiteral $Value)" -Select $script:IntuneSelect
    @(Invoke-DgGraph -Uri $uri -All | Where-Object { $_.operatingSystem -eq 'Windows' })
}

function Find-DgAutopilotDevice {
    param([Parameter(Mandatory)][string]$SerialNumber)
    # Autopilot only supports contains() on serialNumber, so match exactly client-side.
    $uri = New-DgGraphUri -Path 'v1.0/deviceManagement/windowsAutopilotDeviceIdentities' -Filter "contains(serialNumber,$(ConvertTo-DgODataLiteral $SerialNumber))"
    @(Invoke-DgGraph -Uri $uri -All | Where-Object { $_.serialNumber -eq $SerialNumber })
}

# Fallback when we have no serial number: Autopilot can't be filtered by Entra device ID,
# so this pages through every Autopilot identity. Only used when Entra says the device is Autopilot-registered.
function Find-DgAutopilotByEntraDeviceId {
    param([Parameter(Mandatory)][string[]]$DeviceId)
    @(Invoke-DgGraph -Uri 'v1.0/deviceManagement/windowsAutopilotDeviceIdentities' -All |
            Where-Object { $_.azureActiveDirectoryDeviceId -in $DeviceId })
}

function Get-DgEntraDeviceByDeviceId {
    param([Parameter(Mandatory)][string]$DeviceId)
    $uri = New-DgGraphUri -Path 'v1.0/devices' -Filter "deviceId eq $(ConvertTo-DgODataLiteral $DeviceId)" -Select $script:EntraSelect
    @(Invoke-DgGraph -Uri $uri -All)
}

function Find-DgEntraDeviceByName {
    param([Parameter(Mandatory)][string]$Name)
    $uri = New-DgGraphUri -Path 'v1.0/devices' -Filter "displayName eq $(ConvertTo-DgODataLiteral $Name)" -Select $script:EntraSelect
    @(Invoke-DgGraph -Uri $uri -All)
}

function Find-DgAdComputer {
    param([Parameter(Mandatory)][string]$Name, [string]$Server)
    $query = @{
        Filter     = "Name -eq '$($Name -replace "'", "''")'"
        Properties = 'LastLogonDate', 'OperatingSystem', 'Enabled', 'ObjectGUID', 'DistinguishedName', 'WhenCreated', 'ProtectedFromAccidentalDeletion'
    }
    if ($Server) { $query.Server = $Server }
    @(Get-ADComputer @query)
}

function Get-DgJoinTypeLabel {
    param([string]$TrustType)
    switch ($TrustType) {
        'AzureAd' { 'Entra joined' }
        'ServerAd' { 'Hybrid joined' }
        'Workplace' { 'Entra registered' }
        default { $TrustType }
    }
}

function Get-DgDeviceContext {
    param(
        [Parameter(Mandatory)][ValidateSet('Name', 'Serial')][string]$By,
        [Parameter(Mandatory)][string]$Value,
        # The Intune record the operator picked (if any matched the query).
        [object]$IntuneDevice,
        [switch]$IncludeAD,
        [string]$ADServer
    )
    $context = [pscustomobject]@{
        PSTypeName   = 'Disengage.DeviceContext'
        Query        = [pscustomobject]@{ By = $By; Value = $Value }
        DeviceName   = if ($By -eq 'Name') { $Value } else { $null }
        SerialNumber = if ($By -eq 'Serial') { $Value } else { $null }
        Intune       = $IntuneDevice
        Autopilot    = @()
        Entra        = @()
        AD           = $null
        ADChecked    = [bool]$IncludeAD
        Notes        = [System.Collections.Generic.List[string]]::new()
    }
    if ($IntuneDevice) {
        if ($IntuneDevice.deviceName) { $context.DeviceName = $IntuneDevice.deviceName }
        if ($IntuneDevice.serialNumber) { $context.SerialNumber = $IntuneDevice.serialNumber }
    }

    Write-Progress -Id 3 -Activity 'Discovering device records' -Status 'Windows Autopilot' -PercentComplete 25
    if ($context.SerialNumber) {
        $context.Autopilot = Find-DgAutopilotDevice -SerialNumber $context.SerialNumber
    }

    Write-Progress -Id 3 -Activity 'Discovering device records' -Status 'Entra ID' -PercentComplete 50
    $entra = [ordered]@{}
    $anchors = [ordered]@{}
    if (Test-DgGuid $IntuneDevice.azureADDeviceId) { $anchors[$IntuneDevice.azureADDeviceId] = 'Intune device ID' }
    foreach ($ap in $context.Autopilot) {
        if ((Test-DgGuid $ap.azureActiveDirectoryDeviceId) -and -not $anchors.Contains($ap.azureActiveDirectoryDeviceId)) {
            $anchors[$ap.azureActiveDirectoryDeviceId] = 'Autopilot device ID'
        }
    }
    foreach ($deviceId in $anchors.Keys) {
        foreach ($object in Get-DgEntraDeviceByDeviceId -DeviceId $deviceId) {
            $entra[$object.id] = [pscustomobject]@{ Object = $object; Linked = $true; Reason = "Matches $($anchors[$deviceId])"; Include = $true }
        }
    }
    if (-not $context.DeviceName) {
        $context.DeviceName = @($entra.Values.Object.displayName) + @($context.Autopilot.displayName) |
            Where-Object { $_ } | Select-Object -First 1
    }
    if ($context.DeviceName) {
        $nameMatches = @(Find-DgEntraDeviceByName -Name $context.DeviceName | Where-Object { -not $entra.Contains($_.id) })
        # With no hard identifier to go on, a single exact name match is almost certainly the device.
        $suggest = $anchors.Count -eq 0 -and $nameMatches.Count -eq 1
        foreach ($object in $nameMatches) {
            $entra[$object.id] = [pscustomobject]@{ Object = $object; Linked = $false; Reason = 'Display name match only'; Include = $suggest }
        }
    }
    $context.Entra = @($entra.Values)

    # No serial to search Autopilot with, but Entra says the device is Autopilot-registered.
    if (-not $context.Autopilot -and -not $context.SerialNumber) {
        $ztdIds = @($context.Entra | Where-Object { $_.Object.physicalIds -match '^\[ZTDID\]' } | ForEach-Object { $_.Object.deviceId })
        if ($ztdIds) {
            Write-Progress -Id 3 -Activity 'Discovering device records' -Status 'Scanning Autopilot (no serial number available)' -PercentComplete 65
            $context.Autopilot = Find-DgAutopilotByEntraDeviceId -DeviceId $ztdIds
            if ($context.Autopilot) { $context.SerialNumber = $context.Autopilot[0].serialNumber }
        }
    }

    Write-Progress -Id 3 -Activity 'Discovering device records' -Status 'Active Directory' -PercentComplete 80
    $hybridIds = @($context.Entra | Where-Object { $_.Object.trustType -eq 'ServerAd' } | ForEach-Object { "$($_.Object.deviceId)" })
    if ($IncludeAD -and $context.DeviceName) {
        $computer = Find-DgAdComputer -Name $context.DeviceName -Server $ADServer | Select-Object -First 1
        if ($computer) {
            # A hybrid joined device's Entra deviceId is the AD computer's objectGUID.
            $linked = "$($computer.ObjectGUID)" -in $hybridIds
            $onlyRecord = -not $context.Intune -and -not $context.Autopilot -and -not $context.Entra
            $context.AD = [pscustomobject]@{
                Object  = $computer
                Linked  = $linked
                Reason  = if ($linked) { 'objectGUID matches hybrid Entra device' } else { 'Name match only' }
                Include = $linked -or $onlyRecord
            }
        }
    } elseif ($hybridIds) {
        $context.Notes.Add('Device is hybrid joined but AD was not checked. Entra Connect will recreate the Entra object unless the AD computer is removed.')
    }
    Write-Progress -Id 3 -Activity 'Discovering device records' -Completed
    $context
}

function Test-DgDeviceFound {
    param([Parameter(Mandatory)]$Context)
    [bool]($Context.Intune -or $Context.Autopilot -or $Context.Entra -or $Context.AD)
}

function Get-DgLastActivity {
    param([Parameter(Mandatory)]$Context)
    $dates = @(
        $Context.Intune.lastSyncDateTime
        $Context.Entra | Where-Object Include | ForEach-Object { $_.Object.approximateLastSignInDateTime }
        if ($Context.AD.Include) { $Context.AD.Object.LastLogonDate }
    ) | ForEach-Object { ConvertTo-DgUtc $_ } | Where-Object { $_ }
    $dates | Sort-Object -Descending | Select-Object -First 1
}
