#!/bin/sh
# ALLOY stage 00 — apk trust (keys are scp'd by the driver before this runs).
set -e
apk update 2>&1 | tail -1
apk stats | head -2
