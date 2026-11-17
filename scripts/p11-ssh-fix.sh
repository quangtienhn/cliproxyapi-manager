#!/usr/bin/env bash
set -uo pipefail

# P11 SSH auth fix on TX3: install the HAOS add-on's current public key into
# /var/lib/amtunnel/.ssh/authorized_keys (append, never overwrite), with a
# port-forward restriction to 127.0.0.1:8320.
#
# Usage (run as root on TX3):
#   ADDON_PUBKEY='ssh-ed25519 AAAA... amtunnel@haos' bash /root/p11-ssh-fix.sh
# or:
#   bash /root/p11-ssh-fix.sh /path/to/pubkey.txt
#
# The key is NOT a secret (public key), but do not paste private keys.

KEY_FILE="${1:-}"
if [ -n "$KEY_FILE" ]; then
  [ -r "$KEY_FILE" ] || { echo "[FAIL] cannot read $KEY_FILE"; exit 1; }
  PUBKEY=$(cat "$KEY_FILE")
else
  PUBKEY="${ADDON_PUBKEY:-}"
fi

if [ -z "$PUBKEY" ]; then
  echo "[FAIL] no public key provided."
  echo "       Set ADDON_PUBKEY='ssh-ed25519 AAAA... amtunnel@haos' or pass a file path."
  exit 1
fi

# normalize: single line, strip
PUBKEY=$(printf '%s' "$PUBKEY" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
# validate basic shape
if ! printf '%s' "$PUBKEY" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+={0,2}( .*)?$'; then
  echo "[FAIL] input does not look like a valid SSH public key"
  exit 1
fi

KEYMAT=$(printf '%s' "$PUBKEY" | awk '{print $2}')
[ -n "$KEYMAT" ] || { echo "[FAIL] could not extract key material"; exit 1; }

AUTH="/var/lib/amtunnel/.ssh/authorized_keys"
BACKUP_DIR="/root/.p11-ssh-backup-$(date -u '+%Y%m%dT%H%M%SZ')"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [ -f "$AUTH" ]; then
  cp -a "$AUTH" "${BACKUP_DIR}/authorized_keys"
  echo "[INFO] backup: ${BACKUP_DIR}/authorized_keys"
fi

# ensure dir
mkdir -p /var/lib/amtunnel/.ssh
chown amtunnel:amtunnel /var/lib/amtunnel /var/lib/amtunnel/.ssh
chmod 700 /var/lib/amtunnel/.ssh

# check if key material already present
if [ -f "$AUTH" ] && grep -qF "$KEYMAT" "$AUTH"; then
  echo "[INFO] key material already present in authorized_keys; not appending."
  echo "[INFO] existing lines:"
  grep -nF "$KEYMAT" "$AUTH" | sed 's/\(.\{0,20\}\).*/\1.../'
else
  # append with port-forward restriction
  RESTRICTED="permitopen=\"127.0.0.1:8320\",no-X11-forwarding,no-agent-forwarding,no-pty ${PUBKEY}"
  printf '%s\n' "$RESTRICTED" >> "$AUTH"
  chown amtunnel:amtunnel "$AUTH"
  chmod 600 "$AUTH"
  echo "[PASS] appended restricted key to authorized_keys"
fi

# ensure perms regardless
chown amtunnel:amtunnel "$AUTH"
chmod 600 "$AUTH"

echo "[INFO] authorized_keys now has $(wc -l < "$AUTH") line(s)"
echo "[INFO] fingerprints:"
ssh-keygen -lf "$AUTH" 2>&1 | sed 's/^/  /'
echo "[INFO] backup dir: $BACKUP_DIR"
echo "[DONE] next: test from HAOS: ssh -i /data/id_ed25519 -p 22 -L 127.0.0.1:18320:127.0.0.1:8320 amtunnel@TX3_IP"
