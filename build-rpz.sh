#!/usr/bin/env bash

set -eo pipefail   # removed -u to prevent unset var crash

WORK="work"
OUT="public"
TMP="$WORK/tmp"

mkdir -p "$TMP"
mkdir -p "$OUT"

safe_empty() {
    touch "$1"
}

fetch_list() {

    local src="$1"
    local dst="$2"

    safe_empty "$dst"

    if [ ! -f "$src" ]; then
        echo "INFO: $src not found, skipping"
        return 0
    fi

    if [ ! -s "$src" ]; then
        echo "INFO: $src empty, skipping"
        return 0
    fi

    while read -r url; do

        [ -z "$url" ] && continue

        echo "Downloading $url"

        if curl -fL --connect-timeout 30 --max-time 300 "$url" >> "$dst"; then
            echo >> "$dst"
        else
            echo "WARNING: failed $url"
        fi

    done < "$src"

}

extract_domains() {

    sed 's/\r//g' \
    | grep -v '^#' \
    | grep -v '^!' \
    | grep -v '^@' \
    | sed 's/^0.0.0.0 //' \
    | sed 's/^127.0.0.1 //' \
    | sed 's/^::1 //' \
    | awk '{print $1}' \
    | sed 's/^\.//' \
    | grep -v '^$' \
    | grep -v localhost \
    | sort -u

}

echo "==== BLACKLIST ===="

fetch_list "blacklist-sources.txt" "$TMP/black_raw.txt"

safe_empty "$TMP/black.txt"

extract_domains < "$TMP/black_raw.txt" > "$TMP/black.txt" || true

echo "Blacklist count: $(wc -l < "$TMP/black.txt")"

echo "==== WHITELIST ===="

fetch_list "whitelist-sources.txt" "$TMP/white_raw.txt"

safe_empty "$TMP/white.txt"

extract_domains < "$TMP/white_raw.txt" > "$TMP/white.txt" || true

echo "Whitelist count: $(wc -l < "$TMP/white.txt")"

echo "==== FILTER ===="

if [ -s "$TMP/white.txt" ]; then

    comm -23 \
        <(sort "$TMP/black.txt") \
        <(sort "$TMP/white.txt") \
        > "$TMP/filtered.txt"

else

    cp "$TMP/black.txt" "$TMP/filtered.txt"

fi

echo "Filtered count: $(wc -l < "$TMP/filtered.txt")"

echo "==== WILDCARD ===="

fetch_list "wildcard-sources.txt" "$TMP/wild_raw.txt"

safe_empty "$TMP/wild.txt"

extract_domains < "$TMP/wild_raw.txt" > "$TMP/wild.txt" || true

safe_empty "$TMP/wild_expanded.txt"

if [ -s "$TMP/wild.txt" ]; then

    while read -r d; do
        echo "$d"
        echo "*.$d"
    done < "$TMP/wild.txt" | sort -u > "$TMP/wild_expanded.txt"

fi

echo "Wildcard count: $(wc -l < "$TMP/wild.txt")"

echo "==== FINAL ===="

cat \
    "$TMP/filtered.txt" \
    "$TMP/wild_expanded.txt" \
    | sort -u \
    > "$TMP/final.txt"

COUNT=$(wc -l < "$TMP/final.txt")

echo "Final domains: $COUNT"

echo "==== BUILD RPZ ===="

SERIAL=$(date +%Y%m%d%H)

RPZ="$OUT/rpz.zone"

cat > "$RPZ" <<EOF
\$TTL 2h
@ IN SOA localhost. root.localhost. (
    $SERIAL
    1h
    15m
    30d
    2h )
  IN NS localhost.

EOF

if [ -s "$TMP/final.txt" ]; then
    awk '{print $0 " CNAME ."}' "$TMP/final.txt" >> "$RPZ"
fi

echo "==== OTHER FORMATS ===="

cp "$TMP/final.txt" "$OUT/domains.txt"

awk '{print "0.0.0.0 "$0}' "$TMP/final.txt" > "$OUT/hosts.txt"

awk '{print "address=/"$0"/0.0.0.0"}' "$TMP/final.txt" > "$OUT/dnsmasq.conf"

awk '{print "local-zone: \""$0"\" always_nxdomain"}' \
"$TMP/final.txt" > "$OUT/unbound.conf"

echo "==== COMPRESS ===="

gzip -kf "$OUT"/* || true

echo "==== SUCCESS ===="
