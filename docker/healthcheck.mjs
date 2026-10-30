import { readFile, access } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const root = '/run/nginx-nodejs';
async function processStatus(pid, command) {
  if (!/^\d+$/.test(String(pid)) || Number(pid) < 1) throw new Error();
  const stat = await readFile(`/proc/${pid}/stat`, 'utf8');
  const end = stat.lastIndexOf(')');
  const fields = stat.slice(end + 2).split(' ');
  const actualCommand = stat.slice(stat.indexOf('(') + 1, end);
  // The main thread's comm differs by Node release: node (22), MainThread (24), node-MainThread (26).
  const nodeNames = ['node', 'MainThread', 'node-MainThread'];
  if (!(actualCommand === command || command === 'node' && nodeNames.includes(actualCommand)) || !/^[RSDI]$/.test(fields[0])) throw new Error();
  return { parent: fields[1] };
}
async function serviceHealthy(name, command, childCommand, requireReady = false) {
  try {
    const { stdout } = await execute('s6-svstat', ['-o', 'up,wantedup,normallyup,paused,pid,ready', `${root}/service/${name}`], { timeout: 750, killSignal: 'SIGKILL', maxBuffer: 1024 });
    const [up, wanted, normal, paused, pid, ready] = stdout.trim().split(/\s+/);
    if (up !== 'true' || wanted !== 'true' || normal !== 'true' || paused !== 'false' || requireReady && ready !== 'true') return false;
    const state = await processStatus(pid, command);
    await processStatus(state.parent, 's6-supervise');
    if (childCommand) {
      const children = (await readFile(`/proc/${pid}/task/${pid}/children`, 'utf8')).trim().split(/\s+/);
      if (children.length !== 1) return false;
      const child = await processStatus(children[0], childCommand);
      if (child.parent !== pid) return false;
    }
    return true;
  } catch { return false; }
}
async function supervisorHealthy() {
  try {
    await processStatus((await readFile(`${root}/supervisor.pid`, 'utf8')).trim(), 's6-svscan');
    for (const flag of ['stopping', 'failed']) {
      try { await access(`${root}/${flag}`); return false; } catch (error) { if (error.code !== 'ENOENT') return false; }
    }
    return true;
  } catch { return false; }
}
async function httpHealthy(port, path) {
  try {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, { signal: AbortSignal.timeout(2000), redirect: 'error' });
    await response.body?.cancel();
    return response.status === 200;
  } catch { return false; }
}
const checks = [
  ['supervisor', supervisorHealthy()],
  ['nginx', serviceHealthy('nginx', 'node', 'nginx')],
  ['node', serviceHealthy('node', 'node', 'node')],
  ['nginx-events', serviceHealthy('nginx-events', 'node')],
  ['node-log', serviceHealthy('node/log', 's6-log', undefined, true)],
  ['nginx-log', serviceHealthy('nginx-events/log', 's6-log', undefined, true)],
  ['nginx-error-log', serviceHealthy('nginx/log', 's6-log', undefined, true)],
  ['public-http', httpHealthy(8080, process.env.NODE_HEALTH_PATH || '/healthz')],
  ['node-http', httpHealthy(process.env.NODE_PORT || '3000', process.env.NODE_HEALTH_PATH || '/healthz')],
];
checks.push(['nginx-http', httpHealthy(8080, '/__container_health')]);
if (process.env.LOKI_ENABLED === '1') checks.push(['collector', serviceHealthy('collector', 'node', 'fluent-bit')]);
const results = await Promise.all(checks.map(async ([name, result]) => [name, await result]));
const failed = results.filter(([, healthy]) => !healthy).map(([name]) => name);
if (failed.length) console.error(`Unhealthy services: ${failed.join(', ')}`);
process.exit(failed.length ? 1 : 0);
