#!/bin/sh
BASE=${0%/*}; [ "$BASE" = "$0" ] && BASE=.
exec /bin/sh "$BASE/altscreen_runtime_rescue.sh" quarantine
