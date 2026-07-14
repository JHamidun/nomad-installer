#!/usr/bin/env bash
# Verify — финальная диагностика установки Nomad (macOS)
# Печатает строки вида "CHECK ok <ярлык>" / "CHECK fail <ярлык>" / "CHECK skip <ярлык>" —
# их ловит рендерер и рисует чеклист на финальном экране. Всегда exit 0 (не валит установку).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/_lib.sh"

export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

is_selected() {
  [ -z "${HM_SELECTED:-}" ] && return 0
  case ",${HM_SELECTED}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Финальная проверка установки Nomad..."

# --- Git ---
if ! is_selected git; then
  echo "CHECK skip Git"
else
  GIT_OK=0
  if [ -x /Library/Developer/CommandLineTools/usr/bin/git ] || xcode-select -p >/dev/null 2>&1; then
    if git --version >/dev/null 2>&1; then echo "  git: $(git --version 2>/dev/null)"; GIT_OK=1; fi
  elif have git && [ "$(command -v git)" != "/usr/bin/git" ]; then
    if git --version >/dev/null 2>&1; then echo "  git: $(git --version 2>/dev/null)"; GIT_OK=1; fi
  fi
  if [ "$GIT_OK" -eq 1 ]; then echo "CHECK ok Git"; else echo "CHECK fail Git"; fi
fi

# --- Nomad Agent (команда nomad или бинарь в ~/.local/bin) ---
if ! is_selected nomad; then
  echo "CHECK skip Nomad Agent"
else
  NOMAD_OK=0
  if have nomad; then echo "  nomad: $(command -v nomad)"; NOMAD_OK=1
  elif [ -x "$HOME/.local/bin/nomad" ]; then echo "  nomad: ~/.local/bin/nomad (появится в PATH после перезапуска терминала)"; NOMAD_OK=1; fi
  if [ "$NOMAD_OK" -eq 1 ]; then echo "CHECK ok Nomad Agent"; else echo "CHECK fail Nomad Agent"; fi
fi

# --- config.yaml (HERMES_HOME развёрнут?) ---
HH="${HERMES_HOME:-$HOME/.hermes}"
CFG="$HH/config.yaml"
if ! is_selected nomad; then
  echo "CHECK skip Конфиг Nomad"
elif [ -f "$CFG" ]; then
  echo "  config.yaml: $CFG"; echo "CHECK ok Конфиг Nomad"
else
  echo "CHECK fail Конфиг Nomad"
fi

# --- Nomad Cloud (cp.nomadnet.ai) — облачный блок вписан? ---
CLOUD_KEY="${HM_NOMAD_CLOUD_KEY:-}"
if ! is_selected nomad; then
  echo "CHECK skip Nomad Cloud"
elif [ -z "$CLOUD_KEY" ]; then
  echo "  Ключ Nomad Cloud не задавали — облако настроишь позже."
  echo "CHECK skip Nomad Cloud (ключ не задан)"
else
  CLOUD_OK=0
  if [ -f "$CFG" ] && grep -Eq '^# >>> nomad-cloud|cp\.nomadnet\.ai' "$CFG" 2>/dev/null; then CLOUD_OK=1; fi
  if [ "$CLOUD_OK" -eq 1 ]; then echo "CHECK ok Nomad Cloud"; else echo "CHECK fail Nomad Cloud"; fi
fi

exit 0
