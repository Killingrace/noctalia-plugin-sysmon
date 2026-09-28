#!/bin/sh
# procs.sh - process table sampler for the sysmon panel.
# usage: procs.sh LIMIT SORT ORDER SCALE KTHREADS MINE [FILTER]
#   MINE=1 keeps only the caller's processes; FILTER is matched case-insensitively.
#
# CPU% is a delta against the previous sample kept in $XDG_RUNTIME_DIR (tmpfs).
# When that snapshot is missing or stale (panel was closed), a priming pass runs
# first so the very first rows already show live usage, not lifetime averages.

dir=$(dirname "$0")
state="${XDG_RUNTIME_DIR:-/tmp}/noctalia-sysmon-procs"
limit=${1:-60}
sort=${2:-cpu}
order=${3:-desc}
scale=${4:-machine}
kthreads=${5:-0}
mine=""
[ "${6:-0}" = "1" ] && mine=$(id -u)
filter=$(printf '%s' "${7:-}" | tr '[:upper:]' '[:lower:]')
page=$(getconf PAGESIZE 2>/dev/null || echo 4096)

sample() {
  find /proc -mindepth 1 -maxdepth 1 -name '[0-9]*' -printf '%f %U\n' 2>/dev/null |
    LC_ALL=C.UTF-8 gawk -v state="$state" -v limit="$limit" -v sort="$sort" -v order="$order" \
      -v scale="$scale" -v kthreads="$kthreads" -v mineuid="$mine" -v filter="$filter" \
      -v page="$page" -f "$dir/procs.awk" - 2>/dev/null
}

now=$(date +%s)
mtime=$(stat -c %Y "$state" 2>/dev/null || echo 0)
if [ $((now - mtime)) -gt 5 ]; then
  sample >/dev/null
  sleep 0.4
fi
sample
