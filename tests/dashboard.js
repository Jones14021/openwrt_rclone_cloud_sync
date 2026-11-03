const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'backup-dashboard-'));

function testCapacityEndpoint() {
  fs.mkdirSync(path.join(fixture, '.git'));
  fs.mkdirSync(path.join(fixture, '.local'));
  fs.mkdirSync(path.join(fixture, 'backup', 'current'), { recursive: true });
  const date = new Date();
  const month = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
  fs.mkdirSync(path.join(fixture, 'backup', 'monthly', month), { recursive: true });
  fs.writeFileSync(path.join(fixture, '.local', 'volume-id'), '');
  fs.writeFileSync(path.join(fixture, 'backup', 'current', 'example'), 'backup');
  fs.copyFileSync(path.join(root, 'mount-check.sh'), path.join(fixture, 'mount-check.sh'));

  const source = fs.readFileSync(path.join(root, 'web', 'cgi-bin', 'status'), 'utf8')
    .replace('STATE=/tmp/onedrive-backup/status.json', 'STATE="$FIXTURE/state.json"');
  const run = () => {
    const result = spawnSync('busybox', ['sh'], {
      input: source,
      encoding: 'utf8',
      env: { ...process.env, FIXTURE: fixture, REPO: fixture, MOUNT: fixture, MOUNT_CHECK_TEST: '1', QUERY_STRING: 'capacity' },
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout.split(/\r?\n\r?\n/)[1]);
  };

  const estimate = run();
  assert.equal(estimate.available, true);
  assert.equal(estimate.snapshot_needed, false);
  assert.ok(estimate.required_bytes > 0);
  fs.rmSync(path.join(fixture, 'backup', 'monthly', month), { recursive: true });
  assert.equal(run().snapshot_needed, true);
  fs.writeFileSync(path.join(fixture, 'state.json'), JSON.stringify({ phase: 'downloading', pid: process.pid }));
  assert.equal(run().available, false);
  fs.rmSync(path.join(fixture, 'state.json'));
  fs.rmSync(path.join(fixture, 'backup', 'current'), { recursive: true });
  assert.equal(run().available, false);
}

async function testWebStart() {
  const bin = path.join(fixture, 'bin');
  const argsFile = path.join(fixture, 'uhttpd.args');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(fixture, 'web'));
  fs.copyFileSync(path.join(root, 'web', 'index.html'), path.join(fixture, 'web', 'index.html'));
  fs.copyFileSync(path.join(root, 'web-start.sh'), path.join(fixture, 'web-start.sh'));
  fs.writeFileSync(path.join(bin, 'uhttpd'), '#!/bin/sh\nprintf "%s\\n" "$@" > "$FIXTURE/uhttpd.args.tmp"\nmv "$FIXTURE/uhttpd.args.tmp" "$FIXTURE/uhttpd.args"\n', { mode: 0o755 });

  let resolveWritten;
  const written = new Promise(resolve => { resolveWritten = resolve; });
  const watcher = fs.watch(fixture, (event, name) => { if (name === 'uhttpd.args') resolveWritten(); });
  const timer = setTimeout(() => resolveWritten(), 5000);
  try {
    const result = spawnSync('sh', [path.join(fixture, 'web-start.sh')], {
      encoding: 'utf8',
      stdio: 'ignore',
      env: { ...process.env, FIXTURE: fixture, MOUNT: fixture, MOUNT_CHECK_TEST: '1', WEB_PID: path.join(fixture, 'dashboard.pid'), PATH: `${bin}:${process.env.PATH}` },
    });
    assert.equal(result.status, 0, 'dashboard startup failed');
    if (!fs.existsSync(argsFile)) await written;
    const args = fs.readFileSync(argsFile, 'utf8').trim().split('\n');
    assert.equal(args[args.indexOf('-t') + 1], '300');
    assert.equal(args[args.indexOf('-T') + 1], '300');
  } finally {
    clearTimeout(timer);
    watcher.close();
  }
}

async function testDashboard() {
  const elements = {};
  assert.match(fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8'), /id="capacity-warning"[^>]*>Checking monthly snapshot space/);
  let now = Date.parse('2026-11-02T21:00:00+0100');
  const TestDate = class extends Date { static now() { return now; } };
  let status = { phase: 'completed', started_at: '2026-11-02T18:35:36+0100', updated_at: '2026-11-02T19:29:00+0100', usb_mounted: false };
  const context = {
    Date: TestDate,
    document: { getElementById: id => elements[id] ||= {} },
    fetch: async () => ({ json: async () => status }),
  };
  vm.createContext(context);
  const source = fs.readFileSync(path.join(root, 'web', 'app.js'), 'utf8');
  vm.runInContext(source.split("document.getElementById('root-current').onclick")[0], context);
  const run = code => vm.runInContext(code, context);

  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(53m 24s\)/);
  now += 60_000;
  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(53m 24s\)/);
  status = { ...status, phase: 'failed' };
  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(53m 24s\)/);
  status = { ...status, updated_at: null };
  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(-\)/);
  status = { ...status, phase: 'downloading' };
  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(145m 24s\)/);
  now += 60_000;
  await run('refreshStatus()');
  assert.match(elements.started.textContent, /\(146m 24s\)/);

  run('state.status = { usb_mounted: true, phase: "completed", available_bytes: 57.4 * 1024 ** 3 }; state.capacity = { available: true, required_bytes: 88.4 * 1024 ** 3 }; renderCapacity()');
  assert.match(elements['capacity-warning'].textContent, /88\.4 GiB.*57\.4 GiB/);
  run('state.status.available_bytes = 90 * 1024 ** 3; renderCapacity()');
  assert.equal(elements['capacity-warning'].hidden, true);
  run('state.status.available_bytes = 1; state.status.phase = "creating monthly snapshot"; renderCapacity()');
  assert.equal(elements['capacity-warning'].hidden, true);

  let finishCapacity;
  context.fetch = () => new Promise(resolve => { finishCapacity = resolve; });
  run('state.status = { usb_mounted: true, phase: "idle", available_bytes: 57.4 * 1024 ** 3 }; state.capacity = null');
  let pending = run('refreshCapacity()');
  assert.equal(elements['capacity-warning'].hidden, false);
  assert.match(elements['capacity-warning'].textContent, /Checking monthly snapshot space/);
  finishCapacity({ json: async () => ({ available: true, required_bytes: 88.4 * 1024 ** 3 }) });
  await pending;
  assert.match(elements['capacity-warning'].textContent, /88\.4 GiB.*57\.4 GiB/);

  pending = run('refreshCapacity()');
  assert.match(elements['capacity-warning'].textContent, /Checking monthly snapshot space/);
  finishCapacity({ json: async () => ({ available: true, required_bytes: 40 * 1024 ** 3 }) });
  await pending;
  assert.equal(elements['capacity-warning'].hidden, true);

  context.fetch = async () => { throw new Error('unavailable'); };
  await run('refreshCapacity()');
  assert.match(elements['capacity-warning'].textContent, /estimate is unavailable/);
  run('state.status = null');
  await run('refreshStatus()');
  assert.match(elements['capacity-warning'].textContent, /estimate is unavailable/);
}

(async () => {
  try {
    testCapacityEndpoint();
    await testWebStart();
    await testDashboard();
    console.log('Dashboard tests passed');
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });