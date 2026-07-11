cat > sg-installer-menu.sh <<'EOF'
#!/bin/bash

set -u
set -o pipefail

APP_NAME="SourceGuardian Loader Installer"
BASE_DIR="/root/sourceguardian-installer"
DOWNLOAD_DIR="$BASE_DIR/downloads"
EXTRACT_DIR="$BASE_DIR/extracted"
BACKUP_BASE="$BASE_DIR/backups"
LOG_DIR="$BASE_DIR/logs"

TS="$(date +%F-%H%M%S)"
RUN_BACKUP_DIR="$BACKUP_BASE/$TS"
LOG_FILE="$LOG_DIR/run-$TS.log"

OFFICIAL_TGZ_URL="https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz"
OFFICIAL_ZIP_URL="https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.zip"
SOURCEGUARDIAN_PAGE="https://www.sourceguardian.com/loaders.html"

LOADER_ARCHIVE=""

MANUAL_FILES=(
  "/root/loaders.tar.gz"
  "/root/loaders.linux-x86_64.tar.gz"
  "/root/loaders.zip"
  "/root/loaders.linux-x86_64.zip"
)

SUPPORTED_VERSIONS=(
  "7.4"
  "8.0"
  "8.1"
  "8.2"
  "8.3"
  "8.4"
)

ARCH="$(uname -m)"

log() {
    echo "$*"
}

info() {
    echo "[INFO] $*"
}

ok() {
    echo "[OK] $*"
}

warn() {
    echo "[WARN] $*"
}

err() {
    echo "[ERROR] $*" >&2
}

line() {
    echo "============================================================"
}

small_line() {
    echo "------------------------------------------------------------"
}

pause_screen() {
    echo
    read -r -p "Press Enter to continue..."
}

prepare_dirs() {
    mkdir -p "$BASE_DIR" "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$BACKUP_BASE" "$LOG_DIR"
}

start_log() {
    prepare_dirs
    exec > >(tee -a "$LOG_FILE") 2>&1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root."
        exit 1
    fi
}

check_arch() {
    if [ "$ARCH" != "x86_64" ]; then
        err "This script is prepared for Linux x86_64 only."
        err "Detected architecture: $ARCH"
        err "For another architecture, download the correct SourceGuardian loader manually."
        exit 1
    fi
}

need_command() {
    command -v "$1" >/dev/null 2>&1
}

check_basic_tools() {
    local missing=0

    for c in awk grep sed find sort head date tar du; do
        if ! need_command "$c"; then
            err "Required command not found: $c"
            missing=1
        fi
    done

    if [ "$missing" = "1" ]; then
        err "Missing required system tools. Please install them first."
        exit 1
    fi
}

php_compact_version() {
    echo "$1" | tr -d "."
}

php_bin_for_version() {
    local ver="$1"
    local compact
    compact="$(php_compact_version "$ver")"
    echo "/usr/local/php${compact}/bin/php"
}

php_version_from_bin() {
    local php_bin="$1"
    "$php_bin" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
}

php_full_version_from_bin() {
    local php_bin="$1"
    "$php_bin" -r 'echo PHP_VERSION;' 2>/dev/null
}

php_thread_safety() {
    local php_bin="$1"
    local zts

    zts="$("$php_bin" -i 2>/dev/null | awk -F'=> ' '/^Thread Safety/ {print tolower($2); exit}')"

    if echo "$zts" | grep -qi "enabled"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

loader_name_for_php() {
    local php_bin="$1"
    local ver="$2"
    local ts_state

    ts_state="$(php_thread_safety "$php_bin")"

    if [ "$ts_state" = "enabled" ]; then
        echo "ixed.${ver}ts.lin"
    else
        echo "ixed.${ver}.lin"
    fi
}

extension_dir_from_bin() {
    local php_bin="$1"
    "$php_bin" -r 'echo ini_get("extension_dir");' 2>/dev/null
}

scan_dir_from_bin() {
    local php_bin="$1"
    local scan_dir ver compact

    scan_dir="$("$php_bin" --ini 2>/dev/null | awk -F': ' '/Scan for additional .ini files in/ {print $2; exit}')"

    if [ -z "$scan_dir" ] || [ "$scan_dir" = "(none)" ]; then
        ver="$(php_version_from_bin "$php_bin")"
        compact="$(php_compact_version "$ver")"
        scan_dir="/usr/local/php${compact}/lib/php.conf.d"
    fi

    echo "$scan_dir"
}

ini_file_for_php() {
    local php_bin="$1"
    local scan_dir

    scan_dir="$(scan_dir_from_bin "$php_bin")"
    echo "$scan_dir/00-sourceguardian.ini"
}

sourceguardian_loaded() {
    local php_bin="$1"

    if "$php_bin" -m 2>/dev/null | grep -qi '^SourceGuardian$'; then
        return 0
    fi

    if "$php_bin" -v 2>/dev/null | grep -qi 'SourceGuardian'; then
        return 0
    fi

    if "$php_bin" -i 2>/dev/null | grep -qi 'SourceGuardian'; then
        return 0
    fi

    return 1
}

sourceguardian_version() {
    local php_bin="$1"
    local output version

    output="$("$php_bin" -v 2>/dev/null | grep -i 'SourceGuardian' | head -n 1)"
    version="$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"

    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "-"
    fi
}

human_size() {
    local file="$1"

    if [ -f "$file" ]; then
        du -h "$file" 2>/dev/null | awk '{print $1}'
    else
        echo "-"
    fi
}

valid_archive() {
    local file="$1"

    [ -s "$file" ] || return 1

    if echo "$file" | grep -qi '\.zip$'; then
        need_command unzip || return 1
        unzip -t "$file" >/dev/null 2>&1
        return $?
    fi

    tar -tzf "$file" >/dev/null 2>&1
}

clean_failed_file() {
    local file="$1"

    if [ -f "$file" ] && ! valid_archive "$file"; then
        rm -f "$file"
    fi
}

download_with_curl_fast() {
    local url="$1"
    local out="$2"
    local tmp="${out}.part"

    need_command curl || return 1

    rm -f "$tmp"

    info "Trying curl download..."

    curl \
        --fail \
        --location \
        --http1.1 \
        --compressed \
        --retry 4 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 180 \
        --speed-time 20 \
        --speed-limit 2048 \
        --silent \
        --show-error \
        --output "$tmp" \
        --user-agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36" \
        --referer "$SOURCEGUARDIAN_PAGE" \
        --header "Accept: application/x-gzip, application/gzip, application/octet-stream, */*" \
        --header "Accept-Language: en-US,en;q=0.9" \
        --header "Cache-Control: no-cache" \
        "$url" || {
            rm -f "$tmp"
            return 1
        }

    if valid_archive "$tmp"; then
        mv -f "$tmp" "$out"
        ok "Downloaded with curl: $out ($(human_size "$out"))"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

download_with_aria2_fast() {
    local url="$1"
    local out="$2"
    local dir name

    need_command aria2c || return 1

    dir="$(dirname "$out")"
    name="$(basename "$out")"

    rm -f "$out" "$out.aria2"

    info "Trying aria2c download..."

    aria2c \
        --allow-overwrite=true \
        --auto-file-renaming=false \
        --continue=false \
        --max-connection-per-server=4 \
        --split=4 \
        --min-split-size=256K \
        --connect-timeout=15 \
        --timeout=30 \
        --max-tries=4 \
        --retry-wait=2 \
        --summary-interval=0 \
        --console-log-level=warn \
        --download-result=hide \
        --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36" \
        --referer="$SOURCEGUARDIAN_PAGE" \
        --header="Accept: application/x-gzip, application/gzip, application/octet-stream, */*" \
        --header="Accept-Language: en-US,en;q=0.9" \
        --dir="$dir" \
        --out="$name" \
        "$url" || {
            rm -f "$out" "$out.aria2"
            return 1
        }

    if valid_archive "$out"; then
        ok "Downloaded with aria2c: $out ($(human_size "$out"))"
        return 0
    fi

    rm -f "$out" "$out.aria2"
    return 1
}

download_with_wget_clean() {
    local url="$1"
    local out="$2"
    local tmp="${out}.part"

    need_command wget || return 1

    rm -f "$tmp"

    info "Trying wget download..."

    wget \
        --tries=4 \
        --timeout=30 \
        --dns-timeout=15 \
        --connect-timeout=15 \
        --read-timeout=30 \
        --no-cache \
        --quiet \
        --show-progress \
        --progress=bar:force:noscroll \
        --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36" \
        --referer="$SOURCEGUARDIAN_PAGE" \
        --header="Accept: application/x-gzip, application/gzip, application/octet-stream, */*" \
        --header="Accept-Language: en-US,en;q=0.9" \
        -O "$tmp" \
        "$url" || {
            rm -f "$tmp"
            return 1
        }

    if valid_archive "$tmp"; then
        mv -f "$tmp" "$out"
        ok "Downloaded with wget: $out ($(human_size "$out"))"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

copy_manual_archive() {
    local out="$1"
    local f

    for f in "${MANUAL_FILES[@]}"; do
        if [ -s "$f" ]; then
            info "Trying manual archive: $f"

            if valid_archive "$f"; then
                cp -f "$f" "$out"
                ok "Manual archive accepted: $out ($(human_size "$out"))"
                return 0
            fi

            warn "Manual archive exists but is not valid: $f"
        fi
    done

    return 1
}

get_loader_archive() {
    mkdir -p "$DOWNLOAD_DIR"

    local tgz="$DOWNLOAD_DIR/loaders.linux-x86_64.tar.gz"
    local zip="$DOWNLOAD_DIR/loaders.linux-x86_64.zip"

    LOADER_ARCHIVE=""

    clean_failed_file "$tgz"
    clean_failed_file "$zip"

    if [ -s "$tgz" ] && valid_archive "$tgz"; then
        LOADER_ARCHIVE="$tgz"
        ok "Using cached archive: $LOADER_ARCHIVE ($(human_size "$LOADER_ARCHIVE"))"
        return 0
    fi

    if [ -s "$zip" ] && valid_archive "$zip"; then
        LOADER_ARCHIVE="$zip"
        ok "Using cached archive: $LOADER_ARCHIVE ($(human_size "$LOADER_ARCHIVE"))"
        return 0
    fi

    echo
    info "Downloading SourceGuardian loader archive..."
    info "Download directory: $DOWNLOAD_DIR"
    echo

    if download_with_curl_fast "$OFFICIAL_TGZ_URL" "$tgz"; then
        LOADER_ARCHIVE="$tgz"
        return 0
    fi
    warn "curl tar.gz failed."

    if download_with_aria2_fast "$OFFICIAL_TGZ_URL" "$tgz"; then
        LOADER_ARCHIVE="$tgz"
        return 0
    fi
    warn "aria2c tar.gz failed or aria2c is not installed."

    if download_with_wget_clean "$OFFICIAL_TGZ_URL" "$tgz"; then
        LOADER_ARCHIVE="$tgz"
        return 0
    fi
    warn "wget tar.gz failed."

    if download_with_curl_fast "$OFFICIAL_ZIP_URL" "$zip"; then
        LOADER_ARCHIVE="$zip"
        return 0
    fi
    warn "curl zip failed."

    if download_with_aria2_fast "$OFFICIAL_ZIP_URL" "$zip"; then
        LOADER_ARCHIVE="$zip"
        return 0
    fi
    warn "aria2c zip failed or aria2c is not installed."

    if download_with_wget_clean "$OFFICIAL_ZIP_URL" "$zip"; then
        LOADER_ARCHIVE="$zip"
        return 0
    fi
    warn "wget zip failed."

    if copy_manual_archive "$tgz"; then
        LOADER_ARCHIVE="$tgz"
        return 0
    fi

    echo
    err "All automatic download methods failed."
    echo
    echo "Manual fallback:"
    echo "1. Open this page in your browser:"
    echo "   https://www.sourceguardian.com/loaders.html"
    echo
    echo "2. Download Linux x86_64 loaders."
    echo
    echo "3. Upload the file to one of these paths:"
    echo "   /root/loaders.tar.gz"
    echo "   /root/loaders.linux-x86_64.tar.gz"
    echo "   /root/loaders.zip"
    echo "   /root/loaders.linux-x86_64.zip"
    echo
    echo "4. Run this installer again."
    echo

    return 1
}

extract_archive() {
    local archive="$1"
    local dest="$2"

    rm -rf "$dest"
    mkdir -p "$dest"

    if echo "$archive" | grep -qi '\.zip$'; then
        need_command unzip || {
            err "unzip is required for zip archives."
            return 1
        }
        unzip -q "$archive" -d "$dest"
    else
        tar -xzf "$archive" -C "$dest"
    fi
}

backup_php_version() {
    local php_bin="$1"
    local ver="$2"
    local ext_dir="$3"
    local ini_file="$4"
    local loader="$5"
    local php_backup_dir="$RUN_BACKUP_DIR/php-$ver"

    mkdir -p "$php_backup_dir"

    echo "$php_bin" > "$php_backup_dir/php_bin.txt"
    echo "$ver" > "$php_backup_dir/php_version.txt"
    echo "$ext_dir" > "$php_backup_dir/ext_dir.txt"
    echo "$ini_file" > "$php_backup_dir/ini_file.txt"
    echo "$loader" > "$php_backup_dir/loader_name.txt"

    if [ -f "$ini_file" ]; then
        cp -a "$ini_file" "$php_backup_dir/sourceguardian.ini.bak"
    fi

    if [ -f "$ext_dir/$loader" ]; then
        cp -a "$ext_dir/$loader" "$php_backup_dir/$loader.bak"
    fi
}

rollback_php_version() {
    local php_backup_dir="$1"

    local php_bin ver ext_dir ini_file loader
    php_bin="$(cat "$php_backup_dir/php_bin.txt" 2>/dev/null || true)"
    ver="$(cat "$php_backup_dir/php_version.txt" 2>/dev/null || true)"
    ext_dir="$(cat "$php_backup_dir/ext_dir.txt" 2>/dev/null || true)"
    ini_file="$(cat "$php_backup_dir/ini_file.txt" 2>/dev/null || true)"
    loader="$(cat "$php_backup_dir/loader_name.txt" 2>/dev/null || true)"

    if [ -z "$php_bin" ] || [ -z "$ver" ] || [ -z "$ext_dir" ] || [ -z "$ini_file" ] || [ -z "$loader" ]; then
        warn "Backup data is incomplete. Rollback is not possible: $php_backup_dir"
        return 1
    fi

    warn "Rolling back PHP $ver..."

    if [ -f "$php_backup_dir/sourceguardian.ini.bak" ]; then
        cp -a "$php_backup_dir/sourceguardian.ini.bak" "$ini_file"
    else
        rm -f "$ini_file"
    fi

    if [ -f "$php_backup_dir/$loader.bak" ]; then
        cp -a "$php_backup_dir/$loader.bak" "$ext_dir/$loader"
    else
        rm -f "$ext_dir/$loader"
    fi

    if [ -x "$php_bin" ]; then
        "$php_bin" -v >/dev/null 2>&1 || warn "PHP $ver still has issues after rollback."
    fi
}

restart_services() {
    info "Restarting related services..."

    local services=(
        "php-fpm74"
        "php-fpm80"
        "php-fpm81"
        "php-fpm82"
        "php-fpm83"
        "php-fpm84"
        "httpd"
        "apache2"
        "nginx"
        "lsws"
    )

    local svc

    for svc in "${services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
            systemctl restart "$svc" && ok "Restarted $svc" || warn "Could not restart $svc"
        fi
    done
}

status_report() {
    echo
    line
    echo "SourceGuardian Installation Status"
    line
    echo

    printf "%-10s %-8s %-8s %-12s %-18s %-40s\n" "PHP" "Found" "Loaded" "SG-Version" "Loader" "PHP Binary"
    printf "%-10s %-8s %-8s %-12s %-18s %-40s\n" "--------" "------" "------" "----------" "------" "----------"

    local ver php_bin found loaded sg_ver loader php_full

    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        php_bin="$(php_bin_for_version "$ver")"

        if [ -x "$php_bin" ]; then
            found="yes"
            php_full="$(php_full_version_from_bin "$php_bin")"
            loader="$(loader_name_for_php "$php_bin" "$ver")"

            if sourceguardian_loaded "$php_bin"; then
                loaded="yes"
                sg_ver="$(sourceguardian_version "$php_bin")"
            else
                loaded="no"
                sg_ver="-"
            fi

            printf "%-10s %-8s %-8s %-12s %-18s %-40s\n" "$php_full" "$found" "$loaded" "$sg_ver" "$loader" "$php_bin"
        else
            found="no"
            loaded="-"
            sg_ver="-"
            loader="ixed.${ver}.lin"
            printf "%-10s %-8s %-8s %-12s %-18s %-40s\n" "$ver" "$found" "$loaded" "$sg_ver" "$loader" "$php_bin"
        fi
    done

    echo
    small_line
    echo "Backup base: $BACKUP_BASE"
    echo "Log file:    $LOG_FILE"
    small_line
    echo
}

debug_php_loader_files() {
    local php_bin="$1"
    local ver="$2"
    local ext_dir scan_dir ini_file loader

    ext_dir="$(extension_dir_from_bin "$php_bin")"
    scan_dir="$(scan_dir_from_bin "$php_bin")"
    ini_file="$(ini_file_for_php "$php_bin")"
    loader="$(loader_name_for_php "$php_bin" "$ver")"

    echo
    small_line
    echo "Debug information for PHP $ver"
    small_line
    echo "PHP binary:      $php_bin"
    echo "extension_dir:   $ext_dir"
    echo "ini_scan_dir:    $scan_dir"
    echo "ini_file:        $ini_file"
    echo "loader:          $loader"
    echo

    echo "INI file check:"
    if [ -f "$ini_file" ]; then
        ls -l "$ini_file"
        cat "$ini_file"
    else
        echo "INI file not found."
    fi

    echo
    echo "Loader file check:"
    if [ -f "$ext_dir/$loader" ]; then
        ls -l "$ext_dir/$loader"
    else
        echo "Loader file not found."
    fi

    echo
    echo "PHP --ini:"
    "$php_bin" --ini 2>/dev/null || true

    echo
    small_line
}

install_for_php_version() {
    local ver="$1"
    local archive="$2"

    local php_bin ext_dir scan_dir ini_file loader extract_to loader_file php_backup_dir test_log php_real_ver

    php_bin="$(php_bin_for_version "$ver")"

    if [ ! -x "$php_bin" ]; then
        err "PHP $ver was not found at: $php_bin"
        return 1
    fi

    php_real_ver="$(php_version_from_bin "$php_bin")"

    if [ "$php_real_ver" != "$ver" ]; then
        err "Selected PHP version does not match real PHP version."
        err "Selected: $ver"
        err "Real:     $php_real_ver"
        return 1
    fi

    ext_dir="$(extension_dir_from_bin "$php_bin")"
    scan_dir="$(scan_dir_from_bin "$php_bin")"
    ini_file="$(ini_file_for_php "$php_bin")"
    loader="$(loader_name_for_php "$php_bin" "$ver")"

    extract_to="$EXTRACT_DIR/$TS/php-$ver"
    php_backup_dir="$RUN_BACKUP_DIR/php-$ver"
    test_log="$LOG_DIR/php-$ver-test-$TS.log"

    echo
    line
    echo "Installing SourceGuardian for PHP $ver"
    line
    echo "PHP binary:      $php_bin"
    echo "extension_dir:   $ext_dir"
    echo "ini_scan_dir:    $scan_dir"
    echo "ini_file:        $ini_file"
    echo "loader needed:   $loader"
    echo "backup dir:      $php_backup_dir"
    echo "archive:         $archive"
    echo

    if [ ! -f "$archive" ]; then
        err "Loader archive does not exist: $archive"
        return 1
    fi

    if [ ! -d "$ext_dir" ]; then
        err "extension_dir does not exist: $ext_dir"
        return 1
    fi

    info "Testing PHP before installation..."
    if ! "$php_bin" -v >"$test_log" 2>&1; then
        err "PHP $ver has errors before installation. Installation skipped for safety."
        cat "$test_log"
        return 1
    fi
    ok "PHP test passed."

    info "Extracting loader archive..."
    if ! extract_archive "$archive" "$extract_to"; then
        err "Archive extraction failed."
        return 1
    fi

    loader_file="$(find "$extract_to" -type f -name "$loader" | head -n 1)"

    if [ -z "$loader_file" ]; then
        err "Required loader was not found in archive: $loader"
        echo
        echo "Available ixed loaders in archive:"
        find "$extract_to" -type f -name 'ixed*.lin' | sort || true
        return 1
    fi

    ok "Loader found: $loader_file"

    info "Creating backup..."
    backup_php_version "$php_bin" "$ver" "$ext_dir" "$ini_file" "$loader"
    ok "Backup created: $php_backup_dir"

    info "Installing loader..."
    cp -f "$loader_file" "$ext_dir/$loader"
    chmod 755 "$ext_dir/$loader"

    mkdir -p "$scan_dir"

    cat > "$ini_file" <<EOF_INI
extension=$loader
EOF_INI

    ok "Loader installed."
    ok "INI file created: $ini_file"

    info "Testing PHP after installation..."
    if ! "$php_bin" -v >"$test_log" 2>&1; then
        err "PHP $ver failed after installation."
        cat "$test_log"
        warn "Starting automatic rollback..."
        rollback_php_version "$php_backup_dir"
        return 1
    fi

    ok "PHP test passed after installation."

    if sourceguardian_loaded "$php_bin"; then
        ok "SourceGuardian is loaded for PHP $ver."
    else
        warn "PHP is working, but SourceGuardian was not detected for PHP $ver."
        warn "Debug output will be printed below."
        debug_php_loader_files "$php_bin" "$ver"
    fi

    return 0
}

install_single_menu() {
    echo
    line
    echo "Select PHP Version"
    line
    echo

    local i ver php_bin found
    i=1

    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        php_bin="$(php_bin_for_version "$ver")"

        if [ -x "$php_bin" ]; then
            found="installed"
        else
            found="not found"
        fi

        printf " %d) PHP %-4s  [%s]\n" "$i" "$ver" "$found"
        i=$((i + 1))
    done

    echo
    echo " 0) Back"
    echo
    read -r -p "Enter your choice: " choice

    if [ "$choice" = "0" ]; then
        return 0
    fi

    if ! echo "$choice" | grep -qE '^[0-9]+$'; then
        err "Invalid choice."
        pause_screen
        return 1
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#SUPPORTED_VERSIONS[@]}" ]; then
        err "Invalid choice."
        pause_screen
        return 1
    fi

    ver="${SUPPORTED_VERSIONS[$((choice - 1))]}"
    php_bin="$(php_bin_for_version "$ver")"

    if [ ! -x "$php_bin" ]; then
        err "PHP $ver is not installed on this server."
        pause_screen
        return 1
    fi

    echo
    read -r -p "Install SourceGuardian for PHP $ver? Type yes to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        warn "Cancelled."
        pause_screen
        return 0
    fi

    get_loader_archive || {
        err "Could not download or find SourceGuardian loader archive."
        pause_screen
        return 1
    }

    install_for_php_version "$ver" "$LOADER_ARCHIVE"
    restart_services
    status_report
    pause_screen
}

install_all_versions() {
    echo
    line
    echo "Install SourceGuardian for All Detected PHP Versions"
    line
    echo

    local found_count=0
    local ver php_bin

    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        php_bin="$(php_bin_for_version "$ver")"

        if [ -x "$php_bin" ]; then
            echo "Found PHP $ver: $php_bin"
            found_count=$((found_count + 1))
        fi
    done

    if [ "$found_count" -eq 0 ]; then
        err "No supported DirectAdmin PHP versions found."
        pause_screen
        return 1
    fi

    echo
    read -r -p "Install SourceGuardian for all detected PHP versions? Type yes to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        warn "Cancelled."
        pause_screen
        return 0
    fi

    get_loader_archive || {
        err "Could not download or find SourceGuardian loader archive."
        pause_screen
        return 1
    }

    for ver in "${SUPPORTED_VERSIONS[@]}"; do
        php_bin="$(php_bin_for_version "$ver")"

        if [ -x "$php_bin" ]; then
            install_for_php_version "$ver" "$LOADER_ARCHIVE" || warn "Installation failed for PHP $ver. Continuing with next version."
        fi
    done

    restart_services
    status_report
    pause_screen
}

show_manual_fallback() {
    echo
    line
    echo "Manual Download Fallback"
    line
    echo
    echo "If automatic download fails with 403 Forbidden:"
    echo
    echo "1. Open this page in your browser:"
    echo "   https://www.sourceguardian.com/loaders.html"
    echo
    echo "2. Download Linux x86_64 loaders."
    echo
    echo "3. Upload the downloaded file to your server as one of these:"
    echo "   /root/loaders.tar.gz"
    echo "   /root/loaders.linux-x86_64.tar.gz"
    echo "   /root/loaders.zip"
    echo "   /root/loaders.linux-x86_64.zip"
    echo
    echo "4. Run this installer again."
    echo
    pause_screen
}

main_menu() {
    while true; do
        echo
        line
        echo "$APP_NAME"
        line
        echo
        echo " 1) Install for a selected PHP version"
        echo " 2) Install for all detected PHP versions"
        echo " 3) Check SourceGuardian installation status"
        echo " 4) Manual download fallback help"
        echo " 0) Exit"
        echo
        small_line
        echo "Supported versions: PHP 7.4, 8.0, 8.1, 8.2, 8.3, 8.4"
        echo "Log file: $LOG_FILE"
        small_line
        echo
        read -r -p "Enter your choice: " choice

        case "$choice" in
            1)
                install_single_menu
                ;;
            2)
                install_all_versions
                ;;
            3)
                status_report
                pause_screen
                ;;
            4)
                show_manual_fallback
                ;;
            0)
                echo
                ok "Goodbye."
                exit 0
                ;;
            *)
                err "Invalid choice."
                pause_screen
                ;;
        esac
    done
}

main() {
    require_root
    check_arch
    check_basic_tools
    start_log

    line
    echo "$APP_NAME"
    echo "Started at: $(date)"
    echo "Log file: $LOG_FILE"
    line

    main_menu
}

main "$@"
EOF
