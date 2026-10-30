import { createSocket } from 'node:dgram';

const logService = process.env.LOG_SERVICE || 'nginx-nodejs';
const socket = createSocket('udp4');
let dropped = 0;
process.stdout.on('drain', () => {
  if (dropped) {
    const count = dropped;
    dropped = 0;
    process.stdout.write(`${JSON.stringify({ service: logService, event: 'nginx_log_dropped', count })}\n`);
  }
});
socket.on('message', buffer => {
  if (buffer.length > 16384) return;
  if (process.stdout.writableLength >= 65536) { dropped = Math.min(dropped + 1, Number.MAX_SAFE_INTEGER); return; }
  try {
    const message = buffer.toString('utf8');
    const value = JSON.parse(message.slice(message.indexOf('{')));
    if (value.event !== 'nginx_request' || !/^[a-fA-F0-9-]{16,40}$/.test(value.requestId)) return;
    if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'OTHER'].includes(value.method)) return;
    if (!Number.isInteger(value.status) || value.status < 100 || value.status > 599 || !Number.isFinite(value.durationSeconds) || value.durationSeconds < 0) return;
    process.stdout.write(`${JSON.stringify({ timestamp: new Date().toISOString(), service: logService, event: 'nginx_request', requestId: value.requestId, method: value.method, status: value.status, durationSeconds: value.durationSeconds })}\n`);
  } catch {}
});
socket.bind(5514, '127.0.0.1');
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => socket.close());
