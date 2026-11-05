#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Start the pinned llama.cpp RPC worker in the foreground.

Usage: start-worker.sh [--server PATH] [--host IPv4] [--port PORT]
                       [--device NAME] [--threads N] [--allow-lan]

The default bind is 127.0.0.1. A private LAN address needs --allow-lan.
This worker has no authentication. Protect the port with a host firewall.
EOF
}

default_server="${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/privatelm-rpc-worker/build-b11157/bin/ggml-rpc-server"
server="${LLAMA_RPC_SERVER:-$default_server}"
host=127.0.0.1
port=50052
device=""
threads=""
allow_lan=0

while (($#)); do
  case "$1" in
    --server|--host|--port|--device|--threads)
      (($# >= 2)) || { echo "missing value for $1" >&2; exit 2; }
      option="$1"; value="$2"; shift 2
      case "$option" in
        --server) server="$value" ;;
        --host) host="$value" ;;
        --port) port="$value" ;;
        --device) device="$value" ;;
        --threads) threads="$value" ;;
      esac
      ;;
    --allow-lan) allow_lan=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -x "$server" ]] || { echo "RPC server is not executable: $server" >&2; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { echo "port must be an integer from 1 to 65535" >&2; exit 2; }
if [[ -n "$threads" ]]; then
  [[ "$threads" =~ ^[0-9]+$ ]] && ((10#$threads >= 1 && 10#$threads <= 256)) || { echo "threads must be an integer from 1 to 256" >&2; exit 2; }
fi
if [[ -n "$device" ]]; then
  [[ "$device" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "device name contains invalid characters" >&2; exit 2; }
fi

python3 - "$host" "$allow_lan" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("host must be a valid IPv4 address")
if address.version != 4:
    raise SystemExit("host must be IPv4")
if address.is_unspecified or address.is_multicast or address.is_loopback:
    if address != ipaddress.ip_address("127.0.0.1"):
        raise SystemExit("host must not be a wildcard, multicast, or non-default loopback address")
if address != ipaddress.ip_address("127.0.0.1"):
    if sys.argv[2] != "1":
        raise SystemExit("LAN bind requires --allow-lan")
    private_networks = (
        ipaddress.ip_network("10.0.0.0/8"),
        ipaddress.ip_network("172.16.0.0/12"),
        ipaddress.ip_network("192.168.0.0/16"),
    )
    if not any(address in network for network in private_networks):
        raise SystemExit("LAN bind must use a private IPv4 address")
PY

args=(--host "$host" --port "$port")
[[ -z "$device" ]] || args+=(--device "$device")
[[ -z "$threads" ]] || args+=(--threads "$threads")
echo "Starting unauthenticated llama.cpp RPC server on $host:$port. Press Ctrl-C to stop." >&2
exec "$server" "${args[@]}"
