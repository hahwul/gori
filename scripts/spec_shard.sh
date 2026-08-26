#!/usr/bin/env bash
# Print the spec files belonging to shard INDEX of TOTAL, one per line.
#
# `crystal spec` has no sharding of its own, so CI's matrix asks this script which
# files each runner should compile. The partition must be a FUNCTION OF THE TREE,
# not a checked-in list: a hardcoded split silently stops covering whatever spec
# file is added next, and nothing goes red to say so.
#
# Balancing is longest-processing-time-first on FILE SIZE. Size is a proxy for run
# time, and an imperfect one — a 3 KB file that sleeps on a socket outweighs a 40 KB
# table of pure-function examples — but it is the only cost signal available without
# checking in measurements that rot the moment a spec is edited. Measured against a
# real timing run of the suite it lands each of four shards within ~20% of the ideal
# even split, where round-robin over sorted names lands the worst shard at DOUBLE it.
set -euo pipefail

idx=${1:?usage: spec_shard.sh INDEX TOTAL (INDEX is 0-based)}
total=${2:?usage: spec_shard.sh INDEX TOTAL (INDEX is 0-based)}

if [ "$idx" -lt 0 ] || [ "$idx" -ge "$total" ]; then
  echo "spec_shard.sh: INDEX $idx out of range for TOTAL $total" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# `wc -c` rather than `stat`: the flag for a file's size is spelled differently on
# GNU (-c '%s') and BSD/macOS (-f '%z'), and this script runs on both.
find spec -name '*_spec.cr' -print0 | xargs -0 wc -c |
  awk '$2 != "" && $2 != "total" { print $1, $2 }' |
  sort -k1,1nr -k2,2 |
  awk -v idx="$idx" -v total="$total" '
    {
      best = 0
      for (i = 1; i < total; i++)
        if (load[i] < load[best]) best = i
      load[best] += $1
      if (best == idx) print $2
    }'
