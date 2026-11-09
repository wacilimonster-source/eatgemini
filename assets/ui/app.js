// eatgemini 监控界面（原生 ES Module，无外部依赖）。
// 安全约定：所有来自服务端的字符串只用 textContent 渲染，绝不拼 innerHTML。
// 样式约定：控制台 CSP 为 style-src 'self'，禁止 style 属性与内联 <style>；
// 动态数值一律通过 CSSOM（el.style.width = …）赋值。
// 设计来源：产品设计-UI视觉与交互规范（§02–§08）。

const S = {
  snapshot: null,
  csrf: '',
  tab: 'overview',
  models: null,
  requests: null,
  connect: null,
  secrets: null,
  config: null,
  diag: null,
  logLines: [],
  detail: null,
  newRequests: 0,
  knownIds: new Set(),
  expandedModel: null,
  req: { q: '', client: 'all', outcome: 'all', model: 'all', time: 'today' },
  events: [],
  unread: 0,
  eventFilter: 'all',
  hour: new Map(), // 桶 id（2 分钟粒度）-> { ok, fail, fb }
  onboarding: { step: 1, test: 'idle', lanHint: false },
  policyOpen: false,
  configDirty: false,
};

// ---------------------------------------------------------------- 图标 sprite
// 24 网格 / stroke 1.75 / round cap·join / currentColor（设计规范 §04）。
// 内联 SVG 在 HTML 中无需命名空间声明；构建期扫描拒绝外部链接字面量，故由此注入。
const SPRITE_DEFS = `<defs>
<symbol id="i-gem" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M7.3 3.5h9.4L21 9.2 12 20.5 3 9.2 7.3 3.5z"/><path d="M3 9.2h18"/><path d="M7.3 3.5l2.3 5.7L12 20.5l2.4-11.3 2.3-5.7"/></symbol>
<symbol id="i-pulse" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h4l2.5-6.5 4.5 13L16.5 12H21"/></symbol>
<symbol id="i-quota" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v6c0 1.66 3.13 3 7 3s7-1.34 7-3V6"/><path d="M5 12v6c0 1.66 3.13 3 7 3s7-1.34 7-3v-6"/></symbol>
<symbol id="i-list" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M8.5 6h12M8.5 12h12M8.5 18h12"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/></symbol>
<symbol id="i-plug" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="12" r="2.7"/><circle cx="17.5" cy="5" r="2.7"/><circle cx="17.5" cy="19" r="2.7"/><path d="M8.5 10.7l6.7-4.3M8.5 13.3l6.7 4.3"/></symbol>
<symbol id="i-key" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="4"/><path d="M10.5 12.5L20 3"/><path d="M15.5 7.5l3 3"/></symbol>
<symbol id="i-key-x" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="4"/><path d="M10.5 12.5L20 3"/><path d="M15.5 7.5l3 3"/><path d="M3.5 3.5l4 4"/></symbol>
<symbol id="i-sliders" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h5M13.5 7H20M4 12h9M17.5 12H20M4 17h3M11.5 17H20"/><circle cx="11.2" cy="7" r="2.2"/><circle cx="15.3" cy="12" r="2.2"/><circle cx="9.3" cy="17" r="2.2"/></symbol>
<symbol id="i-diag" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M6.5 12.5h2.6l1.7-4 2.6 8 1.7-4h2.4"/></symbol>
<symbol id="i-check-c" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16.5 9"/></symbol>
<symbol id="i-check" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12.5l5 5L19.5 7"/></symbol>
<symbol id="i-alert" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4L21.5 20h-19L12 4z"/><path d="M12 10.5v4"/><path d="M12 17.6h.01"/></symbol>
<symbol id="i-alert-c" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7.5V13"/><path d="M12 16.5h.01"/></symbol>
<symbol id="i-x-c" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M9.3 9.3l5.4 5.4M14.7 9.3l-5.4 5.4"/></symbol>
<symbol id="i-x" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12M18 6L6 18"/></symbol>
<symbol id="i-clock" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7.5V12l3 2"/></symbol>
<symbol id="i-timer" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13.5" r="7.5"/><path d="M12 10v3.5l2.5 2"/><path d="M9.5 2.5h5"/></symbol>
<symbol id="i-arrow-down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v13M6.5 12.5L12 18l5.5-5.5"/></symbol>
<symbol id="i-shield" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.4-3 7.5-7 9-4-1.5-7-4.6-7-9V6l7-3z"/></symbol>
<symbol id="i-shield-x" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.4-3 7.5-7 9-4-1.5-7-4.6-7-9V6l7-3z"/><path d="M9.5 9.7l5 5M14.5 9.7l-5 5"/></symbol>
<symbol id="i-shield-ok" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v6c0 4.4-3 7.5-7 9-4-1.5-7-4.6-7-9V6l7-3z"/><path d="M9 12.2l2.2 2.2 4-4.4"/></symbol>
<symbol id="i-phone" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 17.5h2"/></symbol>
<symbol id="i-doc" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h4"/></symbol>
<symbol id="i-plug-chg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9 7V3.5M15 7V3.5"/><path d="M7 7h10v5a5 5 0 0 1-10 0V7z"/><path d="M12 17v3.5"/></symbol>
<symbol id="i-copy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4.5A2.5 2.5 0 0 1 2 12.5V4.5A2.5 2.5 0 0 1 4.5 2h8A2.5 2.5 0 0 1 15 4.5V5"/></symbol>
<symbol id="i-refresh" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M20 5v5h-5"/><path d="M4 19v-5h5"/><path d="M5 9.5A7.5 7.5 0 0 1 18.4 7L20 8.5"/><path d="M19 14.5A7.5 7.5 0 0 1 5.6 17L4 15.5"/></symbol>
<symbol id="i-eye" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/></symbol>
<symbol id="i-eye-off" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4.5l16 15"/><path d="M9.9 6.2A9.6 9.6 0 0 1 12 6c6 0 9.5 6 9.5 6a17 17 0 0 1-2.8 3.6"/><path d="M6.3 8.1A16.5 16.5 0 0 0 2.5 12S6 18 12 18c1.3 0 2.5-.3 3.6-.8"/><path d="M10 10.2a2.6 2.6 0 0 0 3.6 3.7"/></symbol>
<symbol id="i-chev-d" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></symbol>
<symbol id="i-chev-r" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></symbol>
<symbol id="i-search" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="M20.5 20.5L16 16"/></symbol>
<symbol id="i-ext" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6"/><path d="M20 4L11 13"/><path d="M19 14v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5"/></symbol>
<symbol id="i-qr" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><path d="M14 14h3v3h-3z"/><path d="M20 14.5v.01M20 19.5v.01M14.5 20v.01M18 20v.01"/></symbol>
<symbol id="i-download" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7 10.5L12 15l5-4.5"/><path d="M4.5 19.5h15"/></symbol>
<symbol id="i-send" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M21 3L10.5 13.5"/><path d="M21 3l-7 18-3.5-7.5L3 10l18-7z"/></symbol>
<symbol id="i-info" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/></symbol>
<symbol id="i-undo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H9"/><path d="M8 5L4 9l4 4"/></symbol>
<symbol id="i-arr-up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M6 11l6-6 6 6"/></symbol>
<symbol id="i-arr-dn" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M6 13l6 6 6-6"/></symbol>
<symbol id="i-filter" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5h16l-6.3 7.3V19l-3.4 1.5v-8.2L4 5z"/></symbol>
<symbol id="i-lock" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="10.5" width="13" height="9.5" rx="2"/><path d="M8.5 10.5V7.5a3.5 3.5 0 0 1 7 0v3"/></symbol>
<symbol id="i-unlock" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="10.5" width="13" height="9.5" rx="2"/><path d="M8.5 10.5V7.5a3.5 3.5 0 0 1 6.8-1"/></symbol>
<symbol id="i-bell" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M18 9.5a6 6 0 1 0-12 0c0 5.5-2.5 6.5-2.5 6.5h17S18 15 18 9.5z"/><path d="M10 19.5a2.2 2.2 0 0 0 4 0"/></symbol>
<symbol id="i-terminal" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7l5 5-5 5"/><path d="M12.5 17H19"/></symbol>
<symbol id="i-trash" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 6.5h15"/><path d="M8 6.5V5a1.5 1.5 0 0 1 1.5-1.5h5A1.5 1.5 0 0 1 16 5v1.5"/><path d="M6.5 6.5l1 13a1.5 1.5 0 0 0 1.5 1.4h6a1.5 1.5 0 0 0 1.5-1.4l1-13"/></symbol>
<symbol id="i-inbox" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5"/><path d="M3 13l2.5-8A2 2 0 0 1 7.4 3.5h9.2a2 2 0 0 1 1.9 1.5L21 13"/><path d="M3 13h5.5l1.5 2.5h4L15.5 13H21"/></symbol>
<symbol id="i-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/></symbol>
<symbol id="i-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4"/></symbol>
</defs>`;
document.getElementById('sprite-box').innerHTML = SPRITE_DEFS;

// ---------------------------------------------------------------- 基础工具

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'html') el.innerHTML = v; // 仅限程序内静态串，绝不放服务端数据
    else if (k === 'css') Object.assign(el.style, v);
    else if (k.startsWith('on') && typeof v === 'function') {
      el.addEventListener(k.slice(2), v);
    } else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else if (k === 'disabled') el.disabled = !!v;
    else if (k === 'selected') el.selected = !!v;
    else el.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function icon(name, cls = 'ic') {
  const wrap = document.createElement('span');
  wrap.innerHTML = `<svg class="${cls}" aria-hidden="true"><use href="#i-${name}"/></svg>`;
  return wrap.firstChild;
}

function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleTimeString('zh-CN', { hour12: false });
}

function fmtDuration(ms) {
  if (ms === null || ms === undefined) return '—';
  if (ms < 1000) return `${ms} ms`;
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s} 秒`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} 分 ${s % 60} 秒`;
  const hrs = Math.floor(m / 60);
  return `${hrs} 小时 ${m % 60} 分`;
}

function fmtAgo(iso) {
  if (!iso) return '—';
  const diff = Date.now() - new Date(iso).getTime();
  if (Number.isNaN(diff)) return '—';
  if (diff < 0) return `还有 ${fmtDuration(-diff)}`;
  return `${fmtDuration(diff)}前`;
}

const STATE_LABEL = {
  starting: '启动中',
  needs_key: '等待配置 · 未填写 API Key',
  config_error: '配置错误',
  port_conflict: '端口被占用',
  ready: '运行中',
  degraded: '已降级',
  persist_error: '状态无法保存',
  stopping: '正在退出',
};

const STATE_CLASS = {
  ready: 'ready',
  degraded: 'degraded',
  needs_key: 'needs_key',
  config_error: 'error',
  port_conflict: 'error',
  persist_error: 'error',
  stopping: 'error',
  starting: '',
};

// ---------------------------------------------------------------- Toast / 复制 / 确认

function toast(msg, tone = 'ok') {
  const box = document.getElementById('toasts');
  const t = h('div', { class: `toast ${tone}` },
    icon(tone === 'err' ? 'x-c' : tone === 'info' ? 'info' : 'check-c'),
    h('span', { text: msg }));
  box.append(t);
  setTimeout(() => t.remove(), tone === 'err' ? 3600 : 1900);
}

function copy(text, label = '已复制', btn = null) {
  const done = () => {
    toast(label);
    if (btn) {
      const use = btn.querySelector('use');
      if (use) {
        const old = use.getAttribute('href');
        use.setAttribute('href', '#i-check');
        btn.style.color = 'var(--ok)';
        setTimeout(() => { use.setAttribute('href', old); btn.style.color = ''; }, 1200);
      }
    }
  };
  navigator.clipboard.writeText(text).then(done, () => toast('复制失败，请手动选择', 'err'));
}

/** 自定义确认弹窗（替代 window.confirm），返回 Promise<boolean>。 */
function confirmDialog({ title, body, okText = '确定', okClass = 'btn-danger', icon: ic = 'alert' }) {
  return new Promise((resolve) => {
    const root = document.getElementById('overlay');
    const close = (v) => { root.replaceChildren(); resolve(v); };
    root.replaceChildren(
      h('div', {
        class: 'dlg-mask',
        onclick: () => close(false),
      }),
      h('div', { class: 'dlg', role: 'dialog' },
        h('div', { class: 'dlg-b' },
          h('div', { class: 'dlg-t' }, icon(ic), h('span', { text: title })),
          h('div', { class: 'dlg-d', text: body })),
        h('div', { class: 'dlg-f' },
          h('button', { class: 'btn btn-ghost', text: '取消', onclick: () => close(false) }),
          h('button', { class: `btn ${okClass}`, text: okText, onclick: () => close(true) }))),
    );
    const dlg = root.querySelector('.dlg');
    dlg.tabIndex = -1;
    dlg.focus();
    dlg.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') close(false);
      if (e.key === 'Enter') close(true);
    });
  });
}

function busy(btn, text = '处理中…') {
  if (!btn) return () => {};
  const old = btn.childNodes.length ? Array.from(btn.childNodes) : null;
  btn.disabled = true;
  btn.replaceChildren(h('span', { class: 'spin' }), h('span', { text }));
  return () => {
    btn.disabled = false;
    if (old) btn.replaceChildren(...old);
  };
}

async function api(path, options = {}) {
  const init = { method: options.method || 'GET', headers: {} };
  if (options.body !== undefined) {
    init.headers['content-type'] = 'application/json';
    init.body = JSON.stringify(options.body);
  }
  if (init.method !== 'GET') init.headers['x-egc-csrf'] = S.csrf;
  const res = await fetch(path, init);
  let data = null;
  try { data = await res.json(); } catch (_) { data = null; }
  if (!res.ok) {
    const msg = data?.error?.message || `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return data;
}

// ---------------------------------------------------------------- 主题

const themePref = () => localStorage.getItem('eg-theme') || '';
function applyTheme(pref) {
  const root = document.documentElement;
  root.classList.toggle('light', pref === 'light');
  root.classList.toggle('force-dark', pref === 'dark');
  const btn = document.getElementById('theme-toggle');
  btn.title = pref === 'dark' ? '当前深色 · 点击切换浅色' : pref === 'light' ? '当前浅色 · 点击切换深色' : '跟随系统 · 点击切换';
  btn.replaceChildren(icon(pref === 'light' ? 'sun' : 'moon'));
}
document.getElementById('theme-toggle').addEventListener('click', () => {
  const cur = themePref();
  const sysLight = matchMedia('(prefers-color-scheme: light)').matches;
  let next;
  if (cur === '') next = sysLight ? 'dark' : 'light';
  else next = cur === 'light' ? 'dark' : 'light';
  localStorage.setItem('eg-theme', next);
  applyTheme(next);
});
applyTheme(themePref());

// ---------------------------------------------------------------- 渲染框架

const main = document.getElementById('main');
const overlay = document.getElementById('overlay');

function closeOverlay() { overlay.replaceChildren(); }
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeOverlay();
  if (e.key === '/' && S.tab === 'requests' && !overlay.childElementCount
      && !/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName)) {
    e.preventDefault();
    const q = main.querySelector('#req-q');
    if (q) q.focus();
  }
});

function pageHead(title, desc, ...acts) {
  return h('div', { class: 'page-head' },
    h('div', {},
      h('h2', { text: title }),
      desc ? h('div', { class: 'desc', text: desc }) : null),
    acts.length ? h('div', { class: 'acts' }, ...acts) : null);
}

function skeleton() {
  const bar = (w, ht = 12) => h('div', { class: 'skl', css: { width: w, height: `${ht}px` } });
  return h('div', {},
    h('div', { class: 'grid c6' },
      ...[1, 2, 3, 4, 5, 6].map(() => h('div', { class: 'card' },
        bar('40%', 10), bar('60%', 22)))),
    h('div', { class: 'skl', css: { width: '100%', height: '120px', marginTop: '12px' } }));
}

function emptyState(iconName, title, desc, ...acts) {
  return h('div', { class: 'empty' },
    h('div', { class: 'eic' }, icon(iconName)),
    h('div', { class: 'et', text: title }),
    h('div', { class: 'ed', text: desc }),
    acts.length ? h('div', {}, ...acts) : null);
}

function render() {
  if (!S.snapshot) { main.replaceChildren(skeleton()); return; }
  if (S.snapshot.app.state === 'needs_key' && !localStorage.getItem('eg-onboard') && S.tab === 'overview') {
    main.replaceChildren(renderOnboard());
    return;
  }
  const pages = {
    overview: renderOverview,
    models: renderModels,
    requests: renderRequests,
    connect: renderConnect,
    secrets: renderSecrets,
    settings: renderSettings,
    diag: renderDiag,
  };
  main.replaceChildren(h('div', { class: 'fade-in' }, pages[S.tab] ? pages[S.tab]() : h('div', {})));
  if (S.tab === 'models' && !S.models) loadModels();
  if (S.tab === 'requests' && !S.requests) loadRequests();
  if (S.tab === 'connect' && !S.connect) loadConnect();
  if (S.tab === 'secrets' && !S.secrets) loadSecrets();
  if (S.tab === 'settings' && !S.config) loadConfig();
  if (S.tab === 'diag' && !S.diag) loadDiag();
}

function renderTop() {
  const snap = S.snapshot;
  if (!snap) return;
  const state = snap.app.state;
  document.getElementById('state-dot').className = `dot ${STATE_CLASS[state] || ''}`;
  document.getElementById('state-text').textContent = STATE_LABEL[state] || state;
  document.getElementById('app-ver').textContent = snap.app.version ? `v${snap.app.version}` : '';

  const gw = document.getElementById('gw-url');
  gw.textContent = snap.gateway.addresses[0] || '—';

  // 提示条优先级：config/port/persist 错误 > needs_key（引导页出现时不显示，向导即替代物）
  const banner = document.getElementById('banner');
  const reason = snap.app.reason;
  const isError = STATE_CLASS[state] === 'error';
  const onWizard = state === 'needs_key' && S.tab === 'overview' && !localStorage.getItem('eg-onboard');
  if (reason && state !== 'ready' && !onWizard) {
    banner.classList.remove('hidden');
    banner.classList.toggle('err', isError);
    banner.replaceChildren(
      icon(isError ? 'alert' : 'key', 'ic'),
      h('span', { text: reason }),
      h('div', { class: 'bn-act' },
        state === 'needs_key'
          ? h('a', { class: 'linklike', text: '去填写 Key →', onclick: () => switchTab('secrets') })
          : state === 'port_conflict'
            ? h('a', { class: 'linklike', text: '查看诊断', onclick: () => switchTab('diag') })
            : null),
    );
  } else {
    banner.classList.add('hidden');
  }
  tickReset();
}

function tickReset() {
  const el = document.getElementById('reset-in');
  if (!S.snapshot) return;
  const target = new Date(S.snapshot.quotaDay.nextResetAt).getTime();
  const diff = target - Date.now();
  if (Number.isNaN(diff)) { el.textContent = '—'; return; }
  const remaining = diff > 0 ? `${fmtDuration(diff)}后` : '即将重置';
  el.textContent = remaining;
}
setInterval(tickReset, 30000);

function switchTab(tab) {
  S.tab = tab;
  if (tab === 'overview') S.unread = 0;
  document.querySelectorAll('#nav button[data-tab]').forEach((b) => {
    b.classList.toggle('active', b.dataset.tab === tab);
  });
  renderNavBadge();
  render();
}

function renderNavBadge() {
  const btn = document.querySelector('#nav button[data-tab="overview"]');
  const old = btn.querySelector('.nav-badge');
  if (old) old.remove();
  if (S.unread > 0 && S.tab !== 'overview') {
    btn.append(h('span', { class: 'nav-badge', text: String(S.unread) }));
  }
}

document.querySelectorAll('#nav button[data-tab]').forEach((btn) => {
  btn.addEventListener('click', () => switchTab(btn.dataset.tab));
});

document.getElementById('copy-gw').addEventListener('click', (e) => {
  const url = S.snapshot?.gateway?.addresses?.[0];
  if (url) copy(url, '已复制网关地址', e.currentTarget);
});

document.getElementById('exit').addEventListener('click', async () => {
  const ok = await confirmDialog({
    title: '退出 eatgemini？',
    body: '网关将停止监听，酒馆和 pockettavern 会立即断开。',
    okText: '退出',
  });
  if (!ok) return;
  try {
    await api('/api/app/exit', { method: 'POST' });
    toast('正在退出…', 'info');
  } catch (e) {
    toast(e.message, 'err');
  }
});

// ---------------------------------------------------------------- 事件环（客户端内存，重载即清）

function noteEvent(tone, title, desc, rqId = null) {
  S.events.unshift({ at: new Date(), tone, title, desc, rqId });
  if (S.events.length > 50) S.events.pop();
  if (S.tab !== 'overview') {
    S.unread = Math.min(99, S.unread + 1);
    renderNavBadge();
  }
}

function pill(text, cls) {
  return h('span', { class: `pill ${cls || ''}` },
    cls && cls !== 'line' ? h('span', { class: 'pdot' }) : null,
    text);
}

// ---------------------------------------------------------------- 概览

const HOUR_SLOTS = 30; // 30 × 2 分钟 = 最近一小时
function hourSlotId(ms) { return Math.floor(ms / 120000); }
function recordHour(startedMs, outcome, fellBack) {
  const id = hourSlotId(startedMs || Date.now());
  const b = S.hour.get(id) || { ok: 0, fail: 0, fb: 0 };
  if (outcome === 'succeeded') b.ok += 1;
  else if (String(outcome).startsWith('failed')) b.fail += 1;
  if (fellBack) b.fb += 1;
  S.hour.set(id, b);
  const cutoff = hourSlotId(Date.now()) - HOUR_SLOTS;
  for (const k of S.hour.keys()) if (k < cutoff) S.hour.delete(k);
}
function seedHourFromSnapshot() {
  for (const r of S.snapshot.recentRequests || []) {
    recordHour(new Date(r.startedAt).getTime(), r.outcome, r.fellBack === true);
  }
}

function hourChart() {
  const cur = hourSlotId(Date.now());
  const cols = [];
  for (let i = HOUR_SLOTS - 1; i >= 0; i--) {
    const id = cur - i;
    const b = S.hour.get(id) || { ok: 0, fail: 0, fb: 0 };
    const total = Math.max(1, b.ok + b.fail);
    const col = h('div', { class: 'col', title: `${b.ok} 成功 / ${b.fail} 失败 / ${b.fb} 降级` });
    const er = h('div', { class: 'er' });
    const fl = h('div', { class: 'fl' });
    const ok = h('div', { class: 'ok' });
    er.style.height = `${Math.max(4, (b.fail / total) * 100)}%`;
    fl.style.height = `${Math.max(4, (b.fb / total) * 100)}%`;
    ok.style.height = `${Math.max(5, ((b.ok - 0) / total) * 100)}%`;
    if (b.fail) col.append(er);
    if (b.fb) col.append(fl);
    col.append(ok);
    cols.push(col);
  }
  return h('div', { class: 'chart-hour' }, ...cols);
}

function eventTimeline(items, withLinks = true) {
  if (!items.length) {
    return emptyState('inbox', '暂无事件', '降级、封锁恢复、客户端接入等事件会出现在这里（本页打开后开始记录）。');
  }
  return h('div', { class: 'tl' }, ...items.map((e) => h('div', { class: 'tl-item' },
    h('span', { class: `tl-dot ${e.tone}` }),
    h('div', { class: 'tl-head' }, h('b', { text: e.title }), h('span', { class: 'tl-time', text: fmtTime(e.at) })),
    h('div', { class: 'tl-desc' },
      h('span', { text: e.desc + (e.rqId ? ' · ' : '') }),
      e.rqId && withLinks
        ? h('a', { class: 'linklike', text: '查看请求 →', onclick: () => openDetail(e.rqId) })
        : null))));
}

function renderOverview() {
  const snap = S.snapshot;
  const t = snap.today;
  const okPct = t.requests ? Math.round((t.succeeded / t.requests) * 1000) / 10 : 100;

  const stat = (iconName, label, value, sub, cls = '', act = null) => {
    const el = h('div', { class: `stat ${cls}` },
      h('div', { class: 'k' }, icon(iconName), h('span', { text: label })),
      h('div', { class: 'v', text: String(value ?? 0) }),
      sub ? h('div', { class: 'sub', text: sub }) : null);
    if (act) {
      el.classList.add('clickable');
      el.addEventListener('click', act);
    }
    return el;
  };

  const cards = h('div', { class: 'grid c6' },
    stat('pulse', '今日请求', t.requests, `上游发送 ${t.upstreamAttempts}`),
    stat('check-c', '成功', t.succeeded, `${okPct}%`),
    stat('x-c', '失败', t.failed, t.failed > 0 ? '点击查看' : '无失败', t.failed > 0 ? '' : '',
      t.failed > 0 ? () => { S.req.outcome = 'failed_before_commit'; switchTab('requests'); } : null),
    stat('arrow-down', '发生降级', t.fellBack ?? 0, (t.fellBack ?? 0) > 0 ? '最近事件见下方 · 点击查看' : '未发生', (t.fellBack ?? 0) > 0 ? 'hl-warn' : '',
      (t.fellBack ?? 0) > 0 ? () => { S.req.fallbackOnly = true; S.req.outcome = 'all'; switchTab('requests'); } : null),
    stat('clock', '结果不确定', t.uncertainAttempts ?? 0, '配额按已发保留'),
    stat('phone', '档位可用', `${snap.profiles.filter((p) => p.state === 'available').length}/${snap.profiles.length}`,
      '点击查看模型详情', '', () => switchTab('models')),
  );

  const hourCard = h('div', { class: 'card flush' },
    h('div', { class: 'card-head' },
      h('div', {},
        h('h3', { text: '最近一小时' }),
        h('div', { class: 'sub', text: '每 2 分钟一根 · 本页打开后开始累计' })),
      h('div', { class: 'chart-legend' },
        h('span', {}, h('i', { css: { background: 'var(--ok)' } }), '成功'),
        h('span', {}, h('i', { css: { background: 'var(--err)' } }), '失败'),
        h('span', {}, h('i', { css: { background: 'var(--warn)' } }), '降级'))),
    h('div', { class: 'card-body' },
      hourChart(),
      h('div', { class: 'chart-x' },
        h('span', { text: fmtTime(new Date(Date.now() - 55 * 60000).toISOString()) }),
        h('span', { text: fmtTime(new Date(Date.now() - 30 * 60000).toISOString()) }),
        h('span', { text: fmtTime(new Date().toISOString()) }))),
  );

  const evCard = h('div', { class: 'card' },
    h('div', { class: 'row between' },
      h('h3', { text: '最近事件' }),
      h('a', { class: 'linklike', text: '查看全部', onclick: openEventsDrawer })),
    h('div', { class: 'tl', css: { marginTop: '10px' } },
      ...buildEventList(S.events.slice(0, 4))),
  );

  const statusCard = h('div', { class: 'card' },
    h('div', { class: 'row between' },
      h('h3', { text: '服务状态' }),
      h('button', { class: 'btn btn-ghost btn-sm', text: '重新检查上游', onclick: (e) => checkUpstream(e.currentTarget) })),
    h('div', { class: 'kv', css: { marginTop: '10px' } },
      h('span', { class: 'k', text: '应用状态' }),
      h('span', { text: STATE_LABEL[snap.app.state] || snap.app.state }),
      h('span', { class: 'k', text: '上游 Key' }),
      h('span', { text: snap.upstream.configured ? '已配置' : '未配置' }),
      h('span', { class: 'k', text: '最近检查' }),
      h('span', {
        text: snap.upstream.lastCheck
          ? `${snap.upstream.lastCheck.ok ? '正常' : '失败'} · ${fmtAgo(snap.upstream.lastCheck.at)} · ${snap.upstream.lastCheck.latencyMs} ms`
          : '尚未检查',
      }),
      h('span', { class: 'k', text: '监听' }),
      h('span', { text: snap.gateway.addresses.join('  ') })),
  );

  const inflight = h('div', { class: 'card' },
    h('h3', { text: '进行中' }),
    snap.inFlight.length === 0
      ? h('div', { class: 'muted small', text: '暂无请求' })
      : h('div', { class: 'tbl-wrap', css: { border: '0' } },
          h('table', {},
            h('thead', {}, h('tr', {},
              h('th', { text: '客户端' }), h('th', { text: '档位' }),
              h('th', { text: '模型' }), h('th', { text: '阶段' }), h('th', { text: '已用' }))),
            h('tbody', {}, ...snap.inFlight.map((r) => h('tr', {},
              h('td', { text: r.client }),
              h('td', { text: r.profile || '—' }),
              h('td', { class: 'mono', text: r.model || '—' }),
              h('td', { text: phaseLabel(r.phase) }),
              h('td', { class: 'num', text: fmtDuration(r.elapsedMs) })))))),
  );

  const profileCards = h('div', { class: 'grid c3' },
    ...snap.profiles.map((p) => {
      const cls = p.state === 'available' ? 'ok' : p.state === 'limited' ? 'warn' : 'err';
      return h('div', { class: 'card' },
        h('div', { class: 'row between' },
          h('strong', { class: 'mono', text: `router:${p.id}` }),
          pill(p.state === 'available' ? '可用' : p.state === 'limited' ? '受限' : '不可用', cls)),
        h('div', { class: 'small muted', css: { marginTop: '6px' }, text: p.nextModel ? `下一个：${p.nextModel}` : '没有可用候选' }),
        h('div', { class: 'small muted', text: `${p.availableModels}/${p.totalModels} 个模型可用` }),
        p.retryAt ? h('div', { class: 'small', css: { marginTop: '4px' }, text: `最早 ${fmtTime(p.retryAt)} 恢复` }) : null);
    }));

  const recent = h('div', { class: 'card' },
    h('h3', { text: '最近请求' }),
    snap.recentRequests.length === 0
      ? emptyState('inbox', '还没有请求', '接入酒并发送第一条消息后，这里会显示每次请求的轨迹。')
      : requestTable(snap.recentRequests.slice(0, 10), true),
  );

  return h('div', {},
    pageHead('概览', '额度与请求的总览 · 太平洋日重置',
      h('button', { class: 'btn btn-soft btn-sm', text: '刷新', onclick: (e) => { const d = busy(e.currentTarget, '刷新中'); refreshSnapshot().finally(d); } })),
    cards,
    h('div', { class: 'grid split', css: { marginTop: '12px' } }, hourCard, evCard),
    h('div', { class: 'grid split', css: { marginTop: '12px' } }, statusCard, inflight),
    h('h3', { text: '档位' }),
    profileCards,
    h('h3', { text: '最近' }),
    recent,
  );
}

function buildEventList(items) {
  return items.map((e) => h('div', { class: 'tl-item' },
    h('span', { class: `tl-dot ${e.tone}` }),
    h('div', { class: 'tl-head' }, h('b', { text: e.title }), h('span', { class: 'tl-time', text: fmtTime(e.at) })),
    h('div', { class: 'tl-desc' },
      h('span', { text: e.desc + (e.rqId ? ' · ' : '') }),
      e.rqId ? h('a', { class: 'linklike', text: '查看请求 →', onclick: () => openDetail(e.rqId) }) : null)));
}

function openEventsDrawer() {
  const chips = h('div', { class: 'chipbar', css: { marginBottom: '14px' } });
  const cats = [['all', '全部'], ['degrade', '降级'], ['system', '系统']];
  const list = h('div', { class: 'tl' });
  const renderList = () => {
    const items = S.events.filter((e) => S.eventFilter === 'all'
      || (S.eventFilter === 'degrade' ? e.tone === 'warn' : e.tone !== 'warn'));
    list.replaceChildren(...(items.length
      ? buildEventList(items)
      : [emptyState('inbox', '该类型暂无事件', '事件在本页打开后开始记录，重启后清空。')]));
  };
  for (const [id, label] of cats) {
    chips.append(h('button', {
      class: `chip${S.eventFilter === id ? ' on' : ''}`,
      text: label,
      onclick: (e) => {
        S.eventFilter = id;
        chips.querySelectorAll('.chip').forEach((c) => c.classList.remove('on'));
        e.currentTarget.classList.add('on');
        renderList();
      },
    }));
  }
  renderList();
  overlay.replaceChildren(
    h('div', { class: 'drawer-mask', onclick: closeOverlay }),
    h('div', { class: 'drawer' },
      h('div', { class: 'drawer-head' },
        h('div', {},
          h('h3', { text: '最近事件' }),
          h('div', { class: 'sub', text: '本页打开后开始记录 · 重启即清空 · 不落盘' })),
        h('button', { class: 'iconbtn', onclick: closeOverlay, title: '关闭' }, icon('x'))),
      h('div', { class: 'drawer-body' }, chips, list)),
  );
}

function phaseLabel(phase) {
  return {
    sending: '发送中',
    waiting_first_event: '等待首字',
    streaming: '输出中',
    done: '完成',
    failed: '失败',
    skipped: '跳过',
  }[phase] || phase;
}

function outcomePill(outcome) {
  const map = {
    succeeded: ['ok', '成功'],
    failed_before_commit: ['err', '失败'],
    failed_after_commit: ['warn', '中断'],
    cancelled: ['line', '取消'],
  };
  const [cls, label] = map[outcome] || ['line', outcome];
  return pill(label, cls);
}

async function checkUpstream(btn) {
  const done = busy(btn, '检查中…');
  try {
    const r = await api('/api/upstream/check', { method: 'POST' });
    toast(r.ok ? `上游正常（${r.latencyMs} ms）` : `上游失败：${r.message}`, r.ok ? 'ok' : 'err');
    await refreshSnapshot();
  } catch (e) {
    toast(e.message, 'err');
  } finally {
    done();
  }
}

// ---------------------------------------------------------------- 首次启动引导（F01，纯前端；完成标记存本机）

function renderOnboard() {
  const st = S.onboarding;
  const step = (n, label) => h('div', { class: `wstep ${st.step === n ? 'on' : st.step > n ? 'done' : ''}` },
    h('span', { class: 'wn' }, st.step > n ? icon('check', 'ic ic-12') : h('span', { text: String(n) })),
    h('span', { text: label }));
  const line = (done) => h('div', { class: `wline${done ? ' done' : ''}` });

  const keyInput = h('input', {
    class: 'input mono', type: 'password', placeholder: '粘贴 Google API Key', autocomplete: 'off', spellcheck: 'false', id: 'wiz-key',
  });
  const hint = h('div', { css: { minHeight: '22px', marginTop: '10px' } });

  let body;
  if (st.step === 1) {
    body = h('div', { class: 'card' },
      h('div', { class: 'field' },
        h('span', { class: 'label' }, h('span', { text: 'Google API Key' }), h('span', { class: 'req', text: '*' })),
        h('div', { class: 'input-wrap has-trail' },
          keyInput,
          h('button', {
            class: 'iconbtn trail', title: '显示/隐藏', type: 'button',
            onclick: () => { keyInput.type = keyInput.type === 'password' ? 'text' : 'password'; },
          }, icon('eye'))),
        h('span', { class: 'hint', text: '在 Google AI Studio 免费创建。保存前会先验证有效性（不消耗额度）。DPAPI 本机加密，不会上传。' })),
      hint,
      h('div', { class: 'row', css: { marginTop: '10px' } },
        h('button', {
          class: 'btn btn-soft', type: 'button',
          onclick: async (e) => {
            const v = keyInput.value.trim();
            if (!v) { toast('请先填写 Key', 'err'); return; }
            const done = busy(e.currentTarget, '测试中…');
            hint.replaceChildren();
            try {
              const r = await api('/api/secrets/upstream/verify', { method: 'POST', body: { apiKey: v } });
              hint.replaceChildren(h('span', { class: 'small', css: { color: r.ok ? 'var(--ok)' : 'var(--err)' }, text: r.message }));
            } catch (err) {
              hint.replaceChildren(h('span', { class: 'small', css: { color: 'var(--err)' }, text: err.message }));
            } finally { done(); }
          },
        }, icon('check-c'), h('span', { text: '测试（不耗额度）' })),
        h('button', {
          class: 'btn btn-primary', type: 'button',
          onclick: async (e) => {
            const v = keyInput.value.trim();
            if (!v) { toast('请先填写 Key', 'err'); return; }
            const done = busy(e.currentTarget, '保存中…');
            try {
              await api('/api/secrets/upstream', { method: 'PUT', body: { apiKey: v, sameProject: true, projectRef: null } });
              toast('Key 已保存（DPAPI 本机加密）');
              await refreshSnapshot();
              S.onboarding.step = 2;
              S.onboarding.test = 'idle';
              render();
            } catch (err) {
              toast(err.message, 'err');
            } finally { done(); }
          },
        }, h('span', { text: '保存并下一步' }), icon('chev-r')),
        h('span', { class: 'hint right', text: '第 1 / 3 步' })));
  } else if (st.step === 2) {
    body = h('div', { class: 'card' },
      h('div', { class: 'dim small', text: '正在检测到 Google API 的连通性（不消耗额度）…' }),
      h('div', { id: 'w-net', css: { marginTop: '10px' } },
        st.test === 'idle'
          ? h('div', { class: 'row' }, h('span', { class: 'spin dim' }), h('span', { class: 'small muted', text: ' 检测中…' }))
          : st.test === 'ok'
            ? h('div', { class: 'row' },
                icon('shield-ok', 'ic'), h('span', { class: 'small', text: 'Google API 可达 · 直连' }))
            : h('div', { class: 'row' },
                icon('alert', 'ic'), h('span', { class: 'small', text: '上游检测失败 · 可先跳过，修复后到「设置」重测' }))),
      h('div', { class: 'row', css: { marginTop: '16px' } },
        h('button', { class: 'btn btn-ghost', text: '上一步', onclick: () => { S.onboarding.step = 1; render(); } }),
        h('button', { class: 'btn btn-primary', text: '下一步', onclick: () => { S.onboarding.step = 3; render(); } }),
        h('a', { class: 'linklike right', text: '跳过，稍后再测', onclick: () => { S.onboarding.step = 3; render(); } })));
    if (st.test === 'idle') {
      setTimeout(async () => {
        try {
          const r = await api('/api/upstream/check', { method: 'POST' });
          S.onboarding.test = r.ok ? 'ok' : 'fail';
        } catch (_) { S.onboarding.test = 'fail'; }
        if (S.tab === 'overview' && S.onboarding.step === 2) render();
      }, 900);
    }
  } else {
    const gwUrl = S.snapshot?.gateway?.addresses?.[0] || '—';
    body = h('div', {},
      h('div', { class: 'grid c2' },
        h('div', { class: 'card' },
          h('b', { text: 'SillyTavern' }),
          h('div', { class: 'small muted', css: { margin: '6px 0 8px' }, text: 'API 选「自定义（兼容 OpenAI）」，地址填：' }),
          h('span', { class: 'code', text: gwUrl })),
        h('div', { class: 'card' },
          h('b', { text: 'pockettavern（手机）' }),
          h('div', { class: 'small muted', css: { margin: '6px 0 8px' }, text: '去「接入」页复制连接码或扫码：' }),
          h('a', { class: 'linklike', text: '打开完整接入页 →', onclick: () => { localStorage.setItem('eg-onboard', '1'); switchTab('connect'); } }))),
      h('div', { class: 'card', css: { marginTop: '12px' } },
        h('div', { class: 'switch-row' },
          h('span', { class: 'switch' },
            h('input', { type: 'checkbox', onchange: async (e) => {
              try {
                await api('/api/app/listen', { method: 'POST', body: { mode: e.target.checked ? 'lan' : 'loopback' } });
                toast(e.target.checked ? '已切换局域网模式' : '已切换仅本机');
                await refreshSnapshot();
              } catch (err) { toast(err.message, 'err'); e.target.checked = !e.target.checked; }
            } }),
            h('span', { class: 'tr' }), h('span', { class: 'kn' })),
          h('span', {},
            h('div', { class: 'st', text: '手机要连？切换局域网模式' }),
            h('div', { class: 'sd', text: '酒馆与电脑在同一 Wi-Fi 时开启（「接入」页可随时改）' })))),
      h('div', { class: 'row', css: { marginTop: '16px' } },
        h('button', { class: 'btn btn-ghost', text: '上一步', onclick: () => { S.onboarding.step = 2; render(); } }),
        h('button', {
          class: 'btn btn-primary', type: 'button',
          onclick: () => {
            localStorage.setItem('eg-onboard', '1');
            toast('引导完成 · 可在「设置」调整档位与高级参数');
            refreshSnapshot();
          },
        }, h('span', { text: '完成引导，进入概览' }), icon('check'))),
    );
  }

  return h('div', { class: 'fade-in', css: { maxWidth: '680px', margin: '0 auto', paddingTop: '16px' } },
    pageHead('三步接入，酒馆出字', '全程约 5 分钟。Key 只保存在这台电脑（DPAPI 本机加密），不会上传。'),
    h('div', { class: 'wiz-steps' }, step(1, '填写 Key'), line(st.step > 1), step(2, '测上游'), line(st.step > 2), step(3, '接入酒馆')),
    body,
    h('div', { class: 'card', css: { marginTop: '12px' } },
      h('div', { class: 'row' },
        icon('info', 'ic'), 
        h('span', { class: 'small muted' },
          '遇到问题随时点左下角「诊断」查看连接报告，或',
          h('a', { class: 'linklike', text: '跳过引导', onclick: () => { localStorage.setItem('eg-onboard', '1'); refreshSnapshot(); } }),
          '。'))));
}

// ---------------------------------------------------------------- 模型与额度

async function loadModels() {
  try {
    S.models = await api('/api/models');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'models') render();
}

function statePill(m) {
  const map = {
    available: ['ok', '正常'],
    cooldown: ['warn', '冷却中'],
    limited: ['warn', '疑似用完'],
    exhausted: ['err', '今日用完'],
    unavailable: ['err', '无权限'],
    blocked: ['err', '已停用'],
  };
  const [cls, label] = map[m.state] || ['line', m.state];
  return pill(label, cls);
}

function meterHtml(label, used, limit) {
  const pct = limit ? Math.min(100, Math.round((used / limit) * 100)) : 45;
  const cls = pct >= 90 ? 'err' : pct >= 75 ? 'warn' : limit ? '' : 'blocked';
  const wrap = h('div', { class: `meter ${cls}` },
    h('div', { class: 'cap' },
      h('span', { text: label }),
      h('b', { text: `${used ?? 0} / ${limit ?? '未知'}` })),
    h('div', { class: 'track' }, h('div', { class: 'fill' })));
  wrap.querySelector('.fill').style.width = `${limit ? pct : 45}%`;
  return wrap;
}

function modelDetail(m) {
  const b = m.blockedUntil ? new Date(m.blockedUntil) : null;
  const blocked = m.state !== 'available' && m.state !== 'blocked';
  const src = m.confirmed ? '上游确认' : '本地估算';
  const explain = h('div', {},
    h('div', { class: 'dim small', css: { fontWeight: '600', marginBottom: '8px' }, text: '状态解释 · 最近一次' }));
  if (blocked) {
    explain.append(h('div', { class: 'kv', css: { gridTemplateColumns: '64px 1fr' } },
      h('span', { class: 'k', text: '来源' }),
      h('span', { class: 'v' }, pill(src, m.confirmed ? 'err' : 'info')),
      h('span', { class: 'k', text: '证据' }),
      h('span', { class: 'v small', text: m.notes || '—' }),
      h('span', { class: 'k', text: '恢复' }),
      h('span', { class: 'v', text: b && !Number.isNaN(b.getTime())
        ? `${fmtAgo(m.blockedUntil)}自动探测` : '由探测节奏决定' })));
  } else {
    explain.append(h('div', { class: 'small dim', text: '当前无封锁，正常消耗配额。' }));
  }
  explain.append(
    h('div', { class: 'dim small', css: { fontWeight: '600', margin: '12px 0 6px' }, text: '配额桶' }),
    h('div', {}, m.bucketId ? h('span', { class: 'code', text: m.bucketId }) : h('span', { class: 'dim small', text: '—' })),
  );
  const cap = h('div', {},
    h('div', { class: 'dim small', css: { fontWeight: '600', marginBottom: '8px' }, text: '上下限' }),
    h('div', { class: 'kv', css: { gridTemplateColumns: '64px 1fr' } },
      h('span', { class: 'k', text: '输入' }),
      h('span', { class: 'v', text: Number.isInteger(m.inputTokenLimit) && m.inputTokenLimit > 0 ? `${m.inputTokenLimit.toLocaleString('en-US')} tokens` : '未知' }),
      h('span', { class: 'k', text: '最大输出' }),
      h('span', { class: 'v', text: Number.isInteger(m.outputTokenLimit) && m.outputTokenLimit > 0 ? `${m.outputTokenLimit.toLocaleString('en-US')} tokens` : '未知' })));
  return h('td', { colspan: '7' },
    h('div', { class: 'detail-inner' },
      h('div', { class: 'grid c3' }, explain, cap,
        h('div', {},
          h('div', { class: 'dim small', css: { fontWeight: '600', marginBottom: '8px' }, text: '分钟 RPM' }),
          meterHtml('RPM · 近 60 秒', m.rpmUsed ?? 0, m.rpmLimit ?? null)))));
}

function modelRow(m) {
  const exp = S.expandedModel === m.id;
  const row = h('tr', { class: `data-row clickable${exp ? ' expanded' : ''}` },
    h('td', { css: { paddingRight: '0', width: '34px' } }, icon('chev-d', `ic chev${exp ? ' ic-accent' : ''}`)),
    h('td', {},
      h('div', { class: 'cell-main mono', text: m.id }),
      m.notes && !exp ? h('div', { class: 'cell-sub', text: m.notes }) : null),
    h('td', {},
      h('span', { class: 'switch', onclick: (e) => e.stopPropagation() }, // 切换开关不触发行展开
        h('input', {
          type: 'checkbox', checked: m.enabled,
          onchange: async (e) => {
            e.target.checked = m.enabled; // 先回滚，成功后再刷新
            try {
              await api(`/api/models/${encodeURIComponent(m.id)}/enabled`, { method: 'POST', body: { enabled: !m.enabled } });
              toast('已保存');
              S.models = await api('/api/models');
              render();
            } catch (err) { toast(err.message, 'err'); }
          },
        }),
        h('span', { class: 'tr' }), h('span', { class: 'kn' }))),
    h('td', { text: m.profiles.join(' / ') || '—' }),
    h('td', { class: 'num', text: `${m.rpmUsed ?? 0} / ${m.rpmLimit ?? '未知'}` }),
    h('td', {}, meterHtml('RPD · 太平洋今日', m.rpd?.used ?? 0, m.rpd?.limit ?? null)),
    h('td', {}, statePill(m)),
    h('td', {},
      h('span', { class: 'has-tip' },
        h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button',
          disabled: m.confirmed || m.state === 'available',
          onclick: async (e) => {
            e.stopPropagation();
            try {
              await api(`/api/buckets/${encodeURIComponent(m.bucketId)}/clear-local-estimate`, { method: 'POST' });
              toast('已清除本地估算 · 上游确认的封锁不受影响');
              S.models = await api('/api/models');
              render();
            } catch (err) { toast(err.message, 'err'); }
          },
        }, icon('undo', 'ic ic-13'), h('span', { text: '清除本地估算' })),
        h('span', { class: 'tip', text: '清除的是本机「疑似用完」推测。若 Google 侧确实已封锁，下一次请求会重新标记；上游确认的封锁不能清除。' }))),
  );
  row.addEventListener('click', () => {
    S.expandedModel = S.expandedModel === m.id ? null : m.id;
    render();
  });
  if (!exp) return [row];
  const detail = h('tr', { class: 'detail-row' }, modelDetail(m));
  detail.addEventListener('click', (e) => e.stopPropagation());
  return [row, detail];
}

function renderModels() {
  if (!S.models) return h('div', { class: 'muted', text: '读取中…' });
  return h('div', {},
    pageHead('模型与额度', '限额来自模型配置与 Google 返回 · 「本地估算」指网关依据 429 推断，非官方数据',
      h('button', {
        class: 'btn btn-ghost btn-sm', type: 'button',
        onclick: async (e) => {
          const done = busy(e.currentTarget, '对账中…');
          try {
            const r = await api('/api/router/refresh', { method: 'POST' });
            toast(r.summary || '已读取上游模型列表');
          } catch (err) { toast(err.message, 'err'); } finally { done(); }
        },
      }, icon('refresh', 'ic ic-13'), h('span', { text: '对账模型列表' }))),
    S.models.models.length === 0
      ? h('div', { class: 'card' }, emptyState('quota', '没有模型', '配置里没有可用模型，请检查 config.json 的 models 段。'))
      : h('div', { class: 'tbl-wrap' },
          h('table', {},
            h('thead', {}, h('tr', {},
              h('th', { css: { width: '34px' } }),
              h('th', { text: '模型' }), h('th', { text: '启用' }), h('th', { text: '档位' }),
              h('th', { class: 'num', text: '分钟 RPM' }), h('th', { text: '今日 RPD' }),
              h('th', { text: '状态' }), h('th', { text: '' }))),
            h('tbody', {}, ...S.models.models.flatMap(modelRow)))),
    h('div', { class: 'small dim', css: { marginTop: '10px' } },
      '为网关本地统计，与 Google AI Studio 口径可能不同。点击行展开状态解释。'),
  );
}

// ---------------------------------------------------------------- 请求记录

async function loadRequests() {
  try {
    S.requests = await api('/api/requests?limit=200');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'requests') render();
}

let requestsTimer = null;
function scheduleLoadRequests() {
  if (requestsTimer) return;
  requestsTimer = setTimeout(() => {
    requestsTimer = null;
    if (S.tab === 'requests') loadRequests();
  }, 600);
}

let diagTimer = null;
function scheduleLoadDiag() {
  if (diagTimer) return;
  diagTimer = setTimeout(() => {
    diagTimer = null;
    if (S.tab === 'diag') loadDiag();
  }, 600);
}

function filteredRequests() {
  const items = S.requests?.items || [];
  const f = S.req;
  const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
  const threeDays = Date.now() - 72 * 3600 * 1000;
  return items.filter((r) => {
    if (f.fallbackOnly && r.fellBack !== true) return false;
    if (f.client !== 'all' && r.client !== f.client) return false;
    if (f.outcome !== 'all' && r.outcome !== f.outcome) return false;
    if (f.model !== 'all' && (r.servedModel || '') !== f.model) return false;
    if (f.time === 'today' && new Date(r.startedAt) < todayStart) return false;
    if (f.time === '3d' && new Date(r.startedAt).getTime() < threeDays) return false;
    if (f.q) {
      const q = f.q.toLowerCase();
      const hay = `${r.requestId} ${r.requestedModel} ${r.servedModel || ''} ${r.client}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

function shortModel(m) {
  return m ? m.replace(/^gemini-2\.5-/, '') : '—';
}

function requestTable(items, compact = false) {
  return h('table', {},
    h('thead', {}, h('tr', {},
      h('th', { text: '时间' }),
      h('th', { text: '客户端' }),
      compact ? null : h('th', { text: '请求模型' }),
      h('th', { text: '结果' }),
      compact ? null : h('th', { text: '实际模型' }),
      h('th', { class: 'num', text: '尝试' }),
      h('th', { class: 'num', text: '耗时' }),
      compact ? null : h('th', { css: { width: '30px' } }))),
    h('tbody', {}, ...items.map((r) => {
      const row = h('tr', { class: `data-row clickable${S.knownIds.has(r.requestId) ? '' : ' flash'}` },
        h('td', { class: 'mono dim', text: fmtTime(r.startedAt) }),
        h('td', { text: r.client }),
        compact ? null : h('td', { class: 'mono', text: r.requestedModel }),
        h('td', {}, outcomePill(r.outcome),
          r.errorCode ? h('div', { class: 'cell-sub', text: r.errorCode }) : null),
        compact ? null : h('td', { class: 'mono', text: r.servedModel ? shortModel(r.servedModel) : '—' }),
        h('td', { class: 'num', text: String(r.attempts ?? '—') }),
        h('td', { class: 'num', text: fmtDuration(r.totalMs) }),
        compact ? null : h('td', {}, icon('chev-r', 'ic chev ic-13')),
      );
      row.addEventListener('click', () => openDetail(r.requestId));
      return row;
    })),
  );
}

function renderRequests() {
  if (!S.requests) return h('div', { class: 'muted', text: '读取中…' });
  const items = S.requests.items || [];
  const f = S.req;

  const clients = [...new Set(items.map((r) => r.client))];
  const models = [...new Set(items.map((r) => r.servedModel).filter(Boolean))];
  const sel = (key, opts, width) => h('select', { class: 'eg-sel', css: { width } },
    ...opts.map(([v, label]) => h('option', { value: v, selected: f[key] === v, text: label })));

  const search = h('div', { class: 'input-wrap has-trail', css: { flex: '1', minWidth: '230px' } },
    h('input', {
      class: 'input', id: 'req-q', placeholder: '粘贴请求 ID 或输入模型 / 客户端，回车直达详情…（快捷键 /）',
      value: f.q,
      oninput: (e) => { f.q = e.target.value.trim(); renderReqRows(); },
      onkeydown: (e) => {
        if (e.key !== 'Enter') return;
        const q = f.q;
        if (/^rq_/i.test(q)) {
          const hit = items.find((r) => r.requestId.toLowerCase() === q.toLowerCase());
          if (hit) { openDetail(hit.requestId); return; }
          openDetail(q); // 让后端判定存在性
          return;
        }
        renderReqRows();
      },
    }),
    h('button', { class: 'iconbtn trail', type: 'button', onclick: () => main.querySelector('#req-q')?.focus() },
      icon('search', 'ic ic-dim')));

  const table = h('div', { class: 'tbl-wrap' },
    items.length === 0
      ? h('div', { class: 'empty' },
          emptyState('inbox', '还没有请求记录',
            '接入酒并发送第一条消息后，这里会显示每次请求的完整轨迹。',
            h('button', { class: 'btn btn-soft btn-sm', text: '查看接入方式', onclick: () => switchTab('connect') })))
      : h('table', {},
          h('thead', {}, h('tr', {},
            h('th', { text: '时间' }), h('th', { text: '客户端' }), h('th', { text: '请求模型' }),
            h('th', { text: '结果' }), h('th', { text: '实际模型' }),
            h('th', { class: 'num', text: '尝试' }), h('th', { class: 'num', text: '耗时' }),
            h('th', { css: { width: '30px' } }))),
          h('tbody', { id: 'req-tbody' }, ...filteredRequests().map((r) => {
            const row = h('tr', { class: `data-row clickable${S.knownIds.has(r.requestId) ? '' : ' flash'}` },
              h('td', { class: 'mono dim', text: fmtTime(r.startedAt) }),
              h('td', { text: r.client }),
              h('td', { class: 'mono', text: r.requestedModel }),
              h('td', {}, outcomePill(r.outcome),
                r.errorCode ? h('div', { class: 'cell-sub', text: r.errorCode }) : null),
              h('td', { class: 'mono', text: r.servedModel ? shortModel(r.servedModel) : '—' }),
              h('td', { class: 'num', text: String(r.attempts ?? '—') }),
              h('td', { class: 'num', text: fmtDuration(r.totalMs) }),
              h('td', {}, icon('chev-r', 'ic chev ic-13')));
            row.addEventListener('click', () => openDetail(r.requestId));
            return row;
          }))),
    h('div', { id: 'req-empty' }),
  );

  const wrap = h('div', {},
    pageHead('请求记录', '保留最近 200 条 · 不记录对话内容 · 点行看尝试时间线',
      h('button', { class: 'btn btn-ghost btn-sm', text: '刷新', onclick: (e) => { const d = busy(e.currentTarget, '刷新中'); loadRequests().finally(d); } })),
    h('div', { class: 'row wrap', css: { marginBottom: '12px' } },
      search,
      sel('outcome', [['all', '结果：全部'], ['succeeded', '结果：成功'], ['failed_before_commit', '结果：失败'], ['failed_after_commit', '结果：中断'], ['cancelled', '结果：取消']], '150px'),
      sel('client', [['all', '客户端：全部'], ...clients.map((c) => [c, `客户端：${c}`])], '170px'),
      sel('model', [['all', '实际模型：全部'], ...models.map((m) => [m, `模型：${shortModel(m)}`])], '170px'),
      sel('time', [['today', '时间：今天'], ['3d', '时间：近 3 天'], ['all', '时间：全部']], '120px'),
      f.fallbackOnly
        ? h('button', {
            class: 'pill accent', type: 'button', title: '点击清除',
            onclick: () => { f.fallbackOnly = false; render(); },
          }, icon('arrow-down', 'ic'), h('span', { text: '仅看降级 ×' }))
        : null,
      h('span', { class: 'pill line', id: 'req-count', text: `共 ${filteredRequests().length} 条` })),
    S.newRequests > 0
      ? h('div', {
          class: 'insert-bar',
          onclick: () => { S.newRequests = 0; loadRequests(); },
        }, icon('arr-up', 'ic ic-13'), h('span', { text: `有 ${S.newRequests} 条新请求 · 点击插入（不自动滚动）` }))
      : null,
    table,
    h('div', { class: 'small dim', css: { marginTop: '10px' } },
      '上游未返回 Token 用量的字段不展示，避免本地估算误导。'),
  );
  // 记录本轮已见 ID，供下次渲染时闪烁标记新行
  for (const r of items) S.knownIds.add(r.requestId);
  if (S.knownIds.size > 500) S.knownIds = new Set([...S.knownIds].slice(-300));
  return wrap;
}

function renderReqRows() {
  const tb = main.querySelector('#req-tbody');
  const count = main.querySelector('#req-count');
  if (!tb) return;
  const rows = filteredRequests();
  count.textContent = `共 ${rows.length} 条`;
  if (!rows.length) {
    tb.replaceChildren(h('tr', {}, h('td', { colspan: '8' },
      emptyState('search', '没有匹配的请求', '试试放宽筛选，或粘贴完整请求 ID（rq_ 开头）回车直达详情。'))));
    return;
  }
  tb.replaceChildren(...rows.map((r) => {
    const row = h('tr', { class: `data-row clickable${S.knownIds.has(r.requestId) ? '' : ' flash'}` },
      h('td', { class: 'mono dim', text: fmtTime(r.startedAt) }),
      h('td', { text: r.client }),
      h('td', { class: 'mono', text: r.requestedModel }),
      h('td', {}, outcomePill(r.outcome),
        r.errorCode ? h('div', { class: 'cell-sub', text: r.errorCode }) : null),
      h('td', { class: 'mono', text: r.servedModel ? shortModel(r.servedModel) : '—' }),
      h('td', { class: 'num', text: String(r.attempts ?? '—') }),
      h('td', { class: 'num', text: fmtDuration(r.totalMs) }),
      h('td', {}, icon('chev-r', 'ic chev ic-13')));
    row.addEventListener('click', () => openDetail(r.requestId));
    return row;
  }));
}

async function openDetail(requestId) {
  let detail;
  try {
    detail = await api(`/api/requests/${encodeURIComponent(requestId)}`);
  } catch (e) {
    toast(e.message, 'err');
    return;
  }
  S.detail = detail;
  const tone = detail.outcome === 'succeeded' ? 'ok'
    : detail.outcome === 'cancelled' ? 'warn' : 'err';
  const attRows = (detail.attemptsDetail || []).map((a) => {
    const fail = String(a.status ?? '').startsWith('5') || (a.classification || '').includes('error')
      || ['exhausted', 'blocked'].includes(a.phase);
    return h('div', { class: 'tl-item' },
      h('span', { class: `tl-dot ${fail ? 'err' : a.status === 200 || a.phase === 'done' ? 'ok' : 'warn'}` }),
      h('div', { class: 'tl-head' },
        h('b', { class: 'mono', text: a.model }),
        h('span', { class: 'tl-time', text: `#${a.attemptId}` })),
      h('div', { class: 'tl-desc', text: `${a.phase} · ${a.status ?? '—'} · ${a.classification ?? a.reason ?? '—'} · ${a.latencyMs != null ? fmtDuration(a.latencyMs) : '—'}` }));
  });
  overlay.replaceChildren(
    h('div', { class: 'drawer-mask', onclick: closeOverlay }),
    h('div', { class: 'drawer' },
      h('div', { class: 'drawer-head' },
        h('div', {},
          h('h3', { class: 'mono', text: detail.requestId }),
          h('div', { class: 'sub', text: `${fmtTime(detail.startedAt)} · ${detail.client} · ${detail.totalMs != null ? fmtDuration(detail.totalMs) : '—'}` })),
        h('button', { class: 'iconbtn', onclick: closeOverlay, title: '关闭' }, icon('x'))),
      h('div', { class: 'drawer-body' },
        h('div', { class: 'row wrap', css: { marginBottom: '16px' } },
          outcomePill(detail.outcome),
          pill(`${detail.attempts ?? '—'} 次尝试`, 'line'),
          detail.servedModel ? pill(shortModel(detail.servedModel), 'accent') : null),
        h('div', { class: 'dim small', css: { fontWeight: '600', marginBottom: '10px' } }, '尝试时间线'),
        attRows.length
          ? h('div', { class: 'tl' }, ...attRows)
          : h('div', { class: 'small dim', text: '没有尝试明细（请求可能在本地被拒绝，未消耗上游）' }),
        h('hr', { class: 'sep' }),
        h('div', { class: 'kv' },
          h('span', { class: 'k', text: '请求 ID' }),
          h('span', { class: 'v mono', text: detail.requestId }),
          h('span', { class: 'k', text: '请求模型' }),
          h('span', { class: 'v mono', text: detail.requestedModel }),
          h('span', { class: 'k', text: '实际模型' }),
          h('span', { class: 'v mono', text: detail.servedModel || '—' }),
          h('span', { class: 'k', text: '首字' }),
          h('span', { class: 'v', text: detail.firstEventMs != null ? fmtDuration(detail.firstEventMs) : '—' }),
          h('span', { class: 'k', text: '参数调整' }),
          h('span', { class: 'v', text: (detail.transforms || []).join('、') || '无' }),
          h('span', { class: 'k', text: '跳过原因' }),
          h('span', { class: 'v', text: (detail.skipped || []).join('；') || '无' }))),
      h('div', { class: 'drawer-foot' },
        h('button', {
          class: 'btn btn-soft btn-sm', type: 'button',
          onclick: (e) => copy(detail.requestId, '已复制请求 ID', e.currentTarget),
        }, icon('copy', 'ic ic-13'), h('span', { text: '复制请求 ID' })))),
  );
}

// ---------------------------------------------------------------- 接入

async function loadConnect() {
  try {
    S.connect = await api('/api/connect');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'connect') render();
}

function kvRow(k, valueEl, ...btns) {
  return h('div', { class: 'kv' },
    h('span', { class: 'k', text: k }),
    h('div', { class: 'row' }, valueEl, ...btns));
}

function kvText(k, v) {
  return h('div', { class: 'kv' },
    h('span', { class: 'k', text: k }),
    h('span', { class: 'v' }, h('code', { class: 'code', text: v })));
}

function copyBtn(getText, label) {
  return h('button', {
    class: 'iconbtn', type: 'button', title: '复制', css: { border: '1px solid var(--line-2)' },
    onclick: async (e) => {
      try { copy(await getText(), label, e.currentTarget); } catch (err) { toast(err.message, 'err'); }
    },
  }, icon('copy'));
}

async function revealToken(client) {
  const r = await api(`/api/connect/${client}/reveal`, { method: 'POST' });
  return r.token;
}

function renderConnect() {
  if (!S.connect) return h('div', { class: 'muted', text: '读取中…' });
  const c = S.connect;

  const seg = h('div', { class: 'seg' },
    h('button', { class: c.listenMode === 'loopback' ? 'on' : '', text: '仅本机', onclick: () => saveListen('loopback') }),
    h('button', { class: c.listenMode === 'lan' ? 'on' : '', text: '局域网', onclick: () => saveListen('lan') }));

  const listenCard = h('div', { class: 'card' },
    h('div', { class: 'row between' },
      h('h3', { text: '监听范围' }),
      seg,
      h('label', { class: 'row', css: { marginLeft: 'auto', gap: '6px' } },
        h('span', { class: 'small muted', text: '端口' }),
        h('input', {
          class: 'input', type: 'number', value: String(c.port), css: { width: '100px' },
          onchange: (e) => savePort(Number(e.target.value)),
        }))),
    h('div', { class: 'small', css: { marginTop: '8px' }, text: c.listenMode === 'lan'
      ? '手机将通过局域网访问本机。Windows 可能弹出防火墙提示，请只勾选「专用网络」。不要在公共 Wi-Fi 下开启。'
      : '只接受本机连接。手机直连需要切到局域网模式。' }));

  const st = h('div', { class: 'card' },
    h('div', { class: 'row between' },
      h('h3', { text: 'SillyTavern' }),
      pill('已内置令牌', 'ok')),
    h('div', { css: { marginTop: '10px' } },
      kvText('Chat Completion Source', 'Custom (OpenAI-compatible)'),
      kvRow('Custom Endpoint', h('code', { class: 'code', text: c.sillytavern.endpoint }),
        copyBtn(() => c.sillytavern.endpoint, '已复制端点')),
      kvRow('Custom API Key', h('code', { class: 'code', text: c.sillytavern.tokenMasked }),
        h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button', text: '显示',
          onclick: async (e) => {
            const done = busy(e.currentTarget, '…');
            try { e.currentTarget.previousSibling.textContent = await revealToken('sillytavern'); }
            catch (err) { toast(err.message, 'err'); } finally { done(); }
          },
        }),
        copyBtn(() => revealToken('sillytavern'), '已复制')),
      kvText('Model', 'router:chat')),
    h('div', { class: 'small muted', css: { marginTop: '8px' } },
      '不要选 Google/MakerSuite；URL 不要附加 /chat/completions；Test Message 是真实生成。'));

  const pt = h('div', { class: 'card' },
    h('div', { class: 'row between' },
      h('h3', { text: 'pockettavern（手机）' }),
      h('button', { class: 'btn btn-soft btn-sm', type: 'button', onclick: () => toast('二维码将在后续版本提供（F11），请先用连接码', 'info') },
        icon('qr', 'ic ic-13'), h('span', { text: '显示二维码' }))),
    h('div', { css: { marginTop: '10px' } },
      ...c.pockettavern.urls.map((u, i) =>
        kvRow(c.pockettavern.urls.length > 1 ? `地址 ${i + 1}` : '地址', h('code', { class: 'code', text: u }),
          copyBtn(() => u, '已复制地址'))),
      kvRow('访问令牌', h('code', { class: 'code', text: c.pockettavern.tokenMasked }),
        h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button', text: '显示',
          onclick: async (e) => {
            const done = busy(e.currentTarget, '…');
            try { e.currentTarget.previousSibling.textContent = await revealToken('pockettavern'); }
            catch (err) { toast(err.message, 'err'); } finally { done(); }
          },
        }),
        copyBtn(() => revealToken('pockettavern'), '已复制')),
      kvText('model', 'router:chat')),
    h('div', { class: 'row wrap', css: { marginTop: '10px' } },
      h('button', {
        class: 'btn btn-primary btn-sm', type: 'button',
        onclick: async (e) => {
          const done = busy(e.currentTarget, '生成中…');
          try {
            const r = await api('/api/connect/pockettavern/code', { method: 'POST' });
            copy(r.code, '连接码已复制（含访问令牌，只发给自己的设备）');
          } catch (err) { toast(err.message, 'err'); } finally { done(); }
        },
      }, icon('copy', 'ic ic-13'), h('span', { text: '复制连接码' })),
      h('button', {
        class: 'btn btn-danger-ghost btn-sm', type: 'button',
        onclick: async () => {
          const ok = await confirmDialog({
            title: '重新生成访问令牌？',
            body: '重新生成后，旧令牌立即失效，需要在手机上重新填写。',
            okText: '重新生成',
          });
          if (!ok) return;
          try {
            await api('/api/connect/pockettavern/rotate', { method: 'POST' });
            toast('已重新生成');
            S.connect = null;
            await loadConnect();
          } catch (err) { toast(err.message, 'err'); }
        },
      }, h('span', { text: '重新生成令牌' }))),
    h('div', { class: 'small dim', css: { marginTop: '8px' } },
      '连接码包含访问令牌，只发给自己的设备。泄露后重新生成令牌即可作废。'));

  const lastSeenEntries = Object.entries(c.lastSeen);
  const recent = h('div', { class: 'card' },
    h('h3', { text: '最近连接' }),
    lastSeenEntries.length === 0
      ? h('div', { class: 'empty' }, emptyState('phone', '还没有客户端连接过', '接入后这里会显示客户端与最近连接时间。'))
      : h('div', { class: 'kv', css: { marginTop: '8px' } },
          ...lastSeenEntries.flatMap(([client, info]) => [
            h('span', { class: 'k', text: client }),
            h('span', { class: 'v', text: `${fmtAgo(info.at)} · ${info.ip}` }),
          ])));

  return h('div', {},
    pageHead('接入', '把酒馆或 pockettavern 指向这台电脑的网关地址'),
    listenCard,
    h('div', { class: 'grid split', css: { marginTop: '12px' } }, st, pt),
    h('div', { css: { marginTop: '12px' } }, recent),
  );
}

async function saveListen(mode) {
  try {
    await api('/api/app/listen', { method: 'POST', body: { mode } });
    toast(`已切换${mode === 'lan' ? '局域网' : '仅本机'}模式`);
    S.connect = null;
    await refreshSnapshot();
    await loadConnect();
  } catch (e) {
    toast(e.message, 'err');
  }
}

async function savePort(port) {
  try {
    await api('/api/app/listen', { method: 'POST', body: { port } });
    toast('已应用端口');
    S.connect = null;
    await refreshSnapshot();
    await loadConnect();
  } catch (e) {
    toast(e.message, 'err');
  }
}

// ---------------------------------------------------------------- 密钥

async function loadSecrets() {
  try {
    S.secrets = await api('/api/secrets/upstream');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'secrets') render();
}

function renderSecrets() {
  if (!S.secrets) return h('div', { class: 'muted', text: '读取中…' });
  const s = S.secrets;
  const input = h('input', {
    class: 'input mono', type: 'password', autocomplete: 'off', autocapitalize: 'off',
    spellcheck: 'false', placeholder: '粘贴 Google API Key', css: { letterSpacing: '0.06em' },
  });
  const result = h('div', { class: 'small' });
  const sameProject = h('input', { type: 'checkbox', checked: true });
  const projectInput = h('input', { class: 'input', type: 'text', placeholder: 'default' });
  const invalid = S.snapshot?.app?.state === 'needs_key' ? false : null;

  const statusPill = s.configured
    ? pill(s.source === 'env' ? '来自环境变量' : '健康 · 本机加密', s.source === 'env' ? 'info' : 'ok')
    : pill('未配置', 'warn');

  return h('div', { css: { maxWidth: '760px' } },
    pageHead('密钥', 'Key 使用 Windows DPAPI 加密存储，仅本机可解密'),
    h('div', { class: 'card' },
      h('div', { class: 'row between' },
        h('div', { class: 'row' },
          statusPill,
          h('span', { class: 'small dim', text: s.lastVerifiedAt
            ? `最近验证：${new Date(s.lastVerifiedAt).toLocaleString('zh-CN')} · ${s.lastVerifyResult || ''}`
            : '尚未验证' })),
        h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button',
          onclick: async (e) => {
            const done = busy(e.currentTarget, '验证中…');
            try {
              const r = await api('/api/secrets/upstream/verify', { method: 'POST', body: {} });
              toast(r.message || '验证完成', r.ok ? 'ok' : 'err');
              S.secrets = await api('/api/secrets/upstream');
              render();
            } catch (err) { toast(err.message, 'err'); } finally { done(); }
          },
        }, icon('refresh', 'ic ic-13'), h('span', { text: '重新验证' }))),
      h('hr', { class: 'sep' }),
      h('div', { class: 'kv' },
        h('span', { class: 'k', text: '来源' }),
        h('span', { class: 'v', text: s.source === 'env' ? '环境变量（只读）' : s.source === 'vault' ? '本机加密存储（DPAPI）' : '—' }),
        h('span', { class: 'k', text: 'Key' }),
        h('span', { class: 'v mono', text: s.masked || '—' }),
        h('span', { class: 'k', text: '添加时间' }),
        h('span', { class: 'v', text: s.addedAt ? new Date(s.addedAt).toLocaleString('zh-CN') : '—' })),
      h('label', { class: 'field' }, h('span', { class: 'label' }, h('span', { text: '填写或更换 Key' })),
        h('div', { class: 'input-wrap has-trail' },
          input,
          h('button', {
            class: 'iconbtn trail', type: 'button', title: '显示/隐藏',
            onclick: () => { input.type = input.type === 'password' ? 'text' : 'password'; },
          }, icon('eye')))),
      h('label', { class: 'row', css: { gap: '6px' } },
        sameProject, h('span', { class: 'small', text: '与之前是同一个 Google 项目（保留额度估算）' })),
      h('label', { class: 'field' }, h('span', { class: 'label', text: '新项目标签（不是同一项目时填写）' }), projectInput),
      h('div', { class: 'row wrap' },
        h('button', {
          class: 'btn btn-soft', type: 'button',
          onclick: async (e) => {
            const done = busy(e.currentTarget, '测试中…');
            result.replaceChildren();
            try {
              const r = await api('/api/secrets/upstream/verify', { method: 'POST', body: { apiKey: input.value } });
              result.append(h('span', { css: { color: r.ok ? 'var(--ok)' : 'var(--err)' }, text: r.message }));
            } catch (err) {
              result.append(h('span', { css: { color: 'var(--err)' }, text: err.message }));
            } finally { done(); }
          },
        }, icon('check-c', 'ic ic-13'), h('span', { text: '测试（不消耗额度）' })),
        h('button', {
          class: 'btn btn-primary', type: 'button',
          onclick: async (e) => {
            if (!input.value.trim()) { toast('请先填写 Key', 'err'); return; }
            const done = busy(e.currentTarget, '保存中…');
            try {
              const r = await api('/api/secrets/upstream', {
                method: 'PUT',
                body: { apiKey: input.value, sameProject: sameProject.checked, projectRef: projectInput.value || null },
              });
              toast(r.message || '已保存');
              input.value = '';
              S.secrets = null;
              await refreshSnapshot();
              await loadSecrets();
            } catch (err) { toast(err.message, 'err'); } finally { done(); }
          },
        }, h('span', { text: '保存' })),
        s.configured && s.source !== 'env' ? h('button', {
          class: 'btn btn-danger-ghost', type: 'button',
          onclick: async () => {
            const ok = await confirmDialog({
              title: '删除 Key？',
              body: '删除后网关将停止服务，直到重新填写。',
              okText: '删除',
            });
            if (!ok) return;
            try {
              await api('/api/secrets/upstream', { method: 'DELETE' });
              toast('已删除');
              S.secrets = null;
              await refreshSnapshot();
              await loadSecrets();
            } catch (err) { toast(err.message, 'err'); }
          },
        }, icon('trash', 'ic ic-13'), h('span', { text: '删除 Key' })) : null),
      result,
      h('p', { class: 'hint', css: { marginTop: '10px' } },
        'Key 用 Windows 数据保护（DPAPI）加密保存在 %LOCALAPPDATA%\\eatgemini\\secrets.dat，只有当前 Windows 用户能解开。程序只会把它发送给 Google 官方接口。换电脑或重装系统后需要重新填写。')),
  );
}

// ---------------------------------------------------------------- 设置

const POLICY_META = [
  ['maxDistinctModels', '最大不同模型数', 6, '单次请求最多尝试几个不同模型'],
  ['maxUpstreamRequests', '最大上游请求数', 8, '单次请求最多发出几个上游请求'],
  ['maxTransientRetriesPerRequest', '瞬时错误重试', 1, '同一模型 5xx 类错误的重试上限'],
  ['maxParamRepairsPerRequest', '参数修复重试', 1, '400 类参数错误自动修复的上限'],
  ['routingDeadlineMs', '选路截止（毫秒）', 60000, '超时后停止尝试新模型，直接返回错误'],
  ['requestDeadlineMs', '请求总时长（毫秒）', 0, '0 = 不限制'],
  ['maxInFlight', '全局并发', 4, '超过即排队或拒绝'],
  ['maxQueueLength', '全局排队上限', 8, '队列满即拒绝'],
  ['maxQueueWaitMs', '排队等待（毫秒）', 2000, '并发满时的最长等待'],
  ['unknown429CooldownMs', '未知 429 冷却（毫秒）', 60000, 'Google 没给恢复时间时的默认冷却'],
  ['quotaProbeIntervalMs', '探测间隔（毫秒）', 300000, '「疑似用完」模型的低频探测节奏'],
  ['maxRequestBytes', '请求体上限（字节）', 0, '0 = 不限制'],
  ['maxBufferedResponseBytes', '响应缓冲上限（字节）', 0, '0 = 不限制（长上下文建议保持）'],
  ['maxInFlightPerClient', '每客户端并发', 2, '超过即排队或拒绝'],
  ['maxQueueLengthPerClient', '每客户端排队', 4, '队列满即拒绝'],
];

const PROFILE_DESC = {
  chat: '自动降级 · 酒馆日常用',
  fast: '偏快优先 · 短交互',
  quality: '只用强模型 · 用完即报错',
};

async function loadConfig() {
  try {
    S.config = await api('/api/config');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'settings') render();
}

function markDirty() {
  S.configDirty = true;
  const p = main.querySelector('#unsaved-pill');
  if (p) p.style.display = '';
}

function policyRow(next, key, label, def, hint) {
  const input = h('input', {
    class: 'input', value: String(next.policy[key]), css: { height: '30px' },
    'data-policy': key, 'data-def': String(def),
    oninput: (e) => {
      const v = e.target.value.trim();
      const n = Number(v);
      const okv = v !== '' && !Number.isNaN(n) && Number.isInteger(n) && n >= 0;
      e.target.classList.toggle('invalid', !okv);
      next.policy[key] = okv ? n : undefined; // 保存前校验会拦截 undefined
      if (okv) markDirty();
    },
  });
  return h('div', { class: 'grid', css: { gridTemplateColumns: '190px 140px 1fr', gap: '10px', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--line-1)' } },
    h('span', { class: 'small', css: { fontWeight: '550' }, text: label }),
    input,
    h('span', { class: 'hint', css: { margin: '0' }, text: hint }));
}

function tierCardHtml(next, name, ids) {
  const pills = h('div', { class: 'row wrap', css: { marginTop: '9px', gap: '6px' } });
  ids.forEach((id, i) => {
    const pillEl = h('span', { class: 'pill line mono' },
      h('span', { text: `${i + 1} · ${id}` }),
      h('span', { class: 'row', css: { gap: '2px', marginLeft: '5px' } },
        h('button', {
          class: 'iconbtn', type: 'button', title: '上移', css: { width: '16px', height: '16px' },
          onclick: (e) => { e.stopPropagation(); moveModel(next, name, i, -1); },
        }, icon('arr-up', 'ic ic-12')),
        h('button', {
          class: 'iconbtn', type: 'button', title: '下移', css: { width: '16px', height: '16px' },
          onclick: (e) => { e.stopPropagation(); moveModel(next, name, i, 1); },
        }, icon('arr-dn', 'ic ic-12'))));
    pills.append(pillEl);
  });
  return h('div', { class: 'card', css: { padding: '12px 14px', background: 'var(--bg-elev)', borderColor: 'var(--line-2)' } },
    h('div', { class: 'row' },
      h('b', { text: name }),
      h('span', { class: 'dim small', text: PROFILE_DESC[name] || '自定义档位' })),
    pills);
}

function moveModel(next, profile, i, dir) {
  const ids = next.profiles[profile];
  const j = i + dir;
  if (j < 0 || j >= ids.length) return;
  const t = ids[j]; ids[j] = ids[i]; ids[i] = t;
  markDirty();
  const routing = main.querySelector('#set-routing');
  if (routing) routing.replaceChildren(h('h3', { text: '路由' }), routingHtml(next));
}

function routingHtml(next) {
  const sel = h('select', { class: 'eg-sel', onchange: (e) => { next.policy.defaultProfile = e.target.value.split('（')[0]; markDirty(); } },
    ...Object.keys(next.profiles).map((id) =>
      h('option', { value: id, selected: next.policy.defaultProfile === id, text: `${id}（${PROFILE_DESC[id] || '自定义'}）` })));
  return h('div', {},
    h('div', { class: 'field', css: { width: '220px', margin: '10px 0 14px' } },
      h('span', { class: 'label', text: '默认档位' }), sel),
    h('div', { class: 'grid', css: { gap: '10px' } },
      ...Object.entries(next.profiles).map(([id, ids]) => tierCardHtml(next, id, ids))),
    h('div', { class: 'hint', css: { marginTop: '10px' } },
      '顺序即降级顺序：排前面的先被使用，配额不足时依次向后。点 ↑↓ 调整，保存后热加载生效。'));
}

function renderSettings() {
  const cfgWrap = S.config;
  if (!cfgWrap) return h('div', { class: 'muted', text: '读取中…' });
  const cfg = cfgWrap.config;
  const next = structuredClone(cfg);
  const proxy = next.upstream.proxy || { mode: 'none' };

  const proxyMode = h('select', { class: 'eg-sel', onchange: () => markDirty() },
    ...['none', 'environment', 'manual', 'system'].map((m) =>
      h('option', { value: m, text: { none: '不使用代理', environment: '环境变量优先', manual: '手动填写主机/端口', system: '系统代理（等同环境变量）' }[m], selected: proxy.mode === m })));
  const proxyHost = h('input', { class: 'input', type: 'text', value: proxy.host || '', placeholder: '127.0.0.1', oninput: () => markDirty() });
  const proxyPort = h('input', { class: 'input', type: 'number', value: proxy.port ? String(proxy.port) : '', placeholder: '7897', oninput: () => markDirty() });
  const baseUrlInput = h('input', { class: 'input mono', type: 'text', value: next.upstream.baseUrl, oninput: () => markDirty() });

  const policyBox = h('div', {},
    h('div', { class: 'hint', css: { marginTop: '8px' } },
      '预算上限、重试次数、探测间隔、并发与排队。非法值在保存时被拒绝并定位到字段。'),
    S.policyOpen
      ? h('div', { class: 'fade-in', css: { marginTop: '10px' } },
          ...POLICY_META.map(([key, label, def, hint]) => policyRow(next, key, label, def, hint)))
      : null);

  const unsaved = h('span', { class: 'pill warn', id: 'unsaved-pill', text: '未保存', css: { height: '26px', display: S.configDirty ? '' : 'none' } });

  const save = async (e) => {
    const bad = main.querySelector('.input.invalid');
    if (bad) { toast(`保存被拒：${bad.getAttribute('data-policy') || '字段'} 的值不合法（见标红字段）`, 'err'); return; }
    for (const [key] of POLICY_META) if (next.policy[key] === undefined) next.policy[key] = cfg.policy[key];
    if (!Object.keys(next.profiles).includes(next.policy.defaultProfile)) {
      toast('默认档位引用了不存在的档位', 'err'); return;
    }
    const done = busy(e.currentTarget, '保存中…');
    try {
      await api('/api/config', { method: 'PUT', body: { revision: cfgWrap.revision, config: next } });
      toast('已保存 · 配置热加载生效（下一个请求按新顺序选路）');
      S.configDirty = false;
      S.config = null;
      await refreshSnapshot();
      await loadConfig();
    } catch (err) { toast(err.message, 'err'); } finally { done(); }
  };

  return h('div', { css: { maxWidth: '800px' } },
    pageHead('设置', '保存后立即生效（引擎热加载），无需重启',
      unsaved,
      h('button', { class: 'btn btn-primary btn-sm', type: 'button', onclick: save }, h('span', { text: '保存' }))),
    h('div', { class: 'card', id: 'set-routing' },
      h('h3', { text: '路由' }), routingHtml(next)),
    h('div', { class: 'card', css: { marginTop: '12px' } },
      h('div', {
        class: 'row', css: { gap: '10px', cursor: 'pointer' },
        onclick: () => { S.policyOpen = !S.policyOpen; render(); },
      },
        icon('chev-d', `ic chev${S.policyOpen ? ' ic-accent' : ''}`),
        h('h3', { text: '高级（一般不需要改）', css: { margin: '0' } }),
        h('span', { class: 'pill line', text: `${POLICY_META.length} 项 policy 参数`, css: { marginLeft: 'auto' } })),
      policyBox),
    h('div', { class: 'card', css: { marginTop: '12px' } },
      h('h3', { text: '上游' }),
      h('div', { class: 'field' }, h('span', { class: 'label', text: 'baseUrl' }), baseUrlInput),
      h('div', { class: 'small muted' },
        '只允许 https。改成其他主机意味着 Key 会发给该主机，请确认这是你信任的端点。'),
      h('div', { class: 'grid c3', css: { marginTop: '10px' } },
        h('div', { class: 'field' }, h('span', { class: 'label', text: '代理模式' }), proxyMode),
        h('div', { class: 'field' }, h('span', { class: 'label', text: '主机' }), proxyHost),
        h('div', { class: 'field' }, h('span', { class: 'label', text: '端口' }), proxyPort)),
      h('div', { class: 'hint' },
        '本机代理（如 Clash 的 127.0.0.1:7897）填在这里即可；最终生效的代理见「诊断」页和启动日志。')),
    h('div', { class: 'card', css: { marginTop: '12px' } },
      h('h3', { text: '维护' }),
      h('div', { class: 'row wrap' },
        h('button', { class: 'btn btn-ghost btn-sm', type: 'button', text: '打开数据目录', onclick: () => api('/api/app/open-data-dir', { method: 'POST' }).then(() => toast('已打开')).catch((err) => toast(err.message, 'err')) }),
        h('button', {
          class: 'btn btn-ghost btn-sm', type: 'button', text: '重新加载配置',
          onclick: async (e) => {
            const done = busy(e.currentTarget, '重载中…');
            try {
              await api('/api/config/reload', { method: 'POST' });
              toast('已重新加载');
              S.config = null;
              S.configDirty = false;
              await refreshSnapshot();
              await loadConfig();
            } catch (err) { toast(err.message, 'err'); } finally { done(); }
          },
        }),
        h('button', {
          class: 'btn btn-danger-ghost btn-sm', type: 'button', text: '恢复默认配置',
          onclick: async () => {
            const ok = await confirmDialog({
              title: '恢复默认配置？',
              body: '会用默认配置替换当前配置（原文件保留备份）。档位顺序与 policy 将回到默认值。',
              okText: '恢复默认',
            });
            if (!ok) return;
            try {
              await api('/api/config/reset', { method: 'POST' });
              toast('已恢复默认');
              S.config = null;
              S.configDirty = false;
              await refreshSnapshot();
              await loadConfig();
            } catch (err) { toast(err.message, 'err'); }
          },
        }))),
  );
}

// ---------------------------------------------------------------- 诊断

async function loadDiag() {
  try {
    S.diag = await api('/api/diagnostics');
  } catch (e) {
    toast(e.message, 'err');
  }
  if (S.tab === 'diag') render();
}

function renderDiag() {
  const d = S.diag;
  if (!d) return h('div', { class: 'muted', text: '读取中…' });
  const level = { v: 'all' };
  const logBox = h('pre', { class: 'log' });
  const renderLogs = () => {
    const lines = d.logs || [];
    const shown = level.v === 'all' ? lines : lines.filter((l) => /\b(WRN|ERR|WARN|ERROR)\b/i.test(l));
    logBox.replaceChildren(...(shown.length
      ? shown.slice(-200).map((l) => {
          const isErr = /\b(ERR|ERROR)\b/i.test(l);
          const isWarn = /\b(WRN|WARN)\b/i.test(l);
          const row = h('div', { class: 'logline' },
            h('span', { class: `lv ${isErr ? 'e' : isWarn ? 'w' : 'i'}`, text: isErr ? 'ERR' : isWarn ? 'WRN' : 'INF' }),
            h('span', { class: 'tx', text: l.replace(/^\s*\S+\s+/, '') }));
          return row;
        })
      : [h('div', { class: 'dim small', text: '暂无日志' })]));
  };
  renderLogs();
  return h('div', { css: { maxWidth: '820px' } },
    pageHead('诊断', '导出包不含对话内容与密钥（全链路脱敏）',
      h('button', { class: 'btn btn-ghost btn-sm', type: 'button', text: '刷新', onclick: (e) => { const done = busy(e.currentTarget, '刷新中'); loadDiag().finally(done); } }),
      h('button', {
        class: 'btn btn-primary btn-sm', type: 'button',
        onclick: async (e) => {
          const done = busy(e.currentTarget, '导出中…');
          try {
            const r = await api('/api/diagnostics/export', { method: 'POST' });
            toast(`已导出：${r.path}`);
          } catch (err) { toast(err.message, 'err'); } finally { done(); }
        },
      }, icon('download', 'ic ic-13'), h('span', { text: '导出诊断包' }))),
    h('div', { class: 'card flush' },
      h('table', {},
        h('thead', {}, h('tr', {}, h('th', { text: '运行信息' }), h('th', { text: '值' }))),
        h('tbody', {}, ...Object.entries(d.info).map(([k, v]) => h('tr', { class: 'data-row' },
          h('td', { text: k }),
          h('td', { class: 'mono', text: String(v ?? '—') })))))),
    h('div', { class: 'card', css: { marginTop: '12px' } },
      h('div', { class: 'row between' },
        h('div', { class: 'row' }, icon('terminal', 'ic ic-dim'), h('h3', { text: '运行日志', css: { margin: '0' } })),
        h('select', {
          class: 'eg-sel', css: { width: '120px', height: '28px' },
          onchange: (e) => { level.v = e.target.value; renderLogs(); },
        },
          h('option', { value: 'all', text: '最近 200 行' }),
          h('option', { value: 'warn', text: '仅警告+' }))),
      h('div', { css: { marginTop: '10px' } }, logBox)),
  );
}

// ---------------------------------------------------------------- 数据同步

async function refreshSnapshot() {
  const snap = await fetch('/api/snapshot').then((r) => r.json());
  S.csrf = snap.csrf || S.csrf;
  S.snapshot = snap;
  S.models = null;
  S.requests = null;
  S.connect = null;
  renderTop();
  render();
}

function subscribe() {
  const es = new EventSource('/api/events');
  window.egEventSource = es; // 供诊断/自动化测试挂起实时连接（不影响正常使用）
  es.addEventListener('app.state', (e) => {
    const data = JSON.parse(e.data);
    if (!S.snapshot) return;
    const prev = S.snapshot.app.state;
    S.snapshot.app = { state: data.state, reason: data.reason };
    if (data.state !== prev) {
      noteEvent(data.state === 'degraded' ? 'warn' : ['ready'].includes(data.state) ? 'ok' : 'err',
        '状态变更', `应用状态：${STATE_LABEL[data.state] || data.state}`);
    }
    renderTop();
    if (S.tab === 'overview') render();
  });
  es.addEventListener('request.finished', (e) => {
    const data = JSON.parse(e.data);
    if (!S.snapshot) return;
    S.snapshot.recentRequests.unshift(data);
    S.snapshot.recentRequests = S.snapshot.recentRequests.slice(0, 10);
    const t = S.snapshot.today;
    t.requests += 1;
    if (data.outcome === 'succeeded') t.succeeded += 1;
    else if (data.outcome.startsWith('failed')) t.failed += 1;
    recordHour(new Date(data.startedAt).getTime(), data.outcome, data.fellBack === true);
    if (data.fellBack === true) {
      noteEvent('warn', '模型降级', `${shortModel(data.requestedModel)} 降级至 ${shortModel(data.servedModel) || '—'}`, data.requestId);
    }
    if (S.tab === 'overview') {
      render();
    } else if (S.tab === 'requests') {
      S.newRequests += 1;
      const bar = main.querySelector('.insert-bar');
      if (bar) bar.replaceChildren(icon('arr-up', 'ic ic-13'), h('span', { text: `有 ${S.newRequests} 条新请求 · 点击插入（不自动滚动）` }));
      else scheduleLoadRequests();
    } else if (S.tab === 'diag') {
      scheduleLoadDiag();
    }
  });
  es.addEventListener('request.attempt', () => {
    if (S.tab === 'overview') {
      const inflight = S.snapshot?.inFlight;
      if (inflight) render();
    }
  });
  es.addEventListener('bucket.changed', () => {
    if (S.tab === 'models') {
      S.models = null;
      loadModels();
    }
  });
  es.addEventListener('config.changed', () => {
    noteEvent('info', '配置变更', '配置已热加载（本机或文件修改）');
    S.config = null;
    refreshSnapshot();
  });
  es.addEventListener('secrets.changed', () => {
    noteEvent(S.snapshot?.app?.state === 'needs_key' ? 'err' : 'ok', '密钥变更', '上游 Key 已更新');
    S.secrets = null;
    refreshSnapshot();
  });
  es.addEventListener('log', (e) => {
    const data = JSON.parse(e.data);
    S.logLines.push(data.message);
    if (S.logLines.length > 500) S.logLines.shift();
  });
  es.onerror = () => {
    const t = document.getElementById('state-text');
    t.textContent = '连接已断开，正在重连…';
  };
  es.onopen = () => {
    refreshSnapshot().catch(() => {});
  };
}

refreshSnapshot()
  .then(() => {
    seedHourFromSnapshot();
    // 深链：?tab=models 直达某页（供自动化测试与外部链接使用）
    const q = new URLSearchParams(location.search);
    const deepTab = q.get('tab');
    if (deepTab && ['overview', 'models', 'requests', 'connect', 'secrets', 'settings', 'diag'].includes(deepTab)) {
      switchTab(deepTab);
    }
    // 测试钩子：?sse-off 关闭实时订阅（自动化截图需要网络静默；正常使用不受影响）
    if (!q.has('sse-off')) subscribe();
  })
  .catch(() => {
    main.replaceChildren(
      emptyState('alert', '无法连接 eatgemini',
        '与本地服务的连接中断。网关可能正在重启，稍后将自动重试。',
        h('button', { class: 'btn btn-soft btn-sm', text: '重试', onclick: () => location.reload() })));
  });
