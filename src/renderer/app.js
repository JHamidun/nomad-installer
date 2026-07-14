'use strict';

const CHECK_SVG =
  '<svg width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M2.5 6.2l2.3 2.3 4.7-5" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

let STATE = {
  platform: 'win32',
  homedir: '',
  config: {},
  groups: [],
  byId: {},        // id -> component
  selected: {},    // id -> bool
  logPath: '',     // ~/.nomad-setup/install.log (из bootstrap)
  freeGB: null,    // свободное место на диске в ГБ (preflight, из bootstrap)
  checks: [],      // результаты "CHECK ok/fail/skip <ярлык>" от компонента verify
  resourcesRoot: '', // абсолютный путь к ресурсам
  userWarning: '',   // предупреждение, если установщик запущен под другим пользователем
  vendorAvailable: true,
  cloudKey: '',      // ключ Nomad Cloud (cp.nomadnet.ai), из поля на экране выбора
};

const $ = (sel) => document.querySelector(sel);

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (ch) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]
  ));
}

async function init() {
  const boot = await window.installer.bootstrap();
  STATE.platform = boot.platform;
  STATE.homedir = boot.homedir;
  STATE.config = boot.config || {};
  STATE.logPath = boot.logPath || '';
  STATE.freeGB = (typeof boot.freeGB === 'number') ? boot.freeGB : null;
  STATE.resourcesRoot = boot.resourcesRoot || '';
  STATE.userWarning = boot.userWarning || '';
  STATE.vendorAvailable = boot.vendorAvailable !== false;
  STATE.groups = (boot.components && boot.components.groups) || [];

  STATE.groups.forEach((g) =>
    g.components.forEach((c) => {
      STATE.byId[c.id] = c;
      STATE.selected[c.id] = !!c.default;
    })
  );

  renderGroups();
  renderPreflight();
  renderUserWarning();
  renderVendorWarning();
  setupCloud();
  refreshDerived();

  $('#btn-install').addEventListener('click', startInstall);
  $('#btn-finish').addEventListener('click', () => window.installer.quit());
  setupMascots();
}

// ---- Nomad Cloud key --------------------------------------------------
function cloudCfg() {
  return (STATE.config && STATE.config.nomad && STATE.config.nomad.cloud) || {};
}

function setupCloud() {
  const cc = cloudCfg();
  const reg = $('#cloud-register');
  const input = $('#cloud-key');
  if (reg) {
    reg.addEventListener('click', () => {
      const url = cc.registerUrl || cc.cabinetUrl || '';
      if (url) window.installer.openExternal(url);
    });
  }
  if (input) {
    input.addEventListener('input', () => { STATE.cloudKey = input.value.trim(); refreshDerived(); });
  }
}

// Клик по маскоту → прыжок + смена позы. Чисто визуально.
function setupMascots() {
  const poses = ['watching', 'thinking', 'success', 'loading'];
  document.querySelectorAll('.mascot, .tips-mascot').forEach((img) => {
    img.style.cursor = 'pointer';
    let i = poses.indexOf((img.getAttribute('src') || '').replace(/.*\/(\w+)\.webp/, '$1'));
    img.addEventListener('click', () => {
      img.classList.remove('jump'); void img.offsetWidth; img.classList.add('jump');
      i = (i + 1) % poses.length;
      img.src = 'mascot/' + poses[i] + '.webp';
    });
    img.addEventListener('animationend', () => img.classList.remove('jump'));
  });
}

// ---- selection / dependency logic ----------------------------------

// Dependency resolution lives in deps.js (window.HMDeps) — shared with tests.
function enableWithDeps(id) { window.HMDeps.enableWithDeps(STATE.selected, STATE.byId, id); }
function disableDependents(id) { window.HMDeps.disableDependents(STATE.selected, STATE.byId, id); }

function toggle(id) {
  if (STATE.selected[id]) disableDependents(id);
  else enableWithDeps(id);
  renderGroups();
  refreshDerived();
}

function selectedIds() {
  return Object.keys(STATE.selected).filter((id) => STATE.selected[id]);
}

// Topological order so deps install before dependents (logic in deps.js).
function installOrder() { return window.HMDeps.installOrder(STATE.selected, STATE.byId); }

// Компонент проверки "verify" (hidden, авто-включён) всегда идёт последним.
function ensureVerifyLast(ids) {
  if (ids.indexOf('verify') === -1) return ids;
  return ids.filter((id) => id !== 'verify').concat('verify');
}

// ---- rendering ------------------------------------------------------

function renderGroups() {
  const root = $('#groups');
  root.innerHTML = '';
  STATE.groups.forEach((g) => {
    // Скрытые (служебные) компоненты вроде "verify" не показываем в выборе.
    const visible = g.components.filter((c) => !c.hidden);
    if (!visible.length) return;
    const gd = document.createElement('div');
    gd.className = 'group';
    gd.innerHTML = `<div class="group-title">${g.title}</div>`;
    visible.forEach((c) => gd.appendChild(renderCard(c)));
    root.appendChild(gd);
  });
}

function renderCard(c) {
  const checked = STATE.selected[c.id];
  const el = document.createElement('div');
  el.className = 'card' + (checked ? ' checked' : '');
  const reqNames = (c.requires || []).map((r) => STATE.byId[r] && STATE.byId[r].name).filter(Boolean);
  el.innerHTML = `
    <div class="checkbox">${CHECK_SVG}</div>
    <div class="card-body">
      <div class="card-name">
        ${c.name}
        ${c.why ? `<span class="info" tabindex="0" role="button" aria-label="Что это?">?<span class="tip">${c.why || c.desc}</span></span>` : ''}
        ${c.sizeHint ? `<span class="badge">${c.sizeHint}</span>` : ''}
        ${c.needsAdmin ? `<span class="badge admin">админ</span>` : ''}
        ${reqNames.length ? `<span class="badge dep">требует: ${reqNames.join(', ')}</span>` : ''}
      </div>
      <div class="card-desc">${c.desc}</div>
    </div>`;
  el.addEventListener('click', () => toggle(c.id));
  const info = el.querySelector('.info');
  if (info) {
    info.addEventListener('pointerdown', (e) => e.stopPropagation());
    info.addEventListener('click', (e) => e.stopPropagation());
    const flip = () => {
      const sc = document.querySelector('#view-select .scroll');
      const bounds = sc ? sc.getBoundingClientRect() : { bottom: window.innerHeight };
      info.classList.toggle('tip-up', info.getBoundingClientRect().bottom + 150 > bounds.bottom);
    };
    info.addEventListener('mouseenter', flip);
    info.addEventListener('focus', flip);
  }
  return el;
}

// Preflight: жёлтое предупреждение о нехватке места (не блокирует установку).
function renderPreflight() {
  if (STATE.freeGB === null || STATE.freeGB >= 3) return;
  if (document.getElementById('preflight-warn')) return;
  const el = document.createElement('div');
  el.id = 'preflight-warn';
  el.className = 'preflight-warn';
  el.innerHTML = `⚠️ На диске свободно всего <b>${STATE.freeGB} ГБ</b>, а для установки Nomad нужно ~1-2 ГБ. ` +
    `Установка может прерваться — освободи место.`;
  const hero = document.querySelector('#view-select .hero');
  if (hero) hero.insertAdjacentElement('afterend', el);
}

// Жёлтый баннер, если установщик запущен под другим пользователем.
function renderUserWarning() {
  if (!STATE.userWarning) return;
  if (document.getElementById('userwarn')) return;
  const el = document.createElement('div');
  el.id = 'userwarn';
  el.className = 'preflight-warn';
  el.innerHTML = '⚠️ ' + escapeHtml(STATE.userWarning);
  const hero = document.querySelector('#view-select .hero');
  if (hero) hero.insertAdjacentElement('afterend', el);
}

// На macOS офлайн-исходник Nomad (vendor) лежит в dmg РЯДОМ с приложением.
function renderVendorWarning() {
  if (STATE.vendorAvailable) return;
  if (STATE.platform !== 'darwin') return;
  if (document.getElementById('vendorwarn')) return;
  const el = document.createElement('div');
  el.id = 'vendorwarn';
  el.className = 'preflight-warn';
  el.innerHTML = '⚠️ Запусти установщик из окна, которое открылось при монтировании DMG ' +
    '(двойным кликом по «Nomad Setup» там), а не из «Программы». Иначе офлайн-исходник Nomad ' +
    'не подхватится и установка может не пройти.';
  const hero = document.querySelector('#view-select .hero');
  if (hero) hero.insertAdjacentElement('afterend', el);
}

function refreshDerived() {
  const n = selectedIds().filter((id) => !(STATE.byId[id] && STATE.byId[id].hidden)).length;
  const keyState = STATE.cloudKey ? 'ключ Nomad Cloud задан' : 'без ключа Nomad Cloud';
  $('#summary').textContent = `Выбрано: ${n} компонентов · ${keyState}`;
  $('#btn-install').disabled = n === 0;

  // Подсветка облачной секции: nomad выбран без ключа — мягкое напоминание.
  const hint = $('#cloud-hint');
  if (hint) {
    if (STATE.selected['nomad'] && !STATE.cloudKey) {
      hint.textContent = 'Без ключа агент поставится, но доступ к моделям придётся настроить позже (nomad model).';
      hint.classList.add('warn');
    } else if (STATE.cloudKey) {
      hint.textContent = 'Ключ будет записан в config.yaml агента — Nomad подключится к облаку автоматически.';
      hint.classList.remove('warn');
    } else {
      hint.classList.remove('warn');
    }
  }
}

// ---- install flow ---------------------------------------------------

function envForRun() {
  const cc = cloudCfg();
  return {
    HM_HOME: STATE.homedir || '',
    HM_SELECTED: selectedIds().join(','),
    // Nomad Cloud (cp.nomadnet.ai): свой ключ друга + endpoint/model из config.json.
    // Пустой ключ => nomad.ps1/sh НЕ пишет облачный блок (graceful).
    HM_NOMAD_CLOUD_KEY: STATE.cloudKey || '',
    HM_NOMAD_CLOUD_BASEURL: cc.baseUrl || '',
    HM_NOMAD_CLOUD_MODEL: cc.defaultModel || ''
  };
}

function appendLog(line) {
  const log = $('#log');
  log.textContent += line + '\n';
  log.scrollTop = log.scrollHeight;
}

function setStep(id, status) {
  const step = document.querySelector(`.step[data-id="${id}"]`);
  if (step) step.className = 'step ' + status;
}

let LAST_ENV = null;

function buildSteps(ids) {
  const list = $('#step-list');
  list.innerHTML = '';
  ids.forEach((id) => {
    const li = document.createElement('li');
    li.className = 'step';
    li.dataset.id = id;
    li.innerHTML = `<span class="dot"></span><span>${STATE.byId[id].name}</span>`;
    list.appendChild(li);
  });
}

// Does any (transitive) requirement of id sit in the failed/skipped sets?
function firstBrokenDep(id, badSet) {
  const reqs = (STATE.byId[id] && STATE.byId[id].requires) || [];
  for (const r of reqs) {
    if (badSet.has(r)) return r;
    const deeper = firstBrokenDep(r, badSet);
    if (deeper) return deeper;
  }
  return null;
}

async function runComponents(ids, env) {
  const off = window.installer.onLog(({ line }) => {
    if (line.startsWith('CHECK ')) {
      const m = line.match(/^CHECK (ok|fail|skip)\s+(.*)$/);
      if (m) { STATE.checks.push({ status: m[1], ok: m[1] === 'ok', label: m[2] }); return; }
    }
    appendLog(line);
  });
  const failed = [];
  const skipped = [];
  const bad = new Set();
  let ok = 0;
  for (const id of ids) {
    appendLog(`\n=== ${STATE.byId[id].name} ===`);
    const broken = firstBrokenDep(id, bad);
    if (broken) {
      setStep(id, 'skipped');
      skipped.push(id);
      bad.add(id);
      appendLog(`[~] Пропущено: не установлена зависимость «${STATE.byId[broken].name}»`);
      $('#progress-summary').textContent = `Готово: ${ok} · Ошибок: ${failed.length} · Пропущено: ${skipped.length} · Всего: ${ids.length}`;
      continue;
    }
    if (id === 'verify') STATE.checks = [];
    setStep(id, 'running');
    const res = await window.installer.runComponent(id, env);
    if (res.ok) { setStep(id, 'done'); ok++; }
    else {
      setStep(id, 'error');
      failed.push(id);
      bad.add(id);
      appendLog(`[!] ${STATE.byId[id].name}: завершено с кодом ${res.code}${res.error ? ' — ' + res.error : ''}`);
    }
    $('#progress-summary').textContent = `Готово: ${ok} · Ошибок: ${failed.length} · Пропущено: ${skipped.length} · Всего: ${ids.length}`;
  }
  off && off();
  return { failed, skipped };
}

// Карусель советов на время установки — про Nomad, для новичка.
const TIPS = [
  'Nomad — это твой локальный ИИ-агент. Команда <code>nomad</code> в терминале запускает чат.',
  'Веб-панель: <code>nomad dashboard</code> откроет её на <code>127.0.0.1:9119</code> — управляй агентом из браузера.',
  'Доступ к моделям идёт через облако Nomad (cp.nomadnet.ai). Свой ключ ИИ-модели не нужен — только ключ из кабинета.',
  'Испортил файл? Внутри чата команда <code>/rollback</code> откатит правки — Nomad делает чекпоинты сам (нужен Git).',
  '<kbd>Esc</kbd> или <code>/stop</code> останавливают агента посреди задачи.',
  'Nomad умеет сам ходить по сайтам, писать код и запускать команды — говори целями, а не пошагово.',
  'Ключ Nomad и лимиты — в кабинете cp.nomadnet.ai. Там же видно расход.',
  'С телефона: запусти <code>nomad dashboard</code> на ПК и открой <code>http://IP-компа:9119</code> в браузере телефона (одна Wi-Fi сеть).',
  'Одна задача — один разговор. Закончил — <code>/new</code>, и следующая задача пойдёт чище.',
  'Что-то не так — набери <code>nomad doctor</code>: проверит установку и подскажет.',
];
let TIPS_TIMER = null;
function startTips() {
  const box = $('#tips'), txt = $('#tips-text');
  if (!box || !txt) return;
  let i = Math.floor(Math.random() * TIPS.length);
  const show = () => {
    txt.classList.remove('tips-in');
    txt.innerHTML = TIPS[i % TIPS.length];
    void txt.offsetWidth;
    txt.classList.add('tips-in');
    i++;
  };
  show();
  box.classList.remove('hidden');
  TIPS_TIMER = setInterval(show, 12000);
}
function stopTips() {
  if (TIPS_TIMER) { clearInterval(TIPS_TIMER); TIPS_TIMER = null; }
  const box = $('#tips');
  if (box) box.classList.add('hidden');
}

async function startInstall() {
  const order = ensureVerifyLast(installOrder());
  if (!order.length) return;
  $('#view-select').classList.add('hidden');
  $('#view-progress').classList.remove('hidden');
  buildSteps(order);
  startTips();
  LAST_ENV = envForRun();
  const res = await runComponents(order, LAST_ENV);
  finishInstall(res);
}

async function retryFailed(ids) {
  ids = ensureVerifyLast(ids.concat('verify'));
  STATE.checks = [];
  $('#next-steps').classList.add('hidden');
  $('#btn-finish').classList.add('hidden');
  const m = document.querySelector('#view-progress .mascot');
  if (m) { m.src = 'mascot/loading.webp'; m.alt = 'Nomad готовит окружение'; }
  buildSteps(ids);
  startTips();
  appendLog(`\n— Повторная установка: ${ids.map((i) => STATE.byId[i].name).join(', ')} —`);
  const res = await runComponents(ids, LAST_ENV || envForRun());
  finishInstall(res);
}

function finishInstall(res) {
  stopTips();
  const failed = res.failed || [];
  const skipped = res.skipped || [];
  const checkFailed = (STATE.checks || []).some(
    (c) => (c.status || (c.ok ? 'ok' : 'fail')) === 'fail'
  );
  const okAll = failed.length === 0 && skipped.length === 0 && !checkFailed;
  let title, sub;
  if (okAll) {
    title = 'Готово!';
    sub = 'Nomad установлен. Запусти панель или чат — кнопки ниже.';
  } else if (failed.length === 0 && skipped.length === 0) {
    title = 'Установка завершена, но проверка нашла проблемы';
    sub = 'Нажми «Показать лог» ниже и пришли файл — поможем разобраться.';
  } else {
    title = 'Установка завершена с предупреждениями';
    sub = 'Часть компонентов не установилась — можно повторить ниже.';
  }
  $('#progress-title').textContent = title;
  $('#progress-sub').textContent = sub;
  const mascot = document.querySelector('#view-progress .mascot');
  if (mascot) {
    mascot.src = okAll ? 'mascot/success.webp' : 'mascot/thinking.webp';
    mascot.alt = okAll ? 'Nomad доволен — всё установилось' : 'Nomad задумался — есть проблемы';
  }
  renderNextSteps(failed, skipped);
  $('#btn-finish').classList.remove('hidden');
}

function renderNextSteps(failed, skipped) {
  failed = failed || [];
  skipped = skipped || [];
  const cfg = STATE.config || {};
  const links = cfg.links || {};
  const fin = cfg.finish || {};
  const cc = cloudCfg();
  const isWin = STATE.platform === 'win32';
  const dashUrl = (cfg.dashboard && cfg.dashboard.url) || 'http://127.0.0.1:9119';
  const cabinetUrl = links.cabinet || cc.cabinetUrl || '';
  const pairingDoc = fin.pairingDoc || links.pairingDoc || '';

  // Retry both the real failures and anything skipped because a dep failed.
  const retryList = failed.concat(skipped);
  const skipHtml = skipped.length
    ? `<div class="ns-fail">Пропущено (не встала зависимость): <b>${skipped.map((i) => STATE.byId[i].name).join(', ')}</b>.</div>`
    : '';
  const failHtml = retryList.length
    ? `<div class="ns-fail">${failed.length ? 'Не установилось: <b>' + failed.map((i) => STATE.byId[i].name).join(', ') + '</b>. ' : ''}
         <button type="button" id="ns-retry" class="btn-sm">Повторить неустановленное</button>
         <div class="ns-fail-hint">Если повтор не помогает — нажми «Показать лог» ниже и пришли этот файл в поддержку.</div></div>` + skipHtml
    : '';

  // Deeplink в бота (если задан): payload кодирует результат и платформу.
  const basePayload = fin.botStartPayload || 'nomad_installed';
  const startPayload = (basePayload +
    ((failed.length || skipped.length) ? '_f' : '_ok') +
    '_' + (isWin ? 'w' : 'm')).slice(0, 64);
  const botUrl = links.bot ? links.bot + '?start=' + encodeURIComponent(startPayload) : '';
  const botBtn = botUrl ? `<button type="button" class="btn-sm" data-ext="${botUrl}">↩ Открыть бота</button>` : '';

  const cabinetBtn = cabinetUrl ? `<button type="button" class="btn-sm" data-ext="${cabinetUrl}">☁ Кабинет Nomad Cloud</button>` : '';
  const pairingBtn = pairingDoc
    ? `<button type="button" class="btn-sm" data-ext="${pairingDoc}">📱 Управление с телефона</button>`
    : `<button type="button" id="ns-pair" class="btn-sm">📱 Управление с телефона</button>`;
  const logBtn = STATE.logPath ? `<button type="button" id="ns-log" class="btn-sm">Показать лог</button>` : '';

  const cloudMissing = !STATE.cloudKey
    ? `<div class="ns-fail">Ключ Nomad Cloud не был задан. Добавь его позже: открой кабинет, скопируй ключ и выполни в терминале <code>nomad model</code> → «custom endpoint» → вставь ключ и адрес <code>${escapeHtml(cc.baseUrl || 'https://cp.nomadnet.ai/v1')}</code>.</div>`
    : '';

  // Инлайн-инструкция «управление с телефона» (по умолчанию скрыта).
  const pairHtml = `
    <div id="ns-pair-how" class="ns-checks hidden">
      <div class="ns-checks-title">Управление с телефона</div>
      <ol class="ns-steps" style="margin:0;padding-left:20px">
        <li>На ПК запусти веб-панель: <code>nomad dashboard</code> (откроется на <code>${escapeHtml(dashUrl)}</code>).</li>
        <li>Узнай локальный IP компьютера (Windows: <code>ipconfig</code>, Mac: «Настройки → Wi-Fi»).</li>
        <li>С телефона в той же Wi-Fi-сети открой в браузере <code>http://IP-компа:9119</code>.</li>
        <li>Либо управляй через кабинет Nomad Cloud (кнопка «Кабинет Nomad Cloud» выше).</li>
      </ol>
    </div>`;

  // Чеклист из verify-скрипта ("CHECK ok/fail/skip <ярлык>").
  const checks = STATE.checks || [];
  const checkLi = (c) => {
    const st = c.status || (c.ok ? 'ok' : 'fail');
    if (st === 'skip') {
      return `<li class="skip" style="opacity:.5"><span class="mark">–</span><span>${escapeHtml(c.label)} <span style="font-size:11px">(не выбрано)</span></span></li>`;
    }
    return `<li class="${st === 'ok' ? 'ok' : 'fail'}"><span class="mark">${st === 'ok' ? '✓' : '✕'}</span><span>${escapeHtml(c.label)}</span></li>`;
  };
  const checksHtml = checks.length
    ? `<div class="ns-checks">
         <div class="ns-checks-title">Проверка установки</div>
         <ul class="ns-check-list">${checks.map(checkLi).join('')}</ul>
       </div>`
    : '';

  const ns = $('#next-steps');
  ns.innerHTML = `
    <div class="ns-title">Что дальше</div>
    <ol class="ns-steps">
      <li>Нажми <b>«Открыть панель Nomad»</b> — запустится веб-дашборд агента (<code>${escapeHtml(dashUrl)}</code>).</li>
      <li>Или открой терминал и набери <code>nomad</code> — начнётся чат с агентом.</li>
      <li>Ключи и лимиты — в кабинете Nomad Cloud.</li>
    </ol>
    ${checksHtml}
    ${cloudMissing}
    ${failHtml}
    <div class="ns-actions">
      <button type="button" id="ns-dashboard" class="btn-sm primary">🖥 Открыть панель Nomad</button>
      ${pairingBtn}
      ${cabinetBtn}
      ${logBtn}
      ${botBtn}
    </div>
    ${pairHtml}`;
  ns.classList.remove('hidden');

  const dash = $('#ns-dashboard');
  if (dash) dash.addEventListener('click', () => window.installer.openNomadDashboard());
  const pair = $('#ns-pair');
  if (pair) pair.addEventListener('click', () => {
    const how = $('#ns-pair-how');
    if (how) how.classList.toggle('hidden');
  });
  const logBtnEl = $('#ns-log');
  if (logBtnEl) logBtnEl.addEventListener('click', () => window.installer.openPath(STATE.logPath));
  ns.querySelectorAll('[data-ext]').forEach((b) => b.addEventListener('click', () => window.installer.openExternal(b.dataset.ext)));
  const retry = $('#ns-retry');
  if (retry) retry.addEventListener('click', () => retryFailed(retryList));
}

document.addEventListener('DOMContentLoaded', init);
