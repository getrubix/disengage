# Console rendering for the wizard. Dependency-free on purpose: PowerShell 7's $PSStyle is enough,
# so the tool runs on any admin workstation without installing a UI module.

$script:StatusStyle = @{
    Done         = @{ Glyph = '✔'; Color = 'Green' }
    Removed      = @{ Glyph = '✔'; Color = 'Green' }
    Disabled     = @{ Glyph = '✔'; Color = 'Green' }
    AlreadyGone  = @{ Glyph = '✔'; Color = 'Green' }
    NotPresent   = @{ Glyph = '–'; Color = 'BrightBlack' }
    Skipped      = @{ Glyph = '–'; Color = 'BrightBlack' }
    NotRun       = @{ Glyph = '–'; Color = 'BrightBlack' }
    Found        = @{ Glyph = '•'; Color = 'Cyan' }
    Info         = @{ Glyph = '•'; Color = 'Cyan' }
    Warn         = @{ Glyph = '⚠'; Color = 'Yellow' }
    Pending      = @{ Glyph = '⚠'; Color = 'Yellow' }
    Failed       = @{ Glyph = '✖'; Color = 'Red' }
    StillPresent = @{ Glyph = '✖'; Color = 'Red' }
}

function Get-DgStyle {
    param([string]$Status)
    $style = $script:StatusStyle[$Status]
    if (-not $style) { $style = @{ Glyph = '•'; Color = 'White' } }
    [pscustomobject]@{ Glyph = $style.Glyph; Ansi = $PSStyle.Foreground.($style.Color) }
}

function Write-DgBanner {
    param([string]$Subtitle)
    $s = $PSStyle
    Write-Host ''
    Write-Host "  $($s.Bold)$($s.Foreground.Cyan)DISENGAGE$($s.Reset)  $($s.Foreground.BrightBlack)Windows device offboarding · Intune · Autopilot · Entra ID · AD$($s.Reset)"
    if ($Subtitle) { Write-Host "  $($s.Foreground.Yellow)$Subtitle$($s.Reset)" }
}

function Write-DgSection {
    param([Parameter(Mandatory)][string]$Title)
    $rule = '─' * [Math]::Max(4, 68 - $Title.Length)
    Write-Host ''
    Write-Host "  $($PSStyle.Bold)$Title$($PSStyle.Reset) $($PSStyle.Foreground.BrightBlack)$rule$($PSStyle.Reset)"
}

function Write-DgStatus {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [int]$Indent = 2
    )
    $style = Get-DgStyle $Status
    Write-Host ("{0}{1}{2}{3} {4}" -f (' ' * $Indent), $style.Ansi, $style.Glyph, $PSStyle.Reset, $Message)
}

function Write-DgKeyValue {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data, [int]$Indent = 4)
    $width = ($Data.Keys | ForEach-Object { "$_".Length } | Measure-Object -Maximum).Maximum
    foreach ($key in $Data.Keys) {
        $value = $Data[$key]
        if ($null -eq $value -or "$value" -eq '') { $value = '—' }
        Write-Host ("{0}{1}{2}{3}  {4}" -f (' ' * $Indent), $PSStyle.Foreground.BrightBlack, "$key".PadRight($width), $PSStyle.Reset, $value)
    }
}

function Limit-DgText {
    param([string]$Text, [int]$Width)
    if ($Text.Length -le $Width) { return $Text }
    $Text.Substring(0, $Width - 1) + '…'
}

function Write-DgTable {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [string]$StatusColumn,
        [int]$Indent = 4,
        [int]$MaxColumnWidth = 56
    )
    # Pre-render cell text so widths account for the status glyph.
    $cells = foreach ($row in $Rows) {
        $rendered = @{}
        foreach ($col in $Columns) {
            $value = "$($row.$col)"
            if ($col -eq $StatusColumn) { $value = "$((Get-DgStyle $value).Glyph) $value" }
            $rendered[$col] = $value
        }
        [pscustomobject]@{ Source = $row; Text = $rendered }
    }
    $widths = @{}
    foreach ($col in $Columns) {
        $max = @($cells | ForEach-Object { $_.Text[$col].Length }) + $col.Length | Measure-Object -Maximum
        $widths[$col] = [Math]::Min([int]$max.Maximum, $MaxColumnWidth)
    }

    $pad = ' ' * $Indent
    $header = ($Columns | ForEach-Object { $_.PadRight($widths[$_]) }) -join '   '
    $rule = ($Columns | ForEach-Object { '─' * $widths[$_] }) -join '   '
    Write-Host "$pad$($PSStyle.Bold)$header$($PSStyle.Reset)"
    Write-Host "$pad$($PSStyle.Foreground.BrightBlack)$rule$($PSStyle.Reset)"
    foreach ($cell in $cells) {
        $parts = foreach ($col in $Columns) {
            $text = (Limit-DgText $cell.Text[$col] $widths[$col]).PadRight($widths[$col])
            if ($col -eq $StatusColumn) { "$((Get-DgStyle $cell.Source.$col).Ansi)$text$($PSStyle.Reset)" } else { $text }
        }
        Write-Host "$pad$($parts -join '   ')"
    }
}

function Format-DgDate {
    param($Value)
    $utc = ConvertTo-DgUtc $Value
    if (-not $utc) { return '—' }
    $age = [datetime]::UtcNow - $utc
    $relative = if ($age.TotalMinutes -lt 1) { 'just now' }
    elseif ($age.TotalHours -lt 1) { '{0}m ago' -f [int]$age.TotalMinutes }
    elseif ($age.TotalDays -lt 1) { '{0}h ago' -f [int]$age.TotalHours }
    else { '{0}d ago' -f [int]$age.TotalDays }
    '{0:yyyy-MM-dd HH:mm} ({1})' -f $utc.ToLocalTime(), $relative
}

function Read-DgText {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $answer = Read-Host "  $Prompt"
        if (-not [string]::IsNullOrWhiteSpace($answer)) { return $answer.Trim() }
    }
}

# Returns the zero-based index of the chosen option. -Default is one-based; 0 means no default.
function Read-DgChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$Default = 1
    )
    Write-Host "  $Prompt"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("    {0}[{1}]{2} {3}" -f $PSStyle.Foreground.Cyan, ($i + 1), $PSStyle.Reset, $Options[$i])
    }
    $hint = if ($Default -gt 0) { " [$Default]" } else { '' }
    while ($true) {
        $answer = Read-Host "  Choose 1-$($Options.Count)$hint"
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default -gt 0) { return $Default - 1 }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n - 1 }
        Write-DgStatus Warn "Enter a number between 1 and $($Options.Count)."
    }
}

function Read-DgYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = "$(Read-Host "  $Prompt [$hint]")".Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
    }
}

function Confirm-DgTyped {
    param([Parameter(Mandatory)][string]$Expected, [string]$Prompt = 'Type {0} to confirm')
    $answer = Read-Host ("  $Prompt" -f "$($PSStyle.Bold)$Expected$($PSStyle.Reset)")
    "$answer".Trim() -eq $Expected
}

function New-DgResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail,
        [object]$Data
    )
    [pscustomobject]@{
        PSTypeName = 'Disengage.Result'
        Step       = $null
        Status     = $Status
        Detail     = $Detail
        Data       = $Data
        Seconds    = 0
    }
}

# Runs one offboarding step, prints its outcome, and always returns a Disengage.Result
# (exceptions become Failed results so the orchestrator decides whether to stop).
function Invoke-DgStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$Number,
        [int]$Total
    )
    $label = if ($Total) { "[$Number/$Total] $Name" } else { $Name }
    Write-Host "  $($PSStyle.Foreground.Cyan)›$($PSStyle.Reset) $($PSStyle.Bold)$label$($PSStyle.Reset)"
    if ($Total) {
        Write-Progress -Id 1 -Activity 'Offboarding' -Status $label -PercentComplete ([int](($Number - 1) / $Total * 100))
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = @(& $Action) | Where-Object { $_.PSObject.TypeNames -contains 'Disengage.Result' } | Select-Object -Last 1
        if (-not $result) { $result = New-DgResult -Status Done }
    } catch {
        $result = New-DgResult -Status Failed -Detail $_.Exception.Message
    }
    $timer.Stop()
    $result.Step = $Name
    $result.Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1)
    $suffix = if ($result.Detail) { " — $($result.Detail)" } else { '' }
    Write-DgStatus -Status $result.Status -Message ("{0} {1}({2}s){3}{4}" -f $result.Status, $PSStyle.Foreground.BrightBlack, $result.Seconds, $PSStyle.Reset, $suffix) -Indent 4
    $result
}

# Polls $Condition until it returns $true or the timeout passes, showing a nested progress bar.
function Wait-DgCondition {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [double]$TimeoutMinutes = 10,
        [int]$PollSeconds = 15
    )
    $start = Get-Date
    $deadline = $start.AddMinutes($TimeoutMinutes)
    try {
        while ($true) {
            if (& $Condition) { return $true }
            $now = Get-Date
            if ($now -ge $deadline) { return $false }
            $elapsed = $now - $start
            $percent = [int][Math]::Min(99, $elapsed.TotalSeconds / [Math]::Max(1, ($deadline - $start).TotalSeconds) * 100)
            Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status ('{0:mm\:ss} elapsed · checking every {1}s' -f $elapsed, $PollSeconds) `
                -PercentComplete $percent -SecondsRemaining ([int]($deadline - $now).TotalSeconds)
            Start-Sleep -Seconds $PollSeconds
        }
    } finally {
        Write-Progress -Id 2 -Activity $Activity -Completed
    }
}
