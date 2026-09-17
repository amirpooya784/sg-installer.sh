#!/usr/bin/env bash
#
#  SourceGuardian Loader Manager
#  ------------------------------------------------------------------
#  Safe, transactional installer / updater / remover for the
#  SourceGuardian PHP loader (ixed.*) on Linux hosting servers.
#
#  Supported panels : cPanel / WHM (EA-PHP, alt-php), DirectAdmin
#                     (CustomBuild php-fpm / LSPHP), plain servers
#  Supported webservers : Apache, Nginx + PHP-FPM, LiteSpeed, OpenLiteSpeed
#  Architectures    : x86_64, aarch64
#
#  Usage:
#      ./sg-installer.sh                 # interactive menu
#      ./sg-installer.sh --status
#      ./sg-installer.sh --install all -y
#      ./sg-installer.sh --install 8.1
#      ./sg-installer.sh --remove 8.1
#      ./sg-installer.sh --repair
#
#  NOTE: no `set -e` and no `pipefail`. A menu driven tool must never die
#  silently in the middle of a filesystem transaction; every step checks
#  its own status and rolls back on failure. (`cmd | grep -q` returns 141
#  on SIGPIPE, which under pipefail produced false "corrupt archive" errors.)
#
set -u

SG_VERSION="2.0.0"
SG_SELF_URL="${SG_SELF_URL:-}"          # raw URL for --self-update (optional)

SG_LOG_FILE="${SG_LOG_FILE:-/var/log/sourceguardian-manager.log}"
SG_CACHE_DIR="${SG_CACHE_DIR:-/var/cache/sourceguardian-manager}"
SG_BACKUP_ROOT="${SG_BACKUP_ROOT:-/var/backups/sourceguardian-manager}"
SG_INI_NAME="${SG_INI_NAME:-00-sourceguardian.ini}"

SG_ASSUME_YES=0
SG_TMP_DIR=""
SG_EXTRACT_DIR=""
SG_ARCHIVE=""
SG_TTY_FD=0
SG_RESTART_PENDING=0

# ══════════════════════════════════════════════════════════════════════
#  MODULE: ui  -- colours, banner, boxes, spinner, progress, tables
# ══════════════════════════════════════════════════════════════════════
sg_ui_init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${SG_COLOR:-1}" == 1 ]]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
        C_RED=$'\033[31m';  C_GRN=$'\033[32m';  C_YLW=$'\033[33m'
        C_BLU=$'\033[34m';  C_MAG=$'\033[35m';  C_CYN=$'\033[36m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""
        C_YLW=""; C_BLU=""; C_MAG=""; C_CYN=""
    fi
}

sg_ui_clear() { [[ -t 1 ]] && printf '\033[H\033[2J' || true; }

sg_ui_banner() {
    printf '%s%s' "$C_CYN" "$C_BOLD"
    cat <<'BANNER'
   ╔═══════════════════════════════════════════════════════════════╗
   ║   ███ SourceGuardian Loader Manager ███                       ║
   ║   cPanel / WHM  •  DirectAdmin  •  Standalone Linux           ║
   ╚═══════════════════════════════════════════════════════════════╝
BANNER
    printf '%s' "$C_RESET"
    printf '   %sv%s%s   %s%s%s   %spanel:%s %s   %sarch:%s %s\n\n' \
        "$C_DIM" "$SG_VERSION" "$C_RESET" \
        "$C_DIM" "$(date '+%Y-%m-%d %H:%M')" "$C_RESET" \
        "$C_DIM" "$C_RESET" "${SG_PANEL:-?}" \
        "$C_DIM" "$C_RESET" "${SG_ARCH:-?}"
}

sg_ui_title() {
    printf '\n%s%s▸ %s%s\n' "$C_CYN" "$C_BOLD" "$*" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' $(seq 1 68))" "$C_RESET"
}

sg_ui_kv()      { printf '   %s%-22s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }
sg_ui_info()    { printf '   %s•%s %s\n'  "$C_BLU" "$C_RESET" "$*"; }
sg_ui_ok()      { printf '   %s✔%s %s\n'  "$C_GRN" "$C_RESET" "$*"; }
sg_ui_warn()    { printf '   %s▲%s %s\n'  "$C_YLW" "$C_RESET" "$*"; }
sg_ui_err()     { printf '   %s✘%s %s\n'  "$C_RED" "$C_RESET" "$*" >&2; }
sg_ui_step()    { printf '   %s→%s %s\n'  "$C_MAG" "$C_RESET" "$*"; }

sg_ui_pause() {
    local _x
    [[ "$SG_ASSUME_YES" == 1 ]] && return 0
    printf '\n   %sEnter ↵ to continue...%s' "$C_DIM" "$C_RESET"
    read -r _x <&$SG_TTY_FD 2>/dev/null || true
    printf '\n'
}

SG_SPIN_PID=""
sg_spin_start() {
    local text="$1"
    if [[ ! -t 1 ]]; then printf '   • %s\n' "$text"; return 0; fi
    sg_spin_stop
    (
        local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 n=10
        while :; do
            printf '\r   %s%s%s %s' "$C_CYN" "${frames:i%n:1}" "$C_RESET" "$text"
            i=$((i + 1)); sleep 0.1
        done
    ) & SG_SPIN_PID=$!
    disown "$SG_SPIN_PID" 2>/dev/null || true
}

sg_spin_stop() {
    if [[ -n "$SG_SPIN_PID" ]]; then
        kill "$SG_SPIN_PID" >/dev/null 2>&1
        wait "$SG_SPIN_PID" 2>/dev/null
        SG_SPIN_PID=""
        [[ -t 1 ]] && printf '\r\033[K'
    fi
    return 0
}

# progress bar -- ALWAYS returns 0 (the old version returned 1 on every
# non-final call, which killed the script under `set -e`)
sg_progress() {
    local cur="$1" total="$2" label="$3" w=30 filled empty pct
    [[ -t 1 ]] || { printf '   • [%s/%s] %s\n' "$cur" "$total" "$label"; return 0; }
    (( total > 0 )) || total=1
    pct=$(( cur * 100 / total ))
    filled=$(( cur * w / total )); empty=$(( w - filled ))
    printf '\r   %s[%s%s]%s %3d%%  %-34.34s' "$C_CYN" \
        "$(printf '█%.0s' $(seq 1 $filled) 2>/dev/null)" \
        "$(printf '░%.0s' $(seq 1 $empty)  2>/dev/null)" \
        "$C_RESET" "$pct" "$label"
    (( cur >= total )) && printf '\n'
    return 0
}

# column widths -- separators are generated from them so they can never
# drift out of alignment again
SG_COLW=(5 4 15 17 32)

sg_tbl_line() {                 # sg_tbl_line LEFT MID RIGHT
    local left="$1" mid="$2" right="$3" out="" w seg first=1
    for w in "${SG_COLW[@]}"; do
        seg="$(printf '─%.0s' $(seq 1 $((w + 2))))"
        if (( first )); then out="$left$seg"; first=0; else out+="$mid$seg"; fi
    done
    printf '   %s%s%s%s\n' "$C_CYN" "$out" "$right" "$C_RESET"
}
sg_tbl_row() {                  # 5 cells; cell 4 must already be padded/coloured
    printf '   %s│%s %-*.*s %s│%s %-*.*s %s│%s %-*.*s %s│%s %s %s│%s %-*.*s %s│%s\n' \
        "$C_CYN" "$C_RESET" "${SG_COLW[0]}" "${SG_COLW[0]}" "$1" \
        "$C_CYN" "$C_RESET" "${SG_COLW[1]}" "${SG_COLW[1]}" "$2" \
        "$C_CYN" "$C_RESET" "${SG_COLW[2]}" "${SG_COLW[2]}" "$3" \
        "$C_CYN" "$C_RESET" "$4" \
        "$C_CYN" "$C_RESET" "${SG_COLW[4]}" "${SG_COLW[4]}" "$5" "$C_CYN" "$C_RESET"
}
sg_tbl_head() {
    sg_tbl_line '┌' '┬' '┐'
    sg_tbl_row "PHP" "TS" "LOADER" "$(printf '%-*.*s' "${SG_COLW[3]}" "${SG_COLW[3]}" 'STATUS')" "BINARY"
    sg_tbl_line '├' '┼' '┤'
}
sg_tbl_foot() { sg_tbl_line '└' '┴' '┘'; }
sg_tbl_cell() {                 # sg_tbl_cell COLOR TEXT -> padded to col 4 width
    printf '%s%-*.*s%s' "$1" "${SG_COLW[3]}" "${SG_COLW[3]}" "$2" "$C_RESET"
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: logger
# ══════════════════════════════════════════════════════════════════════
sg_log_init() {
    mkdir -p "$(dirname "$SG_LOG_FILE")" 2>/dev/null
    if ! touch "$SG_LOG_FILE" 2>/dev/null; then
        SG_LOG_FILE="/tmp/sourceguardian-manager.log"; touch "$SG_LOG_FILE" 2>/dev/null
    fi
    chmod 0600 "$SG_LOG_FILE" 2>/dev/null
    return 0
}
sg_log()   { printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" >>"$SG_LOG_FILE" 2>/dev/null; return 0; }
sg_info()  { sg_log INFO  "$*"; sg_ui_info "$*"; }
sg_ok()    { sg_log OK    "$*"; sg_ui_ok   "$*"; }
sg_warn()  { sg_log WARN  "$*"; sg_ui_warn "$*"; }
sg_err()   { sg_log ERROR "$*"; sg_ui_err  "$*"; }
sg_step()  { sg_log STEP  "$*"; sg_ui_step "$*"; }
sg_debug() { [[ "${SG_DEBUG:-0}" == 1 ]] && sg_log DEBUG "$*"; return 0; }

# ══════════════════════════════════════════════════════════════════════
#  MODULE: utils
# ══════════════════════════════════════════════════════════════════════
sg_has()       { command -v "$1" >/dev/null 2>&1; }
sg_is_root()   { [[ "$(id -u)" -eq 0 ]]; }
sg_realpath()  { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }
sg_timestamp() { date '+%Y%m%d-%H%M%S'; }
sg_trim()      { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
sg_slug()      { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
sg_tail()      { local n="$1" s="$2"; (( ${#s} > n )) && printf '…%s' "${s: -$((n-1))}" || printf '%s' "$s"; }

# stdin may be the script itself (curl | bash) -- always read from the tty
sg_tty_init() {
    SG_TTY_FD=0
    [[ -e /dev/tty ]] || return 0
    # braces keep the 2>/dev/null temporary; `exec 9<... 2>/dev/null` would
    # silence the shell's stderr for the rest of the run.
    if { exec 9</dev/tty; } 2>/dev/null; then SG_TTY_FD=9; fi
    return 0
}
sg_ask() {                       # sg_ask VAR "prompt"
    local __v="$1" __p="$2"
    printf '%s' "$__p"
    IFS= read -r "${__v?}" <&$SG_TTY_FD || return 1
}
sg_confirm() {
    local ans
    [[ "$SG_ASSUME_YES" == 1 ]] && return 0
    sg_ask ans "   ${C_YLW}?${C_RESET} ${1:-Continue?} [y/N]: " || return 1
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

sg_cleanup() {
    sg_spin_stop
    [[ -n "$SG_TMP_DIR" && -d "$SG_TMP_DIR" && "$SG_TMP_DIR" == /tmp/* ]] && rm -rf -- "$SG_TMP_DIR"
    [[ "$SG_TTY_FD" == 9 ]] && exec 9<&- 2>/dev/null
    printf '%s' "${C_RESET:-}"
    return 0
}

sg_require_root() {
    sg_is_root && return 0
    sg_ui_err "This tool must run as root (try: sudo $0)"; exit 1
}

sg_preflight() {
    (( ${BASH_VERSINFO[0]:-0} >= 4 )) || { printf 'Bash 4.0+ required.\n' >&2; exit 1; }
    sg_require_root
    SG_TMP_DIR="$(mktemp -d /tmp/sg-manager.XXXXXX)" || { printf 'Cannot create temp dir.\n' >&2; exit 1; }
    trap sg_cleanup EXIT
    trap 'sg_cleanup; exit 130' INT TERM HUP
    sg_tty_init
    sg_log_init
    local missing=()
    sg_has tar  || missing+=(tar)
    sg_has find || missing+=(find)
    sg_has awk  || missing+=(awk)
    sg_has sed  || missing+=(sed)
    { sg_has curl || sg_has wget; } || missing+=("curl or wget")
    if (( ${#missing[@]} )); then
        sg_ui_err "Missing required tool(s): ${missing[*]}"; exit 1
    fi
    return 0
}

# write a file atomically with an explicit mode (umask-proof)
sg_atomic_write() {
    local target="$1" mode="$2" content="$3" dir tmp
    dir="$(dirname "$target")"
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 0755 "$dir" 2>/dev/null
    tmp="$(mktemp "$dir/.sgtmp.XXXXXX")" || return 1
    printf '%s' "$content" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod "$mode" "$tmp" 2>/dev/null
    mv -f "$tmp" "$target"
}

sg_sha256() {
    if   sg_has sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif sg_has openssl;   then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else return 1; fi
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: detect  -- OS / arch / panel / web servers
# ══════════════════════════════════════════════════════════════════════
SG_OS_ID="unknown"; SG_OS_VER="unknown"; SG_PANEL="standalone"
SG_ARCH="unknown";  SG_ARCH_TAG="";      SG_WEB=()

sg_detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        SG_OS_ID="${ID:-unknown}"; SG_OS_VER="${VERSION_ID:-unknown}"
    fi
    case "$SG_OS_ID" in
        almalinux|rocky|centos|rhel|cloudlinux|ubuntu|debian) : ;;
        *) sg_log WARN "Untested OS: $SG_OS_ID $SG_OS_VER" ;;
    esac
    return 0
}

sg_detect_arch() {
    SG_ARCH="$(uname -m)"
    case "$SG_ARCH" in
        x86_64|amd64)  SG_ARCH_TAG="x86_64" ;;
        aarch64|arm64) SG_ARCH_TAG="aarch64" ;;
        i386|i686)     SG_ARCH_TAG="x86" ;;
        *) sg_err "Unsupported architecture: $SG_ARCH"; return 1 ;;
    esac
    return 0
}

sg_detect_panel() {
    if   [[ -x /usr/local/cpanel/cpanel ]];        then SG_PANEL="cpanel"
    elif [[ -d /usr/local/directadmin ]];          then SG_PANEL="directadmin"
    elif [[ -d /usr/local/psa ]];                  then SG_PANEL="plesk"
    else SG_PANEL="standalone"; fi
    return 0
}

sg_unit_exists() {
    local units
    sg_has systemctl || return 1
    units="$(systemctl list-unit-files "$1" 2>/dev/null)"
    [[ "$units" == *"$1"* ]] && return 0
    [[ -f "/etc/systemd/system/$1" || -f "/usr/lib/systemd/system/$1" || -f "/lib/systemd/system/$1" ]]
}

sg_detect_web() {
    SG_WEB=()
    { sg_has httpd || sg_has apache2 || sg_unit_exists httpd.service || sg_unit_exists apache2.service; } && SG_WEB+=(Apache)
    { sg_has nginx || sg_unit_exists nginx.service; } && SG_WEB+=(Nginx)
    if [[ -x /usr/local/lsws/bin/lswsctrl ]]; then
        if [[ -f /usr/local/lsws/PLAIN_CONF || -x /usr/local/lsws/bin/openlitespeed ]]; then
            SG_WEB+=(OpenLiteSpeed)
        else
            SG_WEB+=(LiteSpeed)
        fi
    fi
    (( ${#SG_WEB[@]} )) || SG_WEB+=(unknown)
    return 0
}

sg_detect_all() { sg_detect_os; sg_detect_arch || return 1; sg_detect_panel; sg_detect_web; }

sg_system_info() {
    sg_ui_title "System information"
    sg_ui_kv "Operating system" "$SG_OS_ID $SG_OS_VER"
    sg_ui_kv "Kernel"           "$(uname -r)"
    sg_ui_kv "Architecture"     "$SG_ARCH  (loader tag: $SG_ARCH_TAG)"
    sg_ui_kv "Control panel"    "$SG_PANEL"
    sg_ui_kv "Web server(s)"    "$(IFS=', '; echo "${SG_WEB[*]}")"
    sg_ui_kv "Hostname"         "$(hostname -f 2>/dev/null || hostname)"
    sg_ui_kv "Log file"         "$SG_LOG_FILE"
    sg_ui_kv "Cache dir"        "$SG_CACHE_DIR"
    sg_ui_kv "Backups"          "$SG_BACKUP_ROOT"
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: php  -- discovery + metadata
# ══════════════════════════════════════════════════════════════════════
SG_PHP=()                       # list of php binaries (deduped per install)
declare -A P_VER P_EXTDIR P_SCAN P_INI P_TS P_LOADER P_STATUS P_SGVER P_LABEL
SG_PHP_SCANNED=0

sg_php_probe() {                # cheap validity test
    "$1" -n -r 'exit(PHP_VERSION_ID > 0 ? 0 : 1);' >/dev/null 2>&1
}

sg_php_candidates() {
    local f
    {
        case "$SG_PANEL" in
            cpanel)
                printf '%s\n' /opt/cpanel/ea-php*/root/usr/bin/php
                printf '%s\n' /opt/alt/php*/usr/bin/php
                ;;
            directadmin)
                printf '%s\n' /usr/local/php*/bin/php
                printf '%s\n' /usr/local/php*/bin/lsphp
                ;;
            plesk)
                printf '%s\n' /opt/plesk/php/*/bin/php
                ;;
        esac
        printf '%s\n' /usr/local/lsws/lsphp*/bin/lsphp
        printf '%s\n' /usr/local/lsws/lsphp*/bin/php
        printf '%s\n' /opt/remi/php*/root/usr/bin/php
        printf '%s\n' /usr/bin/php /usr/bin/php[578].* /usr/local/bin/php
        sg_has php && command -v php
    } 2>/dev/null | while IFS= read -r f; do
        [[ -n "$f" && -x "$f" && ! -d "$f" && "$f" != *'*'* ]] && sg_realpath "$f"
    done | awk 'NF' | sort -u
}

# Read everything we need about one PHP install.
sg_php_meta() {
    local bin="$1" ini_out ver ext scan ini ts loader sgver
    ver="$("$bin" -n -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)"
    [[ -n "$ver" ]] || return 1

    # extension_dir: prefer the *effective* value (with php.ini loaded),
    # fall back to the compiled-in constant, and resolve relative values.
    ext="$("$bin" -d error_reporting=0 -d display_errors=0 \
            -r 'echo ini_get("extension_dir");' 2>/dev/null)"
    [[ "$ext" == /* ]] || ext="$("$bin" -n -r 'echo PHP_EXTENSION_DIR;' 2>/dev/null)"
    [[ "$ext" == /* ]] || return 1

    # --- the original script did NOT trim these; php --ini pads with spaces
    ini_out="$("$bin" --ini 2>/dev/null)"
    ini="$(sed -n 's/^Loaded Configuration File:[[:space:]]*//p'          <<<"$ini_out" | head -1)"
    scan="$(sed -n 's/^Scan for additional \.ini files in:[[:space:]]*//p' <<<"$ini_out" | head -1)"
    ini="$(sg_trim "$ini")"; scan="$(sg_trim "$scan")"
    [[ "$ini"  == "(none)" ]] && ini=""
    [[ "$scan" == "(none)" ]] && scan=""
    # if there is no scan dir we will write into the main php.ini instead
    if [[ -z "$scan" && -z "$ini" ]]; then
        ini="$("$bin" -n -r 'echo PHP_CONFIG_FILE_PATH;' 2>/dev/null)/php.ini"
    fi

    ts="$("$bin" -n -r 'echo PHP_ZTS ? "ZTS" : "NTS";' 2>/dev/null)"
    [[ -n "$ts" ]] || ts="NTS"
    if [[ "$ts" == ZTS ]]; then loader="ixed.${ver}ts.lin"; else loader="ixed.${ver}.lin"; fi

    sgver="$("$bin" -v 2>/dev/null | sed -n 's/.*SourceGuardian v\?\([0-9][0-9.]*\).*/\1/p' | head -1)"

    P_VER["$bin"]="$ver"; P_EXTDIR["$bin"]="$ext"; P_SCAN["$bin"]="$scan"
    P_INI["$bin"]="$ini"; P_TS["$bin"]="$ts";      P_LOADER["$bin"]="$loader"
    P_SGVER["$bin"]="${sgver:--}"
    P_LABEL["$bin"]="$bin"
    if sg_php_loaded "$bin"; then P_STATUS["$bin"]="active"; else P_STATUS["$bin"]="-"; fi
    return 0
}

sg_php_loaded() {
    local out
    "$1" -r 'exit(extension_loaded("sourceguardian") ? 0 : 1);' >/dev/null 2>&1 && return 0
    out="$("$1" -v 2>&1)"
    grep -qi 'sourceguardian' <<<"$out"
}

sg_php_discover() {
    local force="${1:-0}" bin i=0 total
    (( SG_PHP_SCANNED == 1 && force == 0 )) && return 0
    SG_PHP=()
    # `assoc=()` is not a reliable reset on bash 4.2 (CentOS 7) -> unset first
    unset P_VER P_EXTDIR P_SCAN P_INI P_TS P_LOADER P_STATUS P_SGVER P_LABEL
    declare -gA P_VER P_EXTDIR P_SCAN P_INI P_TS P_LOADER P_STATUS P_SGVER P_LABEL

    local -a cand=()
    while IFS= read -r bin; do [[ -n "$bin" ]] && cand+=("$bin"); done < <(sg_php_candidates)
    (( ${#cand[@]} )) || { sg_warn "No PHP installation found on this server."; return 1; }

    total=${#cand[@]}
    local -A seen=()
    for bin in "${cand[@]}"; do
        i=$((i + 1))
        sg_progress "$i" "$total" "inspecting $(sg_tail 32 "$bin")"
        sg_php_probe "$bin" || continue
        sg_php_meta  "$bin" || { sg_log WARN "Could not read metadata from $bin"; continue; }
        # two binaries sharing extension_dir + ini scan dir are ONE install
        local key="${P_EXTDIR[$bin]}|${P_SCAN[$bin]}|${P_INI[$bin]}"
        if [[ -n "${seen[$key]:-}" ]]; then
            sg_debug "skip duplicate install: $bin (same as ${seen[$key]})"
            continue
        fi
        seen["$key"]="$bin"
        SG_PHP+=("$bin")
    done
    sg_progress "$total" "$total" "done"
    (( ${#SG_PHP[@]} )) || { sg_warn "No usable PHP binary found."; return 1; }
    SG_PHP_SCANNED=1
    return 0
}

sg_php_by_version() {           # echoes matching binaries for "8.1"
    local want="$1" bin
    for bin in "${SG_PHP[@]}"; do
        [[ "${P_VER[$bin]}" == "$want" ]] && printf '%s\n' "$bin"
    done
}

sg_php_table() {
    sg_php_discover || return 1
    sg_ui_title "PHP installations & SourceGuardian status"
    sg_tbl_head
    local bin st
    for bin in "${SG_PHP[@]}"; do
        # printf padding cannot see through colour escapes -> pad first
        if [[ "${P_STATUS[$bin]}" == active ]]; then
            st="$(sg_tbl_cell "$C_GRN" "ACTIVE   v${P_SGVER[$bin]}")"
        else
            st="$(sg_tbl_cell "$C_DIM" "not installed")"
        fi
        local disp; disp="$(sg_tail "${SG_COLW[4]}" "$bin")"
        sg_tbl_row "${P_VER[$bin]}" "${P_TS[$bin]}" "${P_LOADER[$bin]}" "$st" "$disp"
    done
    sg_tbl_foot
    printf '   %sloader dir = extension_dir of each install; config = %s%s\n' \
        "$C_DIM" "$SG_INI_NAME" "$C_RESET"
    return 0
}

sg_php_select() {               # sets SG_TARGETS[]
    sg_php_discover || return 1
    local i=1 bin choice
    printf '\n'
    for bin in "${SG_PHP[@]}"; do
        printf '   %s%2d)%s PHP %-5s %-4s %s%s%s\n' "$C_BOLD" "$i" "$C_RESET" \
            "${P_VER[$bin]}" "${P_TS[$bin]}" "$C_DIM" "$bin" "$C_RESET"
        i=$((i + 1))
    done
    printf '   %s a)%s all versions\n   %s 0)%s cancel\n\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    sg_ask choice "   Select: " || return 1
    case "$choice" in
        a|A|all) SG_TARGETS=("${SG_PHP[@]}") ;;
        0|q|Q|"") return 1 ;;
        *)
            [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SG_PHP[@]} )) \
                || { sg_warn "Invalid selection."; return 1; }
            SG_TARGETS=("${SG_PHP[choice-1]}")
            ;;
    esac
    return 0
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: download  -- official loaders, POST terms=on (403 otherwise)
# ══════════════════════════════════════════════════════════════════════
SG_BASE_URL="${SG_BASE_URL:-https://www.sourceguardian.com/loaders/download}"
SG_UA="Mozilla/5.0 (X11; Linux x86_64) sg-installer/${SG_VERSION}"

sg_archive_name() { printf 'loaders.linux-%s.tar.gz' "$SG_ARCH_TAG"; }

sg_fetch() {                    # sg_fetch URL DEST
    local url="$1" dest="$2" rc=1
    rm -f "$dest.part"
    if sg_has curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
             -A "$SG_UA" -X POST -d 'terms=on' "$url" -o "$dest.part" 2>>"$SG_LOG_FILE"
        rc=$?
        if (( rc != 0 )); then      # some mirrors dislike POST -> plain GET
            curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 \
                 -A "$SG_UA" "$url" -o "$dest.part" 2>>"$SG_LOG_FILE"; rc=$?
        fi
    elif sg_has wget; then
        wget -q -O "$dest.part" -U "$SG_UA" --timeout=20 --tries=3 \
             --post-data='terms=on' "$url" 2>>"$SG_LOG_FILE"; rc=$?
        (( rc != 0 )) && { wget -q -O "$dest.part" -U "$SG_UA" --timeout=20 --tries=3 "$url" 2>>"$SG_LOG_FILE"; rc=$?; }
    fi
    (( rc == 0 )) && [[ -s "$dest.part" ]] || { rm -f "$dest.part"; return 1; }
    mv -f "$dest.part" "$dest"
}

sg_archive_valid() {
    local list
    [[ -s "$1" ]] || return 1
    list="$(tar -tzf "$1" 2>/dev/null)" || return 1
    [[ "$list" == *ixed.* ]] || return 1
    return 0
}

sg_download() {
    local force="${1:-0}" url
    mkdir -p "$SG_CACHE_DIR" 2>/dev/null; chmod 0755 "$SG_CACHE_DIR" 2>/dev/null
    SG_ARCHIVE="$SG_CACHE_DIR/$(sg_archive_name)"
    if (( force == 0 )) && sg_archive_valid "$SG_ARCHIVE"; then
        sg_ok "Using cached loader archive ($(du -h "$SG_ARCHIVE" | cut -f1))."
        return 0
    fi
    url="$SG_BASE_URL/$(sg_archive_name)"
    sg_spin_start "Downloading loaders from sourceguardian.com ..."
    sg_fetch "$url" "$SG_ARCHIVE"; local rc=$?
    sg_spin_stop
    if (( rc != 0 )); then
        sg_err "Download failed. Check outbound HTTPS / firewall."
        sg_ui_info "Manual fallback: download ${C_BOLD}$url${C_RESET}"
        sg_ui_info "and place it at: ${C_BOLD}$SG_ARCHIVE${C_RESET}, then re-run."
        return 1
    fi
    if ! sg_archive_valid "$SG_ARCHIVE"; then
        rm -f "$SG_ARCHIVE"
        sg_err "Downloaded file is not a valid loader archive (site may return an HTML page)."
        return 1
    fi
    sg_ok "Loader archive downloaded ($(du -h "$SG_ARCHIVE" | cut -f1))  sha256=$(sg_sha256 "$SG_ARCHIVE" | cut -c1-16)…"
    sg_log INFO "archive sha256 $(sg_sha256 "$SG_ARCHIVE")"
    return 0
}

sg_extract() {
    SG_EXTRACT_DIR="$SG_TMP_DIR/loaders"
    rm -rf "$SG_EXTRACT_DIR"; mkdir -p "$SG_EXTRACT_DIR" || return 1
    tar -xzf "$SG_ARCHIVE" -C "$SG_EXTRACT_DIR" 2>>"$SG_LOG_FILE" || { sg_err "Extraction failed."; return 1; }
    return 0
}

sg_find_loader() {              # sg_find_loader ixed.8.1.lin
    find "$SG_EXTRACT_DIR" -type f -name "$1" -print 2>/dev/null | head -1
}

sg_available_loaders() {
    find "$SG_EXTRACT_DIR" -type f -name 'ixed.*.lin' -printf '%f\n' 2>/dev/null | sort -V
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: backup / rollback  (manifest driven)
# ══════════════════════════════════════════════════════════════════════
SG_BK_DIR=""

sg_backup_open() {              # sg_backup_open BIN TAG
    local bin="$1" tag="$2"
    SG_BK_DIR="$SG_BACKUP_ROOT/$tag/php${P_VER[$bin]}-$(sg_slug "$bin")"
    mkdir -p "$SG_BK_DIR/files" || return 1
    : >"$SG_BK_DIR/manifest.tsv" || return 1
    printf '%s\n' "$bin" >"$SG_BK_DIR/php.path"
    sg_log INFO "backup dir $SG_BK_DIR"
    return 0
}

sg_backup_file() {              # record current state of a path
    local path="$1" name
    [[ -n "$SG_BK_DIR" ]] || return 1
    name="$(sg_slug "$path")"
    if [[ -e "$path" ]]; then
        cp -a "$path" "$SG_BK_DIR/files/$name" 2>/dev/null || return 1
        printf 'exists\t%s\t%s\n' "$path" "$name" >>"$SG_BK_DIR/manifest.tsv"
    else
        printf 'absent\t%s\t-\n' "$path" >>"$SG_BK_DIR/manifest.tsv"
    fi
    return 0
}

sg_rollback() {                 # sg_rollback [dir]
    local dir="${1:-$SG_BK_DIR}" state path name
    [[ -n "$dir" && -f "$dir/manifest.tsv" ]] || return 1
    while IFS=$'\t' read -r state path name; do
        [[ -n "$path" ]] || continue
        case "$state" in
            exists) mkdir -p "$(dirname "$path")" 2>/dev/null
                    cp -a "$SG_BK_DIR/files/$name" "$path" 2>/dev/null || \
                    cp -a "$dir/files/$name" "$path" 2>/dev/null ;;
            absent) rm -f "$path" ;;
        esac
    done < "$dir/manifest.tsv"
    sg_warn "Rolled back to the previous configuration."
    return 0
}

sg_backup_list() {
    sg_ui_title "Backup sets"
    local d n=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        n=$((n + 1))
        printf '   %s%-24s%s %s\n' "$C_BOLD" "$(basename "$d")" "$C_RESET" \
            "$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l) target(s)"
    done < <(find "$SG_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -20)
    (( n )) || sg_ui_info "No backups yet."
    return 0
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: ini  -- write / remove the loader directive
# ══════════════════════════════════════════════════════════════════════
SG_INI_BEGIN="; >>> sourceguardian-manager >>>"
SG_INI_END="; <<< sourceguardian-manager <<<"

# Where does the directive go for this install?
sg_ini_target() {               # echoes path ; mode = "dropin" | "main"
    local bin="$1"
    if [[ -n "${P_SCAN[$bin]}" ]]; then
        printf '%s/%s\n' "${P_SCAN[$bin]}" "$SG_INI_NAME"
    else
        printf '%s\n' "${P_INI[$bin]}"
    fi
}
sg_ini_mode() { [[ -n "${P_SCAN[$1]}" ]] && echo dropin || echo main; }

# Comment out any OTHER ixed/sourceguardian directive so PHP does not
# try to load two copies of the loader (fatal "already loaded" warning).
sg_ini_disable_conflicts() {
    local bin="$1" ours="$2" f
    local -a files=()
    if [[ -n "${P_SCAN[$bin]}" && -d "${P_SCAN[$bin]}" ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(
            grep -rlEi '^[[:space:]]*(zend_)?extension[[:space:]]*=.*(ixed|sourceguardian)' \
                 "${P_SCAN[$bin]}" 2>/dev/null)
    fi
    if [[ -f "${P_INI[$bin]}" ]] && grep -qEi '^[[:space:]]*(zend_)?extension[[:space:]]*=.*(ixed|sourceguardian)' "${P_INI[$bin]}" 2>/dev/null; then
        files+=("${P_INI[$bin]}")
    fi
    for f in "${files[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] || continue
        [[ "$(sg_realpath "$f")" == "$(sg_realpath "$ours")" ]] && continue
        sg_backup_file "$f"
        # NOTE: the s/// delimiter must not be '|' -- the regex itself uses
        # alternation, which silently broke the previous version.
        sed -i -E 's@^([[:space:]]*(zend_)?extension[[:space:]]*=.*(ixed\.|sourceguardian).*)$@; disabled by sourceguardian-manager: \1@I' "$f" 2>>"$SG_LOG_FILE"
        if grep -qE '^; disabled by sourceguardian-manager:' "$f" 2>/dev/null; then
            sg_warn "Disabled a conflicting loader line in $(basename "$f")"
        else
            sg_warn "Could not neutralise the loader line in $f -- check it manually."
        fi
    done
    return 0
}

sg_ini_write() {                # sg_ini_write BIN TARGET_PATH LOADER_FULL_PATH
    local bin="$1" target="$2" loader="$3" mode block
    mode="$(sg_ini_mode "$bin")"
    block="$SG_INI_BEGIN
; SourceGuardian loader for PHP ${P_VER[$bin]} (${P_TS[$bin]}) -- generated $(date '+%F %T')
; Managed automatically. Do not edit between these markers.
[SourceGuardian]
zend_extension=$loader
$SG_INI_END"

    sg_backup_file "$target"
    if [[ "$mode" == dropin ]]; then
        # a dedicated drop-in file: just (re)write it whole
        sg_atomic_write "$target" 0644 "$block"$'\n' || return 1
    else
        # no scan dir: append/replace a managed block inside php.ini
        local tmp="$SG_TMP_DIR/php.ini.new"
        if [[ -f "$target" ]]; then
            sed "/^${SG_INI_BEGIN//\//\\/}$/,/^${SG_INI_END//\//\\/}$/d" "$target" >"$tmp" 2>/dev/null || cp -a "$target" "$tmp"
        else
            : >"$tmp"
        fi
        printf '\n%s\n' "$block" >>"$tmp"
        sg_atomic_write "$target" 0644 "$(cat "$tmp")"$'\n' || return 1
    fi
    return 0
}

sg_ini_remove() {               # sg_ini_remove BIN TARGET_PATH
    local bin="$1" target="$2" mode tmp
    mode="$(sg_ini_mode "$bin")"
    [[ -e "$target" ]] || return 0
    sg_backup_file "$target"
    if [[ "$mode" == dropin ]]; then
        rm -f "$target"
    else
        tmp="$SG_TMP_DIR/php.ini.clean"
        sed "/^${SG_INI_BEGIN//\//\\/}$/,/^${SG_INI_END//\//\\/}$/d" "$target" >"$tmp" 2>/dev/null || return 1
        sg_atomic_write "$target" 0644 "$(cat "$tmp")"$'\n' || return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: restart  -- collect units once, restart once
# ══════════════════════════════════════════════════════════════════════
sg_restart_unit() {
    local u="$1"
    sg_unit_exists "$u" || return 0
    systemctl is-active "$u" >/dev/null 2>&1 || systemctl is-enabled "$u" >/dev/null 2>&1 || return 0
    if systemctl restart "$u" >>"$SG_LOG_FILE" 2>&1; then
        sg_log INFO "restarted $u"; printf '%s ' "$u"
    else
        sg_log WARN "failed to restart $u"
    fi
    return 0
}

sg_restart_services() {
    local done_units="" f
    sg_spin_start "Restarting web / PHP services ..."

    if sg_has systemctl; then
        case "$SG_PANEL" in
            cpanel)
                for f in /usr/lib/systemd/system/ea-php*-php-fpm.service \
                         /etc/systemd/system/ea-php*-php-fpm.service; do
                    [[ -e "$f" ]] && done_units+="$(sg_restart_unit "$(basename "$f")")"
                done
                done_units+="$(sg_restart_unit cpanel-php-fpm.service)"
                ;;
            directadmin)
                for f in /usr/lib/systemd/system/php-fpm*.service \
                         /etc/systemd/system/php-fpm*.service; do
                    [[ -e "$f" ]] && done_units+="$(sg_restart_unit "$(basename "$f")")"
                done
                ;;
            *)
                for f in /usr/lib/systemd/system/php*-fpm.service \
                         /usr/lib/systemd/system/php-fpm*.service \
                         /etc/systemd/system/php*-fpm.service; do
                    [[ -e "$f" ]] && done_units+="$(sg_restart_unit "$(basename "$f")")"
                done
                ;;
        esac
        for f in httpd.service apache2.service nginx.service lsws.service openlitespeed.service; do
            done_units+="$(sg_restart_unit "$f")"
        done
    fi

    # cPanel prefers its own service wrappers
    if [[ "$SG_PANEL" == cpanel ]]; then
        [[ -x /usr/local/cpanel/scripts/restartsrv_httpd ]] && \
            /usr/local/cpanel/scripts/restartsrv_httpd >>"$SG_LOG_FILE" 2>&1 && done_units+="restartsrv_httpd "
        [[ -x /usr/local/cpanel/scripts/restartsrv_apache_php_fpm ]] && \
            /usr/local/cpanel/scripts/restartsrv_apache_php_fpm >>"$SG_LOG_FILE" 2>&1 && done_units+="restartsrv_apache_php_fpm "
    fi

    # LiteSpeed / OpenLiteSpeed: reload + drop stale lsphp workers
    if [[ -x /usr/local/lsws/bin/lswsctrl ]]; then
        /usr/local/lsws/bin/lswsctrl restart >>"$SG_LOG_FILE" 2>&1 && done_units+="lswsctrl "
        pkill -9 -x lsphp        >/dev/null 2>&1
        pkill -9 -f '/lsphp'     >/dev/null 2>&1
    fi

    sg_spin_stop
    if [[ -n "$(sg_trim "$done_units")" ]]; then
        sg_ok "Restarted: $(sg_trim "$done_units")"
    else
        sg_warn "No service was restarted automatically -- restart your web server manually."
    fi
    SG_RESTART_PENDING=0
    return 0
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: install / remove / repair
# ══════════════════════════════════════════════════════════════════════
sg_verify() {                   # verify PHP still runs AND loader is active
    local bin="$1" out
    out="$("$bin" -v 2>&1)"
    if grep -qi 'failed loading\|unable to load dynamic library\|segmentation fault' <<<"$out"; then
        sg_log ERROR "verify: $out"; return 2
    fi
    "$bin" -r 'exit(0);' >/dev/null 2>&1 || { sg_log ERROR "verify: php cannot execute"; return 2; }
    grep -qi 'sourceguardian' <<<"$out" && return 0
    "$bin" -r 'exit(extension_loaded("sourceguardian") ? 0 : 1);' >/dev/null 2>&1
}

sg_install_one() {              # sg_install_one BIN TAG
    local bin="$1" tag="$2" src target ini_target rc
    sg_php_meta "$bin" || { sg_err "Cannot read PHP metadata for $bin"; return 1; }

    src="$(sg_find_loader "${P_LOADER[$bin]}")"
    if [[ -z "$src" || ! -f "$src" ]]; then
        sg_err "PHP ${P_VER[$bin]} (${P_TS[$bin]}): no ${P_LOADER[$bin]} in the official archive."
        sg_ui_info "Available: $(sg_available_loaders | tr '\n' ' ')"
        return 1
    fi

    target="${P_EXTDIR[$bin]}/${P_LOADER[$bin]}"
    ini_target="$(sg_ini_target "$bin")"

    sg_backup_open "$bin" "$tag" || { sg_err "Cannot create backup dir."; return 1; }
    sg_backup_file "$target"

    mkdir -p "${P_EXTDIR[$bin]}" 2>/dev/null; chmod 0755 "${P_EXTDIR[$bin]}" 2>/dev/null
    if [[ -n "${P_SCAN[$bin]}" ]]; then
        mkdir -p "${P_SCAN[$bin]}" 2>/dev/null; chmod 0755 "${P_SCAN[$bin]}" 2>/dev/null
    fi

    if ! install -m 0755 -o root -g root "$src" "$target" 2>>"$SG_LOG_FILE"; then
        sg_err "Could not copy loader to $target"; sg_rollback; return 1
    fi

    sg_ini_disable_conflicts "$bin" "$ini_target"
    if ! sg_ini_write "$bin" "$ini_target" "$target"; then
        sg_err "Could not write $ini_target"; sg_rollback; return 1
    fi

    sg_verify "$bin"; rc=$?
    if (( rc == 2 )); then
        sg_err "PHP ${P_VER[$bin]} became unstable -- rolling back."
        sg_rollback; return 1
    elif (( rc != 0 )); then
        sg_err "Loader installed but not reported by PHP ${P_VER[$bin]} -- rolling back."
        sg_rollback; return 1
    fi

    SG_RESTART_PENDING=1
    sg_php_meta "$bin"
    sg_ok "PHP ${P_VER[$bin]} ${P_TS[$bin]} → SourceGuardian ${P_SGVER[$bin]} (${P_LOADER[$bin]})"
    return 0
}

sg_remove_one() {               # sg_remove_one BIN TAG
    local bin="$1" tag="$2" target ini_target
    sg_php_meta "$bin" || return 1
    target="${P_EXTDIR[$bin]}/${P_LOADER[$bin]}"
    ini_target="$(sg_ini_target "$bin")"

    sg_backup_open "$bin" "$tag" || return 1
    sg_ini_remove "$bin" "$ini_target" || { sg_err "Cannot clean $ini_target"; sg_rollback; return 1; }
    sg_backup_file "$target"; rm -f "$target"

    if ! "$bin" -r 'exit(0);' >/dev/null 2>&1; then
        sg_err "PHP ${P_VER[$bin]} broke after removal -- rolling back."; sg_rollback; return 1
    fi
    SG_RESTART_PENDING=1
    if sg_php_loaded "$bin"; then
        sg_warn "PHP ${P_VER[$bin]}: still loaded -- another ini outside ${P_SCAN[$bin]:-php.ini} references it."
        return 1
    fi
    sg_ok "PHP ${P_VER[$bin]}: SourceGuardian removed."
    return 0
}

sg_needs_repair() {
    local bin="$1" target ini_target
    target="${P_EXTDIR[$bin]}/${P_LOADER[$bin]}"
    ini_target="$(sg_ini_target "$bin")"
    [[ -f "$target" ]] || return 0
    [[ "$(stat -c '%a' "$target" 2>/dev/null)" =~ ^(755|775|644)$ ]] || return 0
    [[ -f "$ini_target" ]] || return 0
    grep -qE "^[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*${target//\//\\/}" "$ini_target" 2>/dev/null || return 0
    sg_php_loaded "$bin" || return 0
    return 1
}

sg_run_targets() {              # sg_run_targets install|remove|repair BIN...
    local action="$1"; shift
    local -a targets=("$@")
    local tag bin i=0 ok=0 fail=0
    (( ${#targets[@]} )) || { sg_warn "No target selected."; return 1; }
    tag="$(sg_timestamp)"

    if [[ "$action" != remove ]]; then
        sg_download || return 1
        sg_extract  || return 1
    fi

    local verb
    case "$action" in
        install) verb="Installing" ;;
        remove)  verb="Removing" ;;
        repair)  verb="Repairing" ;;
        *)       verb="Processing" ;;
    esac
    sg_ui_title "$verb -- ${#targets[@]} PHP version(s)"
    for bin in "${targets[@]}"; do
        i=$((i + 1))
        printf '\n   %s[%d/%d] PHP %s%s %s(%s)%s\n' "$C_BOLD" "$i" "${#targets[@]}" \
            "${P_VER[$bin]}" "$C_RESET" "$C_DIM" "$bin" "$C_RESET"
        case "$action" in
            install) sg_install_one "$bin" "$tag" && ok=$((ok+1)) || fail=$((fail+1)) ;;
            remove)  sg_remove_one  "$bin" "$tag" && ok=$((ok+1)) || fail=$((fail+1)) ;;
            repair)
                if sg_needs_repair "$bin"; then
                    sg_step "Repairing ..."
                    sg_install_one "$bin" "$tag" && ok=$((ok+1)) || fail=$((fail+1))
                else
                    sg_ok "Healthy -- nothing to repair."; ok=$((ok+1))
                fi
                ;;
        esac
    done

    printf '\n'
    (( SG_RESTART_PENDING )) && sg_restart_services

    sg_ui_title "Result"
    printf '   %s✔ succeeded: %d%s      %s✘ failed: %d%s\n' \
        "$C_GRN" "$ok" "$C_RESET" "$( ((fail)) && echo "$C_RED" || echo "$C_DIM")" "$fail" "$C_RESET"
    sg_ui_info "Backup set: ${C_BOLD}$SG_BACKUP_ROOT/$tag${C_RESET}"
    if [[ "$SG_PANEL" == directadmin && "$action" != remove ]]; then
        sg_ui_info "Re-run this tool after any CustomBuild PHP rebuild -- it wipes extension_dir."
    elif [[ "$SG_PANEL" == cpanel && "$action" != remove ]]; then
        sg_ui_info "Re-run after EasyApache 4 rebuilds or new PHP version installs."
    fi
    SG_PHP_SCANNED=0
    (( fail == 0 ))
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: status / scan
# ══════════════════════════════════════════════════════════════════════
sg_scan() {
    sg_php_discover 1 || return 1
    local bin active=0 missing=0 orphan=0
    for bin in "${SG_PHP[@]}"; do
        [[ "${P_STATUS[$bin]}" == active ]] && active=$((active + 1))
        if [[ -f "${P_EXTDIR[$bin]}/${P_LOADER[$bin]}" ]]; then
            [[ "${P_STATUS[$bin]}" == active ]] || orphan=$((orphan + 1))
        else
            [[ "${P_STATUS[$bin]}" == active ]] && missing=$((missing + 1))
        fi
    done
    sg_ui_title "Server scan"
    sg_ui_kv "PHP installations"   "${#SG_PHP[@]}"
    sg_ui_kv "Loader active"       "$active"
    sg_ui_kv "Loader file present but inactive" "$orphan"
    sg_ui_kv "Active but file missing"          "$missing"
    sg_ui_kv "Backup sets"         "$(find "$SG_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    sg_php_table
    return 0
}

sg_view_log() {
    sg_ui_title "Last 60 log lines -- $SG_LOG_FILE"
    [[ -r "$SG_LOG_FILE" ]] && tail -n 60 "$SG_LOG_FILE" | sed 's/^/   /' || sg_ui_warn "No log yet."
    return 0
}

sg_self_update() {
    [[ -n "$SG_SELF_URL" ]] || { sg_warn "Set SG_SELF_URL=<raw url> to enable self-update."; return 1; }
    local tmp="$SG_TMP_DIR/new.sh"
    sg_spin_start "Fetching update ..."; sg_fetch "$SG_SELF_URL" "$tmp"; local rc=$?; sg_spin_stop
    (( rc == 0 )) || { sg_err "Download failed."; return 1; }
    bash -n "$tmp" 2>>"$SG_LOG_FILE" || { sg_err "Update failed syntax check -- ignored."; return 1; }
    if [[ -f "${BASH_SOURCE[0]}" && -w "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/* ]]; then
        install -m 0755 "$tmp" "${BASH_SOURCE[0]}" && sg_ok "Updated. Re-run the script."
    else
        sg_warn "Running from a stream -- cannot self-overwrite. Re-run the URL instead."
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════
#  MODULE: menu / cli
# ══════════════════════════════════════════════════════════════════════
SG_TARGETS=()

sg_menu() {
    local choice
    while :; do
        sg_ui_clear; sg_ui_banner
        printf '   %s%s INSTALL %s\n' "$C_BOLD" "$C_CYN" "$C_RESET"
        printf '     %s1%s  Install on ALL PHP versions\n'      "$C_BOLD" "$C_RESET"
        printf '     %s2%s  Install on a selected PHP version\n' "$C_BOLD" "$C_RESET"
        printf '     %s3%s  Update loaders (re-download + reinstall)\n' "$C_BOLD" "$C_RESET"
        printf '\n   %s%s MAINTAIN %s\n' "$C_BOLD" "$C_CYN" "$C_RESET"
        printf '     %s4%s  Repair broken installations\n'       "$C_BOLD" "$C_RESET"
        printf '     %s5%s  Remove SourceGuardian\n'             "$C_BOLD" "$C_RESET"
        printf '     %s6%s  Backup sets\n'                       "$C_BOLD" "$C_RESET"
        printf '\n   %s%s INSPECT %s\n' "$C_BOLD" "$C_CYN" "$C_RESET"
        printf '     %s7%s  PHP / loader status table\n'         "$C_BOLD" "$C_RESET"
        printf '     %s8%s  Full server scan\n'                  "$C_BOLD" "$C_RESET"
        printf '     %s9%s  System information\n'                "$C_BOLD" "$C_RESET"
        printf '    %s10%s  Download loader archive only\n'      "$C_BOLD" "$C_RESET"
        printf '    %s11%s  View log\n'                          "$C_BOLD" "$C_RESET"
        printf '    %s12%s  Self update\n'                       "$C_BOLD" "$C_RESET"
        printf '\n     %s0%s  Exit\n\n'                          "$C_BOLD" "$C_RESET"
        sg_ask choice "   ${C_CYN}❯${C_RESET} Select: " || return 0
        case "$(sg_trim "$choice")" in
            1) sg_php_discover && sg_run_targets install "${SG_PHP[@]}"; sg_ui_pause ;;
            2) if sg_php_select; then sg_run_targets install "${SG_TARGETS[@]}"; fi; sg_ui_pause ;;
            3) rm -f "$SG_CACHE_DIR/$(sg_archive_name)"
               sg_php_discover && sg_run_targets install "${SG_PHP[@]}"; sg_ui_pause ;;
            4) sg_php_discover && sg_run_targets repair "${SG_PHP[@]}"; sg_ui_pause ;;
            5) if sg_php_select; then
                   sg_confirm "Remove SourceGuardian from ${#SG_TARGETS[@]} target(s)?" && \
                       sg_run_targets remove "${SG_TARGETS[@]}"
               fi; sg_ui_pause ;;
            6) sg_backup_list; sg_ui_pause ;;
            7) sg_php_table; sg_ui_pause ;;
            8) sg_scan; sg_ui_pause ;;
            9) sg_system_info; sg_ui_pause ;;
            10) sg_download 1; sg_ui_pause ;;
            11) sg_view_log; sg_ui_pause ;;
            12) sg_self_update; sg_ui_pause ;;
            0|q|Q|exit) printf '\n   %sBye.%s\n\n' "$C_DIM" "$C_RESET"; return 0 ;;
            *) sg_ui_warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

sg_usage() {
    cat <<EOF
SourceGuardian Loader Manager v$SG_VERSION

  Usage: $0 [options]

    (no option)          interactive menu
    --status             show PHP / loader status table
    --scan               full server scan
    --install [VER|all]  install loader (e.g. --install 8.1, default: all)
    --remove  [VER|all]  remove loader
    --repair             repair broken / missing installations
    --download           only download + verify the loader archive
    --sysinfo            system information
    --log                show recent log lines
    --self-update        update this script (needs SG_SELF_URL)
    -y, --yes            assume "yes" for all prompts
    --no-color           disable colours
    -d, --debug          verbose logging
    -h, --help           this help
    -v, --version        version

  Env: SG_LOG_FILE SG_CACHE_DIR SG_BACKUP_ROOT SG_INI_NAME SG_BASE_URL SG_SELF_URL
EOF
}

sg_cli_targets() {              # resolve "all" | "8.1" into SG_TARGETS
    local want="${1:-all}"
    sg_php_discover || return 1
    if [[ "$want" == all ]]; then
        SG_TARGETS=("${SG_PHP[@]}"); return 0
    fi
    SG_TARGETS=()
    local b
    while IFS= read -r b; do [[ -n "$b" ]] && SG_TARGETS+=("$b"); done < <(sg_php_by_version "$want")
    (( ${#SG_TARGETS[@]} )) || { sg_err "No PHP $want found. Available: $(for b in "${SG_PHP[@]}"; do printf '%s ' "${P_VER[$b]}"; done)"; return 1; }
    return 0
}

main() {
    local action="" arg=""
    while (( $# )); do
        case "$1" in
            -h|--help)     sg_ui_init_colors; sg_usage; exit 0 ;;
            -v|--version)  printf '%s\n' "$SG_VERSION"; exit 0 ;;
            -y|--yes)      SG_ASSUME_YES=1 ;;
            -d|--debug)    SG_DEBUG=1 ;;
            --no-color)    SG_COLOR=0 ;;
            --status)      action=status ;;
            --scan)        action=scan ;;
            --repair)      action=repair ;;
            --download)    action=download ;;
            --sysinfo)     action=sysinfo ;;
            --log)         action=log ;;
            --self-update) action=selfupdate ;;
            --install)     action=install; [[ "${2:-}" =~ ^[^-] ]] && { arg="$2"; shift; } ;;
            --remove)      action=remove;  [[ "${2:-}" =~ ^[^-] ]] && { arg="$2"; shift; } ;;
            *) printf 'Unknown option: %s (use --help)\n' "$1" >&2; exit 2 ;;
        esac
        shift
    done

    sg_ui_init_colors
    sg_preflight
    sg_detect_all || exit 1
    sg_log INFO "start v$SG_VERSION panel=$SG_PANEL os=$SG_OS_ID $SG_OS_VER arch=$SG_ARCH action=${action:-menu}"

    case "$action" in
        "")         sg_menu ;;
        status)     sg_ui_banner; sg_php_table ;;
        scan)       sg_ui_banner; sg_scan ;;
        sysinfo)    sg_ui_banner; sg_system_info ;;
        log)        sg_view_log ;;
        download)   sg_ui_banner; sg_download 1 ;;
        selfupdate) sg_self_update ;;
        install)    sg_ui_banner; sg_cli_targets "${arg:-all}" && sg_run_targets install "${SG_TARGETS[@]}" ;;
        remove)     sg_ui_banner; sg_cli_targets "${arg:-all}" && sg_run_targets remove  "${SG_TARGETS[@]}" ;;
        repair)     sg_ui_banner; sg_php_discover && sg_run_targets repair "${SG_PHP[@]}" ;;
    esac
    exit $?
}

main "$@"
