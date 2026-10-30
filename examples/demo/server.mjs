import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

createServer((request, response) => {
  const start = performance.now();
  const requestId = randomUUID();
  const status = request.url === '/' || request.url === '/healthz' ? 200 : 404;
  response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'X-Request-ID': requestId });
  response.end(status === 200 ? 'nginx-nodejs is running\n' : 'Not found\n');
  console.log(JSON.stringify({ event: 'http_request', requestId, method: request.method, status, durationMs: performance.now() - start }));
}).listen(Number(process.env.PORT || 3000), process.env.HOST || '127.0.0.1');
