'use strict';

var SEGMENTS = 20;

function fmtBytes(bytes) {
  if (bytes <= 0) return '--- GB';
  var gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return gb.toFixed(1) + ' GB';
  return (bytes / (1024 * 1024)).toFixed(0) + ' MB';
}

function fmtMemBytes(bytes) {
  if (bytes <= 0) return '0';
  var gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return gb.toFixed(1) + 'G';
  return (bytes / (1024 * 1024)).toFixed(0) + 'M';
}

function makeBar(pct, segments) {
  segments = segments || SEGMENTS;
  var filled  = Math.max(0, Math.min(segments, Math.round((pct / 100) * segments)));
  var empty   = segments - filled;
  var cssClass = pct >= 90 ? 'crit' : (pct >= 70 ? 'warn' : 'lit');
  var bar = '<span class="' + cssClass + '">';
  for (var i = 0; i < filled; i++) bar += '▓';
  bar += '</span>';
  for (var j = 0; j < empty; j++)  bar += '░';
  return bar;
}

// Distribute SEGMENTS cells across the 5 categories, proportional to bytes.
// Uses largest-remainder so we never over-fill and small values aren't
// swallowed to zero.  Returns a single HTML string of coloured glyphs.
function makeBreakdownBar(mem, segments) {
  segments = segments || SEGMENTS;
  var total = mem.total > 0 ? mem.total : 1;
  var parts = [
    { k: 'app',  n: mem.app        / total },
    { k: 'wire', n: mem.wired      / total },
    { k: 'comp', n: mem.compressed / total },
    { k: 'cach', n: mem.cached     / total },
    { k: 'free', n: mem.free       / total }
  ];

  var raw = parts.map(function(p) { return p.n * segments; });
  var floor = raw.map(Math.floor);
  var used = floor.reduce(function(a, b) { return a + b; }, 0);
  var slack = segments - used;
  // Distribute remaining cells by largest fractional remainder.
  var rem = raw.map(function(r, i) { return { i: i, r: r - floor[i] }; })
               .sort(function(a, b) { return b.r - a.r; });
  for (var s = 0; s < slack; s++) {
    var idx = rem[s % rem.length].i;
    floor[idx] += 1;
  }

  var html = '';
  for (var i = 0; i < parts.length; i++) {
    var n = floor[i];
    if (n <= 0) continue;
    html += '<span class="' + parts[i].k + '">';
    for (var c = 0; c < n; c++) html += '▓';
    html += '</span>';
  }
  return html;
}

function pad2(n) { return n < 10 ? '0' + n : '' + n; }

function tick() {
  var d = new Date();
  var ts = pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
  var el = document.getElementById('timestamp');
  if (el) el.textContent = ts;
}
setInterval(tick, 1000);
tick();

window.updateMetrics = function(data, opts) {
  if (typeof data === 'string') {
    try { data = JSON.parse(data); } catch (e) { return; }
  }
  opts = opts || {};

  if (opts.showBreakdown) document.body.classList.add('mode-breakdown');
  else                    document.body.classList.remove('mode-breakdown');

  // CPU
  var cpu = typeof data.cpu === 'number' ? data.cpu : 0;
  var cpuBar = document.getElementById('cpu-bar');
  var cpuPct = document.getElementById('cpu-pct');
  if (cpuBar) cpuBar.innerHTML = makeBar(cpu);
  if (cpuPct) cpuPct.textContent = cpu.toFixed(1) + ' %';

  // Memory
  var mem = typeof data.memory === 'number' ? data.memory : 0;
  var memBar = document.getElementById('mem-bar');
  var memPct = document.getElementById('mem-pct');
  if (memBar) memBar.innerHTML = makeBar(mem);
  if (memPct) memPct.textContent = mem.toFixed(1) + ' %';

  // Memory breakdown (cheap to update even when hidden)
  var mb = data.memBreakdown || null;
  if (mb) {
    var bdBar = document.getElementById('mem-breakdown-bar');
    if (bdBar) bdBar.innerHTML = makeBreakdownBar(mb);
    var setLabel = function(id, name, bytes) {
      var el = document.getElementById(id);
      if (el) el.textContent = name + ' ' + fmtMemBytes(bytes);
    };
    setLabel('mem-app',  'APP',   mb.app);
    setLabel('mem-wire', 'WIRED', mb.wired);
    setLabel('mem-comp', 'COMPR', mb.compressed);
    setLabel('mem-cach', 'CACHE', mb.cached);
    setLabel('mem-free', 'FREE',  mb.free);
  }

  // GPU
  var gpu    = typeof data.gpuUsage === 'number' ? data.gpuUsage : -1;
  var gpuBar = document.getElementById('gpu-bar');
  var gpuPct = document.getElementById('gpu-pct');
  if (gpu < 0) {
    if (gpuBar) gpuBar.innerHTML = '<span style="color:#1a5500;font-size:11px">N/A — NO GPU DATA</span>';
    if (gpuPct) gpuPct.textContent = 'N/A';
  } else {
    if (gpuBar) gpuBar.innerHTML = makeBar(gpu);
    if (gpuPct) gpuPct.textContent = gpu.toFixed(1) + ' %';
  }

  // Disk
  var diskPct    = typeof data.diskPercent === 'number' ? data.diskPercent : 0;
  var diskUsed   = typeof data.diskUsed   === 'number' ? data.diskUsed   : 0;
  var diskTotal  = typeof data.diskTotal  === 'number' ? data.diskTotal  : 0;
  var diskBar    = document.getElementById('disk-bar');
  var diskPctEl  = document.getElementById('disk-pct');
  var diskDetail = document.getElementById('disk-detail');
  if (diskBar)    diskBar.innerHTML   = makeBar(diskPct);
  if (diskPctEl)  diskPctEl.textContent = diskPct.toFixed(1) + ' %';
  if (diskDetail) diskDetail.textContent = fmtBytes(diskUsed) + ' / ' + fmtBytes(diskTotal);

  // Status
  var sv = document.getElementById('status-val');
  if (sv) {
    var highest = Math.max(cpu, mem, diskPct);
    if (highest >= 90) {
      sv.className = 'status-val crit';
      sv.textContent = 'CRITICAL';
    } else if (highest >= 70) {
      sv.className = 'status-val warn';
      sv.textContent = 'ELEVATED';
    } else {
      sv.className = 'status-val';
      sv.textContent = 'NOMINAL';
    }
  }
};

// Called by Swift after purge completes with the released byte count.
// Shows a tiny toast line beneath the memory bar for ~5 seconds, then fades.
window.showReleaseToast = function(amount, hhmmss) {
  var el = document.getElementById('mem-release-toast');
  if (!el) return;
  el.textContent = '▼ Released ' + amount + ' at ' + hhmmss;
  el.classList.add('visible');
  if (window._toastTimer) clearTimeout(window._toastTimer);
  window._toastTimer = setTimeout(function() {
    el.classList.remove('visible');
  }, 5000);
};
