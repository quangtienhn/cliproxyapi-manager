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
  [ -n "$host" ] || host="$(read_opt tx3_host)"
  port="$(read_opt server_port)"
  [ -n "$port" ] || port="$(read_opt tx3_port)"
  raw="$(read_opt host_key)"
  [ -n "$port" ] || port=22
  [ -n "$host" ] || return 1
  [ -n "$raw" ] || return 1

  printf '%s\n' "$raw" | node -e '
    const fs = require("fs");
    const host = process.argv[1];
    const port = String(process.argv[2] || "22");
    const outFile = process.argv[3];
    const name = port === "22" ? host : "[" + host + "]:" + port;
    const types = /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)$/;
    const out = [];
    for (const line of fs.readFileSync(0, "utf8").split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const parts = t.split(/\s+/);
      const keyParts = types.test(parts[0]) ? parts : parts.slice(1);
      if (keyParts.length < 2 || !types.test(keyParts[0])) {
        console.error("invalid host key line");
        process.exit(2);
      }
      if (!/^[A-Za-z0-9+/=]+$/.test(keyParts[1])) {
        console.error("invalid host key encoding");
        process.exit(2);
      }
      out.push(name + " " + keyParts.join(" "));
    }
    if (out.length === 0) process.exit(2);
    fs.writeFileSync(outFile, out.join("\n") + "\n", { mode: 0o600 });
  ' "$host" "$port" "$KNOWN.tmp" || { rm -f "$KNOWN.tmp"; return 1; }
  mv "$KNOWN.tmp" "$KNOWN" || { rm -f "$KNOWN.tmp"; return 1; }
  chmod 600 "$KNOWN"
}

# --- Tunnel supervisor loop ---
tunnel_loop() {
  while :; do
    host="$(read_opt server_host)"; [ -n "$host" ] || host="$(read_opt tx3_host)"
    port="$(read_opt server_port)"; [ -n "$port" ] || port="$(read_opt tx3_port)"
    [ -n "$port" ] || port=22
    user="$(read_opt server_user)"; [ -n "$user" ] || user="$(read_opt tx3_user)"
    [ -n "$user" ] || user=amtunnel
    rhost="$(read_opt remote_host)"; [ -n "$rhost" ] || rhost=127.0.0.1
    rport="$(read_opt remote_port)"; [ -n "$rport" ] || rport=8320

    if [ -z "$host" ]; then
      log "Configuration required: set 'server_host' to your Linux server IP/hostname"
      sleep 15
      continue
    fi

    if ! write_known_hosts; then
      log "SSH host key not configured or invalid; paste your server host key into option 'host_key'"
      sleep 15
      continue
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
