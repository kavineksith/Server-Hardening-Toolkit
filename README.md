# 🔐 Server Hardening Toolkit

A professional, fully automated server hardening script built with a DRY function-library architecture. Every hardening module is independent, idempotent, and safe to re-run — with full dry-run support so you can audit every action before it executes.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [CLI Options](#cli-options)
- [What It Does](#what-it-does)
- [Architecture](#architecture)
- [Function Library Reference](#function-library-reference)
- [File Locations](#file-locations)
- [Connecting After Hardening](#connecting-after-hardening)
- [Diagnostic Commands](#diagnostic-commands)
- [Backups & Recovery](#backups--recovery)
- [Customisation](#customisation)
- [Security Notes](#security-notes)

---

## Features

| Category | What's Applied |
|---|---|
| **SSH** | Drop-in config, modern ciphers only, key-auth only, rate limiting |
| **Firewall** | UFW with default-deny, anti-spoofing rules, SYN/NULL/XMAS drop |
| **Fail2Ban** | SSH + DDoS jails with 24h bans |
| **Kernel** | sysctl hardening — ASLR, SYN cookies, redirect/spoofing blocks |
| **PAM** | 14-char password minimum, complexity rules, 90-day expiry |
| **Auditd** | Logs root commands, identity file changes, unauthorised access |
| **AIDE** | File integrity database with weekly cron check |
| **Port Knocking** | knockd with per-IP iptables rules |
| **Auto-Updates** | Unattended security patches via APT |
| **Attack Surface** | Disables 10+ unused services and 11 risky kernel modules |
| **MOTD** | Legal warning banner; dynamic MOTD info-leak suppressed |

---

## Requirements

- **OS:** Ubuntu 20.04 / 22.04 / 24.04 or Debian 11 / 12
- **Access:** Root or `sudo` privileges
- **Network:** Outbound internet access to install packages
- **SSH Key:** A public key already in `~/.ssh/authorized_keys` for your user before running — the script disables password authentication

> ⚠️ **Run on a fresh server or a snapshot.** Always test with `--dry-run` first on production systems.

---

## Quick Start

```bash
# 1. Download the script
curl -O https://your-repo/harden.sh
chmod +x harden.sh

# 2. Dry-run first — no changes made, all actions printed
sudo ./harden.sh --dry-run

# 3. Run with defaults (SSH port 2222, current user, knock 7000,8000,9000)
sudo ./harden.sh

# 4. Or fully customise
sudo ./harden.sh --user deploy --port 2244 --knock 5100,6200,7300
```

---

## CLI Options

| Flag | Argument | Default | Description |
|---|---|---|---|
| `-u`, `--user` | `USER` | current user | The only user allowed to SSH in |
| `-p`, `--port` | `PORT` | `2222` | SSH listening port (1–65535) |
| `-k`, `--knock` | `SEQ` | `7000,8000,9000` | Port-knock sequence, comma-separated, min 3 ports |
| `-d`, `--dry-run` | — | off | Print every action without executing anything |
| `-s`, `--skip-reboot` | — | off | Suppress the reboot prompt at the end |
| `-v`, `--verbose` | — | off | Log every individual command as it runs |
| `-h`, `--help` | — | — | Print usage and exit |

### Examples

```bash
# Custom user, port, and knock sequence
sudo ./harden.sh --user deploy --port 2244 --knock 5100,6200,7300

# Dry-run with verbose output to review every sysctl, rule, and config write
sudo ./harden.sh --dry-run --verbose

# Non-interactive run in CI/CD (skip reboot prompt)
sudo ./harden.sh --user ci --port 2222 --skip-reboot
```

---

## What It Does

### 1 · SSH Hardening
Writes a drop-in config to `/etc/ssh/sshd_config.d/99-hardened.conf` so the main `sshd_config` is never overwritten. Validates config with `sshd -t` before restarting — you cannot be locked out by a syntax error.

Applied settings:
- Public-key authentication only (`PasswordAuthentication no`)
- Root login disabled
- Only your specified user allowed (`AllowUsers`)
- Modern cipher suite: `chacha20-poly1305`, `aes256-gcm`, `aes256-ctr`
- Weak key exchange algorithms removed
- Legal warning banner at `/etc/ssh/banner`

### 2 · Firewall (UFW)
Full reset to default-deny, then minimal allow-list:

```
ALLOW  <SSH_PORT>/tcp    (with rate limiting)
ALLOW  80/tcp
ALLOW  443/tcp
DROP   INVALID, NULL, XMAS, SYN-RST packets
```

### 3 · Fail2Ban
Two SSH jails:

| Jail | Max Retries | Find Window | Ban Duration |
|---|---|---|---|
| `sshd` | 3 | 10 min | 24 hours |
| `sshd-ddos` | 10 | 30 sec | 24 hours |

### 4 · Kernel Hardening (sysctl)
All settings written to `/etc/sysctl.d/99-hardened.conf` in labelled groups:

- **Reverse-path filtering** — blocks IP spoofing
- **ICMP redirect blocking** — prevents routing attacks
- **SYN flood protection** — TCP SYN cookies enabled
- **Martian logging** — logs packets with impossible source addresses
- **ASLR** — `kernel.randomize_va_space = 2`
- **dmesg / kptr restriction** — hides kernel pointers from users
- **Filesystem** — protects hard/symlinks, disables SUID core dumps

### 5 · PAM / Password Policy

| Setting | Value |
|---|---|
| Minimum length | 14 characters |
| Required: digit, upper, lower, special | 1 each |
| Max consecutive repeats | 3 |
| Password max age | 90 days |
| Password min age | 1 day |
| Expiry warning | 14 days before |

### 6 · Auditd
Audit rules written to `/etc/audit/rules.d/99-hardened.rules`:

- All writes to `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`
- All writes to `/etc/ssh/sshd_config`
- All writes to `/etc/hosts` and network config
- Execution of `insmod`, `rmmod`, `modprobe`
- Unauthorised file access (`EACCES`, `EPERM`)
- All commands run as root (`execve` by euid=0)

### 7 · AIDE (File Integrity Monitoring)
Initialises a baseline database of the filesystem. A weekly cron job at `/etc/cron.weekly/aide-check` runs `aide --check` and mails the report to root.

### 8 · Port Knocking
SSH port is blocked by default. You must knock the sequence before connecting:

```bash
# Open SSH access from your IP
knock <SERVER_IP> 7000 8000 9000

# Connect
ssh -p 2222 user@<SERVER_IP>

# Close SSH access again
knock <SERVER_IP> 9000 8000 7000
```

Rules are per-IP (`%IP%`), so knocking only unblocks your source address.

### 9 · Disabled Services

```
avahi-daemon   cups             isc-dhcp-server
isc-dhcp-server6  nfs-server    rpcbind
rsync          snmpd            telnet
vsftpd
```

### 10 · Disabled Kernel Modules

```
dccp    sctp    rds     tipc
cramfs  freevxfs jffs2  hfs
hfsplus squashfs udf
```

---

## Architecture

The script is structured in 16 sections. Sections 2–11 are a **pure function library**. Section 14 contains the **hardening modules** that call the library. Section 16 is the **main pipeline**.

```
harden.sh
├── Section 1   Global constants & defaults
├── Section 2   Logging library          (_log, log_ok, log_warn ...)
├── Section 3   Execution engine         (run, run_quiet)
├── Section 4   File & backup library    (write_file, append_file, backup_file ...)
├── Section 5   Package library          (pkg_install, pkg_installed)
├── Section 6   Systemd library          (svc_enable_restart, svc_stop_disable)
├── Section 7   Sysctl library           (sysctl_set, sysctl_apply_group)
├── Section 8   Firewall library         (ufw_allow, ufw_limit)
├── Section 9   Audit rule library       (audit_watch, audit_syscall)
├── Section 10  Kernel module library    (module_disable)
├── Section 11  Validation library       (validate_port, validate_user ...)
├── Section 12  Argument parsing
├── Section 13  Pre-flight checks
├── Section 14  Hardening modules        (one function per concern)
├── Section 15  Final report
└── Section 16  Main pipeline
```

---

## Function Library Reference

### Execution
| Function | Signature | Description |
|---|---|---|
| `run` | `run CMD [ARGS...]` | Executes command; in dry-run mode, prints instead |
| `run_quiet` | `run_quiet CMD` | Like `run` but suppresses stderr |

### File & Backup
| Function | Signature | Description |
|---|---|---|
| `backup_file` | `backup_file FILE` | Copies file to `$BACKUP_DIR`, preserving path |
| `write_file` | `write_file DEST CONTENT` | Backs up then writes content atomically |
| `append_file` | `append_file DEST MARKER CONTENT` | Appends only if MARKER not already present (idempotent) |
| `set_file_perms` | `set_file_perms FILE OCTAL [OWNER]` | chmod + optional chown |
| `sed_replace` | `sed_replace PATTERN REPLACEMENT FILE` | Backs up then runs sed in-place |

### Packages
| Function | Signature | Description |
|---|---|---|
| `pkg_installed` | `pkg_installed PKG` | Returns true if package is already installed |
| `pkg_install` | `pkg_install PKG [PKG...]` | Installs only packages not already present |

### Systemd
| Function | Signature | Description |
|---|---|---|
| `svc_enable_restart` | `svc_enable_restart SERVICE` | `systemctl enable` + `systemctl restart` |
| `svc_stop_disable` | `svc_stop_disable SERVICE` | Stops and disables; silently skips if not installed |

### Sysctl
| Function | Signature | Description |
|---|---|---|
| `sysctl_set` | `sysctl_set KEY VALUE` | Idempotent: updates if key exists, appends if not |
| `sysctl_apply_group` | `sysctl_apply_group COMMENT KEY=VALUE...` | Writes a labelled group of sysctl settings |

### Audit
| Function | Signature | Description |
|---|---|---|
| `audit_watch` | `audit_watch PATH PERMS KEY` | Appends a `-w` watch rule (idempotent) |
| `audit_syscall` | `audit_syscall ARCH SYSCALLS EXIT_CODE KEY` | Appends an `-a always,exit` syscall rule |

### Kernel Modules
| Function | Signature | Description |
|---|---|---|
| `module_disable` | `module_disable MOD [MOD...]` | Blacklists and prevents loading via modprobe |

---

## File Locations

| Path | Purpose |
|---|---|
| `/etc/ssh/sshd_config.d/99-hardened.conf` | SSH drop-in config |
| `/etc/ssh/banner` | Legal warning banner |
| `/etc/sysctl.d/99-hardened.conf` | Kernel parameter hardening |
| `/etc/fail2ban/jail.local` | Fail2Ban SSH jails |
| `/etc/audit/rules.d/99-hardened.rules` | Auditd rules |
| `/etc/modprobe.d/99-harden-disable.conf` | Blacklisted kernel modules |
| `/etc/security/pwquality.conf` | PAM password quality |
| `/etc/knockd.conf` | Port knocking sequences |
| `/etc/cron.weekly/aide-check` | Weekly AIDE integrity check |
| `/var/lib/aide/aide.db` | AIDE baseline database |
| `/var/log/harden_<TIMESTAMP>.log` | Full execution log |
| `/root/harden_backups/<TIMESTAMP>/` | All original files backed up |

---

## Connecting After Hardening

```bash
# Step 1 — knock to open SSH for your IP
knock <SERVER_IP> 7000 8000 9000

# Step 2 — connect on the custom SSH port
ssh -p 2222 -i ~/.ssh/id_rsa user@<SERVER_IP>

# Step 3 — optionally close SSH access again
knock <SERVER_IP> 9000 8000 7000
```

Install `knockd` client locally:
```bash
# Ubuntu/Debian
sudo apt install knockd

# macOS
brew install knock
```

---

## Diagnostic Commands

```bash
# Fail2Ban — check active bans and jail status
fail2ban-client status sshd
fail2ban-client status sshd-ddos

# UFW — view all firewall rules
ufw status verbose

# Auditd — list loaded rules / search logs
auditctl -l
ausearch -k identity
ausearch -k root_commands

# AIDE — run manual integrity check
aide --check

# SSH — live log stream
journalctl -u ssh -f

# Sysctl — verify a setting
sysctl kernel.randomize_va_space
sysctl -a | grep rp_filter

# Kernel modules — verify disabled
lsmod | grep dccp       # should return nothing
cat /etc/modprobe.d/99-harden-disable.conf
```

---

## Backups & Recovery

Every file modified by the script is backed up **before** any change is made:

```
/root/harden_backups/
└── 20240115_143022/
    └── etc/
        ├── ssh/sshd_config
        ├── fail2ban/jail.local
        ├── login.defs
        └── security/pwquality.conf
```

To restore a single file:
```bash
cp /root/harden_backups/<TIMESTAMP>/etc/ssh/sshd_config /etc/ssh/sshd_config
systemctl restart ssh
```

---

## Customisation

### Skip a hardening module
Comment out any line in the `main()` pipeline in Section 16:

```bash
main() {
    ...
    install_packages
    harden_ssh
    configure_firewall
    configure_fail2ban
    harden_kernel
    # harden_pam          # ← skip PAM changes
    configure_auditd
    # configure_aide      # ← skip AIDE (slow on large disks)
    ...
}
```

### Add a custom sysctl setting
```bash
sysctl_set "net.ipv4.tcp_rfc1337" "1"
```

### Watch an additional file with auditd
```bash
audit_watch /etc/myapp/config.yml wa myapp_config
```

### Disable an additional kernel module
```bash
module_disable bluetooth usb_storage
```

### Add a firewall rule
```bash
ufw_allow "8443/tcp" "Custom HTTPS"
```

---

## Security Notes

- **Password auth is disabled.** Ensure your SSH public key is in `~/.ssh/authorized_keys` before running, or you will lose access.
- **Port knocking is a layered control**, not a replacement for key-based auth or a firewall. It reduces automated scan noise significantly.
- **AIDE initialisation** takes time on large filesystems and should be re-baselined after every intentional system change with `aide --init`.
- **sysctl `ip_forward = 0`** will break Docker networking. If you use Docker, re-enable it: `sysctl_set "net.ipv4.ip_forward" "1"` or set it after the fact.
- **CIS Benchmark** alignment covers Level 1 (standard) and parts of Level 2 (defence-in-depth). A full Level 2 audit may require additional manual steps specific to your workload.
