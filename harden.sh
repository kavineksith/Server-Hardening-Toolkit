#!/usr/bin/env bash
# ============================================================
#  SERVER HARDENING TOOLKIT
#  CIS Benchmark Level 1/2 aligned | Ubuntu / Debian
#  Architecture: DRY function-library design
# ============================================================
#
#  Usage:
#    sudo ./harden.sh [OPTIONS]
#
#  Options:
#    -u, --user  USER   SSH allow-user     (default: current user)
#    -p, --port  PORT   SSH port           (default: 2222)
#    -k, --knock SEQ    Knock sequence     (default: 7000,8000,9000)
#    -d, --dry-run      Print without executing
#    -s, --skip-reboot  Skip reboot prompt
#    -v, --verbose      Show every command
#    -h, --help         Show this help
#
#  Example:
#    sudo ./harden.sh --user deploy --port 2244 --knock 5100,6200,7300
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 1 — GLOBAL CONSTANTS & DEFAULTS                     ║
# ╚══════════════════════════════════════════════════════════════╝

readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="/var/log/harden_${TIMESTAMP}.log"
readonly BACKUP_DIR="/root/harden_backups/${TIMESTAMP}"
readonly MODPROBE_CONF="/etc/modprobe.d/99-harden-disable.conf"
readonly SYSCTL_CONF="/etc/sysctl.d/99-hardened.conf"
readonly SSHD_DROP_IN="/etc/ssh/sshd_config.d/99-hardened.conf"
readonly AUDIT_RULES="/etc/audit/rules.d/99-hardened.rules"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

# Defaults (overridden by CLI flags)
SSH_PORT=2222
SSH_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
KNOCK_SEQ="7000,8000,9000"
DRY_RUN=false
SKIP_REBOOT=false
VERBOSE=false

# Runtime state
declare -i STEPS_OK=0
declare -i STEPS_WARN=0
declare -a SUMMARY_NOTES=()

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 2 — LOGGING LIBRARY                                 ║
# ╚══════════════════════════════════════════════════════════════╝

RED='\033[0;31m';    YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m';   BOLD='\033[1m';      DIM='\033[2m'
MAGENTA='\033[0;35m'; RESET='\033[0m'

# _log LEVEL COLOUR MESSAGE...
_log() {
    local level="$1" colour="$2"; shift 2
    printf "${colour}[%-7s]${RESET} ${DIM}%s${RESET}  %s\n" \
        "$level" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_info()    { _log "INFO"    "$CYAN"    "$@"; }
log_ok()      { _log "OK"      "$GREEN"   "$@"; (( STEPS_OK++   )); }
log_warn()    { _log "WARN"    "$YELLOW"  "$@"; (( STEPS_WARN++ )); SUMMARY_NOTES+=("$*"); }
log_error()   { _log "ERROR"   "$RED"     "$@"; }
log_verbose() { [[ "$VERBOSE" == true ]] && _log "VERBOSE" "$DIM" "$@" || true; }
log_step()    { echo -e "\n${BOLD}${MAGENTA}>>  $*${RESET}\n" | tee -a "$LOG_FILE"; }
die()         { log_error "$*"; exit 1; }

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 3 — EXECUTION ENGINE                                ║
# ╚══════════════════════════════════════════════════════════════╝

# run CMD [ARGS...]  -- executes or prints in dry-run mode
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} $*" | tee -a "$LOG_FILE"
        return 0
    fi
    log_verbose "EXEC: $*"
    "$@" >> "$LOG_FILE" 2>&1
}

run_quiet() { run "$@" 2>/dev/null || true; }

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 4 — FILE & BACKUP LIBRARY                           ║
# ╚══════════════════════════════════════════════════════════════╝

# backup_file FILE -- copies to timestamped backup dir, preserving path
backup_file() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    local dest="${BACKUP_DIR}${src}"
    run mkdir -p "$(dirname "$dest")"
    run cp -p "$src" "$dest"
    log_verbose "Backed up: $src -> $dest"
}

# write_file DEST CONTENT -- backs up then atomically writes content
write_file() {
    local dest="$1" content="$2"
    backup_file "$dest"
    run mkdir -p "$(dirname "$dest")"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} write_file -> $dest" | tee -a "$LOG_FILE"
    else
        printf '%s\n' "$content" > "$dest"
        log_verbose "Written: $dest"
    fi
}

# append_file DEST MARKER CONTENT -- appends only if marker not already present
append_file() {
    local dest="$1" marker="$2" content="$3"
    grep -qF "$marker" "$dest" 2>/dev/null && {
        log_verbose "append_file: marker already in $dest, skipping"
        return 0
    }
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[DRY-RUN]${RESET} append_file -> $dest" | tee -a "$LOG_FILE"
    else
        printf '\n%s\n' "$content" >> "$dest"
        log_verbose "Appended to: $dest"
    fi
}

# set_file_perms FILE OCTAL [OWNER]
set_file_perms() {
    local file="$1" mode="$2" owner="${3:-}"
    run chmod "$mode" "$file"
    [[ -n "$owner" ]] && run chown "$owner" "$file"
    log_verbose "Perms set: $file -> $mode ${owner:+($owner)}"
}

# sed_replace PATTERN REPLACEMENT FILE
sed_replace() {
    local pattern="$1" replacement="$2" file="$3"
    backup_file "$file"
    run sed -i "s|${pattern}|${replacement}|" "$file"
    log_verbose "sed_replace in $file: $pattern -> $replacement"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 5 — PACKAGE LIBRARY                                 ║
# ╚══════════════════════════════════════════════════════════════╝

pkg_installed() { dpkg -s "$1" &>/dev/null; }

# pkg_install PKG [PKG...] -- skips already-installed packages
pkg_install() {
    local -a to_install=()
    for pkg in "$@"; do
        pkg_installed "$pkg" \
            && { log_verbose "Already installed: $pkg"; continue; }
        to_install+=("$pkg")
    done
    [[ ${#to_install[@]} -eq 0 ]] && return 0
    log_info "Installing: ${to_install[*]}"
    run apt-get install -y --no-install-recommends "${to_install[@]}"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 6 — SYSTEMD SERVICE LIBRARY                         ║
# ╚══════════════════════════════════════════════════════════════╝

svc_enable_restart() {
    local svc="$1"
    run systemctl enable "$svc"
    run systemctl restart "$svc"
    log_ok "Service enabled & restarted: $svc"
}

# svc_stop_disable SERVICE -- silently skips if not installed
svc_stop_disable() {
    local svc="$1"
    systemctl list-unit-files --quiet "${svc}.service" &>/dev/null || return 0
    run_quiet systemctl stop    "$svc"
    run_quiet systemctl disable "$svc"
    log_info "Disabled: $svc"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 7 — SYSCTL LIBRARY                                  ║
# ╚══════════════════════════════════════════════════════════════╝

# sysctl_set KEY VALUE -- idempotent: updates if key exists, appends if not
sysctl_set() {
    local key="$1" value="$2"
    if grep -qE "^${key}\s*=" "$SYSCTL_CONF" 2>/dev/null; then
        run sed -i "s|^${key}.*|${key} = ${value}|" "$SYSCTL_CONF"
    else
        printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_CONF"
    fi
    log_verbose "sysctl: $key = $value"
}

# sysctl_apply_group COMMENT KEY=VALUE [KEY=VALUE...]
sysctl_apply_group() {
    local group_comment="$1"; shift
    printf '\n# -- %s --\n' "$group_comment" >> "$SYSCTL_CONF"
    for pair in "$@"; do
        sysctl_set "${pair%%=*}" "${pair#*=}"
    done
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 8 — FIREWALL LIBRARY                                ║
# ╚══════════════════════════════════════════════════════════════╝

ufw_allow() { run ufw allow "$1" comment "${2:-}"; log_verbose "UFW allow: $1"; }
ufw_limit() { run ufw limit "$1" comment "${2:-}"; log_verbose "UFW limit: $1"; }

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 9 — AUDIT RULE LIBRARY                              ║
# ╚══════════════════════════════════════════════════════════════╝

# audit_watch PATH PERMISSIONS KEY
audit_watch() {
    append_file "$AUDIT_RULES" "-w ${1} -p ${2}" \
        "-w ${1} -p ${2} -k ${3}"
}

# audit_syscall ARCH SYSCALLS EXIT_CODE KEY
audit_syscall() {
    local rule="-a always,exit -F arch=${1} -S ${2} -F exit=-${3} -k ${4}"
    append_file "$AUDIT_RULES" "-S ${2} -F exit=-${3}" "$rule"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 10 — KERNEL MODULE LIBRARY                          ║
# ╚══════════════════════════════════════════════════════════════╝

# module_disable MOD [MOD...] -- blacklists and prevents loading
module_disable() {
    for mod in "$@"; do
        if ! grep -qr "install ${mod}" /etc/modprobe.d/ 2>/dev/null; then
            printf 'install %s /bin/true\nblacklist %s\n' "$mod" "$mod" \
                >> "$MODPROBE_CONF"
            log_info "Kernel module disabled: $mod"
        fi
    done
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 11 — VALIDATION LIBRARY                             ║
# ╚══════════════════════════════════════════════════════════════╝

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]]           || die "Port must be numeric: '$1'"
    (( $1 >= 1 && $1 <= 65535 ))     || die "Port out of range: $1"
}

validate_user() {
    id "$1" &>/dev/null || die "User '$1' does not exist"
}

confirm_or_abort() {
    read -r -p "  ${YELLOW}?${RESET} $1 [y/N] " ans
    [[ "${ans,,}" == "y" ]] || die "Aborted by user."
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 12 — ARGUMENT PARSING                               ║
# ╚══════════════════════════════════════════════════════════════╝

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user)         SSH_USER="$2";    shift 2 ;;
            -p|--port)         SSH_PORT="$2";    shift 2 ;;
            -k|--knock)        KNOCK_SEQ="$2";   shift 2 ;;
            -d|--dry-run)      DRY_RUN=true;     shift   ;;
            -s|--skip-reboot)  SKIP_REBOOT=true; shift   ;;
            -v|--verbose)      VERBOSE=true;     shift   ;;
            -h|--help)         grep '^#  ' "$0" | sed 's/^#  //'; exit 0 ;;
            *) die "Unknown option: $1  (use --help)" ;;
        esac
    done

    validate_port "$SSH_PORT"
    validate_user "$SSH_USER"

    IFS=',' read -ra KNOCK_PORTS <<< "$KNOCK_SEQ"
    [[ ${#KNOCK_PORTS[@]} -ge 3 ]] || die "Knock sequence needs >= 3 ports"
    for kp in "${KNOCK_PORTS[@]}"; do validate_port "$kp"; done
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 13 — PRE-FLIGHT                                     ║
# ╚══════════════════════════════════════════════════════════════╝

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./$SCRIPT_NAME"
}

detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release not found"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "Unsupported OS: ${ID:-unknown}" ;;
    esac
    log_ok "OS: $PRETTY_NAME"
}

check_ssh_keys() {
    local home; home="$(eval echo "~$SSH_USER")"
    local auth_keys="${home}/.ssh/authorized_keys"
    if [[ ! -s "$auth_keys" ]]; then
        log_warn "No authorized_keys for '$SSH_USER' — password auth will be disabled!"
        confirm_or_abort "Continue anyway?"
        SUMMARY_NOTES+=("Add SSH public key for '$SSH_USER' or you will be locked out")
    fi
}

preflight() {
    log_step "Pre-flight Checks"
    require_root
    detect_os
    check_ssh_keys
    run mkdir -p "$BACKUP_DIR"
    run mkdir -p "$(dirname "$LOG_FILE")"
    echo "harden.sh v${SCRIPT_VERSION} started $(date)" > "$LOG_FILE"
    log_ok "Backup dir : $BACKUP_DIR"
    log_ok "Log file   : $LOG_FILE"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 14 — HARDENING MODULES                              ║
# ╚══════════════════════════════════════════════════════════════╝

install_packages() {
    log_step "Installing Required Packages"
    run apt-get update -qq
    pkg_install \
        openssh-server fail2ban ufw aide knockd \
        unattended-upgrades apt-listchanges \
        auditd audispd-plugins libpam-pwquality \
        curl gnupg net-tools lsof
    log_ok "All packages ready"
}

harden_ssh() {
    log_step "SSH Hardening"

    run mkdir -p /etc/ssh/sshd_config.d
    append_file /etc/ssh/sshd_config \
        "sshd_config.d" \
        "Include /etc/ssh/sshd_config.d/*.conf"

    write_file "$SSHD_DROP_IN" "# Managed by harden.sh ${TIMESTAMP}
Port                        ${SSH_PORT}
AddressFamily               inet
PermitRootLogin             no
PasswordAuthentication      no
PermitEmptyPasswords        no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods       publickey
PubkeyAuthentication        yes
AuthorizedKeysFile          .ssh/authorized_keys
AllowUsers                  ${SSH_USER}
MaxAuthTries                3
MaxSessions                 5
LoginGraceTime              30
ClientAliveInterval         300
ClientAliveCountMax         2
TCPKeepAlive                no
X11Forwarding               no
AllowTcpForwarding          no
AllowAgentForwarding        no
GatewayPorts                no
PermitTunnel                no
PermitUserEnvironment       no
Banner                      /etc/ssh/banner
PrintLastLog                yes
LogLevel                    VERBOSE
SyslogFacility              AUTH
Ciphers                     chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
MACs                        hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms               curve25519-sha256,diffie-hellman-group16-sha512"

    write_file /etc/ssh/banner \
"*******************************************************************
  Authorised access only. All activity is logged and monitored.
  Disconnect immediately if you are not an authorised user.
*******************************************************************"

    run sshd -t || die "sshd config validation failed"
    svc_enable_restart ssh
    log_ok "SSH hardened on port ${SSH_PORT}"
}

configure_firewall() {
    log_step "Firewall (UFW)"

    run ufw --force reset
    run ufw default deny  incoming
    run ufw default allow outgoing
    run ufw default deny  forward

    ufw_allow "${SSH_PORT}/tcp" "SSH hardened"
    ufw_allow "80/tcp"          "HTTP"
    ufw_allow "443/tcp"         "HTTPS"
    ufw_limit "${SSH_PORT}/tcp" "SSH rate-limit"

    append_file /etc/ufw/before.rules "harden.sh: drop invalid" \
"# harden.sh: drop crafted/invalid packets
-A ufw-before-input -m conntrack --ctstate INVALID      -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL NONE         -j DROP
-A ufw-before-input -p tcp --tcp-flags ALL ALL          -j DROP
-A ufw-before-input -p tcp --tcp-flags SYN,RST SYN,RST  -j DROP"

    run ufw --force enable
    log_ok "UFW enabled with hardened ruleset"
}

configure_fail2ban() {
    log_step "Fail2Ban"

    write_file "$FAIL2BAN_JAIL" "[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw
ignoreip  = 127.0.0.1/8

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 24h

[sshd-ddos]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 10
findtime = 30s
bantime  = 24h"

    svc_enable_restart fail2ban
    log_ok "Fail2Ban active (SSH jails enabled)"
}

harden_kernel() {
    log_step "Kernel Hardening (sysctl)"

    run mkdir -p "$(dirname "$SYSCTL_CONF")"
    [[ -f "$SYSCTL_CONF" ]] || printf '# harden.sh %s\n' "$TIMESTAMP" > "$SYSCTL_CONF"

    sysctl_apply_group "Reverse-path / source-route filtering" \
        "net.ipv4.conf.all.rp_filter=1" \
        "net.ipv4.conf.default.rp_filter=1" \
        "net.ipv4.conf.all.accept_source_route=0" \
        "net.ipv4.conf.default.accept_source_route=0" \
        "net.ipv6.conf.all.accept_source_route=0"

    sysctl_apply_group "ICMP redirects" \
        "net.ipv4.conf.all.accept_redirects=0" \
        "net.ipv4.conf.default.accept_redirects=0" \
        "net.ipv4.conf.all.secure_redirects=0" \
        "net.ipv6.conf.all.accept_redirects=0" \
        "net.ipv4.conf.all.send_redirects=0" \
        "net.ipv4.conf.default.send_redirects=0"

    sysctl_apply_group "SYN-flood protection" \
        "net.ipv4.tcp_syncookies=1" \
        "net.ipv4.tcp_max_syn_backlog=2048" \
        "net.ipv4.tcp_synack_retries=2" \
        "net.ipv4.tcp_syn_retries=5"

    sysctl_apply_group "ICMP and martian logging" \
        "net.ipv4.icmp_echo_ignore_broadcasts=1" \
        "net.ipv4.icmp_ignore_bogus_error_responses=1" \
        "net.ipv4.conf.all.log_martians=1" \
        "net.ipv4.conf.default.log_martians=1"

    sysctl_apply_group "IP forwarding (disabled)" \
        "net.ipv4.ip_forward=0" \
        "net.ipv6.conf.all.forwarding=0"

    sysctl_apply_group "Kernel exploit mitigations" \
        "kernel.randomize_va_space=2" \
        "kernel.dmesg_restrict=1" \
        "kernel.kptr_restrict=2" \
        "kernel.yama.ptrace_scope=1" \
        "kernel.perf_event_paranoid=3"

    sysctl_apply_group "Filesystem hardening" \
        "fs.protected_hardlinks=1" \
        "fs.protected_symlinks=1" \
        "fs.suid_dumpable=0"

    run sysctl --system
    log_ok "Kernel parameters applied from $SYSCTL_CONF"
}

harden_pam() {
    log_step "PAM / Password Policy"

    write_file /etc/security/pwquality.conf "minlen    = 14
dcredit   = -1
ucredit   = -1
lcredit   = -1
ocredit   = -1
maxrepeat = 3
gecoscheck = 1
dictcheck  = 1
usercheck  = 1
enforcing  = 1"

    sed_replace "^PASS_MAX_DAYS.*" "PASS_MAX_DAYS   90" /etc/login.defs
    sed_replace "^PASS_MIN_DAYS.*" "PASS_MIN_DAYS   1"  /etc/login.defs
    sed_replace "^PASS_WARN_AGE.*" "PASS_WARN_AGE   14" /etc/login.defs

    log_ok "Password policy hardened (14-char min, 90-day expiry)"
}

configure_auditd() {
    log_step "Audit Daemon (auditd)"

    run mkdir -p "$(dirname "$AUDIT_RULES")"
    write_file "$AUDIT_RULES" "-D
-b 8192
-f 1"

    # Identity & auth files
    audit_watch /etc/group       wa identity
    audit_watch /etc/passwd      wa identity
    audit_watch /etc/shadow      wa identity
    audit_watch /etc/sudoers     wa identity
    audit_watch /etc/sudoers.d/  wa identity
    audit_watch /etc/ssh/sshd_config wa sshd_config
    audit_watch /etc/hosts       wa system-locale
    audit_watch /etc/network/    wa system-locale
    audit_watch /sbin/insmod     x  modules
    audit_watch /sbin/rmmod      x  modules
    audit_watch /sbin/modprobe   x  modules

    # Syscall rules
    audit_syscall b64 "open,creat,truncate,ftruncate,openat" EACCES access
    audit_syscall b64 "open,creat,truncate,ftruncate,openat" EPERM  access
    audit_syscall b64 execve                                  EACCES root_commands

    svc_enable_restart auditd
    log_ok "auditd configured with $(grep -c '^-[wWa]' "$AUDIT_RULES") rules"
}

configure_aide() {
    log_step "AIDE (File Integrity Monitoring)"

    log_info "Initialising AIDE database - this may take a few minutes..."
    run aideinit --yes
    run mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

    write_file /etc/cron.weekly/aide-check \
'#!/usr/bin/env bash
/usr/bin/aide --check | mail -s "AIDE Report: $(hostname)" root'

    set_file_perms /etc/cron.weekly/aide-check 0750 root:root
    log_ok "AIDE database initialised; weekly check scheduled"
}

configure_auto_updates() {
    log_step "Unattended Security Updates"

    write_file /etc/apt/apt.conf.d/20auto-upgrades \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade   "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval    "7";'

    run dpkg-reconfigure -f noninteractive unattended-upgrades
    log_ok "Unattended security upgrades enabled"
}

configure_port_knocking() {
    log_step "Port Knocking (knockd)"

    local close_seq
    close_seq="$(echo "$KNOCK_SEQ" | tr ',' '\n' | tac | paste -sd ',')"

    sed_replace "^START_KNOCKD=0" "START_KNOCKD=1" /etc/default/knockd

    write_file /etc/knockd.conf "[options]
    UseSyslog

[openSSH]
    sequence    = ${KNOCK_SEQ}
    seq_timeout = 10
    tcpflags    = syn
    command     = /sbin/iptables -A INPUT -s %IP% -p tcp --dport ${SSH_PORT} -j ACCEPT

[closeSSH]
    sequence    = ${close_seq}
    seq_timeout = 10
    tcpflags    = syn
    command     = /sbin/iptables -D INPUT -s %IP% -p tcp --dport ${SSH_PORT} -j ACCEPT"

    svc_enable_restart knockd
    log_ok "Port knocking active - open: ${KNOCK_SEQ}, close: ${close_seq}"
}

disable_unused() {
    log_step "Disabling Unused Services & Kernel Modules"

    local -a unused_svcs=(
        avahi-daemon cups isc-dhcp-server isc-dhcp-server6
        nfs-server rpcbind rsync snmpd telnet vsftpd
    )
    for svc in "${unused_svcs[@]}"; do svc_stop_disable "$svc"; done

    run mkdir -p "$(dirname "$MODPROBE_CONF")"
    [[ -f "$MODPROBE_CONF" ]] || printf '# harden.sh %s\n' "$TIMESTAMP" > "$MODPROBE_CONF"

    module_disable dccp sctp rds tipc cramfs freevxfs jffs2 hfs hfsplus squashfs udf

    log_ok "Unused services and kernel modules disabled"
}

configure_motd() {
    log_step "Legal MOTD"

    write_file /etc/motd \
"
  +----------------------------------------------------------+
  |         AUTHORISED ACCESS ONLY                           |
  |  This system is for authorised users only. All activity  |
  |  is monitored and logged. Unauthorised access is a       |
  |  criminal offence. Disconnect now if not authorised.     |
  +----------------------------------------------------------+
"
    run_quiet chmod -x /etc/update-motd.d/*
    log_ok "Legal MOTD set; dynamic MOTD suppressed"
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 15 — FINAL REPORT                                   ║
# ╚══════════════════════════════════════════════════════════════╝

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}  === HARDENING COMPLETE ===${RESET}\n"
    echo -e "${BOLD}  Results${RESET}"
    echo    "  -------------------------------------------"
    printf  "  %-22s ${GREEN}%d passed${RESET}\n"    "Checks:"    "$STEPS_OK"
    printf  "  %-22s ${YELLOW}%d warnings${RESET}\n" "Warnings:"  "$STEPS_WARN"
    echo    "  -------------------------------------------"
    printf  "  %-22s %s\n"  "SSH Port:"       "$SSH_PORT"
    printf  "  %-22s %s\n"  "Allowed User:"   "$SSH_USER"
    printf  "  %-22s %s\n"  "Knock Sequence:" "$KNOCK_SEQ"
    printf  "  %-22s %s\n"  "Backups:"        "$BACKUP_DIR"
    printf  "  %-22s %s\n"  "Full Log:"       "$LOG_FILE"
    echo    "  -------------------------------------------"

    if [[ ${#SUMMARY_NOTES[@]} -gt 0 ]]; then
        echo -e "\n${BOLD}  Action Items:${RESET}"
        for note in "${SUMMARY_NOTES[@]}"; do echo "    >> $note"; done
    fi

    echo -e "\n${BOLD}  Connect:${RESET}"
    echo    "    knock <SERVER_IP> ${KNOCK_SEQ//,/ }"
    echo    "    ssh -p $SSH_PORT $SSH_USER@<SERVER_IP>"

    echo -e "\n${BOLD}  Diagnostic Commands:${RESET}"
    printf  "    %-36s # %s\n" "fail2ban-client status sshd"  "active bans"
    printf  "    %-36s # %s\n" "ufw status verbose"           "firewall rules"
    printf  "    %-36s # %s\n" "auditctl -l"                  "loaded audit rules"
    printf  "    %-36s # %s\n" "aide --check"                 "integrity check"
    printf  "    %-36s # %s\n" "journalctl -u ssh -f"         "live SSH log"

    [[ "$DRY_RUN" == true ]] && \
        echo -e "\n  ${YELLOW}*** DRY-RUN -- no changes were made ***${RESET}"
    echo ""
}

# ╔══════════════════════════════════════════════════════════════╗
# ║  SECTION 16 — MAIN PIPELINE                                  ║
# ╚══════════════════════════════════════════════════════════════╝

main() {
    parse_args "$@"
    preflight

    # Each module is independent and idempotent.
    # Comment out any step you want to skip.
    install_packages
    harden_ssh
    configure_firewall
    configure_fail2ban
    harden_kernel
    harden_pam
    configure_auditd
    configure_aide
    configure_auto_updates
    configure_port_knocking
    disable_unused
    configure_motd

    print_summary

    if [[ "$SKIP_REBOOT" == false && "$DRY_RUN" == false ]]; then
        read -r -p "  Reboot now to apply kernel changes? [y/N] " REBOOT_CHOICE
        if [[ "${REBOOT_CHOICE,,}" == "y" ]]; then
            log_info "Rebooting in 5 seconds (Ctrl-C to cancel)..."
            sleep 5
            reboot
        else
            log_warn "Reboot when convenient -- some kernel settings require it."
        fi
    fi
}

main "$@"
