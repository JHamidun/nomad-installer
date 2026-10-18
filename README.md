# Nomad Setup

Установщик «в один клик» для локального AI-агента **Nomad** (S1, self_hosted).
Друг запускает `Setup-Nomad-Windows.exe` (или `Setup-Nomad-Mac.dmg`) → на его машине
появляется рабочий `nomad`, а доступ к ИИ-моделям идёт через **облако Nomad**
(`cp.nomadnet.ai`) — свой ключ модели другу не нужен, VPN не нужен.

Electron-приложение. Один продукт → две сборки: `Setup-Nomad-Windows.exe` и
`Setup-Nomad-Mac.dmg`. Полностью **офлайн**: исходник Nomad и офлайн-Git вшиты в vendor/.

## Компоненты (галочки)

| Компонент | Что делает |
|---|---|
| **Nomad Agent** | Ставит агента нативно через `uv` (Python 3.12) из вшитого исходника, применяет брендинг, пишет `config.yaml` с подключением к облаку Nomad. Команда `nomad`. |
| **Git** | Нужен для чекпоинтов Nomad (`/rollback` внутри чата) и как офлайн-фолбэк источника кода. |

Скрытый служебный шаг **Проверка** печатает чеклист на финальном экране (nomad / git / config.yaml / облако).

Курсовые/dev-env компоненты (Cursor, Claude Code, Node, config-пак, скрепка, VPN-мост)
из этого установщика **убраны** — он делает ровно одно: ставит Nomad.

## Nomad Cloud (cp.nomadnet.ai) — ключевая адаптация

Локальный агент друга берёт доступ к моделям из облака владельца
(OpenAI-совместимый эндпоинт `https://cp.nomadnet.ai/v1`):

1. На экране выбора друг жмёт **«Получить ключ»** → открывается
   `cp.nomadnet.ai/cabinet/register`, он регистрируется и копирует ключ из кабинета.
2. Вставляет ключ в поле → ключ уходит в установку (`renderer → IPC → env HM_NOMAD_CLOUD_KEY`).
3. `scripts/*/nomad.*` дописывают в `HERMES_HOME/config.yaml` **управляемый блок**:

   ```yaml
   # >>> nomad-cloud (managed by installer -- do not edit inside markers) >>>
   model:
     provider: "custom"
     base_url: "https://cp.nomadnet.ai/v1"
     api_key: "<КЛЮЧ ДРУГА ИЗ КАБИНЕТА>"
     default: "claude-opus-4.6"
   # <<< nomad-cloud <<<
   ```

Блок идемпотентен (повторный запуск обновляет, не дублирует). Ключ владельца
**нигде не зашит** — единственный секрет это ключ друга из его кабинета. Если поле
пустое — блок не пишется (агент ставится, облако друг настроит позже).

`base_url` / `defaultModel` / URL кабинета берутся из `config.json` → `nomad.cloud`.

## Разработка

```bash
cd D:\Nomad\nomad-installer
npm install
npm start            # запустить GUI локально
npm test             # smoke-тесты движка зависимостей
```

## Сборка дистрибутивов

### Windows (локально, на машине с репо агента)

```bash
npm run fetch:vendor   # git-setup.exe + git archive исходника Nomad -> vendor/nomad-src + checksums
npm run dist:win       # -> release/Setup-Nomad-Windows.exe (portable, requireAdministrator)
```

`fetch-vendor.ps1` берёт исходник Nomad из локального репо агента:

```powershell
# по умолчанию: HM_NOMAD_AGENT_REPO = D:\Nomad\hamidun-agent, HM_NOMAD_REF = main
git -C D:\Nomad\hamidun-agent archive --output nomad-src.tar main
tar -x -f nomad-src.tar -C vendor\nomad-src     # tracked-файлы, БЕЗ .git (~170 МБ)
```

Переопределить: `HM_NOMAD_AGENT_REPO`, `HM_NOMAD_REF`.

### macOS (GitHub Actions)

`.github/workflows/build-mac.yml` собирает подписанный+нотаризованный `.dmg` на
облачном mac-раннере. У раннера нет локального репо агента → он клонирует его по
секрету **`NOMAD_AGENT_GIT_URL`** (URL приватного репо с токеном). Плюс секреты
подписи (`APPLE_CSC_LINK`, `APPLE_CSC_KEY_PASSWORD`, `APPLE_API_KEY_*`, `APPLE_TEAM_ID`).
Подробнее — `MAC-BUILD.md`.

## Архитектура

- `src/main.js` — главный процесс: читает `config.json`/`components.json`, по IPC запускает
  `scripts/<os>/<id>.ps1|sh`, стримит вывод в UI, прокидывает `HM_*` env (в т.ч. `HM_NOMAD_CLOUD_KEY`).
- `src/preload.js` — безопасный мост (contextIsolation, без nodeIntegration).
- `src/renderer/` — UI: выбор компонентов, поле ключа Nomad Cloud, финальный экран
  (панель Nomad / телефон / кабинет / повтор).
- `scripts/windows/*.ps1`, `scripts/macos/*.sh` — идемпотентные офлайн-первые установщики.
- `tools/fetch-vendor.ps1`, `tools/fetch-vendor-mac.sh` — build-time сбор vendor/.
- `config.json` — endpoint/модель/URL кабинета, ссылки финального экрана.

## Финальный экран «Что дальше»

- **🖥 Открыть панель Nomad** — запускает терминал с `nomad dashboard` (веб-UI на `127.0.0.1:9119`).
- **📱 Управление с телефона** — инлайн-инструкция (dashboard + IP:9119 из телефона).
- **☁ Кабинет Nomad Cloud** — открывает `cp.nomadnet.ai/cabinet`.
- **Повторить неустановленное** — перезапускает только упавшие компоненты.
- **Показать лог** — `~/.nomad-setup/install.log` для поддержки.

## Что НЕ автоматизируется

- Регистрация друга в облаке и генерация ключа — вручную в кабинете (кнопка «Получить ключ» открывает страницу).

## Иконка приложения

Отдельная иконка не задана (electron-builder использует дефолтную).
Для брендинга добавь `build/icon.ico` (Win) / `build/icon.icns` (Mac) и пропиши
`build.win.icon` / `build.mac.icon` в `package.json`.

## Заметка по безопасности

- Ключ владельца LLM НИГДЕ не зашит. Единственный секрет — ключ друга из его кабинета,
  он идёт в `value` инпута → env → `config.yaml`, не в разметку.
- `src/renderer/app.js` использует `innerHTML` только для данных из вшитых
  `components.json`/`config.json` (доверенный источник). XSS-вектора нет.

## Статус

- ✅ Windows-скрипты (nomad, git, verify) + офлайн-vendor (git + nomad-src).
- ✅ macOS-скрипты + CI (подпись + нотаризация) — требуют проверки на реальном Mac.
- ✅ UI, граф зависимостей, стрим логов, экран Nomad Cloud, финальный экран.
- ⏳ Иконки приложения, подтверждение точного `defaultModel` из `cp.nomadnet.ai/v1/models`.
