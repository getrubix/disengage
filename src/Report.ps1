# Run transcript and JSON report. The report never contains secrets — only where the backup went.

function Start-DgRunLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $safe = $Label -replace '[^\w\-]', '_'
    $base = Join-Path $Path ("{0:yyyyMMdd-HHmmss}_{1}" -f (Get-Date), $safe)
    Start-Transcript -Path "$base.log" -UseMinimalHeader | Out-Null
    [pscustomobject]@{ Transcript = "$base.log"; Report = "$base.json" }
}

function Stop-DgRunLog {
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'No transcript running.' }
}

function ConvertTo-DgReportContext {
    param([Parameter(Mandatory)]$Context)
    [ordered]@{
        Query        = $Context.Query
        DeviceName   = $Context.DeviceName
        SerialNumber = $Context.SerialNumber
        Intune       = $Context.Intune
        Autopilot    = $Context.Autopilot
        Entra        = @($Context.Entra | ForEach-Object {
                [ordered]@{ Included = $_.Include; Linked = $_.Linked; Reason = $_.Reason; Object = $_.Object }
            })
        ActiveDirectory = if ($Context.AD) {
            [ordered]@{
                Included          = $Context.AD.Include
                Linked            = $Context.AD.Linked
                Reason            = $Context.AD.Reason
                DistinguishedName = $Context.AD.Object.DistinguishedName
                ObjectGUID        = "$($Context.AD.Object.ObjectGUID)"
                LastLogonDate     = $Context.AD.Object.LastLogonDate
            }
        }
        ADChecked    = $Context.ADChecked
        Notes        = $Context.Notes
    }
}

function Save-DgReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context,
        [object[]]$Steps,
        [object]$Verification,
        [string]$BackupPath,
        [bool]$Wipe,
        [switch]$DryRun
    )
    $graph = Get-MgContext
    [ordered]@{
        Tool         = 'Disengage'
        Version      = '1.0.0'
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        DryRun       = [bool]$DryRun
        Operator     = [ordered]@{
            Windows = "$env:USERDOMAIN\$env:USERNAME"
            Machine = $env:COMPUTERNAME
            Graph   = $graph.Account ?? $graph.AppName
            Tenant  = $graph.TenantId
        }
        WipeRequested = $Wipe
        Outcome      = $Verification.Outcome
        BackupFile   = $BackupPath
        Device       = ConvertTo-DgReportContext $Context
        Steps        = @($Steps | Select-Object Step, Status, Detail, Seconds)
        Verification = @($Verification.Rows)
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding utf8
}
