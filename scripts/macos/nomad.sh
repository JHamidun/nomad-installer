#!/usr/bin/env bash
# Nomad Agent — macOS (Python CLI via uv)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/_lib.sh"
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
DRY="${HM_DRY_RUN:-}"

# 1. Источник Nomad: офлайн vendor (HM_NOMAD_SRC) → git repoUrl из config.json → graceful skip
SRC="${HM_NOMAD_SRC:-}"
if [ ! -f "$SRC/pyproject.toml" ]; then
  REPO=""
  CFGJSON="$DIR/../../config.json"
  if [ -f "$CFGJSON" ]; then
    # Парсим nomad.repoUrl без python (иначе bare python3 без CLT дёргает диалог).
    REPO=$(grep -o '"repoUrl"[[:space:]]*:[[:space:]]*"[^"]*"' "$CFGJSON" 2>/dev/null | head -n1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
  fi
  if [ -n "$REPO" ]; then
    SRC="$HOME/.nomad-src"
    echo "Клонирую Nomad из $REPO ..."
    if [ -z "$DRY" ]; then
      if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only; else git clone --depth 1 "$REPO" "$SRC"; fi
    fi
  fi
fi
if [ -z "$DRY" ] && [ ! -f "$SRC/pyproject.toml" ]; then
  echo "Источник Nomad не найден. Вшей vendor/nomad-src (см. tools/fetch-vendor-mac.sh) или задай nomad.repoUrl в config.json. Пропускаю."
  exit 0
fi

# 2. uv — менеджер Python
if ! have uv; then
  echo "Устанавливаю uv..."
  [ -z "$DRY" ] && curl -fsSL https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi

# 3. Python 3.12 (pyproject требует <3.14) + установка nomad (команды nomad/nmd/hermes)
if [ -z "$DRY" ]; then
  uv python install 3.12
  echo "Устанавливаю Nomad (команды nomad/nmd/hermes)..."
  uv tool install --python 3.12 --force "$SRC"
  export PATH="$HOME/.local/bin:$PATH"
fi

# 4. Брендинг + сид config.yaml → HERMES_HOME (по умолчанию ~/.hermes)
HH="${HERMES_HOME:-$HOME/.hermes}"
CFG="$HH/config.yaml"
if [ -z "$DRY" ]; then
  mkdir -p "$HH/skins"
  if [ -n "$SRC" ]; then
    if [ -f "$SRC/branding/SOUL.md" ]; then cp "$SRC/branding/SOUL.md" "$HH/SOUL.md"
    else echo "  [warn] branding/SOUL.md не найден — пропускаю"; fi
    if [ -f "$SRC/branding/skins/nomad.yaml" ]; then cp "$SRC/branding/skins/nomad.yaml" "$HH/skins/nomad.yaml"
    else echo "  [warn] branding/skins/nomad.yaml не найден — пропускаю"; fi
    if [ ! -f "$CFG" ]; then
      if [ -f "$SRC/branding/config.yaml.template" ]; then cp "$SRC/branding/config.yaml.template" "$CFG"
      else echo "  [warn] branding/config.yaml.template не найден — создам config.yaml с нуля"; fi
    fi
  fi
fi

# 5. Nomad Cloud (cp.nomadnet.ai) — доступ к ИИ-моделям через облако владельца.
#    OpenAI-совместимый custom-провайдер: model.provider=custom + base_url + api_key + default.
#    Ключ — ТОЛЬКО ключ друга из кабинета, ключ владельца нигде не зашит.
#    Идемпотентно: awk снимает прежний управляемый блок + top-level model:, затем префикс.
CLOUD_KEY="${HM_NOMAD_CLOUD_KEY:-}"
CLOUD_URL="${HM_NOMAD_CLOUD_BASEURL:-https://cp.nomadnet.ai/v1}"
CLOUD_MODEL="${HM_NOMAD_CLOUD_MODEL:-claude-opus-4.6}"
# trim + вычистка кавычек/переводов строк (значение уходит в YAML в кавычках)
CLOUD_KEY="$(printf '%s' "$CLOUD_KEY" | tr -d '"\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
CLOUD_URL="$(printf '%s' "$CLOUD_URL" | tr -d '"\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
CLOUD_MODEL="$(printf '%s' "$CLOUD_MODEL" | tr -d '"\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [ -z "$CLOUD_KEY" ]; then
  echo "Ключ Nomad Cloud не задан — облачный блок НЕ пишу (graceful). Настрой позже: nomad model → custom endpoint $CLOUD_URL."
elif [ -n "$DRY" ]; then
  echo "  [dry-run] WOULD: в $CFG вписать model.provider=custom base_url=$CLOUD_URL default=$CLOUD_MODEL api_key=<скрыт>"
else
  STRIPPED=""
  if [ -f "$CFG" ]; then
    STRIPPED="$(awk '
      /^# >>> nomad-cloud/ { skipm=1; next }
      skipm==1 { if ($0 ~ /^# <<< nomad-cloud/) { skipm=0 } next }
      /^model:[[:blank:]]*$/ { skipmod=1; next }
      skipmod==1 { if ($0 ~ /^[[:blank:]]/ || $0 ~ /^[[:blank:]]*$/) { next } else { skipmod=0 } }
      { print }
    ' "$CFG")"
  fi
  {
    echo '# >>> nomad-cloud (managed by installer -- do not edit inside markers) >>>'
    echo 'model:'
    echo '  provider: "custom"'
    echo "  base_url: \"$CLOUD_URL\""
    echo "  api_key: \"$CLOUD_KEY\""
    echo "  default: \"$CLOUD_MODEL\""
    echo '# <<< nomad-cloud <<<'
    printf '%s\n' "$STRIPPED"
  } > "$CFG"
  echo "OK: Nomad подключён к облаку $CLOUD_URL (модель $CLOUD_MODEL). Ключ записан в config.yaml."
fi

if have nomad; then echo "OK: nomad установлен ($(nomad --version 2>&1 | head -n1))"; else echo "Nomad установлен — команда появится в PATH после перезапуска терминала."; fi
exit 0
