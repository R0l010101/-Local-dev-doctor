# Local Dev Doctor

One command that checks a local **Laravel backend** and **React frontend** setup, tells you what is broken and how to fix it, and fixes the safe things for you. It detects each developer's own setup (PHP, Node, MySQL, web server, ports), so nothing is hardcoded to one machine.

Windows only (PowerShell 5.1, built into Windows).

## Install (once)

1. Copy or clone this folder anywhere, e.g. `C:\Users\<you>\tools\Local-dev-doctor`.
2. **Double-click `install.cmd`.**
3. When asked, type your project folders one per line (backend and frontend), then press Enter on an empty line.
4. Close all open terminals (and restart Claude Code).

## Use

Type `doctor` in any terminal: PowerShell, CMD, Git Bash. In Claude Code, type `!doctor`.

| Command | What it does |
|---|---|
| `doctor` | Inside a project folder: checks that project. Anywhere else: checks all your projects |
| `doctor -All` | Checks all your projects |
| `doctor -NoFix` | Report only, changes nothing |
| `doctor -Quick` | File checks only. Silent when everything is OK |
| `doctor -Path X` | Checks the project at X |

It also runs by itself after every `git checkout <branch>` (quick mode, silent when OK).

## Reading the result

| Tag | Meaning | What to do |
|---|---|---|
| `[OK  ]` | Fine | Nothing |
| `[INFO]` | Information (versions, URLs, ports) | Nothing |
| `[FIX ]` | Was broken, **already fixed** | Refresh / restart and try again |
| `[WARN]` | Needs a simple action | Run the command it shows |
| `[FAIL]` | Broken, not safe to fix automatically | Follow the hint |

## What it checks

**Laravel backend**
- `.env`: missing (copies `.env.example`), or a line that lost its `#` (fixes it, backup first)
- Core `config/*.php` missing, e.g. `database.php`: restores from git, or copies its template (`database_*.php`, `database.example.php`, ...)
- `storage/` and `bootstrap/cache` folders missing: creates them
- Stale `bootstrap/cache` from another branch (classes that don't exist): moves it to `bootstrap/cache/_stale/`
- `vendor`, `APP_KEY`, Passport keys
- PHP: finds the version the project needs (`composer.json`) among all PHP installs
- Database: connects with the `.env` credentials. If MySQL is down, reads its error log and names the fault
- Web server and a final `php artisan --version`

**React frontend**
- Env file missing: copies the template (`.env.example`, `.env.development.copy`, ...)
- The same env variable set twice with different values
- `node_modules` out of date with `package-lock.json` (typical after a branch switch)
- Node version vs. `.nvmrc` / `engines`, and Node 17+ with react-scripts 4 (`ERR_OSSL_EVP_UNSUPPORTED`)
- `REACT_APP_*_URL` / `VITE_*_URL`: is the backend it points to actually running?
- Dev server running or not

## Safety

- Never deletes or overwrites files. Fixes copy, move aside, or back up first.
- Never writes to a database, and never connects to a remote one.
- The git hooks are local only (husky hooks are excluded via `.git/info/exclude`), so nothing gets committed.
- `projects.txt` (your project list) is git-ignored.

## Ano ang ginagawa nito? (Tagalog)

Ang **Local Dev Doctor** ay parang "check-up" ng local setup mo. Kapag may kakaiba sa app, gaya ng matagal na login, CORS error, 500 error, o blangkong page, i-type mo lang ang `doctor`. Sa loob ng ilang segundo, sasabihin nito kung **ano ang sira, bakit, at paano ayusin**. Kung ligtas ayusin, **aayusin na nito para sa iyo**.

Hindi ito naka-hardcode sa isang computer. Kusa nitong inaalam ang setup ng bawat dev: aling PHP at Node ang naka-install, saang port ang MySQL, at kung anong web server ang tumatakbo.

### Sa backend (Laravel)

| Sinusuri | Kapag may problema |
|---|---|
| `.env` | Kung wala, kinokopya ang `.env.example`. Kung may linyang nawalan ng `#`, inaayos ito (may backup) |
| `config/database.php` at iba pang config | Kung nawala, ibinabalik mula sa git o kinokopya ang template (hal. `database_sean.php`) |
| `storage/` at `bootstrap/cache` folders | Kung kulang, ginagawa ang mga ito |
| Lumang cache mula sa ibang branch | Inililipat sa `bootstrap/cache/_stale/`, ang madalas na dahilan ng matagal na login |
| PHP version | Hinahanap ang PHP na kailangan ng project mula sa lahat ng naka-install |
| MySQL | Sinusubukang kumonekta. Kung patay, binabasa ang error log at sinasabi ang dahilan |
| Web server at `php artisan` | Sinusuri kung tumatakbo at kung nagbu-boot ang app |

### Sa frontend (React)

| Sinusuri | Kapag may problema |
|---|---|
| Env file (`.env.development`) | Kung wala, kinokopya ang template |
| Parehong setting na dalawang beses naka-set | Binabalaan ka kung alin ang talagang gagamitin |
| `node_modules` | Sinasabi kung kailangan mong mag-`npm install` pagkatapos magpalit ng branch |
| Node version | Binabalaan ka kung masyadong bago ang Node para sa project |
| `REACT_APP_BASE_URL` | Sinusuri kung tumatakbo ba talaga ang backend na tinuturo ng FE |

### Kusa ring tumatakbo

Tuwing magpapalit ka ng branch (`git checkout`), kusa itong magche-check. **Wala itong ipapakita kung maayos ang lahat.**

### Ligtas ito

- Walang binubura o ino-overwrite. Lahat ng ayos ay kinokopya, inililipat, o may backup.
- Hindi nito ginagalaw ang database, at hindi ito kumokonekta sa remote server.
- Walang nasasama sa commit ninyo.

### Paano gamitin

1. **I-install (isang beses):** i-double-click ang `install.cmd`, ilagay ang folder ng backend at frontend mo, tapos Enter sa blangkong linya.
2. **Gamitin:** i-type ang `doctor` sa kahit anong terminal (sa Claude Code: `!doctor`).
3. **Basahin:** `[OK]` = maayos. `[FIX]` = naayos na. `[WARN]`/`[FAIL]` = sundin ang nakasulat.
