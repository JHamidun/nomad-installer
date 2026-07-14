# Verify — финальная диагностика установки Nomad (Windows)
# Печатает строки вида "CHECK ok <ярлык>" / "CHECK fail <ярлык>" / "CHECK skip <ярлык>" —
# их ловит рендерер и рисует чеклист на финальном экране. Всегда exit 0 (диагностика не валит установку).
$ErrorActionPreference = 'Continue'
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' +
                (Join-Path $env:USERPROFILE '.local\bin')
}
Update-Path

# Список выбранных компонентов (id через запятую, из HM_SELECTED). Снятые компоненты → "skip".
$SelectedIds = @()
if ($env:HM_SELECTED) {
    $SelectedIds = $env:HM_SELECTED.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
function Test-Selected([string]$id) {
    if (-not $env:HM_SELECTED) { return $true }
    return ($SelectedIds -contains $id)
}

Write-Host "Финальная проверка установки Nomad..."

# --- Git ---
if (-not (Test-Selected 'git')) {
    Write-Host "CHECK skip Git"
} else {
    $gitOk = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try { $v = ("$(git --version 2>$null)").Trim(); if ($v) { Write-Host "  git: $v"; $gitOk = $true } } catch { }
    }
    if ($gitOk) { Write-Host "CHECK ok Git" } else { Write-Host "CHECK fail Git" }
}

# --- Nomad Agent (команда nomad или бинарь в ~/.local/bin) ---
if (-not (Test-Selected 'nomad')) {
    Write-Host "CHECK skip Nomad Agent"
} else {
    $nomadOk = $false
    if (Get-Command nomad -ErrorAction SilentlyContinue) {
        Write-Host "  nomad: $((Get-Command nomad).Source)"; $nomadOk = $true
    } elseif (Test-Path (Join-Path $env:USERPROFILE '.local\bin\nomad.exe')) {
        Write-Host "  nomad: ~/.local/bin/nomad.exe (появится в PATH после перезапуска терминала)"; $nomadOk = $true
    }
    if ($nomadOk) { Write-Host "CHECK ok Nomad Agent" } else { Write-Host "CHECK fail Nomad Agent" }
}

# --- config.yaml (HERMES_HOME развёрнут?) ---
$hh = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA 'hermes' }
$cfgY = Join-Path $hh 'config.yaml'
if (-not (Test-Selected 'nomad')) {
    Write-Host "CHECK skip Конфиг Nomad"
} elseif (Test-Path $cfgY) {
    Write-Host "  config.yaml: $cfgY"; Write-Host "CHECK ok Конфиг Nomad"
} else {
    Write-Host "CHECK fail Конфиг Nomad"
}

# --- Nomad Cloud (cp.nomadnet.ai) — облачный блок вписан? ---
$cloudKey = if ($env:HM_NOMAD_CLOUD_KEY) { ($env:HM_NOMAD_CLOUD_KEY).Trim() } else { '' }
if (-not (Test-Selected 'nomad')) {
    Write-Host "CHECK skip Nomad Cloud"
} elseif (-not $cloudKey) {
    Write-Host "  Ключ Nomad Cloud не задавали — облако настроишь позже."
    Write-Host "CHECK skip Nomad Cloud (ключ не задан)"
} else {
    $cloudOk = $false
    if (Test-Path $cfgY) {
        try {
            $t = [IO.File]::ReadAllText($cfgY, [Text.Encoding]::UTF8)
            if ($t -match '# >>> nomad-cloud' -or $t -match 'cp\.nomadnet\.ai') { $cloudOk = $true }
        } catch { }
    }
    if ($cloudOk) { Write-Host "CHECK ok Nomad Cloud" } else { Write-Host "CHECK fail Nomad Cloud" }
}

# Диагностика — не провал: всегда зелёный выход.
exit 0
