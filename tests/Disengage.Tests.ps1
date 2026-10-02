BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'Disengage.psm1') -Force
    # The ActiveDirectory module isn't needed to run tests; give Pester something to mock.
    foreach ($cmd in 'Get-ADComputer', 'Get-ADObject', 'Remove-ADObject', 'Set-ADObject') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$cmd" -Value { param([Parameter(ValueFromRemainingArguments)]$Rest) } | Out-Null
        }
    }
    function New-NotFoundError { [System.Exception]::new('Response status code does not indicate success: NotFound (Not Found).') }
}

Describe 'Graph helpers' {
    It 'escapes single quotes in OData literals' {
        ConvertTo-DgODataLiteral "O'Brien-PC" | Should -Be "'O''Brien-PC'"
    }
    It 'URL-encodes the filter expression' {
        New-DgGraphUri -Path 'v1.0/devices' -Filter "displayName eq 'PC 1'" | Should -Be 'v1.0/devices?$filter=displayName%20eq%20%27PC%201%27'
    }
    It 'reads the HTTP status from a Graph error message' {
        $err = try { throw (New-NotFoundError) } catch { $_ }
        Get-DgHttpStatus $err | Should -Be 404
    }
    It 'rejects the empty GUID Intune uses for unjoined devices' {
        Test-DgGuid '00000000-0000-0000-0000-000000000000' | Should -BeFalse
        Test-DgGuid ([guid]::NewGuid()) | Should -BeTrue
    }
}

Describe 'Get-DgDeviceContext' {
    BeforeAll {
        $script:intune = [pscustomobject]@{
            id = 'md-1'; deviceName = 'PC-001'; serialNumber = 'SER123'; operatingSystem = 'Windows'
            azureADDeviceId = '11111111-1111-1111-1111-111111111111'
        }
        Mock -ModuleName Disengage Invoke-DgGraph {
            switch -Wildcard ($Uri) {
                '*windowsAutopilotDeviceIdentities*' {
                    [pscustomobject]@{ id = 'ap-1'; serialNumber = 'SER123'; azureActiveDirectoryDeviceId = '11111111-1111-1111-1111-111111111111' }
                    [pscustomobject]@{ id = 'ap-2'; serialNumber = 'SER1234' }   # contains() also matches this one
                }
                '*filter=deviceId*' {
                    [pscustomobject]@{ id = 'obj-1'; deviceId = '11111111-1111-1111-1111-111111111111'; displayName = 'PC-001'; trustType = 'ServerAd' }
                }
                '*filter=displayName*' {
                    [pscustomobject]@{ id = 'obj-1'; deviceId = '11111111-1111-1111-1111-111111111111'; displayName = 'PC-001'; trustType = 'ServerAd' }
                    [pscustomobject]@{ id = 'obj-stale'; deviceId = '22222222-2222-2222-2222-222222222222'; displayName = 'PC-001'; trustType = 'Workplace' }
                }
            }
        }
    }

    It 'links records by ID and flags name-only Entra matches' {
        $ctx = Get-DgDeviceContext -By Serial -Value 'SER123' -IntuneDevice $script:intune
        $ctx.DeviceName | Should -Be 'PC-001'
        @($ctx.Autopilot).id | Should -Be 'ap-1'
        $linked = $ctx.Entra | Where-Object { $_.Object.id -eq 'obj-1' }
        $linked.Linked | Should -BeTrue
        $linked.Include | Should -BeTrue
        $stale = $ctx.Entra | Where-Object { $_.Object.id -eq 'obj-stale' }
        $stale.Linked | Should -BeFalse
        $stale.Include | Should -BeFalse
    }

    It 'notes that a hybrid device was not checked in AD' {
        $ctx = Get-DgDeviceContext -By Serial -Value 'SER123' -IntuneDevice $script:intune
        $ctx.Notes | Should -Match 'hybrid joined'
    }

    It 'links the AD computer when its objectGUID matches the hybrid Entra deviceId' {
        Mock -ModuleName Disengage Get-ADComputer {
            [pscustomobject]@{ ObjectGUID = [guid]'11111111-1111-1111-1111-111111111111'; DistinguishedName = 'CN=PC-001,OU=Workstations,DC=corp,DC=local' }
        }
        $ctx = Get-DgDeviceContext -By Serial -Value 'SER123' -IntuneDevice $script:intune -IncludeAD
        $ctx.AD.Linked | Should -BeTrue
        $ctx.AD.Include | Should -BeTrue
    }

    It 'asks about an AD computer whose GUID does not match' {
        Mock -ModuleName Disengage Get-ADComputer {
            [pscustomobject]@{ ObjectGUID = [guid]::NewGuid(); DistinguishedName = 'CN=PC-001,OU=Old,DC=corp,DC=local' }
        }
        $ctx = Get-DgDeviceContext -By Serial -Value 'SER123' -IntuneDevice $script:intune -IncludeAD
        $ctx.AD.Linked | Should -BeFalse
        $ctx.AD.Include | Should -BeFalse
    }
}

Describe 'Offboarding steps' {
    BeforeAll {
        Mock -ModuleName Disengage Start-Sleep { }
        Mock -ModuleName Disengage Write-Progress { }
        Mock -ModuleName Disengage Write-Host { }
    }

    It 'treats an Intune record that is already gone as success' {
        Mock -ModuleName Disengage Invoke-DgGraph { throw (New-NotFoundError) }
        $ctx = [pscustomobject]@{ Intune = [pscustomobject]@{ id = 'md-1' } }
        (Remove-DgIntuneDevice -Context $ctx).Status | Should -Be 'AlreadyGone'
    }

    It 'retries the Autopilot delete while Intune removal propagates' {
        $script:deleteCalls = 0
        Mock -ModuleName Disengage Invoke-DgGraph {
            if ($Method -eq 'DELETE') {
                $script:deleteCalls++
                if ($script:deleteCalls -lt 3) { throw [System.Exception]::new('Response status code does not indicate success: BadRequest (Bad Request).') }
                return
            }
            $null   # GET after delete: gone
        }
        $ctx = [pscustomobject]@{ Autopilot = @([pscustomobject]@{ id = 'ap-1'; serialNumber = 'SER123' }) }
        $result = Remove-DgAutopilotDevice -Context $ctx -TimeoutMinutes 1 -PollSeconds 1
        $result.Status | Should -Be 'Done'
        $script:deleteCalls | Should -Be 3
    }

    It 'does not try to delete synced Entra objects when AD was not removed' {
        Mock -ModuleName Disengage Invoke-DgGraph { throw 'should not be called' }
        $ctx = [pscustomobject]@{ Entra = @([pscustomobject]@{
                    Include = $true; Object = [pscustomobject]@{ id = 'obj-1'; displayName = 'PC-001'; trustType = 'ServerAd'; onPremisesSyncEnabled = $true }
                }) }
        $result = Remove-DgEntraDevice -Context $ctx -ADRemoved $false
        $result.Status | Should -Be 'Pending'
    }

    It 'stops the plan after a failed step and marks the rest NotRun' {
        $plan = @(
            [pscustomobject]@{ Kind = 'Intune'; Name = 'one'; Action = { New-DgResult -Status Done } }
            [pscustomobject]@{ Kind = 'Autopilot'; Name = 'two'; Action = { throw 'boom' } }
            [pscustomobject]@{ Kind = 'Entra'; Name = 'three'; Action = { New-DgResult -Status Done } }
        )
        $results = Invoke-DgPlan -Plan $plan
        $results.Status | Should -Be @('Done', 'Failed', 'NotRun')
        $results[1].Detail | Should -Be 'boom'
    }

    It 'plan closures keep their context when run later' {
        Mock -ModuleName Disengage Invoke-DgGraph { $null }
        $ctx = [pscustomobject]@{ Intune = [pscustomobject]@{ id = 'md-42' }; Autopilot = @(); Entra = @(); AD = $null }
        $config = @{ Timeouts = @{ PollSeconds = 5 }; ActiveDirectory = @{ Server = '' }; EntraAction = 'Delete'; Backup = @{} }
        $plan = New-DgPlan -Context $ctx -Config $config -Wipe $false -State @{}
        $plan.Kind | Should -Be 'Intune'
        (& $plan[0].Action).Detail | Should -Match 'md-42'
    }
}

Describe 'Test-DgOffboardState' {
    It 'reports Complete when every record is gone' {
        Mock -ModuleName Disengage Invoke-DgGraph { $null }
        Mock -ModuleName Disengage Get-ADComputer { }
        $ctx = [pscustomobject]@{
            DeviceName = 'PC-001'; SerialNumber = 'SER123'; ADChecked = $true
            Intune     = [pscustomobject]@{ id = 'md-1' }
            Autopilot  = @([pscustomobject]@{ id = 'ap-1'; serialNumber = 'SER123' })
            Entra      = @([pscustomobject]@{ Include = $true; Object = [pscustomobject]@{ id = 'obj-1'; trustType = 'AzureAd' } })
            AD         = [pscustomobject]@{ Include = $true; Object = [pscustomobject]@{ ObjectGUID = [guid]::NewGuid(); DistinguishedName = 'CN=PC-001' } }
        }
        $state = Test-DgOffboardState -Context $ctx
        $state.Outcome | Should -Be 'Complete'
        $state.Rows.Status | Should -Be @('Removed', 'Removed', 'Removed', 'Removed')
    }

    It 'catches a device that re-enrolled during the run' {
        Mock -ModuleName Disengage Invoke-DgGraph {
            if ($Uri -match 'managedDevices\?') { [pscustomobject]@{ id = 'md-new'; deviceName = 'PC-001'; operatingSystem = 'Windows' } }
        }
        $ctx = [pscustomobject]@{
            DeviceName = 'PC-001'; SerialNumber = 'SER123'; ADChecked = $false
            Intune = [pscustomobject]@{ id = 'md-1' }; Autopilot = @(); Entra = @(); AD = $null
        }
        $state = Test-DgOffboardState -Context $ctx
        $state.Outcome | Should -Be 'Incomplete'
        $state.Rows[0].Detail | Should -Match 'New enrollment'
    }
}

Describe 'Backups' {
    It 'round-trips a DPAPI backup' -Skip:(-not $IsWindows) {
        $dir = Join-Path $TestDrive 'backups'
        $ctx = [pscustomobject]@{ DeviceName = 'PC-001'; SerialNumber = 'SER123' }
        $secrets = [pscustomobject]@{
            BitLocker = [System.Collections.Generic.List[object]]@([pscustomobject]@{ KeyId = 'k1'; RecoveryKey = '111111-222222' })
            Laps      = [System.Collections.Generic.List[object]]::new()
            Errors    = [System.Collections.Generic.List[string]]::new()
        }
        $file = Save-DgBackup -Context $ctx -Secrets $secrets -Path $dir
        (Get-Content -Raw $file) | Should -Not -Match '111111-222222'
        (Read-DgBackup -Path $file).BitLocker[0].RecoveryKey | Should -Be '111111-222222'
    }
}
