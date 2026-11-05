#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/ggml-rpc-server"
capture="$tmp/args"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_ARGS"
STUB
chmod +x "$stub"

expect_reject() {
  if CAPTURE_ARGS="$capture" "$root/scripts/start-worker.sh" --server "$stub" "$@" >"$tmp/out" 2>&1; then
    echo "expected rejection: $*" >&2
    exit 1
  fi
}

CAPTURE_ARGS="$capture" "$root/scripts/start-worker.sh" --server "$stub"
grep -Fxq -- '--host' "$capture"
grep -Fxq -- '127.0.0.1' "$capture"
grep -Fxq -- '--port' "$capture"
grep -Fxq -- '50052' "$capture"

if CAPTURE_ARGS="$capture" "$root/scripts/start-worker.sh" --server "$stub" --host 192.168.0.10 --port 50052 >"$tmp/out" 2>&1; then
  echo 'LAN bind must require --allow-lan' >&2
  exit 1
fi
CAPTURE_ARGS="$capture" "$root/scripts/start-worker.sh" --server "$stub" --allow-lan --host 192.168.0.10 --device CUDA0
grep -Fxq -- '192.168.0.10' "$capture"
grep -Fxq -- 'CUDA0' "$capture"

expect_reject --allow-lan --host 0.0.0.0
expect_reject --allow-lan --host 8.8.8.8
expect_reject --allow-lan --host 169.254.1.1
expect_reject --allow-lan --host 100.64.0.1
expect_reject --host not-an-ip
expect_reject --port 0
expect_reject --port 65536
expect_reject --threads 0
expect_reject --device 'CUDA0;touch /tmp/pwned'

echo 'worker launcher safety tests passed'
