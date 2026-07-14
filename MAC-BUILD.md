# Сборка macOS-версии (Setup-Nomad-Mac.dmg)

`.dmg` собирается **только на macOS** (electron-builder требует Mac-тулчейн — `hdiutil` и т.д.).
На Windows Mac-версию скомпилировать нельзя.

## Вариант A — облако (без своего Mac), рекомендуется

GitHub Actions собирает `.dmg` на облачном macOS-раннере.

1. Запушить проект в GitHub-репозиторий (один раз).
2. Прописать секреты репозитория (Settings → Secrets → Actions):
   - **`NOMAD_AGENT_GIT_URL`** — URL приватного репо агента со встроенным токеном,
     напр. `https://x:ghp_XXXX@github.com/OWNER/nomad-agent.git`. Из него vendor-шаг
     клонирует исходник в `vendor/nomad-src` (друзьям доступ к репо не нужен).
   - Подпись/нотаризация: `APPLE_CSC_LINK` (base64 .p12), `APPLE_CSC_KEY_PASSWORD`,
     `APPLE_API_KEY_P8` (base64 .p8), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`, `APPLE_TEAM_ID`.
3. Вкладка **Actions → «Build macOS (.dmg)» → Run workflow**.
4. `.dmg` появится в **Releases** запуска (тег `mac-build-<N>`).

Workflow: `.github/workflows/build-mac.yml`.

## ⚠️ Gatekeeper: «Приложение повреждено» — это НЕ битый файл

Скачанный из браузера неподписанный `.app` современная macOS блокирует формулировкой
**«повреждено, и его не удается открыть»**. Что сделано:

1. **Ad-hoc подпись** (`tools/mac-adhoc-sign.js`, afterPack, `codesign -s -`) — без ЛЮБОЙ
   подписи arm64-бинарь ядро не запускает даже после снятия карантина.
2. **Developer ID + нотаризация** в CI (если заданы секреты Apple) — убирает диалог совсем.
3. **Инструкция внутри dmg** (`assets/mac/ПРОЧТИ ЕСЛИ ПИШЕТ ПОВРЕЖДЕНО.txt`).

Ручной обход (если нотаризации нет): перетащить в «Программы», затем в Терминале
`xattr -cr "/Applications/Nomad Setup.app"`.

## Вариант B — на любом Mac

```bash
npm install
export NOMAD_AGENT_GIT_URL="https://x:<PAT>@github.com/OWNER/nomad-agent.git"
bash tools/fetch-vendor-mac.sh     # git dugite + исходник Nomad + checksums
npm run dist:mac                    # -> release/*.app (финальный dmg собирает CI/hdiutil)
```

Локально с доступным репо агента вместо `NOMAD_AGENT_GIT_URL` можно задать
`HM_NOMAD_AGENT_REPO=/path/to/nomad-agent` — тогда `git archive` возьмёт код из локального клона.

## Что входит в Mac-версию

- **Исходник Nomad — офлайн**, вшит в `vendor/nomad-src` (git archive без .git).
- **Git — офлайн**, вшитый портативный dugite-native (без диалога Apple Command Line Tools).
- Сам Nomad ставится при установке через `uv` (тянет Python 3.12; нужен интернет на первый раз).
- Финальный экран и экран Nomad Cloud — те же, что на Windows.

## Подпись/нотаризация

Нужен Apple Developer ID ($99/год): `codesign` + `notarytool` + `stapler`.
Настроено в `package.json` → `mac` (`hardenedRuntime`, `notarize: true`) + секреты в Actions.
Team ID сборки: `3VN93XA9DY` (Jemal Mohamed Lemine).
