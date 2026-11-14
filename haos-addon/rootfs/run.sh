#!/usr/bin/env sh
set -eu
umask 077

DATA_DIR="/data"
KEY="$DATA_DIR/id_ed25519"
PUB="$DATA_DIR/id_ed25519.pub"
KNOWN="$DATA_DIR/known_hosts"
OPTIONS="$DATA_DIR/options.json"
UPSTREAM_PORT=18320
PROXY_PORT=8080

log() { printf '%s [tunnel] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

read_opt() {
  node -e '
    const fs = require("fs");
    let o = {};
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
    const v = o[process.argv[2]];
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  ' "$OPTIONS" "$1"
}

# --- SSH identity generation ---
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
if [ ! -s "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C 'amtunnel@haos' -f "$KEY"
  log "Generated new secure SSH keypair for tunnel"
fi
chmod 600 "$KEY"
chmod 644 "$PUB"
log "SSH_PUBLIC_KEY=$(cat "$PUB")"
log "SSH_FINGERPRINT=$(ssh-keygen -lf "$PUB" | awk '{print $2}')"

# --- Host key verification & pinning ---
write_known_hosts() {
  host="$(read_opt server_host)"
  port="$(read_opt server_port)"
  raw="$(read_opt host_key)"
  [ -n "$port" ] || port=22
  [ -n "$host" ] || return 1
  [ -n "$raw" ] || return 1

  printf '%s\n' "$raw" | node /app/hostkey.mjs "$host" "$port" "$KNOWN.tmp" \
    || { rm -f "$KNOWN.tmp"; return 1; }
  mv "$KNOWN.tmp" "$KNOWN" || { rm -f "$KNOWN.tmp"; return 1; }
  chmod 600 "$KNOWN"
  log "Pinned host key fingerprint: $(ssh-keygen -lf "$KNOWN" | awk '{print $2}')"
}

# --- Tunnel supervisor loop ---
tunnel_loop() {
  while :; do
    host="$(read_opt server_host)"
    port="$(read_opt server_port)"
    [ -n "$port" ] || port=22
    user="$(read_opt server_user)"
    [ -n "$user" ] || user=amtunnel
    rhost="$(read_opt remote_host)"; [ -n "$rhost" ] || rhost=127.0.0.1
    rport="$(read_opt remote_port)"; [ -n "$rport" ] || rport=8320

    if [ -z "$host" ]; then
      log "Configuration required: set 'server_host' to your Linux server IP/hostname"
      sleep 15
      continue
    fi

    if ! write_known_hosts; then
      log "SSH host key missing or invalid. Paste the server host public key into add-on option 'host_key' (for example the contents of /etc/ssh/ssh_host_ed25519_key.pub)."
      sleep 15
      continue
    fi

    if [ "$rhost" != "127.0.0.1" ] && [ "$rhost" != "localhost" ] && [ "$rhost" != "::1" ]; then
      log "WARNING: remote_host=${rhost} is not a loopback address. The server-side tunnel key only permits 127.0.0.1:${rport}; the connection will fail."
    fi

    log "Connecting ${user}@${host}:${port} -> ${rhost}:${rport} (local 127.0.0.1:${UPSTREAM_PORT})"
    set +e
    ssh -N \
      -i "$KEY" \
      -p "$port" \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no \
      -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$KNOWN" \
      -o GlobalKnownHostsFile=/dev/null \
      -o UpdateHostKeys=no \
      -o VerifyHostKeyDNS=no \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      -o TCPKeepAlive=yes \
      -o ConnectTimeout=10 \
      -o LogLevel=ERROR \
      -L "127.0.0.1:${UPSTREAM_PORT}:${rhost}:${rport}" \
      "${user}@${host}" < /dev/null &
    SSH_PID=$!
    printf '%s\n' "$SSH_PID" > "$DATA_DIR/ssh.pid"
    wait "$SSH_PID"
    rc=$?
    rm -f "$DATA_DIR/ssh.pid"
    set -e
    log "SSH tunnel disconnected (rc=$rc); reconnecting in 5s..."
    sleep 5
  done
}

PORT="$PROXY_PORT" UPSTREAM_PORT="$UPSTREAM_PORT" DATA_DIR="$DATA_DIR" node /app/proxy.mjs &
PROXY_PID=$!

rm -f "$DATA_DIR/ssh.pid"
tunnel_loop &
LOOP_PID=$!

term() {
  log "Shutdown signal received; closing tunnel"
  if [ -s "$DATA_DIR/ssh.pid" ]; then
    kill "$(cat "$DATA_DIR/ssh.pid")" 2>/dev/null || true
    rm -f "$DATA_DIR/ssh.pid"
  fi
  kill "$LOOP_PID" "$PROXY_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  exit 0
}
trap term TERM INT

wait "$PROXY_PID"
kill "$LOOP_PID" 2>/dev/null || true
if [ -s "$DATA_DIR/ssh.pid" ]; then
  kill "$(cat "$DATA_DIR/ssh.pid")" 2>/dev/null || true
  rm -f "$DATA_DIR/ssh.pid"
fi
