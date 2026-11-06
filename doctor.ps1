<#
  Doctor - health check for a local Laravel dev setup. Detects each developer's own setup
  (PHP, MySQL/MariaDB, web server) instead of assuming fixed paths, and fixes missing files.

  Usage:
    doctor            full check, auto-fixes the safe things
    doctor -NoFix     report only, change nothing
    doctor -Quick     file checks only, prints nothing when all OK (used by the git hook)
    doctor -Repo X    check another project
                      (default: the current folder if it has artisan, else C:\xampp1\htdocs\erp)

  Optional override: set DOCTOR_PHP to the php.exe to use.

  Auto-fixes (never deletes, never overwrites):
    - .env missing                -> copy .env.example
    - .env line without # or =    -> add '#'   (backup .env.bak-<stamp>)
    - core config/<name>.php gone -> restore from git, or copy its single template
                                     (<name>_*.php, <name>.example.php, <name>.php.example, <name>.php.dist)
    - storage / bootstrap\cache folders missing -> create
    - stale bootstrap cache (classes that don't exist) -> move to bootstrap\cache\_stale\<stamp>
  Report only: vendor, APP_KEY, Passport keys, PHP version, database server, web server.
#>
param(
    [string]$Repo,
    [switch]$NoFix,
    [switch]$Quick
)

if (-not $Repo) {
    if (Test-Path (Join-Path (Get-Location).Path 'artisan')) { $Repo = (Get-Location).Path }
    else { $Repo = 'C:\xampp1\htdocs\erp' }
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$results = New-Object System.Collections.ArrayList
function Add-Result($status, $name, $msg) {
    [void]$results.Add([pscustomobject]@{ Status = $status; Name = $name; Msg = $msg })
}

function Get-EnvValue($lines, $key) {
    foreach ($l in $lines) {
        if ($l -match "^\s*$key\s*=\s*(.*?)\s*$") { return $Matches[1].Trim('"', "'") }
    }
    return $null
}

# Run php.exe with only its own folder on PATH (mixing two PHP installs' DLLs breaks extensions).
function Invoke-Php($exe, [string[]]$phpArgs) {
    $oldPath = $env:PATH; $oldRc = $env:PHPRC
    $dir = Split-Path $exe
    $env:PATH = "$dir;$env:SystemRoot\system32;$env:SystemRoot"
    $env:PHPRC = $dir
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location $Repo
    $out = & $exe @phpArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    Pop-Location
    $ErrorActionPreference = $oldEap
    $env:PATH = $oldPath; $env:PHPRC = $oldRc
    return @{ Out = $out; Code = $code }
}

function Get-ListenPorts($procId) {
    @(Get-NetTCPConnection -OwningProcess $procId -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
}

if (-not (Test-Path (Join-Path $Repo 'artisan'))) {
    Write-Host "Not a Laravel project (no artisan): $Repo" -ForegroundColor Red; exit 1
}

# ================================================================ FILE CHECKS (also run by -Quick)

# ---------------------------------------------------------------- .env
$envPath = Join-Path $Repo '.env'
$envExample = Join-Path $Repo '.env.example'
if (-not (Test-Path $envPath)) {
    if ((Test-Path $envExample) -and -not $NoFix) {
        Copy-Item $envExample $envPath
        Add-Result 'FIX' '.env' 'was missing - copied from .env.example. Fill in your DB settings, then: php artisan key:generate'
    } else {
        Add-Result 'FAIL' '.env' 'missing (copy .env.example to .env and fill it in)'
    }
}
$envLines = @()
if (Test-Path $envPath) {
    $bytes  = [IO.File]::ReadAllBytes($envPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = (New-Object Text.UTF8Encoding $false).GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    $lines = $text -split "`n"                 # each line keeps its trailing `r
    $bad = @()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim()
        if ($t -ne '' -and -not $t.StartsWith('#') -and -not $t.Contains('=')) { $bad += $i }
    }
    if ($bad.Count -gt 0) {
        $desc = ($bad | ForEach-Object { "line $($_ + 1): `"$($lines[$_].Trim())`"" }) -join '; '
        if ($NoFix) {
            Add-Result 'FAIL' '.env' "missing # on $desc"
        } else {
            Copy-Item $envPath "$envPath.bak-$Stamp"
            foreach ($i in $bad) { $lines[$i] = '# ' + $lines[$i].TrimStart() }
            [IO.File]::WriteAllText($envPath, ($lines -join "`n"), (New-Object Text.UTF8Encoding $hasBom))
            Add-Result 'FIX' '.env' "added # to $desc (backup .env.bak-$Stamp)"
        }
    } elseif (@($results | Where-Object { $_.Name -eq '.env' }).Count -eq 0) {
        Add-Result 'OK' '.env' 'present, no broken lines'
    }
    $envLines = Get-Content $envPath
}

# ---------------------------------------------------------------- core config files
$coreConfigs = 'app', 'auth', 'broadcasting', 'cache', 'database', 'filesystems', 'hashing',
               'logging', 'mail', 'queue', 'services', 'session', 'view'
$configDir = Join-Path $Repo 'config'
$configProblems = 0
foreach ($name in $coreConfigs) {
    $target = Join-Path $configDir "$name.php"
    if (Test-Path $target) { continue }
    $configProblems++
    $rel = "config/$name.php"

    # 1) tracked in git and deleted from the working tree -> restore the committed copy
    $tracked = git -C $Repo ls-files -- $rel 2>$null
    if ($tracked) {
        if ($NoFix) { Add-Result 'FAIL' $rel "missing (tracked in git - restore with: git checkout -- $rel)"; continue }
        git -C $Repo checkout -- $rel 2>$null
        if (Test-Path $target) { Add-Result 'FIX' $rel 'was deleted - restored from git'; continue }
    }

    # 2) a local template next to it
    $templates = @(Get-ChildItem $configDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "${name}_*.php" -or $_.Name -eq "$name.example.php" -or
        $_.Name -eq "$name.php.example" -or $_.Name -eq "$name.php.dist" })
    if ($templates.Count -eq 1) {
        if ($NoFix) { Add-Result 'FAIL' $rel "missing (restore: copy config\$($templates[0].Name))" }
        else {
            Copy-Item $templates[0].FullName $target
            Add-Result 'FIX' $rel "was missing - copied from config\$($templates[0].Name)"
        }
    } elseif ($templates.Count -gt 1) {
        Add-Result 'FAIL' $rel "missing - several templates, pick one and copy it: $(($templates | ForEach-Object Name) -join ', ')"
    } else {
        Add-Result 'FAIL' $rel 'missing and no template found - ask a teammate for their copy'
    }
}
if ($configProblems -eq 0) { Add-Result 'OK' 'config' 'all core config files present' }

# ---------------------------------------------------------------- runtime folders
$dirs = 'storage\app', 'storage\framework\cache', 'storage\framework\sessions',
        'storage\framework\views', 'storage\logs', 'bootstrap\cache'
$missingDirs = @($dirs | Where-Object { -not (Test-Path (Join-Path $Repo $_)) })
if ($missingDirs.Count -eq 0) {
    Add-Result 'OK' 'folders' 'storage and bootstrap\cache folders present'
} elseif ($NoFix) {
    Add-Result 'FAIL' 'folders' "missing: $($missingDirs -join ', ')"
} else {
    foreach ($d in $missingDirs) { New-Item -ItemType Directory -Force (Join-Path $Repo $d) | Out-Null }
    Add-Result 'FIX' 'folders' "created: $($missingDirs -join ', ')"
}

# ---------------------------------------------------------------- stale bootstrap cache
$cacheDir   = Join-Path $Repo 'bootstrap\cache'
$cacheFiles = @('config.php', 'routes-v7.php', 'routes.php', 'services.php') |
              Where-Object { Test-Path (Join-Path $cacheDir $_) }

function Find-MissingClasses($file) {
    $path = Join-Path $cacheDir $file
    if (-not (Test-Path $path)) { return @() }
    $text    = [IO.File]::ReadAllText($path)
    $pattern = 'App\\{1,2}(?:Providers|Http\\{1,2}Controllers)\\{1,2}[A-Za-z0-9_\\]*[A-Za-z0-9_]'
    $classes = [regex]::Matches($text, $pattern) | ForEach-Object { $_.Value -replace '\\\\', '\' } | Sort-Object -Unique
    $missing = @()
    foreach ($c in $classes) {
        if (-not (Test-Path (Join-Path $Repo (($c -replace '^App\\', 'app\') + '.php')))) { $missing += $c }
    }
    return $missing
}

if ($cacheFiles.Count -eq 0) {
    Add-Result 'OK' 'bootstrap cache' 'not cached (Laravel reads source)'
} else {
    $missing = @()
    foreach ($f in $cacheFiles) { $missing += Find-MissingClasses $f }
    $missing = @($missing | Sort-Object -Unique)
    if ($missing.Count -eq 0) {
        Add-Result 'OK' 'bootstrap cache' 'all cached classes exist'
    } else {
        $names = ($missing | Select-Object -First 3 | ForEach-Object { $_.Split('\')[-1] }) -join ', '
        if ($missing.Count -gt 3) { $names += " (+$($missing.Count - 3) more)" }
        if ($NoFix) {
            Add-Result 'FAIL' 'bootstrap cache' "stale - references missing $names"
        } else {
            $dest = Join-Path $cacheDir "_stale\$Stamp"
            New-Item -ItemType Directory -Force $dest | Out-Null
            foreach ($f in $cacheFiles) { Move-Item (Join-Path $cacheDir $f) $dest }
            Add-Result 'FIX' 'bootstrap cache' "stale ($names) - moved $($cacheFiles -join ', ') to bootstrap\cache\_stale\$Stamp"
        }
    }
}

# ================================================================ SETUP CHECKS (full mode only)
if (-not $Quick) {
    $composer = $null
    $composerPath = Join-Path $Repo 'composer.json'
    if (Test-Path $composerPath) { $composer = Get-Content $composerPath -Raw | ConvertFrom-Json }

    # ------------------------------------------------------------ vendor / APP_KEY / Passport
    if (-not (Test-Path (Join-Path $Repo 'vendor\autoload.php'))) {
        Add-Result 'FAIL' 'vendor' 'not installed - run: composer install'
    }
    if ($envLines.Count -gt 0 -and -not (Get-EnvValue $envLines 'APP_KEY')) {
        Add-Result 'WARN' 'APP_KEY' 'empty - run: php artisan key:generate'
    }
    if ($composer -and $composer.require.'laravel/passport' -and
        -not (Test-Path (Join-Path $Repo 'storage\oauth-private.key'))) {
        Add-Result 'WARN' 'passport keys' 'storage\oauth-*.key missing - ask a teammate for them, or run: php artisan passport:keys'
    }

    # ------------------------------------------------------------ PHP: find the one this project needs
    $wanted = $null
    if ($composer -and $composer.config -and $composer.config.platform -and $composer.config.platform.php) {
        $wanted = $composer.config.platform.php
    }
    $wantedMm = $null
    if ($wanted -match '^(\d+\.\d+)') { $wantedMm = $Matches[1] }

    $candidates = @()
    if ($env:DOCTOR_PHP) { $candidates += $env:DOCTOR_PHP }
    $onPath = Get-Command php -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    foreach ($pat in 'C:\xampp*\php\php.exe', 'C:\laragon\bin\php\*\php.exe', 'C:\wamp64\bin\php\*\php.exe',
                     'C:\wamp\bin\php\*\php.exe', 'C:\php*\php.exe', 'C:\tools\php*\php.exe') {
        $candidates += @(Get-ChildItem $pat -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    $candidates = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)

    $phps = @()
    foreach ($c in $candidates) {
        $v = Invoke-Php $c @('-v')
        if ($v.Code -eq 0 -and ($v.Out -join ' ') -match 'PHP (\d+\.\d+\.\d+)') {
            $phps += [pscustomobject]@{ Path = $c; Version = $Matches[1] }
        }
    }

    $php = $null
    if ($phps.Count -eq 0) {
        Add-Result 'FAIL' 'PHP' 'no php.exe found (install PHP, or set DOCTOR_PHP to its path)'
    } else {
        if ($wantedMm) { $php = $phps | Where-Object { $_.Version.StartsWith("$wantedMm.") } | Select-Object -First 1 }
        if (-not $php) { $php = $phps[0] }
        $msg = "$($php.Version) at $($php.Path)"
        if ($wanted) { $msg += " (project wants $wanted)" }
        if ($wantedMm -and -not $php.Version.StartsWith("$wantedMm.")) {
            Add-Result 'WARN' 'PHP' "$msg - no PHP $wantedMm found on this PC"
        } else {
            Add-Result 'INFO' 'PHP' $msg
        }
        if ($onPath -and $onPath.Source -ne $php.Path) {
            $pathVer = ($phps | Where-Object { $_.Path -eq $onPath.Source } | Select-Object -First 1).Version
            Add-Result 'INFO' 'PHP on PATH' "is $pathVer ($($onPath.Source)) - for this project use $($php.Path)"
        }
    }

    # ------------------------------------------------------------ database
    $dbConn = Get-EnvValue $envLines 'DB_CONNECTION'
    $dbHost = Get-EnvValue $envLines 'DB_HOST'
    $dbPort = Get-EnvValue $envLines 'DB_PORT'; if (-not $dbPort) { $dbPort = '3306' }
    $dbName = Get-EnvValue $envLines 'DB_DATABASE'
    $isLocal = ($dbHost -eq '127.0.0.1' -or $dbHost -eq 'localhost')

    if (-not $dbHost) {
        Add-Result 'WARN' 'database' '.env has no DB_HOST'
    } elseif ($dbConn -and $dbConn -ne 'mysql') {
        Add-Result 'INFO' 'database' "$dbConn - only MySQL/MariaDB is checked"
    } elseif (-not $isLocal) {
        Add-Result 'INFO' 'database' "REMOTE $dbHost`:$dbPort / $dbName (not tested - local only)"
    } else {
        $label = "database $dbPort"
        $listener = Get-NetTCPConnection -LocalPort ([int]$dbPort) -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $servers  = @(Get-Process mysqld, mariadbd -ErrorAction SilentlyContinue)

        if ($listener) {
            $srv = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            $where = ''
            if ($srv -and $srv.Path) { $where = " ($($srv.Path))" }
            if (-not $php) {
                Add-Result 'OK' $label "port open$where"
            } else {
                # real connect through PHP's PDO, using the credentials in .env
                $probe = Join-Path $env:TEMP 'doctor-db-probe.php'
                Set-Content $probe -Encoding ASCII -Value @'
<?php
$h = getenv('DOC_H'); $P = getenv('DOC_P'); $d = getenv('DOC_D');
$u = getenv('DOC_U'); $w = getenv('DOC_W'); if ($w === false) { $w = ''; }
try {
    $dsn = "mysql:host=$h;port=$P" . ($d ? ";dbname=$d" : '');
    $p = new PDO($dsn, $u, $w, [PDO::ATTR_TIMEOUT => 5, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $v = $p->query('select version()')->fetchColumn();
    $n = $d ? $p->query('select count(*) from information_schema.tables where table_schema = database()')->fetchColumn() : '?';
    echo "OK|$v|$n";
} catch (Exception $e) { echo 'ERR|' . $e->getMessage(); }
'@
                $env:DOC_H = $dbHost; $env:DOC_P = $dbPort; $env:DOC_D = $dbName
                $env:DOC_U = Get-EnvValue $envLines 'DB_USERNAME'; $env:DOC_W = Get-EnvValue $envLines 'DB_PASSWORD'
                $r = Invoke-Php $php.Path @($probe)
                'DOC_H', 'DOC_P', 'DOC_D', 'DOC_U', 'DOC_W' | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
                $o = ($r.Out -join ' ').Trim()
                if ($o -like 'OK|*') {
                    $parts = $o.Split('|')
                    Add-Result 'OK' $label "connected - $dbName, $($parts[2]) tables, server $($parts[1])$where"
                } elseif ($o -match '1130') {
                    Add-Result 'FAIL' $label 'error 1130 for this user - privilege tables may have failed to load (MariaDB Aria fault)'
                } elseif ($o -match '1045') {
                    Add-Result 'FAIL' $label 'access denied (1045) - check DB_USERNAME / DB_PASSWORD in .env'
                } elseif ($o -match '1049') {
                    Add-Result 'FAIL' $label "database '$dbName' does not exist on this server"
                } elseif ($o -match 'could not find driver') {
                    Add-Result 'FAIL' $label "pdo_mysql is not enabled in $($php.Path)"
                } else {
                    Add-Result 'FAIL' $label "connect failed: $o"
                }
            }
        } elseif ($servers.Count -gt 0) {
            $s = $servers[0]
            $ports = Get-ListenPorts $s.Id
            if ($ports.Count -gt 0) {
                Add-Result 'FAIL' $label "MySQL is running but on port $($ports -join ', '), while .env says DB_PORT=$dbPort"
            } else {
                Add-Result 'WARN' $label 'MySQL is starting - probably crash recovery. Wait 1-2 minutes, do not kill it'
            }
        } else {
            # not running: find the newest error log of any local install
            $hint = 'MySQL is not running - start it (XAMPP / Laragon / WAMP control panel)'
            $logs = @()
            foreach ($pat in 'C:\xampp*\mysql\data', 'C:\laragon\data\mysql*', 'C:\wamp64\bin\mysql\*\data',
                             'C:\wamp\bin\mysql\*\data', 'C:\ProgramData\MySQL\*\Data') {
                foreach ($d in @(Get-ChildItem $pat -Directory -ErrorAction SilentlyContinue)) {
                    $logs += @(Get-ChildItem $d.FullName -File -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -eq 'mysql_error.log' -or $_.Extension -eq '.err' })
                }
            }
            $log = $logs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($log) {
                $lines = Get-Content $log.FullName -Tail 400
                $start = 0
                for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match 'Initializing buffer pool') { $start = [Math]::Max(0, $i - 10); break } }
                $tail = ($lines[$start..($lines.Count - 1)]) -join "`n"
                if     ($tail -match 'Aria engine|Aria recovery failed|aria_log') { $hint += '. Its log shows an ARIA fault - needs an aria_chk repair, do not delete files' }
                elseif ($tail -match 'MLOG_CHECKPOINT')                  { $hint += '. Its log shows an InnoDB redo-log fault - do NOT delete ib_logfile*' }
                elseif ($tail -match 'multi master|master info')         { $hint += '. Its log shows a corrupt multi-master.info' }
                elseif ($tail -match 'must be writable')                 { $hint += '. ibdata1 is locked - another MySQL still running?' }
                elseif ($tail -match 'got exception')                    { $hint += '. Its log shows MySQL crashed' }
                elseif ($tail -match 'Do you already have another|bind on TCP/IP port') { $hint += '. Its port is taken by another program' }
                $hint += " (log: $($log.FullName))"
            }
            Add-Result 'FAIL' $label $hint
        }
    }

    # ------------------------------------------------------------ web server
    $web = @()
    foreach ($p in @(Get-Process httpd, nginx, php, php-cgi, caddy -ErrorAction SilentlyContinue)) {
        $ports = Get-ListenPorts $p.Id
        if ($ports.Count -gt 0) {
            $web += [pscustomobject]@{ Name = $p.ProcessName; Ports = ($ports -join ', '); Path = $p.Path }
        }
    }
    $web = @($web | Sort-Object Name, Ports -Unique)
    if ($web.Count -gt 0) {
        $desc = ($web | ForEach-Object { "$($_.Name) on :$($_.Ports)" }) -join '; '
        Add-Result 'OK' 'web server' $desc
    } else {
        $hint = 'none running - start Apache (XAMPP/Laragon) or: php artisan serve'
        $bat = Get-ChildItem $Repo -Filter 'start-apache.bat' -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bat) { $hint = "none running - run $($bat.FullName.Substring($Repo.Length + 1))" }
        Add-Result 'WARN' 'web server' $hint
    }

    # ------------------------------------------------------------ artisan smoke test
    if ($php -and (Test-Path (Join-Path $Repo 'vendor\autoload.php'))) {
        $r = Invoke-Php $php.Path @('artisan', '--version')
        $first = ($r.Out | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        if ($r.Code -eq 0) {
            Add-Result 'OK' 'artisan' $first
        } else {
            $other = $null
            foreach ($alt in $phps) {
                if ($alt.Path -eq $php.Path) { continue }
                if ((Invoke-Php $alt.Path @('artisan', '--version')).Code -eq 0) { $other = $alt; break }
            }
            if ($other) { Add-Result 'FAIL' 'artisan' "fails with PHP $($php.Version) but works with PHP $($other.Version) ($($other.Path))" }
            else        { Add-Result 'FAIL' 'artisan' "app does not boot: $first" }
        }
    }
}

# ================================================================ OUTPUT
$problems = @($results | Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'INFO' })
if ($Quick -and $problems.Count -eq 0) { exit 0 }

$branch = (git -C $Repo rev-parse --abbrev-ref HEAD 2>$null)
Write-Host ''
Write-Host "Doctor - $Repo  (branch: $branch)" -ForegroundColor Cyan
$colors = @{ OK = 'Green'; INFO = 'Cyan'; FIX = 'Yellow'; WARN = 'Yellow'; FAIL = 'Red' }
foreach ($r in $results) {
    if ($Quick -and ($r.Status -eq 'OK' -or $r.Status -eq 'INFO')) { continue }
    Write-Host ('[{0,-4}] ' -f $r.Status) -ForegroundColor $colors[$r.Status] -NoNewline
    Write-Host ('{0,-20} {1}' -f $r.Name, $r.Msg)
}
Write-Host ''
if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { exit 1 }
exit 0
