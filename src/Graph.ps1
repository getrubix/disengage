# Thin wrapper around Invoke-MgGraphRequest: retries throttling and transient errors, follows
# paging, and turns 404s into $null where the caller says that is an expected outcome.

$script:GraphBase = 'https://graph.microsoft.com'

$script:RequiredGraphPermissions = @(
    'DeviceManagementManagedDevices.ReadWrite.All'
    'DeviceManagementManagedDevices.PrivilegedOperations.All'
    'DeviceManagementServiceConfig.ReadWrite.All'
    'Device.ReadWrite.All'
    'BitlockerKey.Read.All'
    'DeviceLocalCredential.Read.All'
)

# BitLocker and LAPS reads are audited; these headers identify the tool in the Entra audit log.
$script:AuditHeaders = @{ 'ocp-client-name' = 'Disengage'; 'ocp-client-version' = '1.0.0' }

$script:EmptyGuid = '00000000-0000-0000-0000-000000000000'

function ConvertTo-DgODataLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

function New-DgGraphUri {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter,
        [string[]]$Select
    )
    $query = @()
    if ($Filter) { $query += '$filter=' + [uri]::EscapeDataString($Filter) }
    if ($Select) { $query += '$select=' + ($Select -join ',') }
    if ($query) { $Path + '?' + ($query -join '&') } else { $Path }
}

function Test-DgGuid {
    param($Value)
    $parsed = [guid]::Empty
    [guid]::TryParse("$Value", [ref]$parsed) -and $parsed -ne [guid]::Empty
}

function ConvertTo-DgUtc {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse("$Value", [ref]$parsed)) { return $parsed.UtcDateTime }
    $null
}

function Get-DgHttpStatus {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    foreach ($exception in @($ErrorRecord.Exception, $ErrorRecord.Exception.InnerException)) {
        if ($null -eq $exception) { continue }
        $response = $exception.PSObject.Properties['Response']
        if ($response -and $null -ne $response.Value -and $null -ne $response.Value.StatusCode) {
            return [int]$response.Value.StatusCode
        }
        if ($exception.Message -match 'does not indicate success: (\w+)') {
            try { return [int][System.Net.HttpStatusCode]$Matches[1] } catch { Write-Verbose "Unrecognised status '$($Matches[1])'" }
        }
    }
    $null
}

function Get-DgRetryDelay {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord, [int]$Attempt)
    try {
        $retryAfter = $ErrorRecord.Exception.Response.Headers.RetryAfter
        if ($retryAfter.Delta) { return [int][Math]::Ceiling($retryAfter.Delta.TotalSeconds) }
    } catch {
        Write-Verbose 'No Retry-After header; using exponential backoff.'
    }
    [int][Math]::Min(60, [Math]::Pow(2, $Attempt + 1))
}

function Invoke-DgGraph {
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body,
        [hashtable]$Headers,
        # Follow @odata.nextLink and return the combined .value items.
        [switch]$All,
        # Return $null instead of throwing when the resource does not exist.
        [switch]$AllowNotFound,
        [int]$MaxRetries = 5
    )
    $next = if ($Uri -match '^https://') { $Uri } else { "$script:GraphBase/$($Uri.TrimStart('/'))" }
    $items = [System.Collections.Generic.List[object]]::new()

    while ($next) {
        $response = $null
        for ($attempt = 0; ; $attempt++) {
            try {
                $request = @{ Method = $Method; Uri = $next; OutputType = 'PSObject'; ErrorAction = 'Stop' }
                if ($null -ne $Body) {
                    $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
                    $request.ContentType = 'application/json'
                }
                if ($Headers) { $request.Headers = $Headers }
                $response = Invoke-MgGraphRequest @request
                break
            } catch {
                $status = Get-DgHttpStatus $_
                if ($status -eq 404 -and $AllowNotFound) { return $null }
                if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt $MaxRetries) {
                    $delay = Get-DgRetryDelay -ErrorRecord $_ -Attempt $attempt
                    Write-Verbose "Graph returned $status for $Method $next; retrying in ${delay}s"
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw
            }
        }
        if (-not $All) { return $response }
        foreach ($item in @($response.value)) { if ($null -ne $item) { $items.Add($item) } }
        $next = $response.'@odata.nextLink'
    }
    $items.ToArray()
}

# Deletes a Graph resource. Returns 'Deleted', or 'NotFound' if it was already gone.
function Remove-DgGraphResource {
    param([Parameter(Mandatory)][string]$Uri)
    try {
        Invoke-DgGraph -Method DELETE -Uri $Uri | Out-Null
        'Deleted'
    } catch {
        if ((Get-DgHttpStatus $_) -eq 404) { 'NotFound' } else { throw }
    }
}

function Connect-DgGraph {
    param([Parameter(Mandatory)][hashtable]$Config)
    $connect = @{ TenantId = $Config.TenantId; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($Config.Auth.Mode -eq 'Certificate') {
        $connect.ClientId = $Config.Auth.ClientId
        $connect.CertificateThumbprint = $Config.Auth.CertificateThumbprint
    } else {
        $connect.Scopes = $script:RequiredGraphPermissions
        if ($Config.Auth.ClientId) { $connect.ClientId = $Config.Auth.ClientId }
    }
    Connect-MgGraph @connect | Out-Null
    Get-MgContext
}

function Get-DgMissingPermission {
    param([Parameter(Mandatory)]$Context)
    $granted = @($Context.Scopes)
    @($script:RequiredGraphPermissions | Where-Object { $_ -notin $granted })
}
