# Nomad Agent — Windows (Python CLI via uv)
# Continue (не Stop): нативные команды (git/uv/python) пишут в stderr → под Stop = NativeCommandError и падение.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_verify.ps1')  # Confirm-HmArtifact (fail-closed SHA-256 против checksums.json)
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                (Join-Path $env:USERPROFILE '.local\bin')
}
Update-Path
$DRY = [bool]$env:HM_DRY_RUN

# 1. Источник Nomad: офлайн vendor (HM_NOMAD_SRC) → git repoUrl из config.json → graceful skip
$src = $env:HM_NOMAD_SRC
$repoConfigured = $false   # был ли реально задан repoUrl (тогда clone обязан был сработать)
if (-not ($src -and (Test-Path (Join-Path $src 'pyproject.toml')))) {
    $repo = ''
    $cfg = Join-Path $PSScriptRoot '..\..\config.json'
    if (Test-Path $cfg) {
        try { $repo = (Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).nomad.repoUrl } catch {}
    }
    if ($repo) {
        $repoConfigured = $true
        $src = Join-Path $env:LOCALAPPDATA 'nomad-src'
        Write-Host "Клонирую Nomad из $repo ..."
        if ($DRY) {
            Write-Host "  [dry-run] WOULD: git clone --depth 1 $repo $src (or pull if exists)"
        } else {
            if (Test-Path (Join-Path $src '.git')) { git -C $src pull --ff-only }
            else { git clone --depth 1 $repo $src }
        }
    }
}
# repoUrl был задан, но источник так и не появился — это НАСТОЯЩИЙ провал: честный выход 1.
if (-not $DRY -and $repoConfigured -and -not ($src -and (Test-Path (Join-Path $src 'pyproject.toml')))) {
    Write-Host "ОШИБКА: источник Nomad не склонировался (git clone/pull упал или pyproject.toml не появился) — смотри лог выше."
    exit 1
}
if (-not $DRY -and -not ($src -and (Test-Path (Join-Path $src 'pyproject.toml')))) {
    Write-Host "Источник Nomad не найден. Вшей vendor/nomad-src (см. tools/fetch-vendor.ps1) или задай nomad.repoUrl в config.json. Пропускаю."
    exit 0
}
if ($DRY -and (-not $src)) {
    Write-Host "  [dry-run] Источник Nomad не задан — продолжаем dry-run preview секций 2-5."
}

# 2. uv — менеджер Python. FAIL-CLOSED, БЕЗ `irm | iex`.
#    Раньше: `Invoke-RestMethod astral.sh/uv/install.ps1 | Invoke-Expression` — неверифицированный
#    сетевой код, обходивший наш инвариант целостности вшитых установщиков (Confirm-HmArtifact).
#    Теперь: системный uv → вшитый uv.zip (SHA-256 против checksums.json) → стоп. Удалённый код не исполняется.
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    $uvZip = if ($env:HM_VENDOR) { Join-Path $env:HM_VENDOR 'apps\uv-x86_64-pc-windows-msvc.zip' } else { '' }
    if ($uvZip -and (Test-Path $uvZip)) {
        Write-Host "Устанавливаю uv из встроенного пакета (офлайн, verified)..."
        if ($DRY) { Write-Host "  [dry-run] WOULD: Confirm-HmArtifact $uvZip; Expand-Archive → ~\.local\bin (uv.exe, uvx.exe)" }
        else {
            Confirm-HmArtifact $uvZip                 # fail-closed SHA-256 → exit 1 при несовпадении
            $uvTmp  = Join-Path $env:TEMP ('nomad-uv-' + [Guid]::NewGuid().ToString('N'))
            $binDir = Join-Path $env:USERPROFILE '.local\bin'
            New-Item -ItemType Directory -Force $uvTmp, $binDir | Out-Null
            try {
                Expand-Archive -Path $uvZip -DestinationPath $uvTmp -Force
                foreach ($exe in @('uv.exe','uvx.exe')) {
                    $found = Get-ChildItem -Path $uvTmp -Recurse -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { Copy-Item $found.FullName (Join-Path $binDir $exe) -Force }
                }
            } finally { Remove-Item -Recurse -Force $uvTmp -ErrorAction SilentlyContinue }
            Update-Path
            if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Write-Host "БЕЗОПАСНОСТЬ: вшитый uv распаковался, но не запустился. Останавливаюсь."; exit 1 }
        }
    } else {
        Write-Host "БЕЗОПАСНОСТЬ: uv не найден в системе и не вшит ($uvZip отсутствует)."
        Write-Host "  Онлайн-установка через 'irm | iex' отключена намеренно (fail-closed: не исполняем неверифицированный сетевой код)."
        Write-Host "  Реши так: пересобери vendor (powershell -File tools\fetch-vendor.ps1 — он вошьёт verified uv), либо установи uv вручную: https://docs.astral.sh/uv/getting-started/installation/"
        if (-not $DRY) { exit 1 }
    }
    Update-Path
}

# 3. Python 3.12 (pyproject требует <3.14) + установка nomad (команды nomad/nmd/hermes)
if ($DRY) {
    Write-Host "  [dry-run] WOULD: uv python install 3.12; uv tool install --python 3.12 --force `"$src`""
} else {
    uv python install 3.12
    Write-Host "Устанавливаю Nomad (команды nomad/nmd/hermes)..."
    uv tool install --python 3.12 --force "$src"
    Update-Path
}

# 4. Брендинг + профиль Nomad (plugins/nomad, skills, mcp-servers) + сид config.yaml → HERMES_HOME
$hh = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA 'hermes' }
$cfgY = Join-Path $hh 'config.yaml'
if (-not $DRY) {
    New-Item -ItemType Directory -Force -Path $hh, (Join-Path $hh 'skins'), (Join-Path $hh 'profiles\nomad'), (Join-Path $hh 'desktop-plugins\nomad'), (Join-Path $hh 'profiles\nomad\desktop-plugins\nomad') | Out-Null
    $profSrc = if ($env:HM_VENDOR) { Join-Path $env:HM_VENDOR 'nomad-profile' } else { '' }
    if ($profSrc -and (Test-Path (Join-Path $profSrc 'distribution.yaml'))) {
        Write-Host "Разворачиваю профиль Nomad (плагин, суверенные модели РФ, 11 коннекторов РФ, DLP 152-ФЗ, Бадди)..."
        & robocopy "$profSrc" (Join-Path $hh 'profiles\nomad') /E /NFL /NDL /NJH /NJS /NP | Out-Null
        & robocopy "$profSrc" "$hh" /E /NFL /NDL /NJH /NJS /NP | Out-Null
        $dpSrc = Join-Path $profSrc 'plugins\nomad\desktop'
        if (Test-Path $dpSrc) {
            & robocopy "$dpSrc" (Join-Path $hh 'desktop-plugins\nomad') /E /NFL /NDL /NJH /NJS /NP | Out-Null
            & robocopy "$dpSrc" (Join-Path $hh 'profiles\nomad\desktop-plugins\nomad') /E /NFL /NDL /NJH /NJS /NP | Out-Null
        }
        $global:LASTEXITCODE = 0
        Set-Content -Path (Join-Path $hh '.no-bundled-skills') -Value '' -Encoding UTF8
        Set-Content -Path (Join-Path $hh '.skip_upstream_prompt') -Value '' -Encoding UTF8
    }
    if ($src) {
        $soulSrc = Join-Path $src 'branding\SOUL.md'
        if (Test-Path $soulSrc) { Copy-Item $soulSrc (Join-Path $hh 'SOUL.md') -Force }
        else { Write-Host "  [warn] branding\SOUL.md не найден — пропускаю" }
        $nomadYamlSrc = Join-Path $src 'branding\skins\nomad.yaml'
        if (Test-Path $nomadYamlSrc) { Copy-Item $nomadYamlSrc (Join-Path $hh 'skins\nomad.yaml') -Force }
        else { Write-Host "  [warn] branding\skins\nomad.yaml не найден — пропускаю" }
        if (-not (Test-Path $cfgY)) {
            $cfgTmpl = Join-Path $src 'branding\config.yaml.template'
            if (Test-Path $cfgTmpl) { Copy-Item $cfgTmpl $cfgY -Force }
            else { Write-Host "  [warn] branding\config.yaml.template не найден — создам config.yaml с нуля" }
        }
    }
}

# 5. Nomad Cloud (cp.nomadnet.ai) — доступ к ИИ-моделям через облако владельца.
#    OpenAI-совместимый custom-провайдер: config.yaml model.provider=custom +
#    base_url + api_key + default. Ключ — ТОЛЬКО ключ друга из кабинета, ключ
#    владельца нигде не зашит. Идемпотентно (управляемый блок между маркерами).
$cloudKey   = if ($env:HM_NOMAD_CLOUD_KEY)     { ($env:HM_NOMAD_CLOUD_KEY).Trim() }     else { '' }
$cloudUrl   = if ($env:HM_NOMAD_CLOUD_BASEURL) { ($env:HM_NOMAD_CLOUD_BASEURL).Trim() } else { 'https://cp.nomadnet.ai/v1' }
$cloudModel = if ($env:HM_NOMAD_CLOUD_MODEL)   { ($env:HM_NOMAD_CLOUD_MODEL).Trim() }   else { 'nomadnet-auto' }
if (-not $cloudKey) {
    Write-Host "Ключ Nomad Cloud не задан — облачный блок НЕ пишу (graceful). Настрой позже: nomad model → custom endpoint $cloudUrl."
} else {
    # Значения уходят в YAML в двойных кавычках — вычищаем кавычки/переводы строк.
    $keySan   = ($cloudKey   -replace '["\r\n]', '')
    $urlSan   = ($cloudUrl   -replace '["\r\n]', '')
    $modelSan = ($cloudModel -replace '["\r\n]', '')
    if ($DRY) {
        Write-Host "  [dry-run] WOULD: в $cfgY вписать model.provider=custom base_url=$urlSan default=$modelSan api_key=<скрыт>"
    } else {
        $text = ''
        if (Test-Path $cfgY) { $text = [IO.File]::ReadAllText($cfgY, [Text.Encoding]::UTF8) }
        # (1) снять ранее вписанный управляемый блок — идемпотентность
        $text = [regex]::Replace($text, '(?sm)^# >>> nomad-cloud.*?# <<< nomad-cloud <<<\r?\n?', '')
        # (2) снять существующий top-level блок model: (шаблонный provider:auto или прежний custom)
        $text = [regex]::Replace($text, '(?m)^model:[ \t]*\r?\n(?:(?:[ \t].*\r?\n)|(?:[ \t]*\r?\n))*', '')
        # (3) вписать управляемый блок в НАЧАЛО файла
        $nl = "`r`n"
        $block = '# >>> nomad-cloud (managed by installer -- do not edit inside markers) >>>' + $nl +
                 'model:' + $nl +
                 '  provider: "custom"' + $nl +
                 '  base_url: "' + $urlSan + '"' + $nl +
                 '  api_key: "' + $keySan + '"' + $nl +
                 '  default: "' + $modelSan + '"' + $nl +
                 '# <<< nomad-cloud <<<' + $nl
        $text = $block + $text
        # config.yaml — данные: пишем БЕЗ BOM (BOM ломает YAML-парсер).
        [IO.File]::WriteAllText($cfgY, $text, (New-Object Text.UTF8Encoding $false))
        Write-Host "OK: Nomad подключён к облаку $urlSan (модель $modelSan). Ключ записан в config.yaml."
    }
}

if ($DRY) { Write-Host "[dry-run] Nomad preview завершён."; exit 0 }
Update-Path
if (Get-Command nomad -ErrorAction SilentlyContinue) {
    Write-Host "OK: nomad установлен ($((nomad --version 2>&1 | Select-Object -First 1)))"; exit 0
}
if (Test-Path (Join-Path $env:USERPROFILE '.local\bin\nomad.exe')) {
    Write-Host "OK: nomad в ~/.local/bin — появится в PATH после перезапуска терминала."; exit 0
}
Write-Host "ОШИБКА: Nomad не установился — смотри лог выше."
exit 1
