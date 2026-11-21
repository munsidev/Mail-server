#!/usr/bin/env bash
# ==============================================================================
# Local Mail Server Setup and Management Toolkit
# ------------------------------------------------------------------------------
# Target OS: Ubuntu 22.04 LTS / 24.04 LTS (and modern releases)
# Components:
#   - MTA: Postfix (SMTP, Port 25/587)
#   - Access: Dovecot (IMAP Port 143/993, POP3 Port 110/995)
#   - Encryption: OpenSSL TLS/SSL (Self-signed certificates, STARTTLS, IMAPS, POP3S)
#   - Spam Filtering: SpamAssassin (spamd/spamc content filter)
#   - User Management: Linux PAM & Shadow user accounts
# Scope: Local Ubuntu user accounts and optional trusted LAN subnet.
# Security: Closed relay, no public internet delivery, strict subnet boundaries.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Global Constants & Paths
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.2.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration Files
readonly POSTFIX_MAIN_CF="/etc/postfix/main.cf"
readonly POSTFIX_MASTER_CF="/etc/postfix/master.cf"
readonly POSTFIX_CHROOT_RESOLV="/var/spool/postfix/etc/resolv.conf"
readonly DOVECOT_CONF="/etc/dovecot/dovecot.conf"
readonly DOVECOT_MAIL_CF="/etc/dovecot/conf.d/10-mail.conf"
readonly DOVECOT_AUTH_CF="/etc/dovecot/conf.d/10-auth.conf"
readonly DOVECOT_SSL_CF="/etc/dovecot/conf.d/10-ssl.conf"
readonly DOVECOT_MASTER_CF="/etc/dovecot/conf.d/10-master.conf"
readonly SPAMASSASSIN_DEFAULT="/etc/default/spamassassin"

# SSL Certificate Paths
readonly SSL_CERT_DIR="/etc/ssl/certs"
readonly SSL_KEY_DIR="/etc/ssl/private"
readonly SSL_CERT_FILE="${SSL_CERT_DIR}/mail-toolkit.crt"
readonly SSL_KEY_FILE="${SSL_KEY_DIR}/mail-toolkit.key"

# Toolkit Backup Directory
readonly BACKUP_DIR_DEFAULT="/var/backups/mail-toolkit"
readonly LOG_FILE_DEFAULT="/var/log/mail-toolkit.log"
readonly LOCAL_FALLBACK_BACKUP_DIR="${SCRIPT_DIR}/.backups"
readonly LOCAL_FALLBACK_LOG_FILE="${SCRIPT_DIR}/mail-toolkit.log"

# Tag delimiters for managed configuration blocks
readonly TAG_BEGIN="# === BEGIN MANAGED BY MAIL-TOOLKIT ==="
readonly TAG_END="# === END MANAGED BY MAIL-TOOLKIT ==="

# UI Formatting (ANSI Colors if stderr is a TTY)
if [[ -t 2 ]]; then
    readonly C_RESET='\033[0m'
    readonly C_BOLD='\033[1m'
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[0;33m'
    readonly C_BLUE='\033[0;34m'
    readonly C_CYAN='\033[0;36m'
    readonly C_MAGENTA='\033[0;35m'
else
    readonly C_RESET=''
    readonly C_BOLD=''
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_CYAN=''
    readonly C_MAGENTA=''
fi

# ------------------------------------------------------------------------------
# Runtime State Flags
# ------------------------------------------------------------------------------
DRY_RUN=false
ASSUME_YES=false
ACTIVE_BACKUP_DIR="${BACKUP_DIR_DEFAULT}"
ACTIVE_LOG_FILE="${LOG_FILE_DEFAULT}"

# ------------------------------------------------------------------------------
# Logging & Console Output Functions (All UI messages routed to stderr)
# ------------------------------------------------------------------------------
init_environment() {
    if [[ "${EUID}" -eq 0 ]]; then
        ACTIVE_BACKUP_DIR="${BACKUP_DIR_DEFAULT}"
        ACTIVE_LOG_FILE="${LOG_FILE_DEFAULT}"
    else
        ACTIVE_BACKUP_DIR="${LOCAL_FALLBACK_BACKUP_DIR}"
        ACTIVE_LOG_FILE="${LOCAL_FALLBACK_LOG_FILE}"
    fi

    if [[ "${DRY_RUN}" = false && "${EUID}" -eq 0 ]]; then
        mkdir -p "${ACTIVE_BACKUP_DIR}" 2>/dev/null || true
        touch "${ACTIVE_LOG_FILE}" 2>/dev/null || true
        chmod 600 "${ACTIVE_LOG_FILE}" 2>/dev/null || true
    fi
}

log_message() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local message="$*"
    # Sanitize message to avoid leaking secrets
    message="$(printf '%s' "${message}" | tr '\r\n' ' ')"

    if [[ -w "${ACTIVE_LOG_FILE}" || ( ! -e "${ACTIVE_LOG_FILE}" && -w "$(dirname "${ACTIVE_LOG_FILE}")" ) ]]; then
        printf "[%s] [%s] %s\n" "${timestamp}" "${level}" "${message}" >> "${ACTIVE_LOG_FILE}" 2>/dev/null || true
    fi
}

info() {
    printf "${C_BLUE}${C_BOLD}[INFO]${C_RESET} %s\n" "$*" >&2
    log_message "INFO" "$*"
}

success() {
    printf "${C_GREEN}${C_BOLD}[SUCCESS]${C_RESET} %s\n" "$*" >&2
    log_message "SUCCESS" "$*"
}

warn() {
    printf "${C_YELLOW}${C_BOLD}[WARNING]${C_RESET} %s\n" "$*" >&2
    log_message "WARN" "$*"
}

error() {
    printf "${C_RED}${C_BOLD}[ERROR]${C_RESET} %s\n" "$*" >&2
    log_message "ERROR" "$*"
}

dry_notice() {
    if [[ "${DRY_RUN}" = true ]]; then
        printf "${C_MAGENTA}${C_BOLD}[DRY-RUN]${C_RESET} %s\n" "$*" >&2
        log_message "DRY-RUN" "$*"
    fi
}

print_header() {
    local title="$1"
    printf "\n${C_CYAN}${C_BOLD}======================================================================${C_RESET}\n" >&2
    printf "${C_CYAN}${C_BOLD} %s${C_RESET}\n" "${title}" >&2
    printf "${C_CYAN}${C_BOLD}======================================================================${C_RESET}\n" >&2
}

# ------------------------------------------------------------------------------
# User Prompt Helpers
# ------------------------------------------------------------------------------
confirm_action() {
    local prompt_msg="$1"
    local default_ans="${2:-N}"

    if [[ "${ASSUME_YES}" = true ]]; then
        info "Auto-confirming: ${prompt_msg} (flag --yes provided)"
        return 0
    fi

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would prompt user: '${prompt_msg}' (Auto-accepting for dry-run simulation)"
        return 0
    fi

    local choice
    if [[ "${default_ans}" =~ ^[Yy]$ ]]; then
        read -r -p "$(printf "${C_YELLOW}%s [Y/n]: ${C_RESET}" "${prompt_msg}")" choice
        choice="${choice:-Y}"
    else
        read -r -p "$(printf "${C_YELLOW}%s [y/N]: ${C_RESET}" "${prompt_msg}")" choice
        choice="${choice:-N}"
    fi

    if [[ "${choice}" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# System & Requirement Verification
# ------------------------------------------------------------------------------
check_ubuntu_compatibility() {
    info "Verifying host operating system..."
    if [[ ! -f /etc/os-release ]]; then
        if [[ "${DRY_RUN}" = true ]]; then
            warn "Non-Linux or non-standard environment detected (/etc/os-release missing)."
            warn "Dry-run mode continuing for review and syntax validation only."
            return 0
        fi
        error "Cannot detect operating system (/etc/os-release not found)."
        error "This toolkit requires Ubuntu Linux (target 22.04 LTS or 24.04 LTS)."
        return 1
    fi

    local os_id os_version_id os_name
    os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
    os_version_id="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
    os_name="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"

    if [[ "${os_id}" != "ubuntu" ]]; then
        if [[ "${DRY_RUN}" = true ]]; then
            warn "Target OS reported '${os_id}' (${os_name})."
            warn "Dry-run mode continuing for demonstration purposes."
            return 0
        fi
        error "Unsupported distribution: '${os_id}'. This toolkit is designed specifically for Ubuntu."
        return 1
    fi

    success "Operating System detected: ${os_name} (ID: ${os_id}, Version: ${os_version_id})"
    case "${os_version_id}" in
        22.04*|24.04*|24.10*)
            success "Target Ubuntu LTS version verified (${os_version_id})."
            ;;
        20.04*)
            warn "Ubuntu 20.04 LTS detected. While compatible, 22.04 or 24.04 LTS is strongly recommended."
            ;;
        *)
            warn "Untested Ubuntu release detected (${os_version_id}). Standard package names and systemd configurations may vary."
            ;;
    esac
    return 0
}

require_root_privileges() {
    local action_description="$1"
    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Simulating root privileges check for: ${action_description}"
        return 0
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        error "Root / sudo privileges are required to ${action_description}."
        error "Explanation: Mail configuration involves writing to /etc/postfix, /etc/dovecot,"
        error "managing systemd daemons, and opening privileged network ports (25, 110, 143, 993, 995)."
        error "Please re-run this command with sudo: sudo $0 [options]"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Dovecot Engine Version Detection
# ------------------------------------------------------------------------------
get_dovecot_version() {
    local ver=""
    if command -v doveconf >/dev/null 2>&1; then
        ver="$(doveconf -n 2>&1 | grep -E '^#[[:space:]]*[0-9]+\.[0-9]+' | head -n 1 | awk '{print $2}' || true)"
        if [[ -z "${ver}" ]]; then
            ver="$(doveconf -a 2>/dev/null | head -n 1 | awk '{print $1}' || true)"
        fi
    fi
    if [[ -z "${ver}" ]] && command -v dovecot >/dev/null 2>&1; then
        ver="$(dovecot --version 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [[ -z "${ver}" && -f /etc/os-release ]]; then
        if grep -qE 'VERSION_ID="(24\.(04|10)|25\.)' /etc/os-release 2>/dev/null; then
            echo "2.4"
            return
        fi
    fi
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "2.3"
    fi
}

is_dovecot_24_or_newer() {
    local ver
    ver="$(get_dovecot_version)"
    local major="${ver%%.*}"
    local minor="${ver#*.}"
    minor="${minor%%.*}"

    if (( major > 2 || (major == 2 && minor >= 4) )); then
        return 0
    fi
    return 1
}

fix_postfix_chroot_resolv_conf() {
    if [[ -f "${POSTFIX_CHROOT_RESOLV}" && "${EUID}" -eq 0 && "${DRY_RUN}" = false ]]; then
        chown root:root "${POSTFIX_CHROOT_RESOLV}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Input Validation Helpers
# ------------------------------------------------------------------------------
validate_ipv4_subnet() {
    local subnet="$1"
    if [[ ! "${subnet}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
        return 1
    fi

    local o1="${BASH_REMATCH[1]}"
    local o2="${BASH_REMATCH[2]}"
    local o3="${BASH_REMATCH[3]}"
    local o4="${BASH_REMATCH[4]}"
    local mask="${BASH_REMATCH[5]}"

    if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 || mask < 8 || mask > 30 )); then
        return 1
    fi

    if [[ "${o1}.${o2}.${o3}.${o4}" == "0.0.0.0" ]]; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Safe Backup and File Management
# ------------------------------------------------------------------------------
create_backup() {
    local target_file="$1"

    if [[ ! -f "${target_file}" ]]; then
        info "Target file ${target_file} does not exist yet. No pre-existing backup needed."
        return 0
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local base_name
    base_name="$(basename "${target_file}")"
    local backup_target="${ACTIVE_BACKUP_DIR}/${base_name}.${timestamp}.bak"

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would create timestamped backup: ${target_file} -> ${backup_target}"
        printf "%s\n" "${backup_target}"
        return 0
    fi

    mkdir -p "${ACTIVE_BACKUP_DIR}"
    if cp -p "${target_file}" "${backup_target}"; then
        success "Created configuration backup: ${backup_target}"
        log_message "BACKUP" "Backed up ${target_file} to ${backup_target}"
        printf "%s\n" "${backup_target}"
        return 0
    else
        error "Failed to create backup of ${target_file}!"
        return 1
    fi
}

restore_backup() {
    local original_file="$1"
    local raw_backup_file="${2:-}"

    if [[ -z "${raw_backup_file}" ]]; then
        return 0
    fi

    local backup_file
    backup_file="$(printf '%s\n' "${raw_backup_file}" | grep -E '^/' | tail -n 1 | tr -d '\r\n' || true)"

    if [[ -z "${backup_file}" || ! -f "${backup_file}" ]]; then
        error "Backup file '${backup_file:-$raw_backup_file}' not found! Cannot automatically restore."
        return 1
    fi

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would restore ${original_file} from ${backup_file}"
        return 0
    fi

    warn "Restoring ${original_file} from backup: ${backup_file}..."
    cp -p "${backup_file}" "${original_file}"
    success "Restored ${original_file} successfully."
    log_message "RESTORE" "Restored ${original_file} from ${backup_file}"
}

# ------------------------------------------------------------------------------
# Managed Configuration Section Management
# ------------------------------------------------------------------------------
write_managed_block() {
    local target_file="$1"
    local block_content="$2"

    local parent_dir
    parent_dir="$(dirname "${target_file}")"

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would apply managed configuration block to: ${target_file}"
        printf "${C_MAGENTA}--- Planned Managed Block for %s ---${C_RESET}\n" "${target_file}" >&2
        printf "%s\n%s\n%s\n" "${TAG_BEGIN}" "${block_content}" "${TAG_END}" >&2
        printf "${C_MAGENTA}------------------------------------------------${C_RESET}\n" >&2
        return 0
    fi

    mkdir -p "${parent_dir}"

    local temp_file
    temp_file="$(mktemp "${parent_dir}/tmp.mail-toolkit.XXXXXX")"

    local keys_pattern
    keys_pattern="$(grep -E '^[a-zA-Z0-9_]+[[:space:]]*=' <<< "${block_content}" 2>/dev/null | awk -F'=' '{gsub(/[[:space:]]/, ""); print $1}' | tr '\n' '|' | sed 's/|$//' || true)"

    local kpat=""
    if [[ -n "${keys_pattern}" ]]; then
        kpat="^([[:space:]]*)(#\\[superseded\\] )?(${keys_pattern})([[:space:]]*=)"
    fi

    if [[ -f "${target_file}" ]]; then
        if grep -qF "${TAG_BEGIN}" "${target_file}"; then
            awk -v tag_b="${TAG_BEGIN}" -v tag_e="${TAG_END}" -v content="${block_content}" -v kpat="${kpat}" '
                BEGIN { in_block = 0 }
                $0 == tag_b {
                    in_block = 1
                    print tag_b
                    print content
                    print tag_e
                    next
                }
                $0 == tag_e {
                    in_block = 0
                    next
                }
                in_block == 1 { next }
                in_block == 0 {
                    if (length(kpat) > 0 && $0 ~ kpat) {
                        if ($0 ~ /^[[:space:]]*#\[superseded\]/) {
                            print $0
                        } else {
                            print "#[superseded] " $0
                        }
                    } else {
                        print $0
                    }
                }
            ' "${target_file}" > "${temp_file}"
        else
            awk -v kpat="${kpat}" '
                {
                    if (length(kpat) > 0 && $0 ~ kpat) {
                        if ($0 ~ /^[[:space:]]*#\[superseded\]/) {
                            print $0
                        } else {
                            print "#[superseded] " $0
                        }
                    } else {
                        print $0
                    }
                }
            ' "${target_file}" > "${temp_file}"
            printf "\n%s\n%s\n%s\n" "${TAG_BEGIN}" "${block_content}" "${TAG_END}" >> "${temp_file}"
        fi
    else
        if [[ "$(basename "${target_file}")" == "dovecot.conf" ]] && is_dovecot_24_or_newer; then
            printf "dovecot_config_version = 2.4.0\ndovecot_storage_version = 2.4.0\n\n" > "${temp_file}"
        fi
        printf "%s\n%s\n%s\n" "${TAG_BEGIN}" "${block_content}" "${TAG_END}" > "${temp_file}"
    fi

    # Extra safety for Dovecot 2.4+: Comment out unmanaged deprecated directives outside our block
    if is_dovecot_24_or_newer; then
        if [[ "$(basename "${target_file}")" == "10-auth.conf" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(disable_plaintext_auth[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            rm -f "${temp_file}.bak" 2>/dev/null || true
        fi
        if [[ "$(basename "${target_file}")" == "10-mail.conf" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(mail_location[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(mail_inbox_path[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            rm -f "${temp_file}.bak" 2>/dev/null || true
        fi
        if [[ "$(basename "${target_file}")" == "10-ssl.conf" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_cert[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_key[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_dh[[:space:]]*=)/#[superseded] \1/' "${temp_file}" 2>/dev/null || true
            rm -f "${temp_file}.bak" 2>/dev/null || true
        fi
    fi

    chmod 644 "${temp_file}"
    mv -f "${temp_file}" "${target_file}"
    success "Updated managed block in ${target_file}"
    log_message "CONFIG" "Updated managed block in ${target_file}"
}

remove_managed_block() {
    local target_file="$1"

    if [[ ! -f "${target_file}" ]]; then
        return 0
    fi

    if ! grep -qF "${TAG_BEGIN}" "${target_file}" && ! grep -qF "#[superseded] " "${target_file}"; then
        info "No toolkit-managed block detected in ${target_file}."
        return 0
    fi

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would remove managed block and restore superseded lines in: ${target_file}"
        return 0
    fi

    local parent_dir
    parent_dir="$(dirname "${target_file}")"
    local temp_file
    temp_file="$(mktemp "${parent_dir}/tmp.mail-toolkit.rm.XXXXXX")"

    awk -v tag_b="${TAG_BEGIN}" -v tag_e="${TAG_END}" '
        BEGIN { in_block = 0 }
        $0 == tag_b { in_block = 1; next }
        $0 == tag_e { in_block = 0; next }
        in_block == 0 {
            if ($0 ~ /^[[:space:]]*#\[superseded\] /) {
                sub(/^[[:space:]]*#\[superseded\] /, "")
            }
            print $0
        }
    ' "${target_file}" > "${temp_file}"

    if [[ ! -s "${temp_file}" || -z "$(grep -E -v '^[[:space:]]*$' "${temp_file}" || true)" ]]; then
        rm -f "${temp_file}" "${target_file}"
        info "Removed empty configuration file: ${target_file}"
    else
        chmod 644 "${temp_file}"
        mv -f "${temp_file}" "${target_file}"
        success "Removed toolkit-managed settings and restored original directives in ${target_file}"
    fi
    log_message "CONFIG" "Removed managed block from ${target_file}"
}

# ------------------------------------------------------------------------------
# Dovecot v2.4+ Legacy Directive Sanitizer
# ------------------------------------------------------------------------------
sanitize_dovecot_configs_for_v24() {
    if is_dovecot_24_or_newer && [[ "${DRY_RUN}" = false && "${EUID}" -eq 0 ]]; then
        if [[ -f "${DOVECOT_AUTH_CF}" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(disable_plaintext_auth[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_AUTH_CF}" 2>/dev/null || true
            rm -f "${DOVECOT_AUTH_CF}.bak" 2>/dev/null || true
        fi
        if [[ -f "${DOVECOT_MAIL_CF}" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(mail_location[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_MAIL_CF}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(mail_inbox_path[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_MAIL_CF}" 2>/dev/null || true
            rm -f "${DOVECOT_MAIL_CF}.bak" 2>/dev/null || true
        fi
        if [[ -f "${DOVECOT_SSL_CF}" ]]; then
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_cert[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_SSL_CF}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_key[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_SSL_CF}" 2>/dev/null || true
            sed -i.bak -E '/=== BEGIN MANAGED/,/=== END MANAGED/! s/^[[:space:]]*(ssl_dh[[:space:]]*=)/#[superseded] \1/' "${DOVECOT_SSL_CF}" 2>/dev/null || true
            rm -f "${DOVECOT_SSL_CF}.bak" 2>/dev/null || true
        fi
    fi
}

# ------------------------------------------------------------------------------
# Postfix & Dovecot Syntax Validation
# ------------------------------------------------------------------------------
validate_service_configs() {
    info "Validating configuration files for Postfix and Dovecot..."
    local validation_passed=true

    fix_postfix_chroot_resolv_conf
    sanitize_dovecot_configs_for_v24

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Simulating syntax validation: 'postfix check' and 'doveconf -n'"
        return 0
    fi

    # Validate Postfix
    if command -v postfix >/dev/null 2>&1; then
        info "Executing 'postfix check'..."
        if ! postfix check 2>&1 | tee -a "${ACTIVE_LOG_FILE}" >&2; then
            error "Postfix configuration check failed!"
            validation_passed=false
        else
            success "Postfix configuration syntax is valid."
        fi
    else
        warn "Postfix binary not found in PATH; skipping 'postfix check'."
    fi

    # Validate Dovecot
    if command -v doveconf >/dev/null 2>&1; then
        info "Executing 'doveconf -n'..."
        if ! doveconf -n >/dev/null 2>&1; then
            error "Dovecot configuration check failed!"
            doveconf -n 2>&1 | head -n 20 | tee -a "${ACTIVE_LOG_FILE}" >&2
            validation_passed=false
        else
            success "Dovecot configuration syntax is valid."
        fi
    else
        warn "Dovecot binary not found in PATH; skipping 'doveconf -n'."
    fi

    if [[ "${validation_passed}" = true ]]; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Action 1: Check Prerequisites & Installed Packages
# ------------------------------------------------------------------------------
action_check_prerequisites() {
    print_header "1. Prerequisites & Package Inspection"

    check_ubuntu_compatibility || true

    info "Checking core system management tools..."
    local tools=("systemctl" "apt-get" "awk" "sed" "grep" "ss" "ip" "openssl")
    local missing_tools=()

    for tool in "${tools[@]}"; do
        if command -v "${tool}" >/dev/null 2>&1; then
            printf "  %-15s : ${C_GREEN}Found${C_RESET} (%s)\n" "${tool}" "$(command -v "${tool}")" >&2
        else
            printf "  %-15s : ${C_RED}Missing${C_RESET}\n" "${tool}" >&2
            missing_tools+=("${tool}")
        fi
    done

    if [[ "${#missing_tools[@]}" -gt 0 ]]; then
        warn "Missing core utilities: ${missing_tools[*]}."
    else
        success "All required base utilities are available."
    fi

    printf "\n" >&2
    info "Checking mail server packages..."
    local packages=("postfix" "dovecot-core" "dovecot-imapd" "dovecot-pop3d" "mailutils" "spamassassin" "spamc")

    for pkg in "${packages[@]}"; do
        if dpkg -s "${pkg}" 2>/dev/null | grep -q "Status: install ok installed"; then
            local ver
            ver="$(dpkg -s "${pkg}" 2>/dev/null | grep -E '^Version:' | awk '{print $2}')"
            printf "  %-20s : ${C_GREEN}Installed${C_RESET} (Version: %s)\n" "${pkg}" "${ver}" >&2
        else
            printf "  %-20s : ${C_YELLOW}Not Installed${C_RESET}\n" "${pkg}" >&2
        fi
    done

    printf "\n" >&2
    local d_engine
    d_engine="$(get_dovecot_version)"
    info "Dovecot Engine Architecture: Detected ${d_engine} ($(is_dovecot_24_or_newer && echo "Modern 2.4+ driver syntax" || echo "Legacy 2.3 location syntax"))"

    printf "\n" >&2
    info "Privilege Status:"
    if [[ "${EUID}" -eq 0 ]]; then
        printf "  User running as root (UID 0): ${C_GREEN}Yes${C_RESET}\n" >&2
    else
        printf "  User running as non-root (UID %s): ${C_YELLOW}No${C_RESET}\n" "${EUID}" >&2
        printf "  Note: Root / sudo privileges are required for installation and daemon management.\n" >&2
    fi
}

# ------------------------------------------------------------------------------
# Action 2: Install Full Mail Suite Packages
# ------------------------------------------------------------------------------
action_install_packages() {
    print_header "2. Install Full Mail Server Suite"

    require_root_privileges "install system packages" || return 1

    local packages_to_install=("postfix" "dovecot-core" "dovecot-imapd" "dovecot-pop3d" "mailutils" "spamassassin" "spamc")

    info "The following packages will be installed via apt-get:"
    for pkg in "${packages_to_install[@]}"; do
        printf "  - ${C_BOLD}%s${C_RESET}\n" "${pkg}" >&2
    done
    printf "\n" >&2
    info "Component Breakdown:"
    printf "  * postfix          : Mail Transfer Agent (SMTP, Port 25/587)\n" >&2
    printf "  * dovecot-imapd    : IMAP Mailbox Access Protocol Daemon (Port 143/993)\n" >&2
    printf "  * dovecot-pop3d    : POP3 Mailbox Access Protocol Daemon (Port 110/995)\n" >&2
    printf "  * mailutils        : Command-line mail client utility\n" >&2
    printf "  * spamassassin/c   : Automated spam classification & header filtering engine\n\n" >&2

    if ! confirm_action "Proceed with full package installation?"; then
        warn "Package installation aborted by user."
        return 0
    fi

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would run: apt-get update"
        dry_notice "Would run: DEBIAN_FRONTEND=noninteractive apt-get install -y ${packages_to_install[*]}"
        success "Simulated package installation completed successfully."
        return 0
    fi

    info "Updating apt package index..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update; then
        error "Failed to update package repositories via apt-get."
        return 1
    fi

    if command -v debconf-set-selections >/dev/null 2>&1; then
        echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections 2>/dev/null || true
        echo "postfix postfix/mailname string localhost.localdomain" | debconf-set-selections 2>/dev/null || true
    fi

    info "Installing mail packages..."
    if apt-get install -y "${packages_to_install[@]}"; then
        success "Packages installed successfully."
        log_message "INSTALL" "Installed packages: ${packages_to_install[*]}"
    else
        error "Package installation failed! Check /var/log/dpkg.log or apt output."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Action 3: Configure Local Mail Delivery (SMTP, IMAP, POP3, Maildir)
# ------------------------------------------------------------------------------
action_configure_local() {
    print_header "3. Configure Local Mail Delivery (SMTP, IMAP, POP3)"

    require_root_privileges "modify mail server configuration" || return 1

    local hostname_val
    hostname_val="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost.localdomain")"

    local d_ver
    d_ver="$(get_dovecot_version)"

    info "Target Configuration Summary:"
    printf "  * Hostname / Domain     : %s / localdomain\n" "${hostname_val}" >&2
    printf "  * Mailbox Storage Format : Maildir/ (~/Maildir)\n" >&2
    printf "  * Protocols Supported    : SMTP (25), IMAP (143), POP3 (110)\n" >&2
    printf "  * Listening Interfaces   : Loopback only (127.0.0.1, [::1])\n" >&2
    printf "  * Open Relay Prevention  : Active (rejects any non-local destination)\n" >&2
    printf "  * Internet Delivery      : Disabled (default_transport = error)\n" >&2
    printf "  * Dovecot Architecture   : %s (%s)\n\n" "${d_ver}" "$(is_dovecot_24_or_newer && echo "v2.4+ cleartext & driver syntax" || echo "v2.3 location syntax")" >&2

    if ! confirm_action "Apply local mail server configuration?"; then
        warn "Configuration aborted by user."
        return 0
    fi

    local bkp_main bkp_dovecot bkp_dove_mail bkp_dove_auth
    bkp_main="$(create_backup "${POSTFIX_MAIN_CF}")"
    bkp_dovecot="$(create_backup "${DOVECOT_CONF}")"
    bkp_dove_mail="$(create_backup "${DOVECOT_MAIL_CF}")"
    bkp_dove_auth="$(create_backup "${DOVECOT_AUTH_CF}")"

    local postfix_content
    postfix_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit
myhostname = ${hostname_val}
mydomain = localdomain
myorigin = \$mydomain
inet_interfaces = loopback-only
inet_protocols = ipv4
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
mynetworks_style = host
mynetworks = 127.0.0.0/8 [::1]/128
home_mailbox = Maildir/
smtpd_banner = \$myhostname ESMTP Local Mail Server (No Public Relay)
smtpd_relay_restrictions = permit_mynetworks, reject
default_transport = error:Public Internet delivery is disabled by local mail toolkit
relay_transport = error:Public Internet relay is disabled by local mail toolkit
biff = no
append_dot_mydomain = no
readme_directory = no
recipient_delimiter = +
EOF
)

    local dovecot_main_content
    local dovecot_mail_content
    local dovecot_auth_content

    if is_dovecot_24_or_newer; then
        info "Applying modern Dovecot 2.4+ syntax directives (IMAP + POP3)..."
        dovecot_main_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit
listen = 127.0.0.1, ::1
protocols = imap pop3
EOF
)
        dovecot_mail_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+)
mail_home = /home/%{user}
mail_driver = maildir
mail_path = ~/Maildir
EOF
)
        dovecot_auth_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+)
auth_allow_cleartext = yes
auth_mechanisms = plain login
EOF
)
    else
        info "Applying legacy Dovecot 2.3 syntax directives (IMAP + POP3)..."
        dovecot_main_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit
listen = 127.0.0.1, ::1
protocols = imap pop3
EOF
)
        dovecot_mail_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3)
mail_location = maildir:~/Maildir
EOF
)
        dovecot_auth_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3)
disable_plaintext_auth = no
auth_mechanisms = plain login
EOF
)
    fi

    write_managed_block "${POSTFIX_MAIN_CF}" "${postfix_content}"
    write_managed_block "${DOVECOT_CONF}" "${dovecot_main_content}"
    write_managed_block "${DOVECOT_MAIL_CF}" "${dovecot_mail_content}"
    write_managed_block "${DOVECOT_AUTH_CF}" "${dovecot_auth_content}"

    if ! validate_service_configs; then
        error "Configuration validation failed! Rolling back changes..."
        [[ -n "${bkp_main}" ]] && restore_backup "${POSTFIX_MAIN_CF}" "${bkp_main}"
        [[ -n "${bkp_dovecot}" ]] && restore_backup "${DOVECOT_CONF}" "${bkp_dovecot}"
        [[ -n "${bkp_dove_mail}" ]] && restore_backup "${DOVECOT_MAIL_CF}" "${bkp_dove_mail}"
        [[ -n "${bkp_dove_auth}" ]] && restore_backup "${DOVECOT_AUTH_CF}" "${bkp_dove_auth}"
        error "Rollback completed. Services were NOT restarted."
        return 1
    fi

    if confirm_action "Restart Postfix and Dovecot services now?" "Y"; then
        if [[ "${DRY_RUN}" = true ]]; then
            dry_notice "Would run: systemctl restart postfix dovecot"
            dry_notice "Would run: systemctl enable postfix dovecot"
        else
            info "Restarting mail services..."
            systemctl restart postfix dovecot
            systemctl enable postfix dovecot >/dev/null 2>&1 || true
            success "Postfix and Dovecot services successfully restarted."
        fi
    fi

    success "Local mail delivery configuration completed successfully."
}

# ------------------------------------------------------------------------------
# Action 4: Configure TLS/SSL Encryption (Self-Signed Certificates)
# ------------------------------------------------------------------------------
action_configure_ssl() {
    print_header "4. Configure TLS/SSL Encryption"

    require_root_privileges "configure TLS/SSL certificates and encrypted sockets" || return 1

    info "This option configures end-to-end local encryption:"
    printf "  * Generates a 2048-bit RSA self-signed TLS/SSL certificate.\n" >&2
    printf "  * Enables Postfix opportunistic/mandatory STARTTLS on SMTP (Port 25/587).\n" >&2
    printf "  * Enables Dovecot SSL/TLS listeners for IMAPS (Port 993) and POP3S (Port 995).\n" >&2
    printf "  * Certificate path: %s\n" "${SSL_CERT_FILE}" >&2
    printf "  * Private Key path: %s\n\n" "${SSL_KEY_FILE}" >&2

    if ! confirm_action "Generate certificates and enable TLS/SSL encryption?"; then
        warn "TLS/SSL configuration aborted by user."
        return 0
    fi

    local hostname_val
    hostname_val="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")"

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would run: openssl req -new -x509 -days 365 -nodes -out ${SSL_CERT_FILE} -keyout ${SSL_KEY_FILE} -subj '/CN=${hostname_val}/O=LocalMailServer'"
    else
        mkdir -p "${SSL_CERT_DIR}" "${SSL_KEY_DIR}"
        info "Generating self-signed certificate for CN=${hostname_val}..."
        openssl req -new -x509 -days 365 -nodes \
            -out "${SSL_CERT_FILE}" \
            -keyout "${SSL_KEY_FILE}" \
            -subj "/CN=${hostname_val}/O=LocalMailToolkit" >/dev/null 2>&1
        chmod 644 "${SSL_CERT_FILE}"
        chmod 600 "${SSL_KEY_FILE}"
        success "TLS/SSL certificates generated successfully."
    fi

    local bkp_main bkp_ssl bkp_master
    bkp_main="$(create_backup "${POSTFIX_MAIN_CF}")"
    bkp_ssl="$(create_backup "${DOVECOT_SSL_CF}")"
    bkp_master="$(create_backup "${POSTFIX_MASTER_CF}")"

    # Postfix TLS block
    local postfix_ssl_block
    postfix_ssl_block=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (TLS/SSL)
smtpd_tls_cert_file = ${SSL_CERT_FILE}
smtpd_tls_key_file = ${SSL_KEY_FILE}
smtpd_tls_security_level = may
smtpd_tls_auth_only = no
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes
EOF
)

    # Postfix Submission Port 587 block (for mobile / client SMTP)
    local postfix_submission_block
    postfix_submission_block=$(cat <<EOF
# Postfix Submission Port 587 (Mobile / LAN client submission)
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
  -o smtpd_relay_restrictions=permit_mynetworks,reject
EOF
)

    # Dovecot SSL block according to detected engine version
    local dovecot_ssl_block
    if is_dovecot_24_or_newer; then
        info "Applying modern Dovecot 2.4+ SSL directives (ssl_server_cert_file, ssl_server_key_file)..."
        dovecot_ssl_block=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+ TLS/SSL)
ssl = yes
ssl_server_cert_file = ${SSL_CERT_FILE}
ssl_server_key_file = ${SSL_KEY_FILE}
EOF
)
    else
        info "Applying legacy Dovecot 2.3 SSL directives (ssl_cert = <...)..."
        dovecot_ssl_block=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3 TLS/SSL)
ssl = yes
ssl_cert = <${SSL_CERT_FILE}
ssl_key = <${SSL_KEY_FILE}
EOF
)
    fi

    write_managed_block "${POSTFIX_MAIN_CF}" "${postfix_ssl_block}"
    write_managed_block "${POSTFIX_MASTER_CF}" "${postfix_submission_block}"
    write_managed_block "${DOVECOT_SSL_CF}" "${dovecot_ssl_block}"

    if ! validate_service_configs; then
        error "TLS/SSL validation failed! Rolling back changes..."
        [[ -n "${bkp_main}" ]] && restore_backup "${POSTFIX_MAIN_CF}" "${bkp_main}"
        [[ -n "${bkp_ssl}" ]] && restore_backup "${DOVECOT_SSL_CF}" "${bkp_ssl}"
        [[ -n "${bkp_master}" ]] && restore_backup "${POSTFIX_MASTER_CF}" "${bkp_master}"
        return 1
    fi

    if confirm_action "Restart services to activate TLS/SSL?" "Y"; then
        if [[ "${DRY_RUN}" = true ]]; then
            dry_notice "Would run: systemctl restart postfix dovecot"
        else
            systemctl restart postfix dovecot
            success "Services restarted. IMAPS (993), POP3S (995), and SMTP STARTTLS are active."
        fi
    fi

    success "TLS/SSL Encryption successfully configured."
}

# ------------------------------------------------------------------------------
# Action 5: Configure SpamAssassin Spam Filtering
# ------------------------------------------------------------------------------
action_configure_spamassassin() {
    print_header "5. Configure SpamAssassin Spam Filtering"

    require_root_privileges "configure SpamAssassin filtering" || return 1

    info "This option integrates SpamAssassin into the local Postfix mail pipeline:"
    printf "  * Activates the spamd daemon service.\n" >&2
    printf "  * Configures Postfix to route incoming local messages through 'spamc'.\n" >&2
    printf "  * Injects X-Spam-Status, X-Spam-Flag, and score headers into scanned messages.\n\n" >&2

    if ! confirm_action "Enable SpamAssassin content filtering?"; then
        warn "Spam filtering setup aborted by user."
        return 0
    fi

    local bkp_main bkp_master bkp_default
    bkp_main="$(create_backup "${POSTFIX_MAIN_CF}")"
    bkp_master="$(create_backup "${POSTFIX_MASTER_CF}")"
    bkp_default="$(create_backup "${SPAMASSASSIN_DEFAULT}")"

    if [[ "${DRY_RUN}" = true ]]; then
        dry_notice "Would enable spamd in ${SPAMASSASSIN_DEFAULT}"
        dry_notice "Would apply SpamAssassin filter pipe to ${POSTFIX_MASTER_CF}"
        dry_notice "Would run: systemctl restart spamassassin postfix"
        success "Simulated SpamAssassin configuration completed."
        return 0
    fi

    # Enable spamd daemon in /etc/default/spamassassin
    if [[ -f "${SPAMASSASSIN_DEFAULT}" ]]; then
        sed -i.bak -E 's/^[[:space:]]*ENABLED[[:space:]]*=.*/ENABLED=1/' "${SPAMASSASSIN_DEFAULT}" 2>/dev/null || true
        sed -i.bak -E 's/^[[:space:]]*CRON[[:space:]]*=.*/CRON=1/' "${SPAMASSASSIN_DEFAULT}" 2>/dev/null || true
        rm -f "${SPAMASSASSIN_DEFAULT}.bak" 2>/dev/null || true
    fi

    local spamd_user="nobody"
    if id "debian-spamd" >/dev/null 2>&1; then
        spamd_user="debian-spamd"
    fi

    # Define Postfix master.cf filter pipe
    local master_spam_block
    master_spam_block=$(cat <<EOF
# Postfix SpamAssassin Filter Pipe
spamassassin unix - n n - - pipe
  flags=Rq user=${spamd_user} argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f \${sender} \${recipient}
EOF
)

    write_managed_block "${POSTFIX_MASTER_CF}" "${master_spam_block}"

    # Also activate content_filter in main.cf
    local main_spam_block
    main_spam_block=$(cat <<EOF
# SpamAssassin Content Filter Directive
content_filter = spamassassin
EOF
)
    write_managed_block "${POSTFIX_MAIN_CF}" "${main_spam_block}"

    if ! validate_service_configs; then
        error "Configuration validation failed! Rolling back SpamAssassin setup..."
        [[ -n "${bkp_main}" ]] && restore_backup "${POSTFIX_MAIN_CF}" "${bkp_main}"
        [[ -n "${bkp_master}" ]] && restore_backup "${POSTFIX_MASTER_CF}" "${bkp_master}"
        [[ -n "${bkp_default}" ]] && restore_backup "${SPAMASSASSIN_DEFAULT}" "${bkp_default}"
        return 1
    fi

    info "Starting spamassassin and restarting postfix..."
    systemctl enable --now spamassassin >/dev/null 2>&1 || true
    systemctl restart spamassassin postfix 2>/dev/null || true
    success "SpamAssassin spam filter is now active on all local deliveries."
}

# ------------------------------------------------------------------------------
# Action 6: Optionally Enable Access from Trusted LAN Subnet
# ------------------------------------------------------------------------------
action_configure_lan() {
    print_header "6. Configure Trusted LAN Subnet Access"

    require_root_privileges "configure network interfaces and mail bindings" || return 1

    printf "${C_YELLOW}${C_BOLD}SECURITY ADVISORY:${C_RESET}\n" >&2
    printf "  - This option exposes SMTP, IMAP, and POP3 to hosts on your local LAN.\n" >&2
    printf "  - It must NEVER be exposed to the public internet or an untrusted network.\n" >&2
    printf "  - Only the exact CIDR subnet you specify will be authorized to submit mail.\n\n" >&2

    local subnet_input=""
    if [[ -n "${1:-}" ]]; then
        subnet_input="$1"
    else
        read -r -p "$(printf "${C_CYAN}Enter the trusted LAN subnet in CIDR notation (e.g., 192.168.1.0/24): ${C_RESET}")" subnet_input
    fi

    if ! validate_ipv4_subnet "${subnet_input}"; then
        error "Invalid IPv4 CIDR subnet: '${subnet_input}'."
        error "Format must be standard IPv4 CIDR (e.g. 192.168.1.0/24, 10.0.0.0/24). 0.0.0.0/0 is prohibited."
        return 1
    fi

    info "Subnet '${subnet_input}' validated."
    info "Planned changes:"
    printf "  * Postfix 'inet_interfaces' will be set to 'all'.\n" >&2
    printf "  * Postfix 'mynetworks' will include: 127.0.0.0/8 [::1]/128 %s\n" "${subnet_input}" >&2
    printf "  * Dovecot 'listen' will be set to: *, :: (Serving IMAP 143/993, POP3 110/995)\n" >&2
    printf "  * Open relay protection remains ACTIVE: Only local addresses and %s can send mail.\n\n" "${subnet_input}" >&2

    if ! confirm_action "Apply LAN access configuration for subnet ${subnet_input}?"; then
        warn "LAN configuration aborted by user."
        return 0
    fi

    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | grep -E '^Status:' | awk '{print $2}' || true)"
        if [[ "${ufw_status}" == "active" ]]; then
            warn "UFW is active on this host."
            info "Clients on ${subnet_input} need access to ports 25, 110, 143, 993, 995."
            if confirm_action "Would you like this script to configure UFW rules for ${subnet_input}?"; then
                if [[ "${DRY_RUN}" = true ]]; then
                    dry_notice "Would run: ufw allow from ${subnet_input} to any port 25,110,143,993,995 proto tcp"
                else
                    for p in 25 110 143 993 995; do
                        ufw allow from "${subnet_input}" to any port "${p}" proto tcp comment "Mail-Toolkit Port ${p}" >/dev/null 2>&1 || true
                    done
                    success "UFW firewall rules added for ${subnet_input}."
                fi
            fi
        fi
    fi

    local hostname_val
    hostname_val="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost.localdomain")"

    local bkp_main bkp_dovecot bkp_dove_mail bkp_dove_auth
    bkp_main="$(create_backup "${POSTFIX_MAIN_CF}")"
    bkp_dovecot="$(create_backup "${DOVECOT_CONF}")"
    bkp_dove_mail="$(create_backup "${DOVECOT_MAIL_CF}")"
    bkp_dove_auth="$(create_backup "${DOVECOT_AUTH_CF}")"

    local postfix_lan_content
    postfix_lan_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit
myhostname = ${hostname_val}
mydomain = localdomain
myorigin = \$mydomain
inet_interfaces = all
inet_protocols = ipv4
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
mynetworks_style = host
mynetworks = 127.0.0.0/8 [::1]/128 ${subnet_input}
home_mailbox = Maildir/
smtpd_banner = \$myhostname ESMTP Local Mail Server (Trusted LAN Only)
smtpd_relay_restrictions = permit_mynetworks, reject
default_transport = error:Public Internet delivery is disabled by local mail toolkit
relay_transport = error:Public Internet relay is disabled by local mail toolkit
biff = no
append_dot_mydomain = no
readme_directory = no
recipient_delimiter = +
EOF
)

    local dovecot_lan_content
    local dovecot_mail_content
    local dovecot_auth_content

    if is_dovecot_24_or_newer; then
        dovecot_lan_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+)
listen = *, ::
protocols = imap pop3
EOF
)
        dovecot_mail_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+)
mail_home = /home/%{user}
mail_driver = maildir
mail_path = ~/Maildir
EOF
)
        dovecot_auth_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.4+)
auth_allow_cleartext = yes
auth_mechanisms = plain login
EOF
)
    else
        dovecot_lan_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3)
listen = *, ::
protocols = imap pop3
EOF
)
        dovecot_mail_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3)
mail_location = maildir:~/Maildir
EOF
)
        dovecot_auth_content=$(cat <<EOF
# Local Mail Server Setup and Management Toolkit (Dovecot 2.3)
disable_plaintext_auth = no
auth_mechanisms = plain login
EOF
)
    fi

    write_managed_block "${POSTFIX_MAIN_CF}" "${postfix_lan_content}"
    write_managed_block "${DOVECOT_CONF}" "${dovecot_lan_content}"
    write_managed_block "${DOVECOT_MAIL_CF}" "${dovecot_mail_content}"
    write_managed_block "${DOVECOT_AUTH_CF}" "${dovecot_auth_content}"

    if ! validate_service_configs; then
        error "Configuration validation failed! Rolling back LAN changes..."
        [[ -n "${bkp_main}" ]] && restore_backup "${POSTFIX_MAIN_CF}" "${bkp_main}"
        [[ -n "${bkp_dovecot}" ]] && restore_backup "${DOVECOT_CONF}" "${bkp_dovecot}"
        [[ -n "${bkp_dove_mail}" ]] && restore_backup "${DOVECOT_MAIL_CF}" "${bkp_dove_mail}"
        [[ -n "${bkp_dove_auth}" ]] && restore_backup "${DOVECOT_AUTH_CF}" "${bkp_dove_auth}"
        return 1
    fi

    if confirm_action "Restart Postfix and Dovecot services to activate LAN access?" "Y"; then
        if [[ "${DRY_RUN}" = true ]]; then
            dry_notice "Would run: systemctl restart postfix dovecot"
        else
            systemctl restart postfix dovecot
            success "Services restarted with LAN access enabled."
        fi
    fi

    success "LAN configuration complete. Clients on ${subnet_input} can now connect."
}

# ------------------------------------------------------------------------------
# Action 7: Local User Management Helper
# ------------------------------------------------------------------------------
action_manage_users() {
    while true; do
        print_header "7. Local Mail User Account Management"

        printf "  ${C_BOLD}a)${C_RESET} List local user accounts & Maildir status\n" >&2
        printf "  ${C_BOLD}b)${C_RESET} Create a new local mail user\n" >&2
        printf "  ${C_BOLD}c)${C_RESET} Set or reset password for an existing mail user\n" >&2
        printf "  ${C_BOLD}d)${C_RESET} Remove / Delete a local mail user\n" >&2
        printf "  ${C_BOLD}e)${C_RESET} Return to main menu\n\n" >&2

        local sub_choice
        read -r -p "$(printf "${C_CYAN}Select an action [a-e]: ${C_RESET}")" sub_choice

        case "${sub_choice}" in
            a|A)
                info "Listing user accounts (UID >= 1000):"
                printf "%-15s %-8s %-25s %s\n" "Username" "UID" "Home Directory" "Maildir Status" >&2
                printf "%-15s %-8s %-25s %s\n" "--------" "---" "--------------" "--------------" >&2
                if [[ -f /etc/passwd ]]; then
                    awk -F: '$3 >= 1000 && $3 < 65000 {
                        maildir = $6 "/Maildir";
                        printf "%-15s %-8s %-25s ", $1, $3, $6;
                        system("if [ -d " maildir " ]; then echo \"Maildir Initialized\"; else echo \"Not Created Yet\"; fi");
                    }' /etc/passwd >&2
                else
                    warn "/etc/passwd not readable."
                fi
                printf "\n" >&2
                read -r -p "$(printf "${C_YELLOW}Press [Enter] to continue...${C_RESET}")" _
                ;;
            b|B)
                require_root_privileges "create user accounts" || continue
                local new_user
                read -r -p "$(printf "${C_CYAN}Enter new username to create: ${C_RESET}")" new_user
                if [[ ! "${new_user}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    error "Invalid username format. Must begin with lowercase letter or underscore."
                    continue
                fi
                if id "${new_user}" >/dev/null 2>&1; then
                    warn "User '${new_user}' already exists!"
                    continue
                fi
                if [[ "${DRY_RUN}" = true ]]; then
                    dry_notice "Would run: adduser --gecos '' ${new_user}"
                    dry_notice "Would initialize Maildir in /home/${new_user}/Maildir"
                else
                    adduser --gecos "" "${new_user}"
                    mkdir -p "/home/${new_user}/Maildir"/{cur,new,tmp}
                    chown -R "${new_user}:${new_user}" "/home/${new_user}/Maildir"
                    chmod -R 700 "/home/${new_user}/Maildir"
                    success "User '${new_user}' created and Maildir initialized successfully."
                fi
                ;;
            c|C)
                require_root_privileges "change user passwords" || continue
                local existing_user
                read -r -p "$(printf "${C_CYAN}Enter username to reset password: ${C_RESET}")" existing_user
                if ! id "${existing_user}" >/dev/null 2>&1; then
                    error "User '${existing_user}' does not exist!"
                    continue
                fi
                if [[ "${DRY_RUN}" = true ]]; then
                    dry_notice "Would run: passwd ${existing_user}"
                else
                    passwd "${existing_user}"
                    success "Password updated for '${existing_user}'."
                fi
                ;;
            d|D)
                require_root_privileges "remove user accounts" || continue
                local user_to_remove
                read -r -p "$(printf "${C_CYAN}Enter username to delete/remove: ${C_RESET}")" user_to_remove
                if ! id "${user_to_remove}" >/dev/null 2>&1; then
                    error "User '${user_to_remove}' does not exist!"
                    continue
                fi
                local target_uid
                target_uid="$(id -u "${user_to_remove}")"
                if (( target_uid < 1000 )); then
                    error "Refusing to delete system account '${user_to_remove}' (UID ${target_uid})!"
                    continue
                fi
                if [[ -n "${SUDO_USER:-}" && "${user_to_remove}" == "${SUDO_USER}" ]]; then
                    error "Refusing to delete currently active admin user '${user_to_remove}'!"
                    continue
                fi
                if confirm_action "Permanently delete user '${user_to_remove}' and their mailbox?"; then
                    if [[ "${DRY_RUN}" = true ]]; then
                        dry_notice "Would run: deluser --remove-home ${user_to_remove}"
                    else
                        if command -v deluser >/dev/null 2>&1; then
                            deluser --remove-home "${user_to_remove}" >/dev/null 2>&1 || userdel -r "${user_to_remove}" >/dev/null 2>&1
                        else
                            userdel -r "${user_to_remove}" >/dev/null 2>&1
                        fi
                        success "User '${user_to_remove}' and mailbox removed successfully."
                    fi
                else
                    info "User deletion cancelled."
                fi
                ;;
            e|E|q|Q)
                info "Returning to main menu."
                break
                ;;
            *)
                warn "Invalid selection. Please choose an option [a-e]."
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Action 8: Validate Configuration
# ------------------------------------------------------------------------------
action_validate_configuration() {
    print_header "8. Validate Server Configuration"

    info "Performing deep configuration checks..."

    if [[ -f "${POSTFIX_MAIN_CF}" ]] && grep -qF "${TAG_BEGIN}" "${POSTFIX_MAIN_CF}"; then
        success "Toolkit managed section detected in ${POSTFIX_MAIN_CF}."
    else
        warn "No toolkit-managed section in ${POSTFIX_MAIN_CF}."
    fi

    if [[ -f "${DOVECOT_CONF}" ]] && grep -qF "${TAG_BEGIN}" "${DOVECOT_CONF}"; then
        success "Toolkit managed section detected in ${DOVECOT_CONF}."
    else
        warn "No toolkit-managed section in ${DOVECOT_CONF}."
    fi

    validate_service_configs
}

# ------------------------------------------------------------------------------
# Action 9: Show Service Status and Listening Ports
# ------------------------------------------------------------------------------
action_service_status() {
    print_header "9. Service Status & Listening Ports"

    info "Checking core daemon states..."
    if command -v systemctl >/dev/null 2>&1; then
        for srv in postfix dovecot spamassassin; do
            if systemctl is-active --quiet "${srv}" 2>/dev/null; then
                printf "  * %-15s : ${C_GREEN}Active (Running)${C_RESET}\n" "${srv}" >&2
            else
                printf "  * %-15s : ${C_RED}Inactive / Stopped${C_RESET}\n" "${srv}" >&2
            fi
        done
    fi

    printf "\n" >&2
    info "Inspecting listening sockets for mail ports (25, 110, 143, 993, 995, 587)..."
    if command -v ss >/dev/null 2>&1; then
        local sockets
        sockets="$(ss -tulpn 2>/dev/null | grep -E ':(25|110|143|993|995|587)\b' || true)"
        if [[ -n "${sockets}" ]]; then
            printf "%s\n" "${sockets}" >&2
        else
            warn "No active mail listening sockets found."
        fi
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -E ':(25|110|143|993|995|587)\b' || warn "No active mail sockets."
    fi
}

# ------------------------------------------------------------------------------
# Action 10: Instructions for Testing SMTP, IMAP, POP3, TLS & Spam
# ------------------------------------------------------------------------------
action_test_instructions() {
    print_header "10. Comprehensive Protocol & Security Test Guide"

    cat <<'EOF' >&2
1. SMTP Sending Test (Port 25)
----------------------------------------------------------------------
Send an email from 'alice' to 'bob' via CLI:
  $ echo "Subject: Protocol Test
  Hello Bob, testing local SMTP." | sendmail -v bob@localhost

2. Mailbox Inspection (Maildir)
----------------------------------------------------------------------
View individual RFC 5322 message files:
  $ sudo ls -la ~bob/Maildir/new/
  $ sudo cat ~bob/Maildir/new/*

3. IMAP Protocol Retrieval (Port 143 / 993)
----------------------------------------------------------------------
Connect using netcat or openssl:
  $ nc 127.0.0.1 143
  * OK Dovecot ready.
  a1 LOGIN bob <password>
  a2 SELECT INBOX
  a3 FETCH 1 BODY[]
  a4 LOGOUT
Or with TLS:
  $ openssl s_client -connect 127.0.0.1:993 -quiet

4. POP3 Protocol Retrieval (Port 110 / 995)
----------------------------------------------------------------------
Connect to POP3 server:
  $ nc 127.0.0.1 110
  +OK Dovecot ready.
  USER bob
  +OK
  PASS <password>
  +OK Logged in.
  STAT
  +OK 1 540
  RETR 1
  QUIT
Or with POP3S (SSL):
  $ openssl s_client -connect 127.0.0.1:995 -quiet

5. SpamAssassin Filtering Verification
----------------------------------------------------------------------
Send the official GTUBE test spam string:
  $ echo "Subject: Spam Filter Test
  XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X" | sendmail -v bob@localhost
Verify that SpamAssassin injected the spam header:
  $ sudo grep -E 'X-Spam-Flag|X-Spam-Status' ~bob/Maildir/new/*
Expected Result:
  X-Spam-Flag: YES
  X-Spam-Status: Yes, score=1000.0 ...

6. Open Relay Penetration Test
----------------------------------------------------------------------
Attempt to relay to external domain:
  $ nc 127.0.0.1 25
  HELO localhost
  MAIL FROM:<alice@localhost>
  RCPT TO:<victim@google.com>
Expected Result:
  554 5.7.1 <victim@google.com>: Relay access denied
EOF
}

# ------------------------------------------------------------------------------
# Action 11: Remove Toolkit-Managed Configuration
# ------------------------------------------------------------------------------
action_remove_managed_config() {
    print_header "11. Remove Toolkit-Managed Configuration"

    require_root_privileges "remove mail configuration" || return 1

    printf "${C_YELLOW}${C_BOLD}CAUTION:${C_RESET}\n" >&2
    printf "  This action will strip only the configuration sections added by this toolkit\n" >&2
    printf "  marked with '%s'.\n" "${TAG_BEGIN}" >&2
    printf "  Base packages will NOT be purged, leaving your system clean.\n\n" >&2

    if ! confirm_action "Are you sure you want to remove all toolkit-managed settings?"; then
        warn "Removal aborted by user."
        return 0
    fi

    create_backup "${POSTFIX_MAIN_CF}" >/dev/null || true
    create_backup "${POSTFIX_MASTER_CF}" >/dev/null || true
    create_backup "${DOVECOT_CONF}" >/dev/null || true
    create_backup "${DOVECOT_MAIL_CF}" >/dev/null || true
    create_backup "${DOVECOT_AUTH_CF}" >/dev/null || true
    create_backup "${DOVECOT_SSL_CF}" >/dev/null || true

    remove_managed_block "${POSTFIX_MAIN_CF}"
    remove_managed_block "${POSTFIX_MASTER_CF}"
    remove_managed_block "${DOVECOT_CONF}"
    remove_managed_block "${DOVECOT_MAIL_CF}"
    remove_managed_block "${DOVECOT_AUTH_CF}"
    remove_managed_block "${DOVECOT_SSL_CF}"

    if validate_service_configs; then
        if confirm_action "Reload mail services now?" "Y"; then
            if [[ "${DRY_RUN}" = true ]]; then
                dry_notice "Would run: systemctl reload postfix dovecot"
            else
                systemctl reload postfix dovecot 2>/dev/null || systemctl restart postfix dovecot 2>/dev/null || true
                success "Services reloaded with clean configuration."
            fi
        fi
    fi

    success "Toolkit-managed settings successfully removed."
}

# ------------------------------------------------------------------------------
# Interactive Menu Loop
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        printf "\n${C_BLUE}${C_BOLD}======================================================================${C_RESET}\n" >&2
        printf "${C_BLUE}${C_BOLD}   Local Mail Server Setup and Management Toolkit (v%s)${C_RESET}\n" "${SCRIPT_VERSION}" >&2
        if [[ "${DRY_RUN}" = true ]]; then
            printf "${C_MAGENTA}${C_BOLD}   [ACTIVE MODE: DRY-RUN (Non-destructive simulation)]${C_RESET}\n" >&2
        fi
        printf "${C_BLUE}${C_BOLD}======================================================================${C_RESET}\n" >&2
        printf "  ${C_BOLD} 1)${C_RESET} Check prerequisites & installed packages\n" >&2
        printf "  ${C_BOLD} 2)${C_RESET} Install full mail suite (Postfix, Dovecot IMAP/POP3, SpamAssassin)\n" >&2
        printf "  ${C_BOLD} 3)${C_RESET} Configure local mail delivery (SMTP, IMAP, POP3, Maildir)\n" >&2
        printf "  ${C_BOLD} 4)${C_RESET} Configure TLS/SSL encryption (Self-signed cert, IMAPS, POP3S)\n" >&2
        printf "  ${C_BOLD} 5)${C_RESET} Configure SpamAssassin spam filtering\n" >&2
        printf "  ${C_BOLD} 6)${C_RESET} Configure trusted LAN subnet access (Optional)\n" >&2
        printf "  ${C_BOLD} 7)${C_RESET} Manage local mail user accounts (List / Add / Passwd)\n" >&2
        printf "  ${C_BOLD} 8)${C_RESET} Validate configuration (Postfix & Dovecot syntax)\n" >&2
        printf "  ${C_BOLD} 9)${C_RESET} Show service status & listening ports (25, 110, 143, 993, 995)\n" >&2
        printf "  ${C_BOLD}10)${C_RESET} Show testing guide (SMTP, IMAP, POP3, TLS, Spam)\n" >&2
        printf "  ${C_BOLD}11)${C_RESET} Remove toolkit-managed configuration\n" >&2
        printf "  ${C_BOLD}12)${C_RESET} Exit\n" >&2
        printf "${C_BLUE}----------------------------------------------------------------------${C_RESET}\n" >&2

        local choice
        read -r -p "$(printf "${C_CYAN}Select an option [1-12]: ${C_RESET}")" choice

        case "${choice}" in
            1) action_check_prerequisites ;;
            2) action_install_packages ;;
            3) action_configure_local ;;
            4) action_configure_ssl ;;
            5) action_configure_spamassassin ;;
            6) action_configure_lan ;;
            7) action_manage_users ;;
            8) action_validate_configuration ;;
            9) action_service_status ;;
            10) action_test_instructions ;;
            11) action_remove_managed_config ;;
            12|q|Q)
                info "Exiting Local Mail Server Toolkit. Goodbye."
                break
                ;;
            *)
                error "Invalid selection: '${choice}'. Please enter a number between 1 and 12."
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# ------------------------------------------------------------------------------
show_usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

A Bash toolkit for configuring and managing an educational local mail server
on Ubuntu supporting Postfix (SMTP), Dovecot (IMAP, POP3), TLS/SSL, and SpamAssassin.

OPTIONS:
  -h, --help               Display this help text and exit.
  -d, --dry-run            Simulate all operations without modifying system files or services.
  -y, --yes                Automatically answer 'yes' to confirmation prompts.
  -c, --check              Run prerequisites and package installation check.
  -s, --status             Show service status and listening ports.
  -v, --validate           Validate Postfix and Dovecot syntax.
      --install            Install full suite (postfix, dovecot IMAP/POP3, spamassassin).
      --configure-local    Configure local-only delivery (SMTP, IMAP, POP3, Maildir).
      --configure-ssl      Generate self-signed cert and configure TLS/SSL.
      --configure-spam     Configure SpamAssassin spam filtering in Postfix.
      --configure-lan CIDR Configure trusted LAN subnet access (e.g. 192.168.1.0/24).
      --list-users         List local user accounts and Maildir status.
      --test-guide         Print testing walkthrough for all protocols.
      --remove             Remove toolkit-managed configuration blocks.

EXAMPLES:
  Interactive menu:
    sudo ./${SCRIPT_NAME}

  Non-destructive dry-run check:
    ./${SCRIPT_NAME} --dry-run --check

  Automated local setup with SSL:
    sudo ./${SCRIPT_NAME} --configure-local --configure-ssl --yes
EOF
}

main() {
    local cli_action=""
    local lan_cidr=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -c|--check)
                cli_action="check"
                shift
                ;;
            -s|--status)
                cli_action="status"
                shift
                ;;
            -v|--validate)
                cli_action="validate"
                shift
                ;;
            --install)
                cli_action="install"
                shift
                ;;
            --configure-local)
                cli_action="configure_local"
                shift
                ;;
            --configure-ssl)
                cli_action="configure_ssl"
                shift
                ;;
            --configure-spam)
                cli_action="configure_spam"
                shift
                ;;
            --configure-lan)
                cli_action="configure_lan"
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    lan_cidr="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --list-users)
                cli_action="list_users"
                shift
                ;;
            --test-guide)
                cli_action="test_guide"
                shift
                ;;
            --remove)
                cli_action="remove"
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    init_environment

    if [[ -z "${cli_action}" ]]; then
        show_menu
    else
        case "${cli_action}" in
            check) action_check_prerequisites ;;
            status) action_service_status ;;
            validate) action_validate_configuration ;;
            install) action_install_packages ;;
            configure_local) action_configure_local ;;
            configure_ssl) action_configure_ssl ;;
            configure_spam) action_configure_spamassassin ;;
            configure_lan) action_configure_lan "${lan_cidr}" ;;
            list_users) action_manage_users ;;
            test_guide) action_test_instructions ;;
            remove) action_remove_managed_config ;;
        esac
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
