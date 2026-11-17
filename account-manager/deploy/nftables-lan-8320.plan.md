# TX3 NFTABLES FIREWALL CHANGE PLAN (LAN PORT 8320)
**Document ID:** TX3-NFTABLES-PLAN-PORT-8320  
**Target Host:** TX3 (`<TX3_IP>`)  
**Target Firewall:** Native `nftables` via `tx3-firewall.service` (`/etc/tx3-firewall.nft`)  
**Status:** `PREPARED — NOT EXECUTED — WAITING FOR OPERATOR ACTION`

---

## 1. Context & Architectural Analysis

TX3 utilizes a hardened, native `nftables` ruleset managing the `table ip tx3_filter` and `table ip6 tx3_filter` tables, orchestrated via `/etc/systemd/system/tx3-firewall.service` and `/usr/local/sbin/tx3-fw-apply.sh`. Standard Debian `ufw` is **NOT** active.

The existing IPv4 input policy drops all incoming traffic that is not explicitly whitelisted. Port `8317` (CLIProxyAPI) is currently bound only to `<TX3_IP>:8317` (accessed by HAOS).

To permit trusted LAN subnets (`<LAN_SUBNET>` and WireGuard peer subnet `<WG_SUBNET>`) to access the Account Manager Web UI on port `8320`, the firewall configuration must be explicitly updated in `/etc/tx3-firewall.nft`. No traffic from WAN is permitted or routed to port 8320.

---

## 2. Planned Changes to `/etc/tx3-firewall.nft`

In `/etc/tx3-firewall.nft`, under `table ip tx3_filter` -> `chain input`:

### Current Line (approx line 93):
```nftables
ip saddr { <LAN_SUBNET>, <WG_SUBNET> } tcp dport { 8081, 3001, 9090, 19531 } accept
```

### Candidate Updated Line:
```nftables
ip saddr { <LAN_SUBNET>, <WG_SUBNET> } tcp dport { 8081, 3001, 9090, 19531, 8320 } accept
```

---

## 3. Safe Verification and Application Runbook (For Operator Only)

> **MANDATORY NOTE:** Do not execute these steps until hardware deployment approval is formally granted.

### Step 1: Create Specific Timestamped Backup File
```bash
FW_BACKUP="/etc/tx3-firewall.nft.bak.$(date +%Y%m%dT%H%M%S)"
cp /etc/tx3-firewall.nft "$FW_BACKUP"
echo "Saved firewall backup to: $FW_BACKUP"
```

### Step 2: Edit Configuration
Update the port group to include `8320`:
```bash
sed -i 's/{ 8081, 3001, 9090, 19531 }/{ 8081, 3001, 9090, 19531, 8320 }/' /etc/tx3-firewall.nft
```

### Step 3: Validate Syntax Without Modifying Kernel State
```bash
nft -c -f /etc/tx3-firewall.nft
# Output must be completely clean with returncode 0
```

### Step 4: Apply Through TX3 Standard Apply Script
```bash
/usr/local/sbin/tx3-fw-apply.sh --enforce
```

### Step 5: Verify Active Rule in Kernel
```bash
nft -a list table ip tx3_filter | grep 8320
```

---

## 4. Rollback Plan
If any network anomaly occurs, restore the **exact** designated backup file (avoiding ambiguous wildcards):
```bash
# Replace <EXACT_BACKUP_FILENAME> with the exact file saved in Step 1 (e.g. /etc/tx3-firewall.nft.bak.20261110T123000)
cp "$FW_BACKUP" /etc/tx3-firewall.nft
/usr/local/sbin/tx3-fw-apply.sh --enforce
```
