# ERP Doctor installer - run it by double-clicking install.cmd.
# 1. Adds this folder to your user PATH, so `doctor` works in PowerShell, CMD, Git Bash and Claude Code.
# 2. Installs the git post-checkout hook in your ERP repo.
$dir = $PSScriptRoot

# --- 1. PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -contains $dir) {
    Write-Host "PATH       : already set ($dir)"
} else {
    $newPath = (($userPath.TrimEnd(';') + ';' + $dir).TrimStart(';'))
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "PATH       : added $dir"
}

# --- 2. git hook
$repo = 'C:\xampp1\htdocs\erp'
$answer = Read-Host "ERP folder (press Enter for $repo)"
if ($answer.Trim()) { $repo = $answer.Trim().Trim('"') }
$hooks = Join-Path $repo '.git\hooks'
if (-not (Test-Path $hooks)) {
    Write-Host "git hook   : SKIPPED - $hooks not found" -ForegroundColor Yellow
} else {
    $ps1  = (Join-Path $dir 'doctor.ps1') -replace '\\', '/'
    $hook = "#!/bin/sh`n" +
            "# ERP Doctor quick check after a branch switch (local only, not committed).`n" +
            "[ `"`$3`" = `"1`" ] || exit 0`n" +
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Quick -Repo `"`$(pwd -W)`"`n" +
            "exit 0`n"
    [IO.File]::WriteAllText((Join-Path $hooks 'post-checkout'), $hook, (New-Object Text.UTF8Encoding $false))
    Write-Host "git hook   : installed in $repo"
}

Write-Host ''
Write-Host 'Done. Close ALL open terminals (and restart Claude Code), then type: doctor' -ForegroundColor Green
