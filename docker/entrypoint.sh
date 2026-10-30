#!/bin/sh
set -eu
umask 077
# The supervisor and its helper Node processes must not load the app's NODE_OPTIONS (for example
# --require of an APM agent); process.mjs hands it back to the app process only.
if [ "${NODE_OPTIONS+set}" = set ]; then
    NODE_APP_OPTIONS="$NODE_OPTIONS"
    export NODE_APP_OPTIONS
    unset NODE_OPTIONS
fi
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
