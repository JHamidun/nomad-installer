# Build-time: собрать vendor/ для ПОЛНОСТЬЮ ОФЛАЙН установки Nomad (Windows).
# Кладёт: (1) офлайн-установщик Git; (2) исходник Nomad (git archive merged-кода) в vendor/nomad-src;
# (3) checksums.json (fail-closed SHA-256 для вшитых установщиков).
# Идемпотентно: уже скачанные файлы пропускаются; nomad-src переархивируется всегда (свежий код).
# Continue (not Stop): нативные команды (git/tar) пишут в stderr — под Stop это рушит скрипт.
# Запуск: npm run fetch:vendor  (или powershell -File tools/fetch-vendor.ps1)
$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $PSScriptRoot
$apps  = Join-Path $root 'vendor\apps'
New-Item -ItemType Directory -Force $apps | Out-Null
$UA = @{ 'User-Agent' = 'nomad-setup' }

function Dl($url, $out) {
  if (Test-Path $out) { Write-Host "  skip $([IO.Path]::GetFileName($out))"; return }
  try { Write-Host "  GET  $url"; Invoke-WebRequest $url -OutFile $out -MaximumRedirection 6 -UseBasicParsing }
  catch { Write-Host "  ! не скачалось ($([IO.Path]::GetFileName($out))): $($_.Exception.Message)" }
}

# ── 1. Git for Windows (офлайн-установщик; нужен для чекпоинтов Nomad и как фолбэк) ──
Write-Host "[vendor] Git for Windows..."
try {
  $rel = Invoke-RestMethod "https://api.github.com/repos/git-for-windows/git/releases/latest" -Headers $UA
  $a = $rel.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1
  if ($a) { Dl $a.browser_download_url (Join-Path $apps 'git-setup.exe') }
} catch { Write-Host "  ! GitHub API недоступен — git уйдёт в winget/онлайн-фолбэк при установке" }

# ── 1b. uv (менеджер Python, standalone) → vendor\apps (офлайн; verified при установке) ──
# Install-скрипт (scripts/windows/nomad.ps1) ставит uv ТОЛЬКО из этого вшитого архива с
# fail-closed SHA-256 (Confirm-HmArtifact) — никакого `irm … | iex`. Версия: HM_UV_VERSION или latest с GitHub.
Write-Host "[vendor] uv (standalone) → vendor\apps..."
$uvVer = $env:HM_UV_VERSION
if (-not $uvVer) {
  try { $uvVer = (Invoke-RestMethod "https://api.github.com/repos/astral-sh/uv/releases/latest" -Headers $UA).tag_name } catch { $uvVer = $null }
}
if ($uvVer) {
  Write-Host "  uv $uvVer"
  Dl "https://github.com/astral-sh/uv/releases/download/$uvVer/uv-x86_64-pc-windows-msvc.zip" (Join-Path $apps 'uv-x86_64-pc-windows-msvc.zip')
} else {
  Write-Host "  ! не удалось определить версию uv (GitHub API недоступен) — задай HM_UV_VERSION. uv не вшит → установка uv у пользователя fail-closed (стоп с инструкцией)."
}

# ── 2. Исходник Nomad: git archive merged-кода → vendor/nomad-src (tracked-файлы, БЕЗ .git) ──
# Друзьям не нужен доступ к репозиторию: код едет офлайн внутри установщика.
# main агента = смердженный phase2-код (на момент сборки — коммит 184fbe412).
$agentRepo = if ($env:HM_NOMAD_AGENT_REPO) { $env:HM_NOMAD_AGENT_REPO } else { 'D:\Nomad\hamidun-agent' }
$ref       = if ($env:HM_NOMAD_REF)        { $env:HM_NOMAD_REF }        else { 'main' }
$srcOut    = Join-Path $root 'vendor\nomad-src'
Write-Host "[vendor] Исходник Nomad: git archive $ref из $agentRepo → vendor\nomad-src ..."
if (-not (Test-Path (Join-Path $agentRepo '.git'))) {
  Write-Host "  ! репозиторий Nomad не найден ($agentRepo) — задай HM_NOMAD_AGENT_REPO. nomad-src НЕ вшит: установка Nomad упадёт."
} else {
  $resolved = (& git -C $agentRepo rev-parse --short $ref 2>$null)
  Write-Host "  ref $ref → коммит $resolved"
  $tmpTar = Join-Path $env:TEMP 'nomad-src.tar'
  if (Test-Path $tmpTar) { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue }
  # git archive пишет корректный tar (пайп в PowerShell портит бинарь → используем --output).
  & git -C $agentRepo archive --format=tar --output "$tmpTar" $ref
  if ((Test-Path $tmpTar) -and ((Get-Item $tmpTar).Length -gt 0)) {
    if (Test-Path $srcOut) { Remove-Item -Recurse -Force $srcOut -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force $srcOut | Out-Null
    # Нативный Windows tar.exe (bsdtar) — понимает C:\ пути. НЕ msys /usr/bin/tar,
    # который трактует "-f C:\..." как remote host ("Cannot connect to C:").
    & "$env:SystemRoot\System32\tar.exe" -x -f "$tmpTar" -C "$srcOut"
    Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $srcOut 'pyproject.toml')) {
      $mb = [math]::Round(((Get-ChildItem $srcOut -Recurse -File | Measure-Object Length -Sum).Sum)/1MB, 0)
      Write-Host "  ok vendor\nomad-src ($mb МБ, pyproject.toml на месте)"
    } else {
      Write-Host "  ! в vendor\nomad-src нет pyproject.toml — архив пустой/битый. Установка Nomad упадёт."
    }
  } else {
    Write-Host "  ! git archive не создал tar — nomad-src НЕ вшит."
  }
}

# ── 2b. Деперсонализация nomad-src (fail-closed): denylist → scrub → leak-gate ──
# (a) tools/nomad-src-denylist.txt — вырезает внутренние dev/test-артефакты;
# (b) tools/scrub-vendor.py — переписывает personal-identity токены на нейтральные;
# (c) tools/leak-gate.py — если остался хоть один деанон-маркер, СБОРКА ПАДАЕТ.
if (Test-Path (Join-Path $srcOut 'pyproject.toml')) {
  Write-Host "[vendor] Деперсонализация vendor\nomad-src (denylist → scrub → leak-gate)..."
  & python (Join-Path $root 'tools\scrub-vendor.py') $srcOut --denylist (Join-Path $root 'tools\nomad-src-denylist.txt')
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[vendor] FATAL: scrub-vendor.py упал — сборка остановлена (fail-closed)."
    exit 1
  }
  & python (Join-Path $root 'tools\leak-gate.py') $srcOut --allow nomad --allow Nomad
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[vendor] FATAL: leak-gate нашёл деанон-маркеры в vendor\nomad-src — exe с личными данными НЕ собираем."
    Write-Host "[vendor] Расширь tools\nomad-src-denylist.txt или правила tools\scrub-vendor.py и перезапусти."
    exit 1
  }
}

# ── 2c. Профиль Nomad (plugins/nomad, skills, mcp-servers, desktop UI) → vendor\nomad-profile ──
$profRepo = if ($env:HM_NOMAD_PROFILE_DIR) { $env:HM_NOMAD_PROFILE_DIR } else { 'D:\Nomad\nomad-overlay\package' }
$profOut  = Join-Path $root 'vendor\nomad-profile'
if (Test-Path (Join-Path $profRepo 'distribution.yaml')) {
  Write-Host "[vendor] Профиль Nomad из $profRepo → vendor\nomad-profile..."
  New-Item -ItemType Directory -Force $profOut | Out-Null
  & robocopy "$profRepo" "$profOut" /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
  $global:LASTEXITCODE = 0
}

# ── 3. checksums.json — SHA-256 всех вшитых установщиков (fail-closed целостность) ──
Write-Host "[vendor] checksums.json — SHA-256 файлов vendor\apps..."
try {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $entries = New-Object System.Collections.ArrayList
  Get-ChildItem $apps -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 } | Sort-Object Name | ForEach-Object {
    $fs = [IO.File]::OpenRead($_.FullName)
    try { $hb = $sha.ComputeHash($fs) } finally { $fs.Dispose() }
    $hex = ([BitConverter]::ToString($hb) -replace '-', '').ToLower()
    [void]$entries.Add('    "' + $_.Name + '": { "sha256": "' + $hex + '", "bytes": ' + $_.Length + ' }')
  }
  $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $json = "{`r`n  ""generatedAt"": ""$ts"",`r`n  ""algorithm"": ""sha256"",`r`n  ""files"": {`r`n" + ($entries -join ",`r`n") + "`r`n  }`r`n}`r`n"
  [IO.File]::WriteAllText((Join-Path $root 'vendor\checksums.json'), $json)
  Write-Host ("  файлов захешировано: {0}" -f $entries.Count)
} catch { Write-Host "  ! checksums.json не сгенерирован - $($_.Exception.Message)" }

# ── 4. Проверка полноты vendor ──
Write-Host "[vendor] Проверка полноты..."
$missing = @()
$gitExe = Get-Item (Join-Path $apps 'git-setup.exe') -ErrorAction SilentlyContinue
if (-not $gitExe -or $gitExe.Length -eq 0) { $missing += 'apps/git-setup.exe (git уйдёт в онлайн-фолбэк)' }
$uvZip = Get-Item (Join-Path $apps 'uv-x86_64-pc-windows-msvc.zip') -ErrorAction SilentlyContinue
if (-not $uvZip -or $uvZip.Length -eq 0) { $missing += 'apps/uv-x86_64-pc-windows-msvc.zip (без системного uv установка Nomad остановится fail-closed)' }
if (-not (Test-Path (Join-Path $srcOut 'pyproject.toml'))) {
  Write-Host "[vendor] FATAL: нет vendor\nomad-src\pyproject.toml — исходник Nomad не вшит. Установка Nomad упадёт у пользователя."
  Write-Host "[vendor] Проверь HM_NOMAD_AGENT_REPO ($agentRepo) и HM_NOMAD_REF ($ref)."
  exit 1
}
if ($missing.Count -gt 0) {
  Write-Host "[vendor] WARNING: неполный vendor:"
  foreach ($m in $missing) { Write-Host "  - $m" }
} else {
  Write-Host "[vendor] OK: все ключевые артефакты на месте."
}

$total = (Get-ChildItem -Recurse -File (Join-Path $root 'vendor') | Measure-Object Length -Sum).Sum
Write-Host ("[vendor] ГОТОВО — vendor\ весит {0:N0} МБ" -f ($total/1MB))
