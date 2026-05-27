# cloudflare-ufw-sync

> Automatically sync Cloudflare IP ranges to UFW on Debian/Ubuntu — restrict HTTP and HTTPS traffic to Cloudflare-only, with safe idempotent runs, full logging, and cron support.

---

## ⚠️ Compatibility Warning — Read Before Installing

**This script is designed for bare servers where UFW is the sole firewall manager.**

Do not use this script on systems where another service already owns and manages the firewall ruleset. Running multiple tools that write to iptables simultaneously causes rule conflicts, unexpected traffic blocking, and can silently break your server's security posture.

### Known Incompatible Environments

| System / Tool | Why It Conflicts |
|---|---|
| **HestiaCP** | Uses iptables directly by default for all firewall and Fail2Ban integration. HestiaCP's own firewall UI will overwrite or conflict with UFW rules. Installing alongside requires the `--iptables no` flag at setup and is unsupported in the standard configuration. |
| **cPanel / WHM** | Ships a firewall management script (`configure_firewall_for_cpanel`) that **clears all existing iptables rules** on run. cPanel's own documentation explicitly warns against using UFW and recommends CSF instead. |
| **CyberPanel** | Uses CSF (ConfigServer Security & Firewall) for firewall management. CSF manages iptables directly and requires UFW to be disabled to avoid conflicts. |
| **Plesk** | Has a built-in Plesk Firewall module that writes and manages iptables/firewalld rules directly. Running UFW alongside it causes duplicate or conflicting rule chains. |
| **DirectAdmin** | Integrates natively with CSF since v1.61. CSF and UFW cannot coexist — CSF must be the sole iptables manager. |
| **Webmin / Virtualmin** | Includes its own Linux Firewall module and may install firewalld. Multiple firewall managers on the same system produce unpredictable behaviour. |
| **CSF (ConfigServer Security & Firewall)** | A standalone iptables frontend used widely across hosting panels. Its own documentation requires disabling UFW before installation: `ufw disable`. |
| **firewalld** | UFW and firewalld both manage the same underlying iptables/nftables rules. Running both simultaneously causes conflicting rule chains and undefined behaviour. |
| **Docker** | Docker bypasses UFW entirely by injecting rules directly into iptables FORWARD and NAT chains before UFW's INPUT chain is evaluated. This script's rules have no effect on Docker-published container ports. |
| **Kubernetes / container runtimes** | Same class of problem as Docker — container networking rewires iptables at a layer below UFW. |

### Safe to Use When

- The server runs a single application (e.g. Nginx, Caddy, Apache) with no hosting control panel
- UFW is the only active firewall tool (`systemctl status firewalld` is inactive or not installed)
- Docker is not installed, or you understand and have resolved the Docker/UFW bypass issue
- No hosting panel was used to provision the server

**If in doubt:** run `ufw status verbose` and `iptables -L -n | head -40` and confirm that only UFW-generated chains are present before deploying this script.

---

## Table of Contents

- [What This Script Does](#what-this-script-does)
- [Why You Need It](#why-you-need-it)
- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [First Run](#first-run)
- [Automating with Cron](#automating-with-cron)
- [Log File & Rotation](#log-file--rotation)
- [Verifying the Rules](#verifying-the-rules)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [How It Compares to Other Approaches](#how-it-compares-to-other-approaches)
- [License](#license)

---

## What This Script Does

`cloudflare-ufw-sync.sh` is a hardened shell script for Linux servers running **UFW (Uncomplicated Firewall)**. It:

1. Downloads the official Cloudflare IPv4 and IPv6 CIDR ranges directly from `cloudflare.com`
2. Compares new ranges against the previous run — exits cleanly if nothing has changed
3. Validates the downloaded content before touching any firewall rules
4. Removes the previous set of Cloudflare rules cleanly using a state file — no fragile output parsing
5. Adds fresh `ufw allow` rules permitting **TCP ports 80 and 443 only** from every Cloudflare IP range
6. Logs every action with timestamps to `/var/log/cloudflare-ufw-sync.log`

The result: only traffic originating from Cloudflare's network can reach your web server on ports 80 and 443. Direct-to-origin requests from any other IP are blocked by UFW.

> **Note on `ufw reload`:** This script intentionally does not call `ufw reload`. The UFW man page confirms that once UFW is enabled, individual `ufw allow` and `ufw delete` commands apply immediately to the live iptables ruleset without requiring a reload. Calling `ufw reload` unnecessarily flushes and recreates all rule chains, which can momentarily sever active connections including SSH.

---

## Why You Need It

When your web server sits behind **Cloudflare's reverse proxy**, your origin server's real IP should never receive traffic directly from the public internet. If it does, attackers can:

- Bypass Cloudflare's DDoS protection and WAF rules entirely
- Hit your server with raw volumetric attacks
- Scan for vulnerabilities that Cloudflare would normally filter
- Exfiltrate your origin IP and attack it permanently

The standard mitigation is to **restrict ports 80 and 443 at the firewall level** so only Cloudflare's IP ranges can connect. The challenge is that Cloudflare occasionally updates its published IP ranges — meaning a static firewall rule set goes stale. This script solves that by keeping UFW in sync automatically.

---

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                   Script Execution Flow                  │
│                                                         │
│  1. Pre-flight     Root check, curl + ufw present?      │
│         │                                               │
│  2. Fetch          curl cloudflare.com/ips-v4 & ips-v6  │
│         │                                               │
│  3. Validate       CIDR regex check on every line       │
│                    Minimum count sanity check           │
│         │                                               │
│  4. Diff check     Compare new vs previous state file   │
│                    Exit cleanly if no changes           │
│         │                                               │
│  5. Atomic swap    Move .tmp → live files only if valid │
│         │                                               │
│  6. Flush old      Read /etc/cloudflare-ufw.state       │
│                    ufw delete each recorded CIDR        │
│         │                                               │
│  7. Add new        ufw allow tcp port 80,443 per CIDR   │
│                    Write each CIDR to state file        │
│         │                                               │
│  8. Log            Timestamped entry in /var/log/       │
└─────────────────────────────────────────────────────────┘
```

### Why No `ufw reload`?

Individual `ufw allow` and `ufw delete` commands apply immediately to the live kernel ruleset — no reload is needed. This is documented in the official UFW man page:

> *"once ufw is 'enabled', ufw will not flush the chains when adding or removing rules"*

Running `ufw reload` after individual rule changes is redundant and carries risk: it flushes and recreates all iptables chains, which can briefly interrupt active connections. This script omits it by design.

### State File Approach

Rather than parsing `ufw status numbered` output (fragile, format-dependent), this script maintains `/etc/cloudflare-ufw.state` — a plain text file listing every CIDR that was added in the last successful run. On the next run, it reads that file and issues exact `ufw delete` commands before adding fresh rules. This is deterministic, reliable, and format-independent.

### Early Exit on No Change

Before modifying any rules, the script compares the newly downloaded IP list against the state file. If Cloudflare's ranges are unchanged since the last run, the script exits cleanly without touching UFW at all — minimising unnecessary firewall churn on routine cron runs.

### Validation Before Any Changes

The script validates downloaded files against strict CIDR regex patterns **before** touching a single firewall rule. If the download is empty, truncated, returns an HTML error page, or contains unexpected content, the script exits with an error and leaves UFW completely untouched.

### Idempotent by Design

Running the script multiple times always results in the same final state — no rule duplication, no accumulation of stale entries.

---

## Requirements

| Requirement | Details |
|---|---|
| **OS** | Debian, Ubuntu, or any Debian-based Linux distribution |
| **Shell** | Bash 4.0+ (`/bin/bash`) |
| **UFW** | `ufw` installed and active — and the **only** active firewall manager |
| **curl** | `curl` installed (used for downloads) |
| **Privileges** | Must run as `root` or via `sudo` |
| **Network** | Outbound HTTPS access to `www.cloudflare.com` |

Check your versions:

```bash
bash --version
ufw --version
curl --version
```

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourrepo/cloudflare-ufw-sync.git
cd cloudflare-ufw-sync
```

### 2. Make the script executable

```bash
chmod +x cloudflare-ufw-sync.sh
```

### 3. Ensure UFW is installed and active

```bash
apt update && apt install -y ufw curl
ufw enable
ufw status
```

### 4. Ensure your SSH port is allowed **before** running the script

> ⚠️ **Critical:** This script does not touch SSH, but make sure you have a rule allowing your SSH port so you do not lock yourself out.

```bash
ufw allow 22/tcp
ufw status
```

### 5. Enable IPv6 support in UFW (recommended)

Edit `/etc/default/ufw`:

```bash
nano /etc/default/ufw
```

Set:

```
IPV6=yes
```

Save and reload:

```bash
ufw reload
```

---

## Configuration

All configuration is at the top of `cloudflare-ufw-sync.sh`:

```bash
CF_V4_URL="https://www.cloudflare.com/ips-v4"   # Cloudflare IPv4 source URL
CF_V6_URL="https://www.cloudflare.com/ips-v6"   # Cloudflare IPv6 source URL
COMMENT="Cloudflare"                             # UFW rule comment tag
LOGFILE="/var/log/cloudflare-ufw-sync.log"       # Log file path
STATEFILE="/etc/cloudflare-ufw.state"            # State file path
MIN_V4_EXPECTED=5                                # Min valid IPv4 CIDRs (abort if fewer)
MIN_V6_EXPECTED=3                                # Min valid IPv6 CIDRs (abort if fewer)
```

You do not need to change anything for a standard setup. The URLs are Cloudflare's official published IP list endpoints and do not change.

---

## First Run

Run the script manually first to verify it works correctly:

```bash
sudo bash cloudflare-ufw-sync.sh
```

Expected output:

```
[2024-11-20 14:32:01] ===== Cloudflare UFW Sync Started =====
[2024-11-20 14:32:01] Fetching Cloudflare IPv4 ranges from https://www.cloudflare.com/ips-v4 ...
[2024-11-20 14:32:02] Fetching Cloudflare IPv6 ranges from https://www.cloudflare.com/ips-v6 ...
[2024-11-20 14:32:03] Validation passed: 14 IPv4 CIDRs and 6 IPv6 CIDRs look valid
[2024-11-20 14:32:03] No state file found at /etc/cloudflare-ufw.state — assuming this is a first run
[2024-11-20 14:32:03] Adding new IPv4 rules...
[2024-11-20 14:32:05] Added 14 IPv4 rules
[2024-11-20 14:32:05] Adding new IPv6 rules...
[2024-11-20 14:32:06] Added 6 IPv6 rules
[2024-11-20 14:32:07] ===== Cloudflare UFW Sync Complete =====
```

On subsequent runs where Cloudflare's IPs are unchanged:

```
[2024-11-27 03:00:01] ===== Cloudflare UFW Sync Started =====
[2024-11-27 03:00:02] Validation passed: 14 IPv4 CIDRs and 6 IPv6 CIDRs look valid
[2024-11-27 03:00:02] Cloudflare IPs are unchanged since last run. No UFW updates required.
[2024-11-27 03:00:02] ===== Cloudflare UFW Sync Complete =====
```

---

## Automating with Cron

Cloudflare updates its IP ranges infrequently, but automating the sync weekly ensures you never fall out of date.

### Add a weekly cron job

```bash
crontab -e
```

Add this line to run every Sunday at 03:00:

```cron
0 3 * * 0 /path/to/cloudflare-ufw-sync/cloudflare-ufw-sync.sh >> /var/log/cloudflare-ufw-sync.log 2>&1
```

> Replace `/path/to/cloudflare-ufw-sync/` with the actual full path where you cloned the repo.

The `>> /var/log/cloudflare-ufw-sync.log 2>&1` redirect ensures both stdout and stderr are captured by the log file on cron runs.

### Verify cron is working

After the scheduled time has passed, check the log:

```bash
tail -50 /var/log/cloudflare-ufw-sync.log
```

---

## Log File & Rotation

The script logs all activity to `/var/log/cloudflare-ufw-sync.log` with full timestamps. Every run appends to the same file.

### Set up log rotation

Create `/etc/logrotate.d/cloudflare-ufw-sync`:

```bash
nano /etc/logrotate.d/cloudflare-ufw-sync
```

Paste:

```
/var/log/cloudflare-ufw-sync.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
```

This keeps 8 weeks of compressed logs and automatically manages file size.

Test your logrotate config:

```bash
logrotate --debug /etc/logrotate.d/cloudflare-ufw-sync
```

---

## Verifying the Rules

### View all active UFW rules

```bash
ufw status verbose
```

### Filter to see only Cloudflare rules

```bash
ufw status | grep Cloudflare
```

### View the state file

```bash
cat /etc/cloudflare-ufw.state
```

This file lists every CIDR currently added by the script and is read on the next run to cleanly remove old rules.

### Count active Cloudflare rules

```bash
ufw status | grep -c Cloudflare
```

---

## Uninstalling

To remove all Cloudflare UFW rules added by this script:

```bash
# Remove all rules listed in the state file
while IFS= read -r ip; do
  ufw delete allow proto tcp from "$ip" to any port 80,443
done < /etc/cloudflare-ufw.state

# Remove state and log files
rm -f /etc/cloudflare-ufw.state
rm -f /var/log/cloudflare-ufw-sync.log
rm -f /etc/logrotate.d/cloudflare-ufw-sync
```

Then remove the cron entry:

```bash
crontab -e   # Delete the cloudflare-ufw-sync line
```

---

## Troubleshooting

### Script exits with "Failed to download IPv4 ranges"

- Check outbound internet access: `curl -v https://www.cloudflare.com/ips-v4`
- Check DNS resolution: `dig www.cloudflare.com`
- Verify your server is not firewalling its own outbound HTTPS traffic

### "Must run as root" error

```bash
sudo bash cloudflare-ufw-sync.sh
```

### IPv6 rules not being added

Check `/etc/default/ufw` — the line `IPV6=yes` must be present and uncommented. After changing it:

```bash
ufw disable && ufw enable
sudo ./cloudflare-ufw-sync.sh
```

### Rules are accumulating (duplicates from a previous version)

If you previously ran an older version of this script before the state file approach was added, you may have legacy duplicate rules. Clear them manually:

```bash
# View all rules with numbers
ufw status numbered

# Delete by number — work from the highest number down to avoid index shifting
ufw --force delete <NUMBER>
```

Then run `cloudflare-ufw-sync.sh` fresh — it will build a clean state file.

### Checking the log for errors

```bash
grep -i error /var/log/cloudflare-ufw-sync.log
grep -i warn  /var/log/cloudflare-ufw-sync.log
```

---

## Security Considerations

**This script only allows Cloudflare IPs on ports 80 and 443.** Ensure the following:

- Your **SSH port** has an allow rule independent of this script. SSH must remain accessible from your management IP regardless of what this script does.
- Cloudflare's IP list is fetched over **HTTPS** with certificate validation enforced (`curl -sSf`). A compromised HTTP response or captive portal redirect cannot inject rules.
- The validation step ensures no non-CIDR content (HTML error pages, truncated responses) is ever passed to `ufw allow`.
- The state file at `/etc/cloudflare-ufw.state` is the authoritative record of what this script added. Do not edit it manually.
- UFW rules added by this script are tagged with the comment `Cloudflare` for easy identification and auditing.
- `ufw reload` is intentionally absent — individual rule changes apply immediately and a reload would unnecessarily flush chains, risking brief connection drops.

---

## How It Compares to Other Approaches

| Approach | Idempotent | Validated | Logged | Auto-cleanup | No reload risk |
|---|---|---|---|---|---|
| **This script** | ✅ | ✅ | ✅ | ✅ state file | ✅ |
| Original clusterednetworks version | ❌ accumulates | ❌ | ❌ | ❌ | ❌ reloads |
| Nginx `geo` module | ✅ | ✅ | partial | ✅ | N/A |
| Cloudflare Tunnel (cloudflared) | ✅ | ✅ | ✅ | ✅ | N/A |
| Manual static rules | ❌ | ❌ | ❌ | ❌ | — |

**Cloudflare Tunnel** (`cloudflared`) is the most secure long-term option as it eliminates the need for any open inbound ports. This script is the right choice when you need to keep standard HTTP/HTTPS ports open — for example, for SSL termination at the origin, legacy applications, or servers that handle non-Cloudflare traffic on the same interface.

---

## License

This project is licensed under the **GNU General Public License v2.0 or later**.  
Original script structure by [clusterednetworks.com](https://clusterednetworks.com).  
Hardened and maintained in this repository.

See [LICENSE](./LICENSE) for full terms.

---

*Keywords: cloudflare ufw sync, ubuntu firewall cloudflare ips, restrict origin server cloudflare, ufw allow cloudflare ip ranges, cloudflare ip whitelist linux, debian ufw cloudflare automation, protect origin server behind cloudflare, cloudflare firewall rules linux, ufw cloudflare cron, origin server protection ubuntu*
