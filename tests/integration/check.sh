#!/usr/bin/env bash
# Checks the running Compose stack (docker compose up) end to end: the vote
# page offers both options, a vote cast there is stored in Postgres by the
# worker (which reads votes only from the Redis queue), and result pushes the
# new count over Socket.IO. Exits non-zero at the first check that fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

vote=http://localhost:8080
result=http://localhost:8081

# Compose waits only until vote and result are running, not until they answer
wait_for() {
  for _ in $(seq 60); do
    curl -fs -o /dev/null "$1" && return
    sleep 1
  done
  echo "FAIL: no answer from $1" >&2
  return 1
}
wait_for "$vote/"
wait_for "$result/"

page=$(curl -fs "$vote/")
for option in a b; do
  grep -q "value=\"$option\">" <<< "$page" || { echo "FAIL: the vote page has no option $option" >&2; exit 1; }
done
echo "ok: the vote page offers both options"

voter=ci-$(date +%s)-$RANDOM
curl -fs -o /dev/null -b "voter_id=$voter" -d vote=b "$vote/"
echo "ok: voted b as $voter"

sql() { docker compose exec -T db psql -U postgres -tAc "$1"; }
stored=""
for _ in $(seq 30); do
  # The worker creates the votes table on its first connection, so errors are expected until then
  stored=$(sql "SELECT count(*) FROM votes WHERE id = '$voter'" 2> /dev/null || true)
  [ "$stored" = 1 ] && break
  sleep 1
done
[ "$stored" = 1 ] || { echo "FAIL: the worker did not store the vote within 30 s" >&2; exit 1; }
echo "ok: the worker stored the vote"

b=$(sql "SELECT count(*) FROM votes WHERE vote = 'b'")
node tests/integration/scores.mjs "ws://localhost:8081/result/socket.io/?EIO=4&transport=websocket" "$b"
echo "ok: result pushed b = $b"
