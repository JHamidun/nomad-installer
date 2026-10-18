#!/usr/bin/env bash
# Build-time (на macOS-раннере): собрать vendor/ для ПОЛНОГО офлайна установки Nomad (arm64).
# Кладёт: (1) вшитый портативный Git (dugite-native, без Apple CLT-диалога);
#         (2) исходник Nomad → vendor/nomad-src (git archive локального репо ИЛИ git clone по URL);
#         (3) checksums.json (fail-closed SHA-256 вшитых артефактов).
# set -u, НЕ -e: нативные тулзы пишут в stderr. Запуск: bash tools/fetch-vendor-mac.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="$ROOT/vendor/apps"
mkdir -p "$APPS"

# ── 1. Git: вшитый портативный dugite-native (офлайн, без Apple CLT-диалога) ──
echo "[vendor-mac] Git: вшитый портативный dugite-native..."
DUGITE_BASE="https://github.com/desktop/dugite-native/releases/download/v2.53.0-3"
dugite_get() {
  local arch="$1" want="$2"
  local out="$APPS/git-macos-$arch.tar.gz"
  if [ -s "$out" ]; then echo "  skip git-macos-$arch.tar.gz"; return; fi
  echo "  GET dugite-native macOS-$arch"
  if curl -fsSL "$DUGITE_BASE/dugite-native-v2.53.0-f49d009-macOS-$arch.tar.gz" -o "$out"; then
    local got; got=$(shasum -a 256 "$out" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
      echo "  ! SHA-256 git-macos-$arch НЕ совпал (ожидалось $want, получено $got) — удаляю."
      rm -f "$out"
    fi
  else
    echo "  ! dugite-native macOS-$arch не скачался — git на этой арх уйдёт в CLT-фолбэк."
  fi
}
dugite_get arm64 "e561cfc80c755e6f3e938653e81efcd025c9827a5b76dd42778b1159b3fab437"
dugite_get x64   "caf27c36b8834969550535bcd5e58186f970e080d1e175e76d9c1de3aac409ed"
mkdir -p "$ROOT/vendor/licenses"
cat > "$ROOT/vendor/licenses/git-dugite-NOTICE.txt" <<'NOTICE'
Вшитый Git — сборка dugite-native (GitHub Desktop), git под лицензией GNU GPL v2.0.
Исходники: https://github.com/desktop/dugite-native  и  https://git-scm.com
Полный текст GPL-2.0: https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
NOTICE

# ── 1b. uv (менеджер Python, standalone) → vendor/apps (офлайн; verified при установке) ──
# Install-скрипт (scripts/macos/nomad.sh) ставит uv ТОЛЬКО из этого вшитого архива с
# fail-closed SHA-256 — никакого `curl … | sh`. Версия: HM_UV_VERSION или latest с GitHub.
echo "[vendor-mac] uv (standalone) → vendor/apps..."
UV_VER="${HM_UV_VERSION:-}"
if [ -z "$UV_VER" ]; then
  UV_VER="$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest 2>/dev/null \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)".*/\1/')"
fi
if [ -n "$UV_VER" ]; then
  for tgt in aarch64-apple-darwin x86_64-apple-darwin; do
    uvout="$APPS/uv-$tgt.tar.gz"
    if [ -s "$uvout" ]; then echo "  skip uv-$tgt.tar.gz"; continue; fi
    echo "  GET uv $UV_VER $tgt"
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VER/uv-$tgt.tar.gz" -o "$uvout" \
      || { echo "  ! uv-$tgt не скачался — офлайн-установка uv на этой арх будет fail-closed."; rm -f "$uvout"; }
  done
else
  echo "  ! не удалось определить версию uv (GitHub API недоступен) — задай HM_UV_VERSION. uv не вшит → установка uv fail-closed у пользователя."
fi

# ── 2. Исходник Nomad → vendor/nomad-src (tracked-файлы, БЕЗ .git) ──
# На локальной машине: git archive из HM_NOMAD_AGENT_REPO.
# На GitHub-раннере (нет локального репо): git clone --depth 1 из NOMAD_AGENT_GIT_URL
#   (приватный репо → URL со встроенным токеном, напр. https://x:${TOKEN}@github.com/OWNER/nomad-agent.git).
AGENT_REPO="${HM_NOMAD_AGENT_REPO:-/c/Vibecode/hamidun-agent}"
REF="${HM_NOMAD_REF:-main}"
GITURL="${NOMAD_AGENT_GIT_URL:-}"
SRCOUT="$ROOT/vendor/nomad-src"
echo "[vendor-mac] Исходник Nomad → vendor/nomad-src (ref $REF)..."
rm -rf "$SRCOUT"; mkdir -p "$SRCOUT"
if [ -d "$AGENT_REPO/.git" ]; then
  echo "  git archive из локального репо $AGENT_REPO"
  git -C "$AGENT_REPO" archive --format=tar "$REF" | tar -x -C "$SRCOUT"
elif [ -n "$GITURL" ]; then
  echo "  git clone --depth 1 -b $REF <NOMAD_AGENT_GIT_URL>"
  TMPC="$(mktemp -d)"
  if git clone --depth 1 -b "$REF" "$GITURL" "$TMPC" 2>/dev/null || git clone --depth 1 "$GITURL" "$TMPC"; then
    # копируем tracked-файлы БЕЗ .git
    (cd "$TMPC" && git archive --format=tar HEAD) | tar -x -C "$SRCOUT"
    rm -rf "$TMPC"
  else
    echo "  ! git clone не удался — проверь NOMAD_AGENT_GIT_URL/токен."
    rm -rf "$TMPC"
  fi
else
  echo "  ! нет локального репо ($AGENT_REPO) и не задан NOMAD_AGENT_GIT_URL — исходник Nomad не вшит."
fi

# ── 2b. Деперсонализация nomad-src (fail-closed): denylist → scrub → leak-gate ──
# (a) tools/nomad-src-denylist.txt — вырезает внутренние dev/test-артефакты;
# (b) tools/scrub-vendor.py — переписывает personal-identity токены на нейтральные;
# (c) tools/leak-gate.py — если остался хоть один деанон-маркер, СБОРКА ПАДАЕТ.
if [ -f "$SRCOUT/pyproject.toml" ]; then
  echo "[vendor-mac] Деперсонализация vendor/nomad-src (denylist → scrub → leak-gate)..."
  python3 "$ROOT/tools/scrub-vendor.py" "$SRCOUT" --denylist "$ROOT/tools/nomad-src-denylist.txt" \
    || { echo "[vendor-mac] FATAL: scrub-vendor.py упал — сборка остановлена (fail-closed)."; exit 1; }
  python3 "$ROOT/tools/leak-gate.py" "$SRCOUT" --allow nomad --allow Nomad \
    || { echo "[vendor-mac] FATAL: leak-gate нашёл деанон-маркеры в vendor/nomad-src — dmg с личными данными НЕ собираем. Расширь tools/nomad-src-denylist.txt или tools/scrub-vendor.py."; exit 1; }
fi

# ── 2c. Профиль Nomad (plugins/nomad, skills, mcp-servers, desktop UI) → vendor/nomad-profile ──
PROF_OUT="$ROOT/vendor/nomad-profile"
rm -rf "$PROF_OUT"; mkdir -p "$PROF_OUT"
PROF_URL="${NOMAD_PROFILE_GIT_URL:-https://github.com/JHamidun/nomad-profile.git}"
echo "[vendor-mac] Профиль Nomad → vendor/nomad-profile..."
TMPP="$(mktemp -d)"
if git clone --depth 1 "$PROF_URL" "$TMPP" 2>/dev/null; then
  (cd "$TMPP" && git archive --format=tar HEAD) | tar -x -C "$PROF_OUT"
  rm -rf "$TMPP"
  echo "  ok vendor/nomad-profile ($(du -sh "$PROF_OUT" 2>/dev/null | cut -f1))"
else
  echo "  ! не удалось склонировать nomad-profile ($PROF_URL)"
  rm -rf "$TMPP"
fi

# ── 3. checksums.json — SHA-256 вшитых артефактов (fail-closed целостность) ──
echo "[vendor-mac] checksums.json..."
CHK="$ROOT/vendor/checksums.json"
{
  printf '{\n'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "algorithm": "sha256",\n'
  printf '  "files": {\n'
  CHK_FIRST=1
  while IFS= read -r f; do
    [ -s "$f" ] || continue
    CHK_SUM=$(shasum -a 256 "$f" | awk '{print $1}')
    CHK_SIZE=$(wc -c < "$f" | tr -d ' ')
    if [ "$CHK_FIRST" -eq 1 ]; then CHK_FIRST=0; else printf ',\n'; fi
    printf '    "%s": { "sha256": "%s", "bytes": %s }' "$(basename "$f")" "$CHK_SUM" "$CHK_SIZE"
  done < <(find "$APPS" -maxdepth 1 -type f)
  printf '\n  }\n}\n'
} > "$CHK"
echo "  файлов захешировано: $(find "$APPS" -maxdepth 1 -type f -size +0c 2>/dev/null | wc -l | tr -d ' ')"

# ── 4. Проверка полноты (FATAL, если нет исходника Nomad) ──
if [ ! -f "$SRCOUT/pyproject.toml" ]; then
  echo "[vendor-mac] FATAL: нет vendor/nomad-src/pyproject.toml — исходник Nomad не вшит. Установка Nomad упадёт."
  echo "[vendor-mac] Задай HM_NOMAD_AGENT_REPO (локально) или NOMAD_AGENT_GIT_URL (на раннере)."
  exit 1
fi
[ -s "$APPS/git-macos-arm64.tar.gz" ] || echo "[vendor-mac] WARNING: нет git-macos-arm64.tar.gz — git уйдёт в CLT-фолбэк."
echo "[vendor-mac] ГОТОВО: vendor = $(du -sh "$ROOT/vendor" 2>/dev/null | cut -f1)"
