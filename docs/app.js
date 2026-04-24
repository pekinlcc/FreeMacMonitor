// ─────────────────────────────────────────────────────────────
// Free Mac Monitor · GitHub Pages
// Demo animation + bilingual toggle
// ─────────────────────────────────────────────────────────────

(function () {
  'use strict';

  // ── i18n toggle ────────────────────────────────────────────
  const STORAGE_KEY = 'fmm-lang';
  const root = document.documentElement;
  const toggle = document.getElementById('lang-toggle');
  const enOpt = toggle && toggle.querySelector('.lang-en');
  const zhOpt = toggle && toggle.querySelector('.lang-zh');

  function applyLang(lang) {
    root.setAttribute('data-lang', lang);
    root.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.querySelectorAll('[data-en]').forEach(el => {
      const txt = lang === 'zh' ? el.getAttribute('data-zh') : el.getAttribute('data-en');
      if (txt != null) el.innerHTML = txt;
    });
    if (enOpt && zhOpt) {
      enOpt.classList.toggle('is-active', lang === 'en');
      zhOpt.classList.toggle('is-active', lang === 'zh');
    }
  }

  let initial = localStorage.getItem(STORAGE_KEY);
  if (!initial) {
    initial = (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh' : 'en';
  }
  applyLang(initial);

  if (toggle) {
    toggle.addEventListener('click', () => {
      const current = root.getAttribute('data-lang') || 'en';
      const next = current === 'en' ? 'zh' : 'en';
      localStorage.setItem(STORAGE_KEY, next);
      applyLang(next);
    });
  }

  // ── Dashboard demo ─────────────────────────────────────────
  const BAR_CELLS = 22;
  const THRESHOLDS = { cpu: 80, mem: 80, gpu: 80, disk: 85 };

  const state = {
    cpu: 18,
    mem: 52,
    gpu: 8,
    disk: 62,
    diskGBUsed: 248,
    diskGBTotal: 512,
    statusKey: 'NOMINAL', // NOMINAL | WARN | CRIT
  };

  function renderBar(id, pct) {
    const el = document.getElementById(id);
    if (!el) return;
    const filled = Math.max(0, Math.min(BAR_CELLS, Math.round(pct / 100 * BAR_CELLS)));
    const klass = pct >= 85 ? 'crit' : pct >= 70 ? 'warn' : 'lit';
    const lit = '&#9619;'.repeat(filled);   // ▓
    const dim = '&#9617;'.repeat(BAR_CELLS - filled); // ░
    el.innerHTML = `<span class="${klass}">${lit}</span>${dim}`;
  }

  function fmtPct(p) {
    return String(Math.round(p)).padStart(3, ' ') + '%';
  }

  function renderAll() {
    const cpuPct = document.getElementById('d-cpu-pct');
    const memPct = document.getElementById('d-mem-pct');
    const gpuPct = document.getElementById('d-gpu-pct');
    const diskPct = document.getElementById('d-disk-pct');
    const diskDetail = document.getElementById('d-disk-detail');
    const statusEl = document.getElementById('d-status');
    const timeEl = document.getElementById('d-time');

    if (cpuPct) cpuPct.textContent = fmtPct(state.cpu);
    if (memPct) memPct.textContent = fmtPct(state.mem);
    if (gpuPct) gpuPct.textContent = fmtPct(state.gpu);
    if (diskPct) diskPct.textContent = fmtPct(state.disk);
    if (diskDetail) diskDetail.textContent = `${state.diskGBUsed} GB / ${state.diskGBTotal} GB`;

    renderBar('d-cpu-bar', state.cpu);
    renderBar('d-mem-bar', state.mem);
    renderBar('d-gpu-bar', state.gpu);
    renderBar('d-disk-bar', state.disk);

    const metrics = [
      { k: 'cpu', v: state.cpu, t: THRESHOLDS.cpu },
      { k: 'mem', v: state.mem, t: THRESHOLDS.mem },
      { k: 'gpu', v: state.gpu, t: THRESHOLDS.gpu },
      { k: 'disk', v: state.disk, t: THRESHOLDS.disk },
    ];
    const breaching = metrics.find(m => m.v >= m.t);
    const warning = metrics.find(m => m.v >= m.t - 10 && m.v < m.t);

    if (statusEl) {
      statusEl.className = 'pp-status-v';
      if (breaching) {
        statusEl.textContent = (breaching.k + ' CRITICAL').toUpperCase();
        statusEl.classList.add('crit');
      } else if (warning) {
        statusEl.textContent = (warning.k + ' ELEVATED').toUpperCase();
        statusEl.classList.add('warn');
      } else {
        statusEl.textContent = 'NOMINAL';
      }
    }

    if (timeEl) {
      const d = new Date();
      const hh = String(d.getHours()).padStart(2, '0');
      const mm = String(d.getMinutes()).padStart(2, '0');
      const ss = String(d.getSeconds()).padStart(2, '0');
      timeEl.textContent = `${hh}:${mm}:${ss}`;
    }
  }

  // Random walk towards a drifting target — keeps values believable.
  const targets = { cpu: 20, mem: 55, gpu: 10, disk: 62 };
  function tick() {
    // Occasionally pick new targets, with a rare chance to spike.
    if (Math.random() < 0.08) {
      const spike = Math.random() < 0.18;
      targets.cpu = spike ? 85 + Math.random() * 12 : 10 + Math.random() * 55;
      targets.mem = 45 + Math.random() * 30;
      targets.gpu = spike && Math.random() < 0.4 ? 80 + Math.random() * 15 : 5 + Math.random() * 45;
    }
    // Disk drifts very slowly
    targets.disk = Math.max(40, Math.min(90, targets.disk + (Math.random() - 0.5) * 0.6));

    for (const k of ['cpu', 'mem', 'gpu', 'disk']) {
      const delta = (targets[k] - state[k]) * 0.18 + (Math.random() - 0.5) * 3;
      state[k] = Math.max(0, Math.min(100, state[k] + delta));
    }
    state.diskGBUsed = Math.round(state.disk / 100 * state.diskGBTotal);

    renderAll();
  }

  // Kick off quickly so the first paint isn't dashes.
  renderAll();
  tick();
  setInterval(tick, 1000);

  // ── Menu-bar rolling readout ──────────────────────────────
  const mbEl = document.getElementById('mb-rolling');
  const mbClock = document.getElementById('mb-clock');
  const sequence = ['cpu', 'mem', 'gpu', 'disk'];
  const labels = { cpu: 'CPU', mem: 'MEM', gpu: 'GPU', disk: 'DSK' };
  let idx = 0;

  function updateMenubar() {
    if (!mbEl) return;
    // If any metric is critical, lock the rotation on it in red.
    const crit = sequence.find(k => state[k] >= THRESHOLDS[k]);
    const key = crit || sequence[idx];
    const v = Math.round(state[key]);
    mbEl.textContent = `${labels[key]} ${String(v).padStart(2, ' ')}%`;
    mbEl.classList.toggle('crit', !!crit);
    if (!crit) idx = (idx + 1) % sequence.length;
  }

  function updateMenubarClock() {
    if (!mbClock) return;
    const d = new Date();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    mbClock.textContent = `${hh}:${mm}`;
  }

  updateMenubar();
  updateMenubarClock();
  setInterval(updateMenubar, 3000);
  setInterval(updateMenubarClock, 30000);

  // ── Copy buttons ──────────────────────────────────────────
  document.querySelectorAll('.copy-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const sel = btn.getAttribute('data-copy');
      const target = sel ? document.querySelector(sel) : null;
      if (!target) return;
      const text = target.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
      } catch (_) {
        const ta = document.createElement('textarea');
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
      }
      const original = btn.textContent;
      btn.textContent = 'COPIED';
      btn.classList.add('copied');
      setTimeout(() => {
        btn.textContent = original;
        btn.classList.remove('copied');
      }, 1400);
    });
  });

})();
