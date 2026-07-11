#!/bin/bash

set -e

APP="SourceGuardian Auto Installer"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root."
    exit 1
fi

BASE="/root/sourceguardian-installer"
mkdir -p "$BASE"

TGZ="$BASE/loaders.linux-x86_64.tar.gz"
TMP="$BASE/extract"

echo "== $APP =="

detect_panel() {
    if [ -d "/usr/local/cpanel" ]; then
        echo "cpanel"
    elif [ -d "/usr/local/directadmin" ]; then
        echo "directadmin"
    else
        echo "none"
    fi
}

PANEL=$(detect_panel)

echo "Detected panel: $PANEL"

download_loader() {
    if [ ! -f "$TGZ" ]; then
        curl -L --fail \
        "https://www.sourceguardian.com/loaders/download/loaders.linux-x86_64.tar.gz" \
        -o "$TGZ"
    fi
}

get_php_list() {
    case "$PANEL" in
        cpanel)
            find /opt/cpanel -path "*/root/usr/bin/php" -type f 2>/dev/null | sort
        ;;
        directadmin)
            find /usr/local -path "*/bin/php" -type f 2>/dev/null | grep -E "php[0-9]+" | sort
        ;;
        *)
            command -v php
        ;;
    esac
}

install_php() {
    PHPBIN="$1"

    [ -x "$PHPBIN" ] || return

    VER=$("$PHPBIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)

    [ -n "$VER" ] || return

    EXT=$("$PHPBIN" -r 'echo ini_get("extension_dir");')

    INI=$("$PHPBIN" --ini 2>/dev/null | awk -F': ' '/Scan for additional .ini files in/{print $2}')

    [ "$INI" = "(none)" ] && INI="/etc/php.d"

    TS=$("$PHPBIN" -i | grep "Thread Safety" | grep -qi enabled && echo ts || echo "")

    if [ "$TS" = "ts" ]; then
        LOADER="ixed.${VER}ts.lin"
    else
        LOADER="ixed.${VER}.lin"
    fi

    echo
    echo "Installing PHP $VER"
    echo "Binary: $PHPBIN"
    echo "Loader: $LOADER"

    mkdir -p "$TMP"

    tar -xzf "$TGZ" -C "$TMP"

    FILE=$(find "$TMP" -name "$LOADER" | head -1)

    if [ -z "$FILE" ]; then
        echo "Loader not found for PHP $VER"
        return
    fi

    cp -f "$FILE" "$EXT/$LOADER"
    chmod 755 "$EXT/$LOADER"

    mkdir -p "$INI"

    echo "extension=$LOADER" > "$INI/00-sourceguardian.ini"

    echo "Installed PHP $VER"
}

download_loader

while read -r PHP; do
    install_php "$PHP"
done < <(get_php_list)

echo
echo "Restarting services..."

case "$PANEL" in
    cpanel)
        systemctl restart cpanel-php-fpm 2>/dev/null || true
        ;;
    directadmin)
        systemctl restart php-fpm 2>/dev/null || true
        ;;
esac

systemctl restart httpd 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true

echo
echo "Done."
