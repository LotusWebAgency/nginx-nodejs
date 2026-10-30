const MAX_MESSAGE = 512;
const MAX_INPUT = 2048;
const levels = new Set(['debug', 'info', 'notice', 'warn', 'error', 'crit', 'alert', 'emerg']);

export function scrub(text) {
  return String(text).slice(0, MAX_INPUT)
    .replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])/g, '')
    .replace(/[\x00-\x1f\x7f]+/g, ' ')
    .replace(/\?[^\s"'`]+/g, '')
    .replace(/\b(?:Bearer|Basic)\s+[^\s"'`]+/gi, '<redacted>')
    .replace(/(\/\/)[^/\s@"'`]+@/g, '$1<redacted>@')
    .replace(/\b([\w.-]*(?:token|key|secret|password|dsn|auth)[\w.-]*)(["']\s*[=:]\s*)[\s\S]*/gi, '$1$2<redacted>')
    .replace(/\b([\w.-]*(?:token|key|secret|password|dsn|auth)[\w.-]*)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"'`,;&)}\]]+)/gi, '$1$2<redacted>')
    .replace(/[^\s@<>"'`()]+@[^\s@<>"'`()]+\.[^\s@<>"'`()]+/g, '<email>')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '<ip>')
    .replace(/(?<![\w:])(?=[0-9a-f:]*::|(?:[0-9a-f]{1,4}:){4})[0-9a-f:]{3,39}(?![\w:])/gi, '<ip>')
    .replace(/\+?\d(?:[\d ().-]*\d)?/g, match => (match.replace(/\D/g, '').length >= 6 ? '<digits>' : match))
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_MESSAGE);
}

export function nginxError(line) {
  const parsed = /^(?:\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d|nginx:) \[(\w+)\] (.*)$/s.exec(line);
  const level = parsed && levels.has(parsed[1]) ? parsed[1] : 'error';
  const cut = (parsed ? parsed[2] : line).split(/, (?:client|server|request|upstream|host|referrer): /)[0];
  return { level, message: scrub(cut) };
}

export function createLimiter({ limit = 30, windowMs = 60000, report }) {
  let count = 0;
  let suppressed = 0;
  let timer = null;
  function flush() {
    clearTimeout(timer);
    timer = null;
    const dropped = suppressed;
    count = 0;
    suppressed = 0;
    if (dropped > 0) report(dropped);
  }
  return {
    allow() {
      if (!timer) {
        timer = setTimeout(flush, windowMs);
        timer.unref();
      }
      if (count < limit) {
        count += 1;
        return true;
      }
      suppressed += 1;
      return false;
    },
    flush,
  };
}
