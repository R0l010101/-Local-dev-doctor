# Local Dev Doctor installer - run it by double-clicking install.cmd. Safe to run again.
# 1. Adds this folder to your user PATH, so `doctor` works in PowerShell, CMD, Git Bash and Claude Code.
# 2. Asks for your project folders (Laravel backend, React frontend) and saves them in projects.txt.
# 3. Installs a git post-checkout hook in each project (works with husky too; never committed).
$dir = $PSScriptRoot
$projectsFile = Join-Path $dir 'projects.txt'

function Get-ProjectType($p) {
    if (-not (Test-Path $p)) { return $null }
    if (Test-Path (Join-Path $p 'artisan')) { return 'Laravel' }
    $pkg = Join-Path $p 'package.json'
    if ((Test-Path $pkg) -and ((Get-Content $pkg -Raw) -match '"react"\s*:')) { return 'React' }
    return $null
}

# ---------------------------------------------------------------- 1. PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$keep = @(); $removed = @()
foreach ($p in ($userPath -split ';' | Where-Object { $_ })) {
    $isOtherDoctor = ($p -ne $dir) -and (($p -match '\\(erp|laravel|dev)-doctor\\?$') -or (Test-Path (Join-Path $p 'doctor.ps1')))
    if ($isOtherDoctor) { $removed += $p } else { $keep += $p }
}
if ($keep -notcontains $dir) { $keep += $dir }
$newPath = $keep -join ';'
if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "PATH       : set to $dir"
    foreach ($r in $removed) { Write-Host "PATH       : removed old entry $r" }
} else {
    Write-Host "PATH       : already set"
}

# Old installs added a `doctor` function to the PowerShell profile; it would shadow the PATH command.
if (Test-Path $PROFILE) {
    $lines = @(Get-Content $PROFILE)
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*function\s+doctor\b') { $lines[$i] = '# (replaced by Local Dev Doctor on PATH) ' + $lines[$i]; $changed = $true }
    }
    if ($changed) {
        Copy-Item $PROFILE "$PROFILE.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Set-Content $PROFILE $lines -Encoding UTF8
        Write-Host 'profile    : old doctor function commented out (backup kept)'
    }
}

# ---------------------------------------------------------------- 2. projects
$projects = @()
if (Test-Path $projectsFile) {
    $projects = @(Get-Content $projectsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
Write-Host ''
if ($projects.Count -gt 0) {
    Write-Host 'Projects already registered:'
    foreach ($p in $projects) { Write-Host "  $p  [$(Get-ProjectType $p)]" }
} else {
    Write-Host 'No projects registered yet.'
}
Write-Host 'Add your backend (Laravel) and frontend (React) folders. Press Enter on an empty line when done.'
while ($true) {
    $answer = (Read-Host 'Project folder').Trim().Trim('"')
    if (-not $answer) { break }
    $type = Get-ProjectType $answer
    if (-not $type) { Write-Host "  not a Laravel/React project: $answer" -ForegroundColor Yellow; continue }
    $full = (Resolve-Path $answer).Path.TrimEnd('\')
    if ($projects -contains $full) { Write-Host '  already registered'; continue }
    $projects += $full
    Write-Host "  added [$type]"
}
Set-Content $projectsFile ($projects) -Encoding UTF8

# ---------------------------------------------------------------- 3. git hooks
$ps1 = (Join-Path $dir 'doctor.ps1') -replace '\\', '/'
$hook = "#!/bin/sh`n" +
        "# Local Dev Doctor: quick check after a branch switch (local only, not committed).`n" +
        "[ `"`$3`" = `"1`" ] || exit 0`n" +
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Quick -Path `"`$(pwd -W)`"`n" +
        "exit 0`n"
Write-Host ''
foreach ($p in $projects) {
    if (-not (git -C $p rev-parse --git-dir 2>$null)) { Write-Host "git hook   : SKIPPED $p (not a git repo)" -ForegroundColor Yellow; continue }

    # respects core.hooksPath (husky uses .husky)
    $hooksDir = (git -C $p rev-parse --git-path hooks) -replace '/', '\'
    if (-not [IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $p $hooksDir }
    $hookFile = Join-Path $hooksDir 'post-checkout'

    if ((Test-Path $hookFile) -and -not ((Get-Content $hookFile -Raw) -match 'doctor\.ps1')) {
        Write-Host "git hook   : SKIPPED $p - it already has its own post-checkout hook. Add this line to it:" -ForegroundColor Yellow
        Write-Host "             powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Quick -Path `"`$(pwd -W)`""
        continue
    }
    $rel = $null
    if ($hookFile.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $hookFile.Substring($p.Length + 1) -replace '\\', '/'
        if ($rel -notlike '.git/*' -and (git -C $p ls-files -- $rel)) {
            Write-Host "git hook   : SKIPPED $p - $rel is a tracked file" -ForegroundColor Yellow
            continue
        }
        if ($rel -like '.git/*') { $rel = $null }   # inside .git: never committed anyway
    }
    New-Item -ItemType Directory -Force $hooksDir | Out-Null
    [IO.File]::WriteAllText($hookFile, $hook, (New-Object Text.UTF8Encoding $false))

    # a hook inside the working tree (e.g. .husky/) must never be committed: exclude it locally
    if ($rel) {
        $exclude = (git -C $p rev-parse --git-path info/exclude) -replace '/', '\'
        if (-not [IO.Path]::IsPathRooted($exclude)) { $exclude = Join-Path $p $exclude }
        $already = (Test-Path $exclude) -and ((Get-Content $exclude) -contains $rel)
        if (-not $already) {
            New-Item -ItemType Directory -Force (Split-Path $exclude) | Out-Null
            Add-Content $exclude $rel
        }
    }
    Write-Host "git hook   : installed in $p"
}

Write-Host ''
Write-Host 'Done. Close ALL open terminals (and restart Claude Code), then type: doctor' -ForegroundColor Green
