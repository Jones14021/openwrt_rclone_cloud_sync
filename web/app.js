const state = { root: 'current', path: '' };
const text = (id, value) => { document.getElementById(id).textContent = value || '-'; };
const formatBytes = value => value === undefined ? '-' : `${(value / 1024 / 1024 / 1024).toFixed(1)} GiB`;
const elapsed = timestamp => { const seconds = Math.max(0, Math.floor((Date.now() - new Date(timestamp).getTime()) / 1000)); return Number.isFinite(seconds) ? `${Math.floor(seconds / 60)}m ${seconds % 60}s` : '-'; };

async function refreshStatus() {
  try {
    const status = await (await fetch('/cgi-bin/status', { cache: 'no-store' })).json();
    text('phase', status.phase); text('started', status.started_at ? `${status.started_at} (${elapsed(status.started_at)})` : '-'); text('success', status.last_success_at);
    text('storage', status.usb_mounted ? `${formatBytes(status.available_bytes)} free / ${formatBytes(status.total_bytes)}` : 'Unavailable');
    text('summary', status.usb_mounted ? (status.updated_at ? `PID ${status.pid || '-'} · updated ${status.updated_at}` : 'Idle') : 'USB unavailable');
    const error = document.getElementById('error'); error.hidden = !status.error; error.textContent = status.error || '';
  } catch { text('summary', 'Status endpoint unavailable'); }
}
async function refreshLog() { try { document.getElementById('log').textContent = await (await fetch('/cgi-bin/logs', { cache: 'no-store' })).text(); } catch { document.getElementById('log').textContent = 'Log endpoint unavailable.'; } }
function query() { return `root=${encodeURIComponent(state.root)}&path=${encodeURIComponent(state.path)}`; }
function renderCrumbs() {
  const crumbs = document.getElementById('breadcrumbs'); const items = [state.root, ...state.path.split('/').filter(Boolean)]; crumbs.replaceChildren();
  items.forEach((item, index) => { const button = document.createElement('button'); button.type = 'button'; button.textContent = item; button.onclick = () => { state.path = state.path.split('/').slice(0, index).join('/'); refreshFiles(); }; crumbs.append(button); if (index < items.length - 1) crumbs.append(' / '); });
}
async function refreshFiles() {
  const files = document.getElementById('files'); files.textContent = 'Loading...'; renderCrumbs();
  try { const listing = await (await fetch(`/cgi-bin/files?${query()}`, { cache: 'no-store' })).json(); files.replaceChildren(); if (!listing.entries.length) files.textContent = 'This directory is empty.'; listing.entries.forEach(entry => { const row = document.createElement('div'); row.className = 'file'; const link = document.createElement('a'); link.href = '#'; link.textContent = `${entry.name}${entry.directory ? '/' : ''}`; link.onclick = event => { event.preventDefault(); if (entry.directory) { state.path = [state.path, entry.name].filter(Boolean).join('/'); refreshFiles(); } else { window.location = `/cgi-bin/files?${query()}&download=${encodeURIComponent(entry.name)}`; } }; const size = document.createElement('span'); size.textContent = entry.directory ? 'directory' : formatBytes(entry.size); const modified = document.createElement('time'); modified.textContent = entry.modified; row.append(link, size, modified); files.append(row); }); }
  catch { files.textContent = 'Backup files are unavailable.'; }
}
document.getElementById('root-current').onclick = () => { state.root = 'current'; state.path = ''; refreshFiles(); };
document.getElementById('root-monthly').onclick = () => { state.root = 'monthly'; state.path = ''; refreshFiles(); };
document.getElementById('refresh-log').onclick = refreshLog;
refreshStatus(); refreshLog(); refreshFiles(); setInterval(refreshStatus, 10000);