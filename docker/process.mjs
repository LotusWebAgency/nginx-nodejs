import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { createLimiter, nginxError, scrub } from './scrub.mjs';
import { collectorPaths } from './collector-paths.mjs';

const service = process.argv[2];
const app = process.env.APP_DIR || '/app';
const logService = process.env.LOG_SERVICE || 'nginx-nodejs';
let nodeCommand;
try { nodeCommand = JSON.parse(readFileSync('/run/nginx-nodejs/node-command.json', 'utf8')); } catch { process.exit(78); }
const commands = {
  node: [nodeCommand[0], nodeCommand.slice(1)],
  nginx: ['nginx', ['-e', 'stderr', '-c', '/run/nginx-nodejs/nginx.conf', '-g', 'daemon off;']],
  collector: ['fluent-bit', ['--config', '/run/nginx-nodejs/fluent-bit.yaml']],
};
if (!commands[service]) process.exit(78);
let collectorEnvironment = {};
if (service === 'collector') {
  try { collectorEnvironment = JSON.parse(readFileSync('/run/nginx-nodejs/fluent-bit-env.json', 'utf8')); }
  catch { process.exit(78); }
  if (process.argv[3] === '--validate') {
    const result = spawnSync('fluent-bit', ['--dry-run', '--config', '/run/nginx-nodejs/fluent-bit.yaml'], { env: { ...process.env, ...collectorEnvironment }, stdio: 'ignore', timeout: 10000 });
    process.exit(result.status === 0 ? 0 : 78);
  }
  const logs = ['node/log', 'nginx-events/log', 'nginx/log'].map(name => `/run/nginx-nodejs/service/${name}`);
  const ready = spawnSync('s6-svwait', ['-U', '-a', '-t', '10000', ...logs], { stdio: 'ignore', timeout: 11000 });
  if (ready.status !== 0) process.exit(1);
  try {
    const config = JSON.parse(readFileSync('/run/nginx-nodejs/fluent-bit.yaml', 'utf8'));
    config.pipeline.inputs[0].path = collectorPaths().join(',');
    writeFileSync('/run/nginx-nodejs/fluent-bit.yaml', JSON.stringify(config, null, 2), { mode: 0o600 });
    chmodSync('/run/nginx-nodejs/fluent-bit.yaml', 0o600);
  } catch { process.exit(78); }
}
const allowedEvents = new Set(['http_request', 'runtime_error', 'browser_error', 'sentry_delivery', 'nginx_request']);
const methods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'OTHER']);
const diagnostics = new Map();
function emit(value) {
  if (process.stdout.writableLength < 65536) process.stdout.write(`${JSON.stringify(value)}\n`);
}
const limiter = createLimiter({
  report: count => emit({ timestamp: new Date().toISOString(), service: logService, event: 'process_diagnostic_suppressed', process: service, count }),
});
// The limiter runs before scrubbing so flooding lines cannot keep the regexes busy.
function diagnostic(build) {
  if (!limiter.allow()) return;
  const fields = build();
  if (fields) emit({ timestamp: new Date().toISOString(), service: logService, ...fields });
}
function safeLine(line, oversized = false) {
  if (service === 'nginx') {
    if (oversized) return diagnostic(() => ({ event: 'nginx_error', level: 'error', message: 'oversized output line omitted' }));
    return diagnostic(() => {
      const { level, message } = nginxError(line);
      return message ? { event: 'nginx_error', level, message } : null;
    });
  }
  try {
    const value = JSON.parse(line);
    if (!allowedEvents.has(value?.event)) {
      diagnostic(() => ({ event: 'process_diagnostic', process: service, message: 'unrecognized structured output omitted' }));
      return;
    }
    const output = { timestamp: new Date().toISOString(), service: logService, event: value.event };
    if (typeof value.requestId === 'string' && /^[a-fA-F0-9-]{16,40}$/.test(value.requestId)) output.requestId = value.requestId;
    if (typeof value.release === 'string' && /^(?:local|[a-fA-F0-9]{7,40})$/.test(value.release)) output.release = value.release;
    if (methods.has(value.method)) output.method = value.method;
    for (const key of ['status', 'durationMs', 'durationSeconds']) if (typeof value[key] === 'number' && Number.isFinite(value[key]) && value[key] >= 0) output[key] = value[key];
    if (['ssr_exception', 'http_5xx'].includes(value.kind)) output.kind = value.kind;
    if (typeof value.eventId === 'string' && /^[a-f0-9]{32}$/.test(value.eventId)) output.eventId = value.eventId;
    if (typeof value.delivered === 'boolean') output.delivered = value.delivered;
    emit(output);
  } catch {
    if (service === 'collector') {
      const event = /buffer.*(?:full|dropp)|events dropped|overlimit|(?:drop|evict).*chunk|chunk.*(?:drop|evict)/i.test(line) ? 'collector_buffer_full' : /retry|connection.*(?:refused|closed)|\b50[0234]\b/i.test(line) ? 'collector_retry' : 'collector_diagnostic';
      if (Date.now() - (diagnostics.get(event) || 0) > 60000) {
        diagnostics.set(event, Date.now());
        emit({ service: logService, event, process: service });
      }
      return;
    }
    diagnostic(() => {
      const message = oversized ? 'oversized output line omitted' : scrub(line);
      return message ? { event: 'process_diagnostic', process: service, message } : null;
    });
  }
}
// Under a cgroup v2 memory limit, cap the V8 heap below it so the app is collected before the kernel kills the container.
// The allowance covers Nginx, the helper Node processes and the collector, which share the limit.
const reservedMb = 160;
function appHeapOptions() {
  const setting = process.env.NODE_MAX_OLD_SPACE_SIZE || '';
  if (setting === 'off') return '';
  if (setting) return `--max-old-space-size=${Number(setting)}`;
  if ((process.env.NODE_OPTIONS || '').includes('--max-old-space-size') || nodeCommand.some(value => value.startsWith('--max-old-space-size'))) return '';
  try {
    const limit = readFileSync('/sys/fs/cgroup/memory.max', 'utf8').trim();
    if (!/^\d+$/.test(limit)) return '';
    return `--max-old-space-size=${Math.max(64, Math.floor((Number(limit) / 1048576 - reservedMb) * 0.75))}`;
  } catch { return ''; }
}
const environment = { ...process.env, ...collectorEnvironment, HOST: '127.0.0.1', PORT: process.env.NODE_PORT || '3000', NO_COLOR: '1' };
if (service === 'node') {
  const heap = appHeapOptions();
  if (heap) environment.NODE_OPTIONS = [process.env.NODE_OPTIONS, heap].filter(Boolean).join(' ');
}
const [command, args] = commands[service];
const child = spawn(command, args, { cwd: service === 'node' ? app : '/', env: environment, stdio: ['ignore', 'pipe', 'pipe'] });
for (const stream of [child.stdout, child.stderr]) {
  let pending = '';
  let oversized = false;
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    for (const part of chunk.match(/[^\n]*\n|[^\n]+$/g) || []) {
      if (pending.length + part.length > 16384) oversized = true;
      if (!oversized) pending += part;
      if (part.endsWith('\n')) {
        safeLine(oversized ? '' : pending, oversized);
        pending = '';
        oversized = false;
      }
    }
  });
  stream.on('end', () => { if (pending || oversized) safeLine(oversized ? '' : pending, oversized); });
}
for (const signal of ['SIGTERM', 'SIGINT', 'SIGQUIT']) process.on(signal, () => child.kill(service === 'nginx' ? signal : 'SIGTERM'));
child.on('error', () => {
  emit({ service: logService, event: 'process_start_failed', process: service });
  process.exitCode = 1;
});
child.on('close', (code, signal) => {
  limiter.flush();
  emit({ timestamp: new Date().toISOString(), service: logService, event: 'process_exit', process: service, code, signal });
  process.exitCode = code === 0 ? 0 : 1;
});
