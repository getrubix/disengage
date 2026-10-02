# First-run setup: signs the operator in, detects what it can, asks for the rest, and writes config.json.

$script:DocumentEncryptionEku = '1.3.6.1.4.1.311.80.1'

# Entra Connect's AD DS connector account (MSOL_xxxx) records its server in the description:
# "... running on computer AADC01 configured to synchronize to tenant contoso.onmicrosoft.com ..."
function ConvertFrom-DgMsolDescription {
    param([string]$Description)
    if ($Description -match 'running on computer ([^\s,.]+)') { $Matches[1] }
}

function Find-DgEntraConnectServer {
    param([string]$Server)
    $query = @{ Filter = "SamAccountName -like 'MSOL_*'"; Properties = 'Description', 'whenChanged' }
    if ($Server) { $query.Server = $Server }
    @(Get-ADUser @query | Sort-Object whenChanged -Descending |
            ForEach-Object { ConvertFrom-DgMsolDescription $_.Description } |
            Where-Object { $_ } | Select-Object -Unique)
}

function Find-DgEncryptionCertificate {
    @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object {
            $_.NotAfter -gt (Get-Date) -and $_.EnhancedKeyUsageList.ObjectId -contains $script:DocumentEncryptionEku
        } | Sort-Object NotAfter -Descending)
}

function New-DgEncryptionCertificate {
    param([Parameter(Mandatory)][string]$TenantId)
    New-SelfSignedCertificate -Type DocumentEncryptionCert -Subject "CN=Disengage backup escrow ($TenantId)" `
        -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -KeyUsage KeyEncipherment, DataEncipherment `
        -KeyLength 3072 -NotAfter (Get-Date).AddYears(5)
}

function Read-DgSetupSettings {
    param([Parameter(Mandatory)][string]$Path)
    $existing = if (Test-Path $Path) {
        try { Get-Content -Raw $Path | ConvertFrom-Json -AsHashtable } catch { @{} }
    } else { @{} }
    Merge-DgHashtable $script:DefaultConfig $existing
}

function Invoke-DgSetup {
    param([Parameter(Mandatory)][string]$Path)
    $settings = Read-DgSetupSettings -Path $Path
    $rerun = Test-Path $Path

    Write-DgSection 'Setup'
    if ($rerun) { Write-DgStatus Info 'Re-running setup. Your current values are the defaults; press Enter to keep them.' }
    else { Write-DgStatus Info "No configuration found. Answer a few questions and it will be saved to $Path." }

    # 1. Sign in. The tenant comes from whoever signs in.
    Write-Host ''
    Write-DgStatus Info 'Sign in with the account you will offboard devices with. A browser window will open.'
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $connect = @{ Scopes = $script:RequiredGraphPermissions; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($rerun -and (Test-DgGuid $settings.TenantId)) { $connect.TenantId = $settings.TenantId }
    if ($settings.Auth.Mode -eq 'Interactive' -and $settings.Auth.ClientId) { $connect.ClientId = $settings.Auth.ClientId }
    Connect-MgGraph @connect | Out-Null
    $graph = Get-MgContext
    $settings.TenantId = $graph.TenantId
    Write-DgStatus Done "Signed in as $($graph.Account) · tenant $($graph.TenantId)"
    $missing = Get-DgMissingPermission -Context $graph
    if ($missing) {
        Write-DgStatus Warn "Not yet consented: $($missing -join ', ')"
        Write-DgStatus Warn 'A Global Administrator or Privileged Role Administrator must grant admin consent before devices can be offboarded. Setup will still save your config.' -Indent 4
    }

    # 2. What happens to Entra objects.
    Write-Host ''
    $entraChoice = Read-DgChoice -Prompt 'When a device is offboarded, its Entra ID device object should be:' -Options @(
        'Deleted (recommended)'
        'Disabled — kept for audit, you delete it later'
    ) -Default ($settings.EntraAction -eq 'Disable' ? 2 : 1)
    $settings.EntraAction = @('Delete', 'Disable')[$entraChoice]

    # 3. On-prem Active Directory.
    Write-Host ''
    if (-not (Get-Module -ListAvailable ActiveDirectory)) {
        Write-DgStatus Warn 'The ActiveDirectory module (RSAT) is not installed here, so AD settings cannot be detected.'
        Write-DgStatus Info 'AD handling stays on: if you later run from a machine with RSAT, domain-joined devices are handled there.' -Indent 4
        $settings.ActiveDirectory.Enabled = $true
    } else {
        $domain = $null
        try {
            Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
            $domainArgs = @{}
            if ($settings.ActiveDirectory.Server) { $domainArgs.Server = $settings.ActiveDirectory.Server }
            $domain = Get-ADDomain @domainArgs
            Write-DgStatus Done "Active Directory domain: $($domain.DNSRoot)"
        } catch {
            Write-DgStatus Warn "Active Directory is not reachable from here: $($_.Exception.Message)"
        }
        $settings.ActiveDirectory.Enabled = Read-DgYesNo -Prompt 'Remove on-prem AD computer objects for domain-joined and hybrid devices?' -Default $true
        if ($settings.ActiveDirectory.Enabled) {
            $settings.ActiveDirectory.Server = Read-DgText -Prompt 'Domain controller to use (blank = automatic)' -Default $settings.ActiveDirectory.Server -Optional

            $servers = @()
            if ($domain) {
                try { $servers = Find-DgEntraConnectServer -Server $settings.ActiveDirectory.Server }
                catch { Write-Verbose "Entra Connect lookup failed: $($_.Exception.Message)" }
            }
            Write-Host ''
            if ($servers) {
                Write-DgStatus Found "Entra Connect found on: $($servers -join ', ')"
                $options = @($servers | ForEach-Object { "Trigger a delta sync on $_ after AD deletes (needs PowerShell remoting)" }) + 'Do not trigger syncs; wait for the normal cycle'
                $current = [array]::IndexOf($servers, $settings.ActiveDirectory.EntraConnectServer)
                $default = if ($current -ge 0) { $current + 1 } elseif ($rerun -and -not $settings.ActiveDirectory.EntraConnectServer) { $options.Count } else { 1 }
                $pick = Read-DgChoice -Prompt 'Entra Connect sync:' -Options $options -Default $default
                $settings.ActiveDirectory.EntraConnectServer = if ($pick -lt $servers.Count) { $servers[$pick] } else { '' }
            } else {
                $settings.ActiveDirectory.EntraConnectServer = Read-DgText -Prompt 'Entra Connect server to trigger delta syncs on (blank = wait for the normal cycle)' `
                    -Default $settings.ActiveDirectory.EntraConnectServer -Optional
            }
        }
    }

    # 4. Backup encryption for BitLocker keys and LAPS passwords.
    Write-Host ''
    Write-DgStatus Info 'BitLocker keys and LAPS passwords are backed up, encrypted, before each device is deleted.'
    $certs = Find-DgEncryptionCertificate
    $options = @($certs | ForEach-Object { "Use certificate '$($_.Subject)' (expires $($_.NotAfter.ToString('d')), $($_.Thumbprint.Substring(0, 8))…)" })
    $options += 'Create a new escrow certificate (recommended if you have none)'
    $options += 'No certificate: DPAPI (only you, on this machine, can decrypt backups)'
    $current = [array]::IndexOf(@($certs.Thumbprint), $settings.Backup.CertificateThumbprint)
    $default = if ($current -ge 0) { $current + 1 } elseif ($rerun -and -not $settings.Backup.CertificateThumbprint) { $options.Count } else { 1 }
    $pick = Read-DgChoice -Prompt 'How should backups be encrypted?' -Options $options -Default $default

    if ($pick -lt $certs.Count) {
        $settings.Backup.CertificateThumbprint = $certs[$pick].Thumbprint
    } elseif ($pick -eq $certs.Count) {
        $cert = New-DgEncryptionCertificate -TenantId $settings.TenantId
        $settings.Backup.CertificateThumbprint = $cert.Thumbprint
        Write-DgStatus Done "Created $($cert.Subject) ($($cert.Thumbprint))"
        Write-DgStatus Warn 'The private key is the only way to decrypt backups. Keep a copy somewhere safe (e.g. your password vault).' -Indent 4
        if (Read-DgYesNo -Prompt 'Export the certificate with its private key to a .pfx file now?' -Default $true) {
            $pfx = Read-DgText -Prompt 'Save as' -Default (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) 'Disengage-escrow.pfx')
            $password = Read-Host '  Password to protect the .pfx' -AsSecureString
            Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $password | Out-Null
            Write-DgStatus Done "Exported to $pfx — move it to your vault, then delete this copy."
        }
    } else {
        $settings.Backup.CertificateThumbprint = ''
    }

    # 5. Save. Interactive sign-in is the default; certificate auth is configured by editing the file.
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding utf8

    Write-Host ''
    Write-DgStatus Done "Saved $Path"
    Write-DgKeyValue ([ordered]@{
            'Tenant'            = $settings.TenantId
            'Sign-in'           = $settings.Auth.Mode
            'Entra objects'     = $settings.EntraAction
            'Active Directory'  = if ($settings.ActiveDirectory.Enabled) { 'On' + ($settings.ActiveDirectory.Server ? " (DC $($settings.ActiveDirectory.Server))" : '') } else { 'Off' }
            'Entra Connect'     = $settings.ActiveDirectory.EntraConnectServer ? "Delta sync on $($settings.ActiveDirectory.EntraConnectServer)" : 'Wait for normal cycle'
            'Backup encryption' = $settings.Backup.CertificateThumbprint ? "Certificate $($settings.Backup.CertificateThumbprint)" : 'DPAPI'
        })
    Write-DgStatus Info 'Run with -Setup to change these later. Paths and timeouts can be edited in the file.'
}
