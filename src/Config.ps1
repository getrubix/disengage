# Configuration loading and preflight checks.

$script:DefaultConfig = @{
    TenantId                = ''
    Auth                    = @{ Mode = 'Interactive'; ClientId = ''; CertificateThumbprint = '' }
    EntraAction             = 'Delete'
    RecentActivityHours     = 24
    ActiveDirectory         = @{ Enabled = $true; Server = ''; EntraConnectServer = '' }
    Backup                  = @{ Path = './Backups'; CertificateThumbprint = '' }
    Logging                 = @{ Path = './Logs' }
    Timeouts                = @{ WipeMinutes = 30; AutopilotMinutes = 15; EntraSyncMinutes = 40; PollSeconds = 15 }
}

function Merge-DgHashtable {
    param([hashtable]$Base, [hashtable]$Override)
    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $merged[$key] = Merge-DgHashtable $merged[$key] $Override[$key]
        } else {
            $merged[$key] = $Override[$key]
        }
    }
    $merged
}

function Import-DgConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Config file not found at $Path. Copy config.example.json to config.json and fill in your tenant details."
    }
    $config = Merge-DgHashtable $script:DefaultConfig (Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable)

    $problems = @()
    if (-not $config.TenantId -or $config.TenantId -eq $script:EmptyGuid) { $problems += 'TenantId is not set.' }
    if ($config.Auth.Mode -notin 'Interactive', 'Certificate') { $problems += "Auth.Mode must be 'Interactive' or 'Certificate'." }
    if ($config.Auth.Mode -eq 'Certificate' -and -not ($config.Auth.ClientId -and $config.Auth.CertificateThumbprint)) {
        $problems += 'Certificate auth needs Auth.ClientId and Auth.CertificateThumbprint.'
    }
    if ($config.EntraAction -notin 'Delete', 'Disable') { $problems += "EntraAction must be 'Delete' or 'Disable'." }
    if ($problems) { throw "Invalid config ($Path):`n  - " + ($problems -join "`n  - ") }

    # Relative paths are relative to the config file, not the current directory.
    $root = Split-Path -Parent (Resolve-Path $Path)
    foreach ($section in 'Backup', 'Logging') {
        if (-not [IO.Path]::IsPathRooted($config[$section].Path)) {
            $config[$section].Path = [IO.Path]::GetFullPath((Join-Path $root $config[$section].Path))
        }
    }
    $config
}

function Test-DgEncryptionCertificate {
    param([Parameter(Mandatory)][string]$Thumbprint)
    $cert = Get-ChildItem "Cert:\CurrentUser\My\$Thumbprint", "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cert) { return "Certificate $Thumbprint not found in CurrentUser\My or LocalMachine\My" }
    if ($cert.NotAfter -lt (Get-Date)) { return "Certificate $Thumbprint expired on $($cert.NotAfter.ToString('d'))" }
    if ($cert.EnhancedKeyUsageList.ObjectId -notcontains '1.3.6.1.4.1.311.80.1') { return "Certificate $Thumbprint lacks the Document Encryption EKU" }
    $null
}

# Runs and prints every preflight check. Returns Ready (all blocking checks passed) and AdAvailable.
function Invoke-DgPreflight {
    param([Parameter(Mandatory)][hashtable]$Config)
    $ready = $true
    $adAvailable = $false

    Write-DgStatus Done "PowerShell $($PSVersionTable.PSVersion)"

    if (Get-Module -ListAvailable Microsoft.Graph.Authentication) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Write-DgStatus Done 'Microsoft.Graph.Authentication module'
    } else {
        Write-DgStatus Failed 'Microsoft.Graph.Authentication module missing — Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
        return [pscustomobject]@{ Ready = $false; AdAvailable = $false }
    }

    try {
        foreach ($dir in $Config.Backup.Path, $Config.Logging.Path) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $probe = Join-Path $dir ".write-test-$PID"
            Set-Content -Path $probe -Value '' ; Remove-Item $probe
        }
        Write-DgStatus Done "Backup and log folders writable ($($Config.Backup.Path))"
    } catch {
        Write-DgStatus Failed "Cannot write to backup/log folder: $($_.Exception.Message)"
        $ready = $false
    }

    if ($Config.Backup.CertificateThumbprint) {
        $certProblem = Test-DgEncryptionCertificate -Thumbprint $Config.Backup.CertificateThumbprint
        if ($certProblem) { Write-DgStatus Failed "Backup encryption: $certProblem"; $ready = $false }
        else { Write-DgStatus Done 'Backup encryption: CMS certificate' }
    } else {
        Write-DgStatus Warn "Backup encryption: DPAPI — only $env:USERNAME on $env:COMPUTERNAME can decrypt backups. Set Backup.CertificateThumbprint for shared escrow."
    }

    try {
        $graph = Connect-DgGraph -Config $Config
        $who = $graph.Account ?? "$($graph.AppName) (app-only)"
        Write-DgStatus Done "Connected to Microsoft Graph as $who · tenant $($graph.TenantId)"
        $missing = Get-DgMissingPermission -Context $graph
        if ($missing) {
            Write-DgStatus Failed "Missing Graph permissions: $($missing -join ', ')"
            $ready = $false
        } else {
            Write-DgStatus Done 'Graph permissions'
        }
    } catch {
        Write-DgStatus Failed "Could not connect to Microsoft Graph: $($_.Exception.Message)"
        $ready = $false
    }

    if (-not $Config.ActiveDirectory.Enabled) {
        Write-DgStatus Skipped 'Active Directory disabled in config'
    } elseif (-not (Get-Module -ListAvailable ActiveDirectory)) {
        Write-DgStatus Warn 'ActiveDirectory module not installed (RSAT) — on-prem computer objects will not be checked or removed'
    } else {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
            $domainArgs = @{}
            if ($Config.ActiveDirectory.Server) { $domainArgs.Server = $Config.ActiveDirectory.Server }
            $domain = Get-ADDomain @domainArgs
            Write-DgStatus Done "Active Directory: $($domain.DNSRoot)"
            $adAvailable = $true
        } catch {
            Write-DgStatus Warn "Active Directory unreachable — on-prem objects will not be removed: $($_.Exception.Message)"
        }
    }
    if ($adAvailable -and $Config.ActiveDirectory.EntraConnectServer) {
        Write-DgStatus Info "Entra Connect delta sync will be triggered on $($Config.ActiveDirectory.EntraConnectServer)"
    }

    [pscustomobject]@{ Ready = $ready; AdAvailable = $adAvailable }
}
