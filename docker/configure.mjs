import { mkdirSync, readFileSync, writeFileSync, cpSync, existsSync, statSync, accessSync, constants, chmodSync, readdirSync, unlinkSync, symlinkSync, rmSync } from 'node:fs';
import { isIP } from 'node:net';
import { collectorPaths } from './collector-paths.mjs';

function fail(message) {
  console.error(`Runtime configuration error: ${message}`);
  process.exit(78);
}
process.on('uncaughtException', () => fail('unable to read or write runtime configuration'));
function setting(name) {
  if (process.env[name] !== undefined && process.env[`${name}_FILE`] !== undefined) fail(`set either ${name} or ${name}_FILE`);
  const file = process.env[`${name}_FILE`];
  if (!file) return process.env[name] || '';
  try {
    if (statSync(file).size > 8192) fail(`${name}_FILE is too large`);
    return readFileSync(file, 'utf8').replace(/[\r\n]+$/, '');
  } catch { fail(`unable to read ${name}_FILE`); }
}
if (process.getuid() !== 1000) fail('UID 1000 is required');
const mode = process.env.RUNTIME_MODE || 'prod';
if (!['dev', 'prod'].includes(mode)) fail('RUNTIME_MODE must be dev or prod');
const app = process.env.APP_DIR || '/app';
function validPath(value) {
  return /^\/[a-zA-Z0-9_./-]+$/.test(value) && !value.split('/').includes('..');
}
if (!validPath(app)) fail('invalid APP_DIR');
const staticRoot = process.env.STATIC_ROOT || '/app/public';
if (!validPath(staticRoot)) fail('invalid STATIC_ROOT');
const nodePort = process.env.NODE_PORT || '3000';
if (!/^\d{1,5}$/.test(nodePort) || Number(nodePort) < 1024 || Number(nodePort) > 65535 || [8080, 8081].includes(Number(nodePort))) fail('invalid NODE_PORT');
const healthPath = process.env.NODE_HEALTH_PATH || '/healthz';
if (!/^\/[a-zA-Z0-9_./-]*$/.test(healthPath) || healthPath.split('/').includes('..')) fail('invalid NODE_HEALTH_PATH');
const logService = process.env.LOG_SERVICE || 'nginx-nodejs';
const appEnv = process.env.APP_ENV || 'production';
const safeLabel = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;
if (!safeLabel.test(logService)) fail('invalid LOG_SERVICE');
if (!safeLabel.test(appEnv)) fail('invalid APP_ENV');
const nodeCommand = process.argv.slice(2);
if (!['node', '/usr/bin/node'].includes(nodeCommand[0]) || nodeCommand.some(value => value.includes('\0'))) fail('command must start with node or /usr/bin/node');
let extraFilters = [];
const filtersFile = process.env.FLUENT_BIT_FILTERS_FILE;
if (filtersFile) {
  try {
    if (statSync(filtersFile).size > 65536) fail('invalid Fluent Bit filter configuration');
    const value = JSON.parse(readFileSync(filtersFile, 'utf8'));
    if (!Array.isArray(value) || value.some(filter => !filter || typeof filter !== 'object' || Array.isArray(filter) || !['grep', 'modify', 'record_modifier'].includes(filter.name))) fail('invalid Fluent Bit filter configuration');
    extraFilters = value.map(filter => {
      const { match_regex, ...options } = filter;
      return { ...options, match: 'runtime' };
    });
  } catch { fail('invalid Fluent Bit filter configuration'); }
}
const enabled = process.env.LOKI_ENABLED || '0';
if (!['0', '1'].includes(enabled)) fail('LOKI_ENABLED must be 0 or 1');
const host = process.env.LOKI_HOST || '';
const port = process.env.LOKI_PORT || '3100';
const tls = process.env.LOKI_TLS || 'off';
if (enabled === '1' && (!/^[a-zA-Z0-9][a-zA-Z0-9.-]*$/.test(host) || !/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535 || !['on', 'off'].includes(tls))) fail('invalid Loki host, port, or TLS setting');
const bearer = setting('LOKI_BEARER_TOKEN');
const user = setting('LOKI_USER');
const password = setting('LOKI_PASSWORD');
const tenant = setting('LOKI_TENANT_ID');
if (bearer && (user || password)) fail('Loki bearer and basic authentication are mutually exclusive');
if ((user && !password) || (password && !user)) fail('Loki basic authentication requires user and password');
if (bearer && !/^[\x21-\x7e]{1,8192}$/.test(bearer)) fail('invalid Loki bearer token');
if ((user && !/^[^:\r\n\0]{1,256}$/.test(user)) || (password && /[\r\n\0]/.test(password))) fail('invalid Loki basic credentials');
if (tenant && !/^[a-zA-Z0-9_.-]{1,150}$/.test(tenant)) fail('invalid Loki tenant ID');
const ca = process.env.LOKI_CA_FILE || '';
if (ca) {
  if (!/^\/[a-zA-Z0-9_./-]+$/.test(ca)) fail('invalid LOKI_CA_FILE');
  try { accessSync(ca, constants.R_OK); } catch { fail('unable to read LOKI_CA_FILE'); }
}
const publicScheme = process.env.PUBLIC_SCHEME || 'http';
if (!['http', 'https'].includes(publicScheme)) fail('PUBLIC_SCHEME must be http or https');
const ingress = (process.env.INGRESS_TRUSTED_IPS || '').split(',').filter(Boolean);
for (const value of ingress) {
  const parts = value.split('/');
  const family = isIP(parts[0]);
  if (!family || parts.length > 2 || (parts.length === 2 && (!/^\d{1,3}$/.test(parts[1]) || Number(parts[1]) > (family === 4 ? 32 : 128)))) fail('invalid INGRESS_TRUSTED_IPS');
}
// A restarted container without a runtime tmpfs keeps the previous run's state.
for (const entry of existsSync('/run/nginx-nodejs') ? readdirSync('/run/nginx-nodejs') : []) rmSync(`/run/nginx-nodejs/${entry}`, { recursive: true, force: true });
for (const path of ['/run/nginx-nodejs', '/run/nginx-nodejs/client_temp', '/run/nginx-nodejs/proxy_temp', '/run/nginx-nodejs/fastcgi_temp', '/run/nginx-nodejs/uwsgi_temp', '/run/nginx-nodejs/scgi_temp', '/var/lib/nginx-nodejs/logs/node', '/var/lib/nginx-nodejs/logs/nginx', '/var/lib/nginx-nodejs/logs/nginx-error', '/var/lib/nginx-nodejs/fluent-bit/storage']) mkdirSync(path, { recursive: true });
cpSync('/etc/nginx-nodejs/services', '/run/nginx-nodejs/service', { recursive: true });
function linkScripts(source, target) {
  for (const entry of readdirSync(source, { withFileTypes: true })) {
    const from = `${source}/${entry.name}`;
    const to = `${target}/${entry.name}`;
    if (entry.isDirectory()) linkScripts(from, to);
    else if (statSync(from).mode & 0o111) {
      unlinkSync(to);
      symlinkSync(from, to);
    }
  }
}
linkScripts('/etc/nginx-nodejs/services', '/run/nginx-nodejs/service');
writeFileSync('/run/nginx-nodejs/node-command.json', JSON.stringify(nodeCommand), { mode: 0o600 });
chmodSync('/run/nginx-nodejs/node-command.json', 0o600);
writeFileSync('/run/nginx-nodejs/nginx.conf', readFileSync('/etc/nginx-nodejs/nginx.conf', 'utf8').replaceAll('__STATIC_ROOT__', staticRoot).replaceAll('__LOG_SERVICE__', logService));
writeFileSync('/run/nginx-nodejs/ingress.conf', `${ingress.map(ip => `set_real_ip_from ${ip};`).join('\n')}\nreal_ip_header X-Forwarded-For;\nreal_ip_recursive off;\n`);
writeFileSync('/run/nginx-nodejs/proxy.conf', readFileSync('/etc/nginx-nodejs/proxy.conf', 'utf8').replace('__PUBLIC_SCHEME__', publicScheme).replace('__NODE_PORT__', String(Number(nodePort))));
writeFileSync('/run/nginx-nodejs/routes.conf', readFileSync(`/etc/nginx-nodejs/routes.${mode}.conf`));
writeFileSync('/run/nginx-nodejs/static-server.conf', readFileSync('/etc/nginx-nodejs/static-server.conf', 'utf8').replaceAll('__STATIC_ROOT__', staticRoot));
if (enabled === '0') writeFileSync('/run/nginx-nodejs/service/collector/down', '');
const collectorEnvironment = {};
function credential(name, value) {
  const variable = `COLLECTOR_${name}`;
  const reference = `${variable}_REFERENCE`;
  collectorEnvironment[variable] = value;
  // Output properties and string config maps each expand once, after YAML parsing.
  collectorEnvironment[reference] = '${' + variable + '}';
  return '${' + reference + '}';
}
const fluentBit = {
  service: {
    flush: 1, daemon: 'off', log_level: 'warn', grace: 20,
    'scheduler.base': 1, 'scheduler.cap': 30,
    'storage.path': '/var/lib/nginx-nodejs/fluent-bit/storage',
    'storage.sync': 'normal', 'storage.checksum': 'on',
    'storage.max_chunks_up': 8, 'storage.backlog.mem_limit': '8M',
  },
  parsers: [{
    name: 'runtime_json', format: 'json', time_key: 'timestamp',
    time_format: '%Y-%m-%dT%H:%M:%S.%LZ', time_offset: '+0000', time_keep: 'on',
  }],
  pipeline: {
    inputs: [{
      name: 'tail', tag: 'runtime',
      path: collectorPaths().join(','),
      parser: 'runtime_json', read_from_head: 'on', refresh_interval: 1, rotate_wait: 5,
      buffer_chunk_size: 16384, buffer_max_size: 16384, skip_long_lines: 'on',
      db: '/var/lib/nginx-nodejs/fluent-bit/tail.db', 'db.sync': 'normal',
      'db.locking': 'on', 'db.compare_filename': 'off', 'storage.type': 'filesystem',
    }],
    // A failed JSON parse must never forward the raw line produced by Tail.
    filters: [{ name: 'grep', match: 'runtime', regex: `service ^${logService}$` }, ...extraFilters],
    outputs: [enabled === '1' ? {
      name: 'loki', match: 'runtime', host, port: Number(port),
      labels: `service=${logService},environment=${appEnv}`, line_format: 'json',
      auto_kubernetes_labels: 'off', retry_limit: 'no_limits',
      // Fluent Bit evicts the oldest chunk at this limit, unlike Vector drop_newest.
      'storage.total_limit_size': 268435456,
      'net.connect_timeout': 5, 'net.io_timeout': 5,
      tls, 'tls.verify': 'on', 'tls.verify_hostname': 'on', 'tls.vhost': host,
      'tls.ca_file': ca || '/etc/ssl/certs/ca-certificates.crt',
      ...(bearer ? { bearer_token: credential('BEARER', bearer) } : user ? { http_user: credential('USER', user), http_passwd: credential('PASSWORD', password) } : {}),
      ...(tenant ? { tenant_id: tenant } : {}),
    } : { name: 'null', match: 'runtime' }],
  },
};
for (const [file, value] of [['fluent-bit.yaml', fluentBit], ['fluent-bit-env.json', collectorEnvironment]]) {
  writeFileSync(`/run/nginx-nodejs/${file}`, JSON.stringify(value, null, 2), { mode: 0o600 });
  chmodSync(`/run/nginx-nodejs/${file}`, 0o600);
}
