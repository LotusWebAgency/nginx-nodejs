import { readdirSync } from 'node:fs';

export function collectorPaths(base = '/var/lib/nginx-nodejs/logs') {
  if (!/^\/[a-zA-Z0-9_/-]+$/.test(base) || base.split('/').includes('..')) throw new Error('invalid collector log directory');
  const paths = [`${base}/*/current`];
  // Snapshot archives at startup to avoid rereading newly rotated current files.
  for (const stream of ['node', 'nginx', 'nginx-error']) {
    const directory = `${base}/${stream}`;
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (entry.isFile() && /^@[a-f0-9]{24}\.[su]$/.test(entry.name)) paths.push(`${directory}/${entry.name}`);
    }
  }
  return paths;
}
