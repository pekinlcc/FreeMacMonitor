'use strict';

var SEGMENTS = 20;

function fmtBytes(bytes) {
  if (bytes <= 0) return '--- GB';
  var gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return gb.toFixed(1) + ' GB';
  return (bytes / (1024 * 1024)).toFixed(0) + ' MB';
}

function makeBar(pct, segments) {
  segments = segments || SEGMENTS;
  var filled  = Math.max(0, Math.min(segments, Math.round((pct / 100) * segments)));
  var empty   = segments - filled;
  var cssClass = pct >= 90 ? 'crit' : (pct >= 70 ? 'warn' : 'lit');
  var bar = '<span class="' + cssClass + '">';
  for (var i = 0; i < filled; i++) bar += '▓'; // ▓
  bar += '</span>';
  for (var j = 0; j < empty; j++)  bar += '░'; // ░
  return bar;
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

window.updateMetrics = function(data) {
  if (typeof data === 'string') {
    try { data = JSON.parse(data); } catch (e) { return; }
  }

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
