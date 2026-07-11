#!/usr/bin/env bash
# Generated single-file build of SourceGuardian Loader Manager
set -Eeuo pipefail
IFS=$'\n\t'
SG_VERSION="1.0.0"
SG_PROJECT_URL="${SG_PROJECT_URL:-https://raw.githubusercontent.com/USERNAME/REPO/main/sg-installer.sh}"

# ===== module: ui =====
# Terminal user interface
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    SG_RESET=$'\033[0m'; SG_BOLD=$'\033[1m'; SG_DIM=$'\033[2m'
    SG_RED=$'\033[31m'; SG_GREEN=$'\033[32m'; SG_YELLOW=$'\033[33m'
    SG_BLUE=$'\033[34m'; SG_CYAN=$'\033[36m'; SG_WHITE=$'\033[37m'
else
    SG_RESET=""; SG_BOLD=""; SG_DIM=""; SG_RED=""; SG_GREEN=""
    SG_YELLOW=""; SG_BLUE=""; SG_CYAN=""; SG_WHITE=""
fi
SG_SPINNER_PID=""

sg_ui_banner() {
    printf '%s%s' "$SG_CYAN" "$SG_BOLD"
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════════╗
║        SourceGuardian Loader Manager for Linux Hosting Servers       ║
║          cPanel / WHM • DirectAdmin • Transactional Install          ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
    printf '%s' "$SG_RESET"
    printf '  %sVersion:%s %-10s %sLog:%s %s\n\n' "$SG_BOLD" "$SG_RESET" "$SG_VERSION" "$SG_BOLD" "$SG_RESET" "$SG_LOG_FILE"
}

sg_ui_info()    { printf '%sℹ%s %s\n' "$SG_BLUE" "$SG_RESET" "$*"; }
sg_ui_success() { printf '%s✓%s %s\n' "$SG_GREEN" "$SG_RESET" "$*"; }
sg_ui_warn()    { printf '%s⚠%s %s\n' "$SG_YELLOW" "$SG_RESET" "$*"; }
sg_ui_error()   { printf '%s✗%s %s\n' "$SG_RED" "$SG_RESET" "$*" >&2; }
sg_ui_title()   { printf '\n%s┌─ %s%s%s\n%s└─────────────────────────────────────────────────────────────────────%s\n' "$SG_CYAN" "$SG_BOLD" "$*" "$SG_RESET" "$SG_CYAN" "$SG_RESET"; }
sg_ui_pause()   { [[ -t 0 ]] && read -r -p "Press Enter to continue..." _ || true; }

sg_spinner_start() {
    local text="$1"
    [[ -t 1 ]] || { printf '• %s\n' "$text"; return 0; }
    sg_spinner_stop
    (
        local frames='|/-\\' i=0
        while :; do
            printf '\r%s[%s]%s %s' "$SG_CYAN" "${frames:i++%4:1}" "$SG_RESET" "$text"
            sleep 0.12
        done
    ) &
    SG_SPINNER_PID=$!
}

sg_spinner_stop() {
    if [[ -n "${SG_SPINNER_PID:-}" ]]; then
        kill "$SG_SPINNER_PID" 2>/dev/null || true
        wait "$SG_SPINNER_PID" 2>/dev/null || true
        SG_SPINNER_PID=""
        printf '\r\033[K' 2>/dev/null || true
    fi
}

sg_progress() {
    local current="$1" total="$2" label="$3" width=32 filled empty percent
    (( total > 0 )) || total=1
    percent=$((current * 100 / total)); filled=$((current * width / total)); empty=$((width-filled))
    printf '\r%s[%s%s]%s %3d%% %s' "$SG_CYAN" "$(printf '%*s' "$filled" '' | tr ' ' '█')" "$(printf '%*s' "$empty" '' | tr ' ' '░')" "$SG_RESET" "$percent" "$label"
    (( current >= total )) && printf '\n'
}

sg_table_line() { printf '%s+----------------+----------+------+----------------------+----------------------+----------+%s\n' "$SG_CYAN" "$SG_RESET"; }
sg_table_header() {
    sg_table_line
    printf '%s|%s %-14s %s|%s %-8s %s|%s %-4s %s|%s %-20s %s|%s %-20s %s|%s %-8s %s|%s\n' "$SG_CYAN" "$SG_RESET" PHP "$SG_CYAN" "$SG_RESET" Installed "$SG_CYAN" "$SG_RESET" TS "$SG_CYAN" "$SG_RESET" Extension "$SG_CYAN" "$SG_RESET" INI "$SG_CYAN" "$SG_RESET" Version "$SG_CYAN" "$SG_RESET"
    sg_table_line
}
sg_table_row() {
    printf '%s|%s %-14.14s %s|%s %-8.8s %s|%s %-4.4s %s|%s %-20.20s %s|%s %-20.20s %s|%s %-8.8s %s|%s\n' "$SG_CYAN" "$SG_RESET" "$1" "$SG_CYAN" "$SG_RESET" "$2" "$SG_CYAN" "$SG_RESET" "$3" "$SG_CYAN" "$SG_RESET" "$4" "$SG_CYAN" "$SG_RESET" "$5" "$SG_CYAN" "$SG_RESET" "$6" "$SG_CYAN" "$SG_RESET"
}

# ===== module: logger =====
# Logging subsystem
SG_LOG_FILE="${SG_LOG_FILE:-/var/log/sourceguardian-installer.log}"

sg_log_init() {
    local dir
    dir="$(dirname "$SG_LOG_FILE")"
    mkdir -p "$dir" 2>/dev/null || true
    touch "$SG_LOG_FILE" 2>/dev/null || SG_LOG_FILE="/tmp/sourceguardian-installer.log"
    chmod 0600 "$SG_LOG_FILE" 2>/dev/null || true
}

sg_log() {
    local level="$1"; shift
    local msg="$*"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >>"$SG_LOG_FILE" 2>/dev/null || true
}

sg_info()  { sg_log INFO "$*";  sg_ui_info "$*"; }
sg_warn()  { sg_log WARN "$*";  sg_ui_warn "$*"; }
sg_error() { sg_log ERROR "$*"; sg_ui_error "$*"; }
sg_debug() { [[ "${SG_DEBUG:-0}" == 1 ]] && sg_log DEBUG "$*" || true; }

# ===== module: utils =====
# Generic helpers and lifecycle
sg_has() { command -v "$1" >/dev/null 2>&1; }
sg_is_root() { [[ "$(id -u)" -eq 0 ]]; }
sg_trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
sg_realpath() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
sg_mkdir() { mkdir -p "$1" 2>/dev/null; }
sg_timestamp() { date '+%Y%m%d-%H%M%S'; }
sg_confirm() { local prompt="${1:-Continue?}" answer; [[ "${SG_ASSUME_YES:-0}" == 1 ]] && return 0; read -r -p "$prompt [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]]; }
sg_safe_rm() { [[ -n "${1:-}" && "$1" != / ]] && rm -rf -- "$1"; }
sg_join_by() { local d="$1"; shift; local first=1 x; for x in "$@"; do ((first)) || printf '%s' "$d"; printf '%s' "$x"; first=0; done; }

sg_cleanup() {
    sg_spinner_stop
    [[ -n "${SG_TMP_DIR:-}" && -d "${SG_TMP_DIR:-}" ]] && sg_safe_rm "$SG_TMP_DIR" || true
}

sg_die() { sg_error "$*"; return 1; }

sg_require_root() {
    sg_is_root || { sg_ui_error "Run this tool as root."; exit 1; }
}

sg_preflight() {
    (( BASH_VERSINFO[0] >= 4 )) || { printf 'Bash 4+ is required.\n' >&2; exit 1; }
    sg_require_root
    umask 077
    SG_TMP_DIR="$(mktemp -d /tmp/sg-installer.XXXXXX)" || exit 1
    trap sg_cleanup EXIT INT TERM HUP
    sg_log_init
    sg_has tar || { sg_error "tar is required."; exit 1; }
    sg_has sha256sum || sg_warn "sha256sum is unavailable; SHA-256 verification will be skipped unless openssl exists."
}

sg_atomic_write() {
    local target="$1" content="$2" dir tmp
    dir="$(dirname "$target")"; sg_mkdir "$dir" || return 1
    tmp="$(mktemp "$dir/.sg.XXXXXX")" || return 1
    printf '%s\n' "$content" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" || true
    mv -f "$tmp" "$target"
}

sg_sha256() {
    if sg_has sha256sum; then sha256sum "$1" | awk '{print $1}'
    elif sg_has openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
    fi
}

# ===== module: detect =====
# OS, panel, architecture and web server detection
SG_OS_ID="unknown"; SG_OS_VERSION="unknown"; SG_PANEL="none"; SG_ARCH="unknown"; SG_WEB_SERVERS=()

sg_detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        SG_OS_ID="${ID:-unknown}"; SG_OS_VERSION="${VERSION_ID:-unknown}"
    fi
    case "$SG_OS_ID" in almalinux|rocky|centos|ubuntu|debian) : ;; *) sg_warn "OS '$SG_OS_ID' is not officially tested." ;; esac
}

sg_detect_arch() {
    SG_ARCH="$(uname -m)"
    [[ "$SG_ARCH" == x86_64 ]] || sg_die "Only x86_64 is currently supported. Detected: $SG_ARCH"
}

sg_detect_panel() {
    if [[ -d /usr/local/cpanel && -x /usr/local/cpanel/cpanel ]]; then SG_PANEL="cpanel"
    elif [[ -d /usr/local/directadmin ]]; then SG_PANEL="directadmin"
    else SG_PANEL="none"
    fi
}

sg_service_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/$1" || -f "/usr/lib/systemd/system/$1" || -f "/lib/systemd/system/$1" ]]; }

sg_detect_web_servers() {
    SG_WEB_SERVERS=()
    if sg_has httpd || sg_has apache2 || sg_service_exists httpd.service || sg_service_exists apache2.service; then
        SG_WEB_SERVERS+=(Apache)
    fi
    if sg_has nginx || sg_service_exists nginx.service; then
        SG_WEB_SERVERS+=(Nginx)
    fi
    if [[ -x /usr/local/lsws/bin/lswsctrl ]]; then
        SG_WEB_SERVERS+=(LiteSpeed)
    elif [[ -x /usr/local/lsws/bin/openlitespeed ]] || sg_service_exists lsws.service || sg_service_exists openlitespeed.service; then
        SG_WEB_SERVERS+=(OpenLiteSpeed)
    fi
    ((${#SG_WEB_SERVERS[@]} > 0)) || SG_WEB_SERVERS+=(Unknown)
}

sg_detect_all() { sg_detect_os; sg_detect_arch || return 1; sg_detect_panel; sg_detect_web_servers; }

sg_system_info() {
    sg_ui_title "System Information"
    printf '  %-18s %s %s\n' OS "$SG_OS_ID" "$SG_OS_VERSION"
    printf '  %-18s %s\n' Architecture "$SG_ARCH"
    printf '  %-18s %s\n' 'Control panel' "$SG_PANEL"
    printf '  %-18s %s\n' 'Web server(s)' "$(sg_join_by ', ' "${SG_WEB_SERVERS[@]}")"
    printf '  %-18s %s\n' Kernel "$(uname -r)"
    printf '  %-18s %s\n' Hostname "$(hostname -f 2>/dev/null || hostname)"
}

# ===== module: php =====
# PHP discovery and metadata
SG_PHP_BINS=()
declare -A SG_PHP_VERSION SG_PHP_EXT_DIR SG_PHP_SCAN_DIR SG_PHP_TS SG_PHP_LOADER SG_PHP_STATUS SG_PHP_SG_VERSION SG_PHP_LOADED

sg_php_add() {
    local bin="$1" real
    [[ -x "$bin" ]] || return 0
    real="$(sg_realpath "$bin")"
    local x; for x in "${SG_PHP_BINS[@]}"; do [[ "$x" == "$real" ]] && return 0; done
    "$real" -n -r 'exit(PHP_VERSION_ID>0?0:1);' >/dev/null 2>&1 || return 0
    SG_PHP_BINS+=("$real")
}

sg_discover_php() {
    SG_PHP_BINS=()
    local f
    case "$SG_PANEL" in
        cpanel)
            for f in /opt/cpanel/ea-php*/root/usr/bin/php; do [[ -e "$f" ]] && sg_php_add "$f"; done
            ;;
        directadmin)
            for f in /usr/local/php*/bin/php /usr/local/php*/bin/php-cli /usr/local/php*/bin/lsphp; do [[ -e "$f" ]] && sg_php_add "$f"; done
            ;;
    esac
    sg_has php && sg_php_add "$(command -v php)"
    for f in /usr/bin/php* /usr/local/bin/php* /opt/remi/php*/root/usr/bin/php /usr/local/lsws/lsphp*/bin/php; do [[ -e "$f" ]] && sg_php_add "$f"; done
    mapfile -t SG_PHP_BINS < <(printf '%s\n' "${SG_PHP_BINS[@]}" | awk 'NF' | sort -u)
    ((${#SG_PHP_BINS[@]})) || return 1
    sg_php_collect_all
}

sg_php_collect() {
    local bin="$1" out ini scan ext ts loader status ver sgver loaded
    ver="$($bin -n -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;' 2>/dev/null || true)"
    [[ -n "$ver" ]] || return 1
    ext="$($bin -n -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
    out="$($bin --ini 2>/dev/null || true)"
    scan="$(awk -F': ' '/Scan for additional .ini files in/{print $2}' <<<"$out")"
    ini="$(awk -F': ' '/Loaded Configuration File/{print $2}' <<<"$out")"
    [[ -n "$scan" && "$scan" != '(none)' ]] || scan="$(dirname "${ini:-/etc/php.ini}")/conf.d"
    ts="$($bin -n -r 'echo PHP_ZTS ? "TS" : "NTS";' 2>/dev/null || echo NTS)"
    if [[ "$ts" == TS ]]; then loader="ixed.${ver}ts.lin"; else loader="ixed.${ver}.lin"; fi
    loaded="$($bin -m 2>/dev/null | paste -sd, - || true)"
    if "$bin" -r 'exit(extension_loaded("SourceGuardian") || extension_loaded("sourceguardian") ? 0 : 1);' >/dev/null 2>&1; then status=yes
    elif grep -qi sourceguardian <<<"$($bin -v 2>&1)"; then status=yes
    else status=no
    fi
    sgver="$($bin -r 'ob_start(); phpinfo(INFO_MODULES); $x=ob_get_clean(); if(preg_match("/SourceGuardian[^0-9]*([0-9]+(?:\\.[0-9]+)+)/i",$x,$m)) echo $m[1];' 2>/dev/null || true)"
    SG_PHP_VERSION["$bin"]="$ver"; SG_PHP_EXT_DIR["$bin"]="$ext"; SG_PHP_SCAN_DIR["$bin"]="$scan"
    SG_PHP_TS["$bin"]="$ts"; SG_PHP_LOADER["$bin"]="$loader"; SG_PHP_STATUS["$bin"]="$status"
    SG_PHP_SG_VERSION["$bin"]="${sgver:--}"; SG_PHP_LOADED["$bin"]="$loaded"
}

sg_php_collect_all() { local i=0 b total=${#SG_PHP_BINS[@]}; for b in "${SG_PHP_BINS[@]}"; do i=$((i + 1)); sg_progress "$i" "$total" "Inspecting $(basename "$b")"; sg_php_collect "$b" || sg_warn "Could not inspect $b"; done; }

sg_php_ini_file() { printf '%s/00-sourceguardian.ini' "${SG_PHP_SCAN_DIR[$1]}"; }

sg_php_status_table() {
    sg_discover_php || { sg_warn "No PHP installations found."; return 1; }
    sg_ui_title "PHP / SourceGuardian Status"
    sg_table_header
    local b
    for b in "${SG_PHP_BINS[@]}"; do
        sg_table_row "${SG_PHP_VERSION[$b]}" "${SG_PHP_STATUS[$b]}" "${SG_PHP_TS[$b]}" "${SG_PHP_LOADER[$b]}" "$(basename "$(sg_php_ini_file "$b")")" "${SG_PHP_SG_VERSION[$b]}"
    done
    sg_table_line
}

sg_php_select() {
    sg_discover_php || return 1
    local i=1 choice b
    for b in "${SG_PHP_BINS[@]}"; do printf '  %d) PHP %-6s %s\n' "$i" "${SG_PHP_VERSION[$b]}" "$b"; i=$((i + 1)); done
    read -r -p 'Select PHP: ' choice
    [[ "$choice" =~ ^[0-9]+$ && choice -ge 1 && choice -le ${#SG_PHP_BINS[@]} ]] || return 1
    SG_SELECTED_PHP="${SG_PHP_BINS[choice-1]}"
}

# ===== module: download =====
# Official loader download and integrity verification
SG_DOWNLOAD_URL="${SG_DOWNLOAD_URL:-https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz}"
SG_MD5_URL="${SG_MD5_URL:-${SG_DOWNLOAD_URL}.md5}"
SG_CACHE_DIR="${SG_CACHE_DIR:-/var/cache/sourceguardian-installer}"
SG_ARCHIVE="$SG_CACHE_DIR/loaders.linux-x86_64.tar.gz"

sg_fetch() {
    local url="$1" dest="$2"
    rm -f "$dest.part"
    if sg_has curl; then curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$dest.part"
    elif sg_has wget; then wget -O "$dest.part" --timeout=20 --tries=3 "$url"
    elif sg_has aria2c; then aria2c --allow-overwrite=true --auto-file-renaming=false -x4 -s4 -o "$(basename "$dest.part")" -d "$(dirname "$dest")" "$url"
    else return 127
    fi
    [[ -s "$dest.part" ]] || return 1
    mv -f "$dest.part" "$dest"
}

sg_verify_archive() {
    local archive="$1" expected actual md5file="$SG_TMP_DIR/archive.md5"
    tar -tzf "$archive" >/dev/null 2>&1 || return 1
    if sg_fetch "$SG_MD5_URL" "$md5file" >/dev/null 2>&1; then
        expected="$(grep -Eo '[a-fA-F0-9]{32}' "$md5file" | head -1 | tr 'A-F' 'a-f')"
        if [[ -n "$expected" ]]; then
            if sg_has md5sum; then actual="$(md5sum "$archive" | awk '{print $1}')"
            elif sg_has openssl; then actual="$(openssl dgst -md5 "$archive" | awk '{print $NF}')"
            else actual=""; fi
            [[ -z "$actual" || "$actual" == "$expected" ]] || return 1
        fi
    fi
    actual="$(sg_sha256 "$archive" 2>/dev/null || true)"
    [[ -n "$actual" ]] && sg_log INFO "Archive SHA256: $actual"
    return 0
}

sg_download_loader() {
    sg_mkdir "$SG_CACHE_DIR" || return 1
    if [[ -s "$SG_ARCHIVE" ]] && sg_verify_archive "$SG_ARCHIVE"; then sg_ui_success "Using verified cached loader archive."; return 0; fi
    sg_spinner_start "Downloading SourceGuardian loaders"
    if ! sg_fetch "$SG_DOWNLOAD_URL" "$SG_ARCHIVE"; then
        sg_spinner_stop; sg_error "Automatic download failed. Download manually and place it at: $SG_ARCHIVE"; return 1
    fi
    sg_spinner_stop
    sg_verify_archive "$SG_ARCHIVE" || { rm -f "$SG_ARCHIVE"; sg_error "Loader archive integrity verification failed."; return 1; }
    sg_ui_success "Loader archive downloaded and verified."
}

sg_extract_archive() {
    local dir="$SG_TMP_DIR/loaders"
    rm -rf "$dir"; mkdir -p "$dir" || return 1
    tar -xzf "$SG_ARCHIVE" -C "$dir" || return 1
    SG_EXTRACT_DIR="$dir"
}

# ===== module: backup =====
# Backup and rollback support
SG_BACKUP_ROOT="${SG_BACKUP_ROOT:-/var/backups/sourceguardian-installer}"

sg_backup_php() {
    local bin="$1" tag="${2:-$(sg_timestamp)}" dir loader ini
    dir="$SG_BACKUP_ROOT/$tag/$(echo "${SG_PHP_VERSION[$bin]}-$bin" | tr '/' '_')"
    mkdir -p "$dir" || return 1
    loader="${SG_PHP_EXT_DIR[$bin]}/${SG_PHP_LOADER[$bin]}"; ini="$(sg_php_ini_file "$bin")"
    [[ -e "$loader" ]] && cp -a "$loader" "$dir/loader.bak" || true
    [[ -e "$ini" ]] && cp -a "$ini" "$dir/ini.bak" || true
    printf '%s\n' "$loader" >"$dir/loader.path"; printf '%s\n' "$ini" >"$dir/ini.path"; printf '%s\n' "$bin" >"$dir/php.path"
    SG_LAST_BACKUP="$dir"; sg_log INFO "Backup created: $dir"
}

sg_rollback_php() {
    local dir="$1" loader ini
    [[ -d "$dir" ]] || return 1
    loader="$(cat "$dir/loader.path")"; ini="$(cat "$dir/ini.path")"
    if [[ -f "$dir/loader.bak" ]]; then cp -a "$dir/loader.bak" "$loader"; else rm -f "$loader"; fi
    if [[ -f "$dir/ini.bak" ]]; then mkdir -p "$(dirname "$ini")"; cp -a "$dir/ini.bak" "$ini"; else rm -f "$ini"; fi
    sg_warn "Rollback restored the previous PHP configuration."
}

# ===== module: restart =====
# Service discovery and safe restart
sg_restart_unit() { local u="$1"; systemctl is-enabled "$u" >/dev/null 2>&1 || systemctl is-active "$u" >/dev/null 2>&1 || return 0; systemctl restart "$u" >/dev/null 2>&1 && sg_log INFO "Restarted $u" || sg_warn "Could not restart $u"; }

sg_restart_services() {
    sg_has systemctl || { sg_warn "systemctl unavailable; restart services manually."; return 0; }
    local u
    case "$SG_PANEL" in
        cpanel)
            for u in httpd.service apache2.service cpanel-php-fpm.service; do sg_restart_unit "$u"; done
            for u in /usr/lib/systemd/system/ea-php*-php-fpm.service /etc/systemd/system/ea-php*-php-fpm.service; do [[ -e "$u" ]] && sg_restart_unit "$(basename "$u")"; done
            ;;
        directadmin)
            for u in php-fpm.service php-fpm*.service httpd.service apache2.service nginx.service lsws.service openlitespeed.service; do
                [[ "$u" == *'*'* ]] && { for u2 in /usr/lib/systemd/system/$u /etc/systemd/system/$u /lib/systemd/system/$u; do [[ -e "$u2" ]] && sg_restart_unit "$(basename "$u2")"; done; } || sg_restart_unit "$u"
            done
            ;;
        *) for u in php-fpm.service httpd.service apache2.service nginx.service lsws.service openlitespeed.service; do sg_restart_unit "$u"; done ;;
    esac
    [[ -x /usr/local/lsws/bin/lswsctrl ]] && /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
}

# ===== module: install =====
# Transactional installation and verification
sg_find_loader() { find "$SG_EXTRACT_DIR" -type f -name "$1" -print -quit 2>/dev/null; }

sg_verify_php() {
    local bin="$1"
    "$bin" -n -r 'echo "ok";' >/dev/null 2>&1 || return 1
    "$bin" -r 'exit(extension_loaded("SourceGuardian") || extension_loaded("sourceguardian") ? 0 : 1);' >/dev/null 2>&1 || grep -qi sourceguardian <<<"$($bin -v 2>&1)"
}

sg_install_php() {
    local bin="$1" source target ini backup_tag="$2" content
    sg_php_collect "$bin" || return 1
    source="$(sg_find_loader "${SG_PHP_LOADER[$bin]}")"
    [[ -f "$source" ]] || { sg_error "Loader ${SG_PHP_LOADER[$bin]} is unavailable for PHP ${SG_PHP_VERSION[$bin]}."; return 1; }
    target="${SG_PHP_EXT_DIR[$bin]}/${SG_PHP_LOADER[$bin]}"; ini="$(sg_php_ini_file "$bin")"
    sg_backup_php "$bin" "$backup_tag" || return 1
    mkdir -p "${SG_PHP_EXT_DIR[$bin]}" "${SG_PHP_SCAN_DIR[$bin]}" || return 1
    install -m 0755 "$source" "$target" || { sg_rollback_php "$SG_LAST_BACKUP"; return 1; }
    content="; Managed by SourceGuardian Loader Manager\nextension=${SG_PHP_LOADER[$bin]}"
    sg_atomic_write "$ini" "$content" || { sg_rollback_php "$SG_LAST_BACKUP"; return 1; }
    sg_restart_services
    if ! sg_verify_php "$bin"; then sg_error "PHP verification failed for $bin; rolling back."; sg_rollback_php "$SG_LAST_BACKUP"; sg_restart_services; return 1; fi
    sg_ui_success "SourceGuardian installed for PHP ${SG_PHP_VERSION[$bin]}."
}

sg_install_targets() {
    local mode="$1" tag b i=0 failures=0 targets=()
    sg_download_loader || return 1; sg_extract_archive || return 1; sg_discover_php || return 1
    if [[ "$mode" == selected ]]; then sg_php_select || return 1; targets=("$SG_SELECTED_PHP"); else targets=("${SG_PHP_BINS[@]}"); fi
    tag="$(sg_timestamp)"
    for b in "${targets[@]}"; do i=$((i + 1)); sg_progress "$i" "${#targets[@]}" "Installing PHP ${SG_PHP_VERSION[$b]}"; sg_install_php "$b" "$tag" || failures=$((failures + 1)); done
    ((failures == 0)) || { sg_warn "$failures installation(s) failed and were rolled back where necessary."; return 1; }
}

# ===== module: uninstall =====
# Safe removal
sg_remove_php() {
    local bin="$1" tag="$2" loader ini
    sg_php_collect "$bin" || return 1
    loader="${SG_PHP_EXT_DIR[$bin]}/${SG_PHP_LOADER[$bin]}"; ini="$(sg_php_ini_file "$bin")"
    sg_backup_php "$bin" "$tag" || return 1
    rm -f "$ini" "$loader" || { sg_rollback_php "$SG_LAST_BACKUP"; return 1; }
    sg_restart_services
    if sg_verify_php "$bin"; then sg_warn "SourceGuardian still appears loaded for PHP ${SG_PHP_VERSION[$bin]}; another INI may reference it."; return 1; fi
    sg_ui_success "SourceGuardian removed from PHP ${SG_PHP_VERSION[$bin]}."
}

sg_remove_all() {
    sg_discover_php || return 1
    sg_confirm "Remove SourceGuardian from all detected PHP versions?" || return 0
    local tag="$(sg_timestamp)" b failures=0
    for b in "${SG_PHP_BINS[@]}"; do sg_remove_php "$b" "$tag" || failures=$((failures + 1)); done
    ((failures == 0))
}

# ===== module: repair =====
# Repair missing loader, broken INI and permissions
sg_repair_php() {
    local bin="$1" loader ini need=0
    sg_php_collect "$bin" || return 1
    loader="${SG_PHP_EXT_DIR[$bin]}/${SG_PHP_LOADER[$bin]}"; ini="$(sg_php_ini_file "$bin")"
    [[ -f "$loader" ]] || need=1
    [[ -r "$ini" ]] || need=1
    [[ -f "$ini" ]] && grep -Eq "^[[:space:]]*(zend_)?extension[[:space:]]*=[[:space:]]*${SG_PHP_LOADER[$bin]}" "$ini" || need=1
    [[ -f "$loader" && "$(stat -c '%a' "$loader" 2>/dev/null)" =~ ^(755|750|644)$ ]] || need=1
    sg_verify_php "$bin" || need=1
    ((need)) || { sg_ui_success "PHP ${SG_PHP_VERSION[$bin]} requires no repair."; return 0; }
    sg_install_php "$bin" "repair-$(sg_timestamp)"
}

sg_repair_all() { sg_download_loader || return 1; sg_extract_archive || return 1; sg_discover_php || return 1; local b failures=0; for b in "${SG_PHP_BINS[@]}"; do sg_repair_php "$b" || failures=$((failures + 1)); done; ((failures == 0)); }

# ===== module: status =====
# Scan and status reporting
sg_scan_server() {
    sg_ui_title "Server Scan"
    sg_discover_php || { sg_warn "No PHP installations detected."; return 1; }
    printf '  Detected PHP installations: %s\n' "${#SG_PHP_BINS[@]}"
    local b refs=0 missing=0
    for b in "${SG_PHP_BINS[@]}"; do
        [[ "${SG_PHP_STATUS[$b]}" == yes ]] && refs=$((refs + 1))
        [[ -f "${SG_PHP_EXT_DIR[$b]}/${SG_PHP_LOADER[$b]}" ]] || missing=$((missing + 1))
    done
    printf '  Active SourceGuardian loaders: %s\n' "$refs"
    printf '  Missing expected loader files: %s\n' "$missing"
    printf '  Backup sets: %s\n' "$(find "$SG_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    sg_php_status_table
}

sg_view_log() { sg_ui_title "Installer Log"; [[ -r "$SG_LOG_FILE" ]] && tail -n 200 "$SG_LOG_FILE" || sg_warn "Log file is unavailable."; }

# ===== module: menu =====
# Interactive menu
sg_main_menu() {
    local choice
    while :; do
        sg_ui_banner
        printf '  1) Install SourceGuardian on ALL PHP Versions\n'
        printf '  2) Install on Selected PHP Version\n'
        printf '  3) Update SourceGuardian\n'
        printf '  4) Remove SourceGuardian\n'
        printf '  5) Repair Installation\n'
        printf '  6) PHP Status\n'
        printf '  7) Scan Server\n'
        printf '  8) Download Loader\n'
        printf '  9) View Log\n'
        printf ' 10) System Information\n'
        printf ' 11) Self Update\n'
        printf '  0) Exit\n\n'
        read -r -p 'Select an option: ' choice
        case "$choice" in
            1) sg_install_targets all; sg_ui_pause ;;
            2) sg_install_targets selected; sg_ui_pause ;;
            3) rm -f "$SG_ARCHIVE"; sg_install_targets all; sg_ui_pause ;;
            4) sg_remove_all; sg_ui_pause ;;
            5) sg_repair_all; sg_ui_pause ;;
            6) sg_php_status_table; sg_ui_pause ;;
            7) sg_scan_server; sg_ui_pause ;;
            8) sg_download_loader; sg_ui_pause ;;
            9) sg_view_log; sg_ui_pause ;;
            10) sg_system_info; sg_ui_pause ;;
            11) sg_self_update; sg_ui_pause ;;
            0) return 0 ;;
            *) sg_ui_warn "Invalid selection."; sleep 1 ;;
        esac
    done
}

sg_self_update() {
    [[ "$SG_PROJECT_URL" == *USERNAME/REPO* ]] && { sg_warn "Set SG_PROJECT_URL to your GitHub raw URL before using self-update."; return 1; }
    local tmp="$SG_TMP_DIR/sg-installer.new"
    sg_fetch "$SG_PROJECT_URL" "$tmp" || return 1
    bash -n "$tmp" || { sg_error "Downloaded update failed syntax validation."; return 1; }
    if [[ -f "${BASH_SOURCE[0]}" && -w "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* ]]; then
        install -m 0755 "$tmp" "${BASH_SOURCE[0]}"; sg_ui_success "Updated successfully."
    else
        sg_warn "Streamed execution cannot overwrite itself. Run the new raw URL again."
    fi
}
main() { sg_preflight; sg_detect_all; sg_log INFO "Started SourceGuardian Manager $SG_VERSION panel=$SG_PANEL os=$SG_OS_ID"; sg_main_menu; }
main "$@"
