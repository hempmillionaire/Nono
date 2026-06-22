#!/usr/bin/env bash
#
# NONO VPS smoke test.
#
# Target: clean Ubuntu 24.04 LTS (also works on 22.04). Runs everything end-to-end:
#   1. install build deps
#   2. build release-static against current checkout
#   3. assert all expected binaries exist
#   4. nonod --version
#   5. start a private regtest daemon (no P2P, fixed difficulty 1, mainnet nettype -> N... addresses)
#   6. start nono-wallet-rpc, create a fresh mainnet wallet via JSON-RPC
#   7. assert the address starts with 'N'
#   8. mine 5 blocks via generateblocks to that address
#   9. report genesis hash, block 1 coinbase reward, and a tail of both logs
#  10. clean shutdown
#
# Run from the repo root:
#     bash utils/smoke/vps_smoke.sh
#
# All artifacts land in ./smoke-out/ and a single summary is written to
# ./smoke-out/REPORT.md so it can be pasted back into Slack.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$REPO_ROOT/smoke-out"
# BUILD_DIR / BIN_DIR are resolved after the build, because Monero's
# Makefile writes to build/$(OS)/$(BRANCH)/release/ which we can't
# predict from outside (it depends on uname + current git branch).
BUILD_DIR=""
BIN_DIR=""
DATA_DIR="$OUT_DIR/nonod-data"
WALLET_DIR="$OUT_DIR/wallets"
LOG_DIR="$OUT_DIR/logs"
REPORT="$OUT_DIR/REPORT.md"

DAEMON_RPC_PORT=24701   # NONO mainnet RPC port. P2P is not opened in regtest mode.
WALLET_RPC_PORT=28088   # arbitrary unused local port
WALLET_NAME="smoke"
WALLET_PASS=""          # empty password is fine for a throwaway regtest wallet

mkdir -p "$OUT_DIR" "$DATA_DIR" "$WALLET_DIR" "$LOG_DIR"
: > "$REPORT"

log() { printf '[smoke] %s\n' "$*" | tee -a "$REPORT"; }
section() { printf '\n## %s\n\n' "$*" >> "$REPORT"; printf '\n=== %s ===\n' "$*"; }
fail() { printf '[smoke][FATAL] %s\n' "$*" | tee -a "$REPORT" >&2; exit 1; }

cleanup() {
  set +e
  if [[ -n "${WRPC_PID:-}" ]] && kill -0 "$WRPC_PID" 2>/dev/null; then
    kill "$WRPC_PID" 2>/dev/null
    wait "$WRPC_PID" 2>/dev/null
  fi
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    "$BIN_DIR/nonod" --rpc-bind-port "$DAEMON_RPC_PORT" exit 2>/dev/null || true
    sleep 2
    kill "$DAEMON_PID" 2>/dev/null
    wait "$DAEMON_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

rpc() {
  # rpc <port> <method> [params-json]
  local port="$1" method="$2" params="${3:-{}}"
  curl -fsS -X POST "http://127.0.0.1:${port}/json_rpc" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"${method}\",\"params\":${params}}"
}

wait_for_port() {
  # wait_for_port <port> <timeout-seconds> <label>
  local port="$1" timeout="$2" label="$3" t=0
  while ! (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
    sleep 1; t=$((t+1))
    if [[ "$t" -ge "$timeout" ]]; then
      fail "timed out waiting for $label on port $port"
    fi
  done
  log "$label is up on port $port (waited ${t}s)"
}

############################################
section "Environment"
log "host: $(uname -a)"
log "cwd:  $REPO_ROOT"
log "head: $(git rev-parse HEAD)  ($(git rev-parse --abbrev-ref HEAD))"
log "free RAM:  $(free -h | awk '/^Mem:/ {print $2 " total / " $7 " avail"}')"
log "free disk: $(df -h . | awk 'NR==2 {print $4 " avail on " $1}')"
log "cores: $(nproc)"

############################################
section "Install build deps"
if ! command -v sudo >/dev/null; then SUDO=""; else SUDO="sudo"; fi
$SUDO apt-get update -y
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential cmake pkg-config ccache \
  libboost-all-dev libssl-dev libzmq3-dev libsodium-dev libpgm-dev libnorm-dev \
  libunbound-dev libevent-dev libgss-dev libkrb5-dev libunwind8-dev liblzma-dev libreadline-dev libhidapi-dev libusb-1.0-0-dev \
  libprotobuf-dev protobuf-compiler libudev-dev \
  python3 git curl ca-certificates

############################################
section "Sync submodules"
# A fresh clone leaves external/* empty (or stale after a checkout that
# changes pinned submodule SHAs). --init brings them in, --recursive
# handles nested submodules, --force resets any local divergence so the
# build always sees the pinned trees.
log "running: git submodule update --init --force --recursive"
git submodule update --init --force --recursive 2>&1 | tee -a "$LOG_DIR/submodule.log"

############################################
section "Build"
log "running: make release-static -j$(nproc)"
make release-static "-j$(nproc)" 2>&1 | tail -40 | tee -a "$LOG_DIR/build.tail.log"

############################################
section "Resolve build output dir"
# Monero's Makefile writes to build/$(OS)/$(BRANCH)/release/, e.g.
# build/Linux/master/release. Find the actual bin dir by locating
# the freshly-built nonod under build/. Pick the most recently
# modified match if more than one exists (e.g. a prior branch's
# leftovers).
NONOD_PATH="$(find "$REPO_ROOT/build" -type f -name nonod -path '*/release/bin/*' -printf '%T@ %p\n' 2>/dev/null \
              | sort -nr | head -1 | awk '{print $2}')"
if [[ -z "$NONOD_PATH" ]]; then
  fail "could not locate built nonod under $REPO_ROOT/build"
fi
BIN_DIR="$(dirname "$NONOD_PATH")"
BUILD_DIR="$(dirname "$BIN_DIR")"
log "BIN_DIR:   $BIN_DIR"
log "BUILD_DIR: $BUILD_DIR"

############################################
section "Binary inventory"
EXPECTED=(nonod nono-wallet-cli nono-wallet-rpc nono-blockchain-import nono-blockchain-export nono-blockchain-prune)
for b in "${EXPECTED[@]}"; do
  if [[ -x "$BIN_DIR/$b" ]]; then
    log "OK   $b"
  else
    fail "missing binary: $BIN_DIR/$b"
  fi
done

############################################
section "nonod --version"
"$BIN_DIR/nonod" --version | tee -a "$REPORT"

############################################
section "Start private regtest daemon"
# --regtest: single-node mode, mining via generateblocks RPC
# --offline + --no-igd + zero p2p peers: no network exposure at all
# nettype is mainnet (default) so wallets produce N... addresses
"$BIN_DIR/nonod" \
  --regtest \
  --fixed-difficulty 1 \
  --offline \
  --no-igd \
  --hide-my-port \
  --p2p-bind-ip 127.0.0.1 \
  --p2p-bind-port 0 \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port "$DAEMON_RPC_PORT" \
  --confirm-external-bind \
  --data-dir "$DATA_DIR" \
  --log-file "$LOG_DIR/nonod.log" \
  --log-level 1 \
  --non-interactive \
  >"$LOG_DIR/nonod.stdout" 2>&1 &
DAEMON_PID=$!
log "nonod pid=$DAEMON_PID"
wait_for_port "$DAEMON_RPC_PORT" 30 "nonod RPC"

############################################
section "Daemon get_info"
INFO_JSON="$(rpc "$DAEMON_RPC_PORT" get_info)"
echo "$INFO_JSON" | python3 -m json.tool | tee -a "$REPORT"

############################################
section "Genesis (block 0) header"
GENESIS_JSON="$(rpc "$DAEMON_RPC_PORT" get_block_header_by_height '{"height":0}')"
echo "$GENESIS_JSON" | python3 -m json.tool | tee -a "$REPORT"
GENESIS_HASH="$(echo "$GENESIS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["block_header"]["hash"])')"
log "genesis hash: $GENESIS_HASH"

############################################
section "Start wallet RPC"
"$BIN_DIR/nono-wallet-rpc" \
  --rpc-bind-ip 127.0.0.1 \
  --rpc-bind-port "$WALLET_RPC_PORT" \
  --disable-rpc-login \
  --daemon-address "127.0.0.1:$DAEMON_RPC_PORT" \
  --wallet-dir "$WALLET_DIR" \
  --log-file "$LOG_DIR/wallet-rpc.log" \
  --log-level 1 \
  --non-interactive \
  >"$LOG_DIR/wallet-rpc.stdout" 2>&1 &
WRPC_PID=$!
log "nono-wallet-rpc pid=$WRPC_PID"
wait_for_port "$WALLET_RPC_PORT" 30 "wallet RPC"

############################################
section "Create wallet (mainnet)"
rpc "$WALLET_RPC_PORT" create_wallet \
  "{\"filename\":\"$WALLET_NAME\",\"password\":\"$WALLET_PASS\",\"language\":\"English\"}" \
  | python3 -m json.tool | tee -a "$REPORT"

ADDR_JSON="$(rpc "$WALLET_RPC_PORT" get_address)"
echo "$ADDR_JSON" | python3 -m json.tool | tee -a "$REPORT"
ADDR="$(echo "$ADDR_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["address"])')"
log "wallet address: $ADDR"

############################################
section "Address-prefix assertion (must start with N)"
if [[ "${ADDR:0:1}" != "N" ]]; then
  fail "address does not start with 'N': $ADDR  -- prefix work is incomplete or wallet is wrong nettype"
fi
log "OK address starts with N"

############################################
section "Mine 5 blocks"
GEN_JSON="$(rpc "$DAEMON_RPC_PORT" generateblocks \
  "{\"amount_of_blocks\":5,\"wallet_address\":\"$ADDR\",\"starting_nonce\":0}")"
echo "$GEN_JSON" | python3 -m json.tool | tee -a "$REPORT"

############################################
section "Block 1 header (first coinbase reward)"
BLK1_JSON="$(rpc "$DAEMON_RPC_PORT" get_block_header_by_height '{"height":1}')"
echo "$BLK1_JSON" | python3 -m json.tool | tee -a "$REPORT"

REWARD_ATOMIC="$(echo "$BLK1_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["block_header"]["reward"])')"
# 10 decimals per CRYPTONOTE_DISPLAY_DECIMAL_POINT
REWARD_NONO="$(python3 -c "print(f'{int(\"$REWARD_ATOMIC\")/10**10:.10f}')")"
log "block 1 reward: $REWARD_ATOMIC atomic = $REWARD_NONO NONO"
log "expected ~42.38 NONO (EMISSION_SPEED_FACTOR_PER_MINUTE=21 + 60s blocks)"

############################################
section "Log tails"
{ echo '### nonod.log (last 30)'; tail -30 "$LOG_DIR/nonod.log" || true; } >> "$REPORT"
{ echo '### wallet-rpc.log (last 30)'; tail -30 "$LOG_DIR/wallet-rpc.log" || true; } >> "$REPORT"

############################################
section "Done"
log "all assertions passed"
log "report:   $REPORT"
log "logs:     $LOG_DIR/"
log "data:     $DATA_DIR/"
log "wallets:  $WALLET_DIR/   (throwaway regtest wallet; DO NOT send real funds)"
