foreach ($file in 'Ui', 'Graph', 'Config', 'Discovery', 'Backup', 'Offboard', 'Verify', 'Report', 'Setup', 'Workflow') {
    . (Join-Path $PSScriptRoot "$file.ps1")
}
Export-ModuleMember -Function *-Dg*
