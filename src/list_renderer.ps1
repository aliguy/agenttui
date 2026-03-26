# list_renderer.ps1
# Renders the session list panel for AgentTUI
# Runs as a persistent process in the left WezTerm pane

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$StateDir = Join-Path $env:USERPROFILE ".agenttui"
$SessionsFile = Join-Path $StateDir "sessions.json"
$SelectionFile = Join-Path $StateDir "selected.txt"
$CommandFile = Join-Path $StateDir "command.txt"

# Ensure state dir exists
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# Colors (Catppuccin Mocha)
$ESC = [char]27
function FG($r,$g,$b) { "$ESC[38;2;${r};${g};${b}m" }
function BG($r,$g,$b) { "$ESC[48;2;${r};${g};${b}m" }
function Reset { "$ESC[0m" }
function Bold { "$ESC[1m" }
function Dim { "$ESC[2m" }
function HideCursor { "$ESC[?25l" }
function ShowCursor { "$ESC[?25h" }
function ClearScreen { "$ESC[2J$ESC[H" }
function MoveTo($row,$col) { "$ESC[${row};${col}H" }
function ClearLine { "$ESC[2K" }
function AltScreenOn { "$ESC[?1049h" }
function AltScreenOff { "$ESC[?1049l" }

# Color palette
$cBase = @(30,30,46)
$cSurface0 = @(49,50,68)
$cSurface1 = @(69,71,90)
$cOverlay0 = @(108,112,134)
$cText = @(205,214,244)
$cSubtext0 = @(166,173,200)
$cGreen = @(166,227,161)
$cRed = @(243,139,168)
$cBlue = @(137,180,250)
$cYellow = @(249,226,175)
$cMauve = @(203,166,247)

$selectedIdx = 0
$sessions = @()

function Load-Sessions {
    $script:sessions = @()
    if (Test-Path $SessionsFile) {
        try {
            $content = Get-Content $SessionsFile -Raw
            if ($content -and $content.Trim() -ne "" -and $content.Trim() -ne "[]") {
                $parsed = $content | ConvertFrom-Json
                if ($parsed) {
                    $script:sessions = @($parsed)
                }
            }
        } catch { }
    }
    # Clamp selection
    if ($script:sessions.Count -gt 0) {
        if ($script:selectedIdx -ge $script:sessions.Count) {
            $script:selectedIdx = $script:sessions.Count - 1
        }
        if ($script:selectedIdx -lt 0) { $script:selectedIdx = 0 }
    }
}

function Write-Selection {
    if ($sessions.Count -gt 0 -and $selectedIdx -lt $sessions.Count) {
        $sessions[$selectedIdx].id | Out-File -FilePath $SelectionFile -NoNewline -Encoding utf8
    }
}

function Render {
    $w = $Host.UI.RawUI.WindowSize.Width
    $h = $Host.UI.RawUI.WindowSize.Height
    if ($w -lt 10) { $w = 40 }
    if ($h -lt 5) { $h = 30 }

    $buf = ""
    $buf += ClearScreen
    $buf += HideCursor

    # Title bar
    $buf += MoveTo 2 1
    $buf += BG $cMauve[0] $cMauve[1] $cMauve[2]
    $buf += FG $cBase[0] $cBase[1] $cBase[2]
    $buf += Bold
    $titleText = " Instances "
    $buf += $titleText + (" " * [Math]::Max(0, $w - $titleText.Length))
    $buf += Reset

    # Empty state
    if ($sessions.Count -eq 0) {
        $buf += MoveTo 5 3
        $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
        $buf += "No sessions yet."
        $buf += MoveTo 7 3
        $buf += "Press "
        $buf += FG $cMauve[0] $cMauve[1] $cMauve[2]
        $buf += Bold
        $buf += "Alt+N"
        $buf += Reset
        $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
        $buf += " to create one."
        $buf += Reset

        [Console]::Write($buf)
        return
    }

    # Render each session
    $row = 4
    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $s = $sessions[$i]
        $sel = ($i -eq $selectedIdx)

        # Selected background fill
        if ($sel) {
            $buf += MoveTo $row 1
            $buf += BG $cSurface0[0] $cSurface0[1] $cSurface0[2]
            $buf += " " * $w
            $buf += MoveTo ($row+1) 1
            $buf += " " * $w
            $buf += MoveTo ($row+2) 1
            $buf += " " * $w
        }

        # Line 1: index + title + status
        $buf += MoveTo $row 1
        if ($sel) { $buf += BG $cSurface0[0] $cSurface0[1] $cSurface0[2] }

        $idxStr = " $($i+1). "
        $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
        $buf += $idxStr

        # Title
        if ($sel) {
            $buf += FG $cText[0] $cText[1] $cText[2]
            $buf += Bold
        } else {
            $buf += FG $cText[0] $cText[1] $cText[2]
        }

        $titleTxt = if ($s.title) { $s.title } else { "untitled" }
        $maxTitleW = $w - $idxStr.Length - 5
        if ($titleTxt.Length -gt $maxTitleW -and $maxTitleW -gt 3) {
            $titleTxt = $titleTxt.Substring(0, $maxTitleW - 3) + "..."
        }
        $buf += $titleTxt
        $buf += Reset
        if ($sel) { $buf += BG $cSurface0[0] $cSurface0[1] $cSurface0[2] }

        # Status icon (UTF-8 encoding set above)
        $status = "$($s.status)".Trim().ToLower()
        if ($status -eq "running") {
            $buf += FG $cGreen[0] $cGreen[1] $cGreen[2]; $buf += " ● "
        } elseif ($status -eq "ready") {
            $buf += FG $cBlue[0] $cBlue[1] $cBlue[2]; $buf += " ● "
        } elseif ($status -eq "paused") {
            $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]; $buf += " ⏸ "
        } elseif ($status -eq "loading") {
            $buf += FG $cYellow[0] $cYellow[1] $cYellow[2]; $buf += " ○ "
        } else {
            $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]; $buf += " ● "
        }
        $buf += Reset

        # Line 2: branch + diff stats
        $row++
        $buf += MoveTo $row 1
        if ($sel) { $buf += BG $cSurface0[0] $cSurface0[1] $cSurface0[2] }

        $branchPrefix = (" " * $idxStr.Length) + "└─"
        $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
        $buf += $branchPrefix

        $branch = if ($s.branch) { $s.branch } else { "" }

        # Diff stats
        $statsStr = ""
        if ($s.diff_stats) {
            $a = if ($s.diff_stats.additions) { $s.diff_stats.additions } else { 0 }
            $d = if ($s.diff_stats.deletions) { $s.diff_stats.deletions } else { 0 }
            if ($a -gt 0 -or $d -gt 0) { $statsStr = "+$a,-$d" }
        }

        $maxBranchW = $w - $branchPrefix.Length - $statsStr.Length - 3
        if ($branch.Length -gt $maxBranchW -and $maxBranchW -gt 3) {
            $branch = $branch.Substring(0, $maxBranchW - 3) + "..."
        }

        if ($sel) {
            $buf += FG $cSubtext0[0] $cSubtext0[1] $cSubtext0[2]
        } else {
            $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
        }
        $buf += $branch

        if ($statsStr -ne "") {
            $spaces = [Math]::Max(1, $w - $branchPrefix.Length - $branch.Length - $statsStr.Length - 2)
            $buf += " " * $spaces
            $addPart = $statsStr -replace ",.*", ""
            $delPart = $statsStr -replace ".*,", ""
            $buf += FG $cGreen[0] $cGreen[1] $cGreen[2]
            $buf += $addPart
            $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]
            $buf += ","
            $buf += FG $cRed[0] $cRed[1] $cRed[2]
            $buf += $delPart
        }

        $buf += Reset
        $row += 2
    }

    # Menu bar at the bottom
    $menuRow = $h - 1
    $buf += MoveTo $menuRow 1
    $buf += FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]

    $menuItems = @(
        @{ key="j/k"; desc="navigate" },
        @{ key="n"; desc="new" },
        @{ key="N"; desc="+prompt" },
        @{ key="c"; desc="pause" },
        @{ key="r"; desc="resume" },
        @{ key="p"; desc="push" },
        @{ key="D"; desc="delete" }
    )

    $menuStr = ""
    foreach ($item in $menuItems) {
        $menuStr += " $(FG $cMauve[0] $cMauve[1] $cMauve[2])$($item.key)$(FG $cOverlay0[0] $cOverlay0[1] $cOverlay0[2]) $($item.desc) "
    }
    $buf += $menuStr
    $buf += Reset

    [Console]::Write($buf)
}

# Main
[Console]::Write((AltScreenOn))
[Console]::Write((HideCursor))

Load-Sessions
Render
Write-Selection

# Input loop
try {
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                "UpArrow" {
                    if ($selectedIdx -gt 0) { $script:selectedIdx-- }
                    Write-Selection
                    Render
                }
                "DownArrow" {
                    if ($selectedIdx -lt ($sessions.Count - 1)) { $script:selectedIdx++ }
                    Write-Selection
                    Render
                }
                "J" {
                    if (-not $key.Modifiers) {
                        if ($selectedIdx -lt ($sessions.Count - 1)) { $script:selectedIdx++ }
                        Write-Selection
                        Render
                    }
                }
                "K" {
                    if (-not $key.Modifiers) {
                        if ($selectedIdx -gt 0) { $script:selectedIdx-- }
                        Write-Selection
                        Render
                    }
                }
                "Q" {
                    break
                }
                "Escape" {
                    break
                }
            }
        }

        # Reload sessions periodically
        Start-Sleep -Milliseconds 500
        Load-Sessions
        Render
    }
} finally {
    [Console]::Write((ShowCursor))
    [Console]::Write((AltScreenOff))
}
