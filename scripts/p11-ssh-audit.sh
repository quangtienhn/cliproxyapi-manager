#!/usr/bin/env bash
set -uo pipefail

# P11 SSH audit (READ-ONLY) on TX3.
# Run as root: bash /root/p11-ssh-audit.sh

echo "===== P11 SSH AUTH AUDIT (READ-ONLY) ====="
echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "host: $(hostname)"
echo

echo "===== amtunnel account ====="
getent passwd amtunnel
echo "--- password status ---"
passwd -S amtunnel 2>&1 || true
echo "--- home dir ---"
ls -ld /var/lib/amtunnel /var/lib/amtunnel/.ssh 2>&1
ls -l /var/lib/amtunnel/.ssh 2>&1
echo

echo "===== authorized_keys fingerprint ====="
if [ -f /var/lib/amtunnel/.ssh/authorized_keys ]; then
  ssh-keygen -lf /var/lib/amtunnel/.ssh/authorized_keys 2>&1
  echo "--- line count ---"
  wc -l /var/lib/amtunnel/.ssh/authorized_keys
  echo "--- key types (no key material) ---"
  awk '{print NR": "$1" (len="length($2)")"}' /var/lib/amtunnel/.ssh/authorized_keys
else
  echo "MISSING authorized_keys"
fi
echo

echo "===== sshd effective config for amtunnel ====="
sshd -T -C user=amtunnel,host=TX3_HOST,addr=HAOS_IP 2>&1 | grep -Ei 'allowtcpforwarding|permitopen|authorizedkeysfile|pubkeyauthentication|authenticationmethods|strictmodes|passwordauthentication|allowusers|denyusers|authorizedkeyscommand|permitrootlogin|forcecommand|chrootdirectory' || true
echo

echo "===== sshd config files (Match/Allow/Deny) ====="
grep -RniE 'Match|AllowUsers|DenyUsers|AuthorizedKeysCommand|ForceCommand|PermitOpen|AllowTcpForwarding' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || echo "(none found)"
echo

echo "===== sshd service ====="
systemctl is-active ssh 2>&1
systemctl is-enabled ssh 2>&1
echo

echo "===== recent auth failures (last 40, redacted) ====="
journalctl -u ssh -n 40 --no-pager 2>/dev/null | sed -E 's/(publickey for .*)/\1/; s/([0-9]{1,3}\.){3}[0-9]{1,3}/<IP>/g' | tail -40
echo

echo "===== account manager listener ====="
ss -ltnp 2>/dev/null | grep -E ':8320\b' || ss -ltn | grep -E ':8320\b'
echo

echo "===== END SSH AUDIT ====="
