<#
  Local Dev Doctor - health check for local Laravel (backend) and React (frontend) projects.
  Detects each developer's own setup instead of assuming fixed paths, and fixes missing files.

  Usage:
    doctor            inside a project folder: check that project
                      anywhere else: check every project listed in projects.txt
    doctor -All       check every project in projects.txt
    doctor -NoFix     report only, change nothing
    doctor -Quick     file checks only, prints nothing when all OK (used by the git hook)
    doctor -Path X    check the project at X

  Optional override: set DOCTOR_PHP to the php.exe to use.

  Laravel auto-fixes (never deletes, never overwrites):
    - .env missing -> copy .env.example;  .env line without # or = -> add '#' (backup first)
    - core config/<name>.php missing -> restore from git, or copy its single template
      (<name>_*.php, <name>.example.php, <name>.php.example, <name>.php.dist)
    - storage / bootstrap\cache folders missing -> create
    - stale bootstrap cache (classes that don't exist) -> move to bootstrap\cache\_stale\<stamp>
  React auto-fixes:
    - no env file at all -> copy the template (.env.example, .env.development.copy, ...)
  Everything else (PHP, Node, database, servers, packages) is reported with the command to run.
#>
param(
    [Alias('Repo')][string]$Path,
    [switch]$All,
    [switch]$NoFix,
    [switch]$Quick
)

$ToolDir      = $PSScriptRoot
$ProjectsFile = Join-Path $ToolDir 'projects.txt'
$Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'

# ================================================================ helpers

function Add-Result($status, $name, $msg) {
    [void]$script:results.Add([pscustomobject]@{ Status = $status; Name = $name; Msg = $msg })
}

function Get-EnvValue($lines, $key) {
    foreach ($l in $lines) {
        if ($l -match "^\s*$key\s*=\s*(.*?)\s*$") { return $Matches[1].Trim('"', "'") }
    }
    return $null
}

function Get-ProjectType($dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    if (Test-Path (Join-Path $dir 'artisan')) { return 'Laravel' }
    $pkgPath = Join-Path $dir 'package.json'
    if (Test-Path $pkgPath) {
        $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
        if (($pkg.dependencies -and $pkg.dependencies.react) -or ($pkg.devDependencies -and $pkg.devDependencies.react)) { return 'React' }
    }
    return $null
}

# Port -> listening process, built once.
$script:listeners = $null
function Get-Listener($port) {
    if ($null -eq $script:listeners) {
        $script:listeners = @{}
        foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
            if (-not $script:listeners.ContainsKey([int]$c.LocalPort)) {
                $script:listeners[[int]$c.LocalPort] = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            }
        }
    }
    if ($script:listeners.ContainsKey([int]$port)) { return $script:listeners[[int]$port] }
    return $null
}
function Test-Listening($port) {
    Get-Listener $port | Out-Null
    return $script:listeners.ContainsKey([int]$port)
}

function Get-ListenPorts($procId) {
    @(Get-NetTCPConnection -OwningProcess $procId -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
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

# ================================================================ LARAVEL

function Test-Laravel {
    # ------------------------------------------------------------ .env
    $envPath = Join-Path $Repo '.env'
    $envExample = Join-Path $Repo '.env.example'
    $envFixed = $false
    if (-not (Test-Path $envPath)) {
        if ((Test-Path $envExample) -and -not $NoFix) {
            Copy-Item $envExample $envPath
            Add-Result 'FIX' '.env' 'was missing - copied from .env.example. Fill in your DB settings, then: php artisan key:generate'
            $envFixed = $true
        } else {
            Add-Result 'FAIL' '.env' 'missing (copy .env.example to .env and fill it in)'
        }
    }
    $script:envLines = @()
    if (Test-Path $envPath) {
        $bytes  = [IO.File]::ReadAllBytes($envPath)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text   = (New-Object Text.UTF8Encoding $false).GetString($bytes)
        if ($hasBom) { $text = $text.Substring(1) }
        $lines = $text -split "`n"             # each line keeps its trailing `r
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
        } elseif (-not $envFixed) {
            Add-Result 'OK' '.env' 'present, no broken lines'
        }
        $script:envLines = Get-Content $envPath
    }
    $envLines = $script:envLines

    # ------------------------------------------------------------ core config files
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

    # ------------------------------------------------------------ runtime folders
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

    # ------------------------------------------------------------ stale bootstrap cache
    $cacheDir   = Join-Path $Repo 'bootstrap\cache'
    $cacheFiles = @('config.php', 'routes-v7.php', 'routes.php', 'services.php') |
                  Where-Object { Test-Path (Join-Path $cacheDir $_) }
    if ($cacheFiles.Count -eq 0) {
        Add-Result 'OK' 'bootstrap cache' 'not cached (Laravel reads source)'
    } else {
        $pattern = 'App\\{1,2}(?:Providers|Http\\{1,2}Controllers)\\{1,2}[A-Za-z0-9_\\]*[A-Za-z0-9_]'
        $missing = @()
        foreach ($f in $cacheFiles) {
            $text = [IO.File]::ReadAllText((Join-Path $cacheDir $f))
            $classes = [regex]::Matches($text, $pattern) | ForEach-Object { $_.Value -replace '\\\\', '\' } | Sort-Object -Unique
            foreach ($c in $classes) {
                if (-not (Test-Path (Join-Path $Repo (($c -replace '^App\\', 'app\') + '.php')))) { $missing += $c }
            }
        }
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

    if ($Quick) { return }

    # ------------------------------------------------------------ vendor / APP_KEY / Passport
    $composer = $null
    $composerPath = Join-Path $Repo 'composer.json'
    if (Test-Path $composerPath) { $composer = Get-Content $composerPath -Raw | ConvertFrom-Json }
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
        $srv = Get-Listener $dbPort
        $servers = @(Get-Process mysqld, mariadbd -ErrorAction SilentlyContinue)

        if (Test-Listening $dbPort) {
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
            $ports = Get-ListenPorts $servers[0].Id
            if ($ports.Count -gt 0) {
                Add-Result 'FAIL' $label "MySQL is running but on port $($ports -join ', '), while .env says DB_PORT=$dbPort"
            } else {
                Add-Result 'WARN' $label 'MySQL is starting - probably crash recovery. Wait 1-2 minutes, do not kill it'
            }
        } else {
            # not running: read the newest error log of any local install
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
        if ($ports.Count -gt 0) { $web += [pscustomobject]@{ Name = $p.ProcessName; Ports = ($ports -join ', ') } }
    }
    $web = @($web | Sort-Object Name, Ports -Unique)
    if ($web.Count -gt 0) {
        Add-Result 'OK' 'web server' (($web | ForEach-Object { "$($_.Name) on :$($_.Ports)" }) -join '; ')
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

# ================================================================ REACT

function Test-React {
    $pkg = Get-Content (Join-Path $Repo 'package.json') -Raw | ConvertFrom-Json
    $allDeps = @{}
    foreach ($section in @($pkg.dependencies, $pkg.devDependencies)) {
        if ($section) { foreach ($p in $section.PSObject.Properties) { $allDeps[$p.Name] = $p.Value } }
    }
    $isVite = $allDeps.ContainsKey('vite')

    # ------------------------------------------------------------ env files
    $envOrder = '.env.development.local', '.env.local', '.env.development', '.env'   # npm start priority
    $present = @($envOrder | Where-Object { Test-Path (Join-Path $Repo $_) })
    if ($present.Count -eq 0) {
        $tpl = @('.env.development.example', '.env.example', '.env.sample', '.env.dist',
                 '.env.development.copy', '.env.copy') | Where-Object { Test-Path (Join-Path $Repo $_) } | Select-Object -First 1
        if ($tpl) {
            $target = $tpl -replace '\.(example|sample|dist|copy)$', ''
            if ($NoFix) {
                Add-Result 'FAIL' 'env file' "none found (copy $tpl to $target)"
            } else {
                Copy-Item (Join-Path $Repo $tpl) (Join-Path $Repo $target)
                Add-Result 'FIX' 'env file' "none found - copied $tpl to $target. Check the values inside"
                $present = @($target)
            }
        } else {
            Add-Result 'WARN' 'env file' 'none found and no template - ask a teammate for their .env.development'
        }
    } else {
        Add-Result 'OK' 'env file' ($present -join ', ')
    }

    # effective values: the first file in priority order wins; inside one file the last line wins
    $effective = @{}
    $dupes = @()
    foreach ($name in $envOrder) {
        $file = Join-Path $Repo $name
        if (-not (Test-Path $file)) { continue }
        $vals = @{}
        foreach ($l in Get-Content $file) {
            if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                $k = $Matches[1]; $v = $Matches[2].Trim('"', "'")
                if ($vals.ContainsKey($k) -and $vals[$k] -ne $v) { $dupes += "$k in $name" }
                $vals[$k] = $v
            }
        }
        foreach ($k in $vals.Keys) {
            if (-not $effective.ContainsKey($k)) { $effective[$k] = @{ Value = $vals[$k]; File = $name } }
        }
    }
    if ($dupes.Count -gt 0) {
        Add-Result 'WARN' 'env duplicates' "set twice with different values (the LAST line wins): $(($dupes | Select-Object -Unique) -join '; ')"
    }

    # ------------------------------------------------------------ node_modules up to date?
    $pm = 'npm'
    if (Test-Path (Join-Path $Repo 'yarn.lock')) { $pm = 'yarn' }
    if (Test-Path (Join-Path $Repo 'pnpm-lock.yaml')) { $pm = 'pnpm' }
    if ((Test-Path (Join-Path $Repo 'yarn.lock')) -and (Test-Path (Join-Path $Repo 'package-lock.json'))) {
        Add-Result 'WARN' 'lock files' 'both package-lock.json and yarn.lock exist - the team should use one'
    }
    $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not (Test-Path (Join-Path $Repo 'node_modules'))) {
        Add-Result 'FAIL' 'packages' "node_modules missing - run: $pm install"
    } elseif ($node) {
        $probe = Join-Path $env:TEMP 'doctor-deps-probe.js'
        Set-Content $probe -Encoding ASCII -Value @'
const fs = require('fs'), path = require('path');
const root = process.argv[2];
const read = f => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return null; } };
const pkg = read(path.join(root, 'package.json')) || {};
const lock = read(path.join(root, 'package-lock.json'));
const deps = Object.assign({}, pkg.dependencies, pkg.devDependencies);
const out = [];
for (const n of Object.keys(deps)) {
  const inst = read(path.join(root, 'node_modules', n, 'package.json'));
  if (!inst) { out.push(n + ' (not installed)'); continue; }
  let want = null;
  if (lock && lock.packages && lock.packages['node_modules/' + n]) want = lock.packages['node_modules/' + n].version;
  else if (lock && lock.dependencies && lock.dependencies[n]) want = lock.dependencies[n].version;
  if (want && want !== inst.version) out.push(n + ' ' + inst.version + ' -> ' + want);
}
console.log(out.join('\n'));
'@
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $stale = @(& $node.Source $probe $Repo 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne '' })
        $ErrorActionPreference = $oldEap
        if ($stale.Count -eq 0) {
            Add-Result 'OK' 'packages' 'node_modules matches package-lock'
        } else {
            $list = ($stale | Select-Object -First 3) -join '; '
            if ($stale.Count -gt 3) { $list += " (+$($stale.Count - 3) more)" }
            Add-Result 'WARN' 'packages' "out of date after a branch switch? run: $pm install  [$list]"
        }
    }

    if ($Quick) { return }

    # ------------------------------------------------------------ Node version
    if (-not $node) {
        Add-Result 'FAIL' 'node' 'Node.js not found - install it (or nvm-windows)'
    } else {
        $ver = (& $node.Source -v).Trim()
        $major = [int](($ver -replace '^v', '').Split('.')[0])
        $wanted = $null
        foreach ($f in '.nvmrc', '.node-version') {
            $fp = Join-Path $Repo $f
            if (Test-Path $fp) { $wanted = (Get-Content $fp -TotalCount 1).Trim(); break }
        }
        if (-not $wanted -and $pkg.engines -and $pkg.engines.node) { $wanted = $pkg.engines.node }

        $rs = $null
        if ($allDeps.ContainsKey('react-scripts') -and ($allDeps['react-scripts'] -match '(\d+)')) { $rs = [int]$Matches[1] }

        if ($rs -and $rs -lt 5 -and $major -ge 17) {
            Add-Result 'FAIL' 'node' "Node $ver is too new for react-scripts $rs (npm start fails with ERR_OSSL_EVP_UNSUPPORTED) - use Node 16, or set NODE_OPTIONS=--openssl-legacy-provider"
        } elseif ($wanted -and ($wanted -match '(\d+)') -and ([int]$Matches[1] -ne $major) -and ($wanted -notmatch '[<>^~|]')) {
            Add-Result 'WARN' 'node' "$ver, but the project wants $wanted"
        } else {
            $msg = "$ver ($($node.Source))"
            if ($wanted) { $msg += " (project wants $wanted)" }
            Add-Result 'INFO' 'node' $msg
        }
    }

    # ------------------------------------------------------------ which backend does the FE call?
    $urlKeys = @($effective.Keys | Where-Object {
        $_ -match '^(REACT_APP|VITE)_\w*(BASE_URL|API_URL|API_BASE|BACKEND_URL|SERVER_URL)$' -and
        $effective[$_].Value -match '^https?://' } | Sort-Object)
    if ($urlKeys.Count -eq 0) {
        Add-Result 'INFO' 'backend URL' 'no REACT_APP_*/VITE_* URL setting found'
    }
    foreach ($k in $urlKeys) {
        $url = $effective[$k].Value
        $src = $effective[$k].File
        $uri = $null
        try { $uri = [Uri]$url } catch { }
        if (-not $uri) { Add-Result 'WARN' $k "not a valid URL: $url ($src)"; continue }
        if ($uri.Host -eq 'localhost' -or $uri.Host -eq '127.0.0.1') {
            $owner = Get-Listener $uri.Port
            if (Test-Listening $uri.Port) {
                $who = ''
                if ($owner) { $who = " - $($owner.ProcessName) is listening" }
                Add-Result 'OK' $k "$url ($src)$who"
            } else {
                Add-Result 'FAIL' $k "$url ($src) - nothing is listening on port $($uri.Port). Start the backend, or fix the port"
            }
        } else {
            Add-Result 'INFO' $k "REMOTE $url ($src)"
        }
    }

    # ------------------------------------------------------------ dev server
    $port = 3000
    if ($isVite) { $port = 5173 }
    if ($effective.ContainsKey('PORT') -and $effective['PORT'].Value -match '^\d+$') { $port = [int]$effective['PORT'].Value }
    if (Test-Listening $port) { Add-Result 'INFO' 'dev server' "running on :$port" }
    else                      { Add-Result 'INFO' 'dev server' "not running on :$port (start with: $pm start)" }
}

# ================================================================ which projects to check

$targets = @()
if ($Path) {
    $targets = @($Path)
} else {
    $here = (Get-Location).Path
    $top = git -C $here rev-parse --show-toplevel 2>$null
    if ($top) { $top = $top -replace '/', '\' }
    if (-not $All -and (Get-ProjectType $here)) { $targets = @($here) }
    elseif (-not $All -and $top -and (Get-ProjectType $top)) { $targets = @($top) }
    elseif (Test-Path $ProjectsFile) {
        $targets = @(Get-Content $ProjectsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
}
if ($targets.Count -eq 0) {
    Write-Host 'No project to check. Run doctor inside a project folder, or run install.cmd to register your projects.' -ForegroundColor Yellow
    exit 1
}

$anyFail = $false
$printed = $false
$colors = @{ OK = 'Green'; INFO = 'Cyan'; FIX = 'Yellow'; WARN = 'Yellow'; FAIL = 'Red' }
foreach ($Repo in $targets) {
    $script:results = New-Object System.Collections.ArrayList
    $type = Get-ProjectType $Repo
    if     ($type -eq 'Laravel') { Test-Laravel }
    elseif ($type -eq 'React')   { Test-React }
    else {
        Add-Result 'FAIL' 'project' 'not found, or not a Laravel/React project'
    }

    if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { $anyFail = $true }
    $problems = @($results | Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'INFO' })
    if ($Quick -and $problems.Count -eq 0) { continue }

    $branch = ''
    if ($type) { $branch = (git -C $Repo rev-parse --abbrev-ref HEAD 2>$null) }
    $printed = $true
    Write-Host ''
    Write-Host "Doctor - $Repo  [$type]  (branch: $branch)" -ForegroundColor Cyan
    foreach ($r in $results) {
        if ($Quick -and ($r.Status -eq 'OK' -or $r.Status -eq 'INFO')) { continue }
        Write-Host ('[{0,-4}] ' -f $r.Status) -ForegroundColor $colors[$r.Status] -NoNewline
        Write-Host ('{0,-20} {1}' -f $r.Name, $r.Msg)
    }
}
if ($printed) { Write-Host '' }
if ($anyFail) { exit 1 }
exit 0
