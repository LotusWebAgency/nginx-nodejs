#!/bin/sh
if [ -n "${4:-}" ]; then kill -KILL -- "-$4" 2>/dev/null || true; fi
if [ ! -f /run/nginx-nodejs/stopping ]; then
    touch /run/nginx-nodejs/failed /run/nginx-nodejs/stopping
    s6-svscanctl -t /run/nginx-nodejs/service
fi
exit 125
