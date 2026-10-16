'use strict';
// Подпись Windows-сборок для electron-builder (package.json → build.win.signtoolOptions.sign).
// Сертификат — облачный Certum Code Signing (CN=Zhemal Khamidun, 05.10.2026 — 05.10.2027).

const { execFileSync, execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const CERT_SHA1 = '0D519A2C48DF89680D004A0FA09F449573E9689F';
const TSA = ['http://time.certum.pl', 'http://time.certum.pl', 'http://timestamp.digicert.com'];
const CONNECTOR = path.join(os.homedir(), '.claude', 'tools', 'simplysign_connect.py');

function decide(env, platform) {
  if (env.HM_WIN_SIGN === '0') {
    return { sign: false, why: 'HM_WIN_SIGN=0 — сборка БЕЗ подписи осознанно' };
  }
  if (env.HM_WIN_SIGN === '1') return { sign: true, why: '' };
  if (platform !== 'win32') {
    return { sign: false, why: 'не Windows: нет signtool и SimplySign (HM_WIN_SIGN=1 — заставить)' };
  }
  if (env.CI || env.GITHUB_ACTIONS) {
    return { sign: false, why: 'CI: SimplySign там нет (HM_WIN_SIGN=1 — заставить)' };
  }
  return { sign: true, why: '' };
}

const PRODUCT_EXE = 'Nomad Setup.exe';
const OWN_ARTIFACT_RE = /^Setup-Nomad-Windows(-Lite)?\.exe$/i;
const UNPACKED_DIR_RE = /^win-[\w.-]*unpacked$/i;
function isOwn(file) {
  const parts = String(file || '').split(/[\\/]+/).filter(Boolean);
  if (parts.length < 2) return false;
  const name = parts[parts.length - 1];
  const parent = parts[parts.length - 2];
  const ancestors = parts.slice(0, -1);
  const unpackedAt = ancestors.map((a) => UNPACKED_DIR_RE.test(a)).lastIndexOf(true);
  const below = unpackedAt >= 0 ? ancestors.slice(unpackedAt + 1) : ancestors.slice(-2);
  if (name.toLowerCase() === PRODUCT_EXE.toLowerCase() && UNPACKED_DIR_RE.test(parent)) return true;
  if (name.toLowerCase() === 'elevate.exe' && parent.toLowerCase() === 'resources'
      && !below.some((a) => a.toLowerCase() === 'vendor')) return true;
  if (OWN_ARTIFACT_RE.test(name) && !ancestors.some((a) => UNPACKED_DIR_RE.test(a))) return true;
  return false;
}
function isForeign(file) {
  return !isOwn(file);
}

function plan(file, env, platform) {
  if (!isOwn(file)) {
    return {
      sign: false,
      foreign: true,
      why: 'не из списка своих файлов (подписываем exe приложения, elevate.exe и итоговый portable); ' +
        'у вшитых вендорских файлов SHA-256 закреплён в vendor\\checksums.json, подпись сломала бы проверку целостности',
    };
  }
  const d = decide(env, platform);
  return { sign: d.sign, foreign: false, why: d.why };
}

function certSha1(env) {
  return String((env && env.HM_WIN_CERT_SHA1) || CERT_SHA1).replace(/\s+/g, '').toUpperCase();
}

function signtoolArgs(file, sha1, tsa) {
  return ['sign', '/sha1', sha1, '/fd', 'sha256', '/tr', tsa, '/td', 'sha256', file];
}

function findSigntool(env) {
  if (env.HM_SIGNTOOL) return env.HM_SIGNTOOL;
  const base = path.join(process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)', 'Windows Kits', '10', 'bin');
  let vers = [];
  try { vers = fs.readdirSync(base).filter((v) => /^10\.\d+\.\d+\.\d+$/.test(v)); } catch (e) { /* нет SDK */ }
  vers.sort((a, b) => {
    const x = a.split('.').map(Number), y = b.split('.').map(Number);
    for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return y[i] - x[i];
    return 0;
  });
  for (const v of vers) {
    const p = path.join(base, v, 'x64', 'signtool.exe');
    if (fs.existsSync(p)) return p;
  }
  throw new Error('sign-win: signtool.exe не найден (Windows SDK). Поставь SDK или задай HM_SIGNTOOL');
}

let connected = null;
function connectOnce(env) {
  if (connected) return;
  if (env.HM_SIMPLYSIGN_CONNECT) {
    execSync(env.HM_SIMPLYSIGN_CONNECT, { stdio: 'inherit' });
  } else if (fs.existsSync(CONNECTOR)) {
    execFileSync('python', [CONNECTOR], { stdio: 'inherit' });
  } else {
    console.log('  • sign-win: коннектора SimplySign нет — считаю, что вход в SimplySign Desktop уже выполнен');
  }
  connected = true;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function sign(configuration) {
  const file = configuration.path;
  const env = process.env;
  const d = plan(file, env, process.platform);
  if (!d.sign) {
    let shown = path.basename(file);
    if (d.foreign) {
      shown = /[\\/]resources[\\/]/i.test(String(file))
        ? String(file).replace(/^.*?[\\/](resources[\\/])/i, '$1')
        : String(file).split(/[\\/]+/).slice(-3).join('\\');
    }
    console.log('  • sign-win: ПРОПУСК подписи ' + shown + ' — ' + d.why);
    return;
  }
  connectOnce(env);
  const tool = findSigntool(env);
  const sha1 = certSha1(env);
  let last = null;
  for (let i = 0; i < TSA.length; i++) {
    try {
      execFileSync(tool, signtoolArgs(file, sha1, TSA[i]), { stdio: 'pipe', timeout: 300000 });
      last = null;
      break;
    } catch (e) {
      last = String((e.stdout || '') + (e.stderr || '') || e.message).trim();
      console.log('  • sign-win: попытка ' + (i + 1) + ' не удалась (' + TSA[i] + '): ' + last.split('\n').pop());
      if (i < TSA.length - 1) await sleep(5000 * (i + 1));
    }
  }
  if (last) {
    throw new Error('sign-win: не подписан ' + file + '. Вход в SimplySign Desktop выполнен? ' +
      '(python ~/.claude/tools/simplysign_connect.py --status). Последняя ошибка: ' + last);
  }
  execFileSync(tool, ['verify', '/pa', '/q', file], { stdio: 'pipe' });
  console.log('  • sign-win: подписан и проверен ' + path.basename(file));
}

module.exports = sign;
module.exports.default = sign;
module.exports.decide = decide;
module.exports.plan = plan;
module.exports.isOwn = isOwn;
module.exports.isForeign = isForeign;
module.exports.signtoolArgs = signtoolArgs;
module.exports.certSha1 = certSha1;
module.exports.CERT_SHA1 = CERT_SHA1;
module.exports.PRODUCT_EXE = PRODUCT_EXE;
module.exports.OWN_ARTIFACT_RE = OWN_ARTIFACT_RE;
