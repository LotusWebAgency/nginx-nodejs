#!/bin/sh
set -eu
umask 077
node /etc/nginx-nodejs/configure.mjs "$@"
if ! nginx -e /dev/null -t -c /run/nginx-nodejs/nginx.conf >/dev/null 2>&1; then
    echo 'Runtime configuration error: Nginx validation failed' >&2
    exit 78
fi
if ! node /etc/nginx-nodejs/process.mjs collector --validate >/dev/null 2>&1; then
    echo 'Runtime configuration error: collector validation failed' >&2
    exit 78
fi
echo "$$" > /run/nginx-nodejs/supervisor.pid
exec s6-svscan /run/nginx-nodejs/service
