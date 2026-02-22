#!/usr/bin/env bash

set -eo pipefail

WORK="work"
OUT="public"
TMP="$WORK/tmp"

mkdir -p "$TMP"
mkdir -p "$OUT"

safe_empty() {
    touch "$1"
}

# Download remote sources
fetch_list() {
    local src="$1"
    local dst="$2"

    safe_empty "$dst"

    if [ ! -f "$src" ] || [ ! -s "$src" ]; then
        echo "INFO: $src missing or empty, skipping"
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

# Extract clean domains from hosts files
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
    | LC_ALL=C sort -u
}

# Expand whitelist to include apex + wildcard form
expand_whitelist() {
    local input="$1"
    local output="$2"
    safe_empty "$output"

    if [ ! -s "$input" ]; then return 0; fi

    while read -r domain; do
        echo "$domain"
        echo "*.$domain"
    done < "$input" | LC_ALL=C sort -u > "$output"
}

# Filter blacklist using suffix match against whitelist
filter_blacklist_with_whitelist_suffix() {
    local blacklist="$1"
    local whitelist="$2"
    local output="$3"

    safe_empty "$output"

    if [ ! -s "$whitelist" ]; then
        cp "$blacklist" "$output"
        return
    fi

    awk '
    NR==FNR {w[$0]; next}
    {
        d=$0
        skip=0
        for (i in w) {
            if(d==i || d ~ ("\\." i "$")) skip=1
        }
        if(!skip) print d
    }' "$whitelist" "$blacklist" | LC_ALL=C sort -u > "$output"
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

echo "==== EXPAND WHITELIST ===="
expand_whitelist "$TMP/white.txt" "$TMP/white_expanded.txt"
echo "Expanded whitelist count: $(wc -l < "$TMP/white_expanded.txt")"

echo "==== FILTER BLACKLIST ===="
filter_blacklist_with_whitelist_suffix "$TMP/black.txt" "$TMP/white.txt" "$TMP/filtered.txt"
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
    done < "$TMP/wild.txt" | LC_ALL=C sort -u > "$TMP/wild_expanded.txt"
fi
echo "Wildcard count: $(wc -l < "$TMP/wild.txt")"

echo "==== FINAL MERGE ===="
cat "$TMP/filtered.txt" "$TMP/wild_expanded.txt" | LC_ALL=C sort -u > "$TMP/final.txt"
COUNT=$(wc -l < "$TMP/final.txt")
echo "Final domains: $COUNT"

echo "==== BUILD RPZ SAFELY ===="
SERIAL=$(date +%Y%m%d%H)
RPZ_TMP="$OUT/rpz.zone.tmp"
RPZ="$OUT/rpz.zone"
safe_empty "$RPZ_TMP"

cat > "$RPZ_TMP" <<EOF
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
    awk '{print $0 " CNAME ."}' "$TMP/final.txt" >> "$RPZ_TMP"
fi

# Ensure final newline
echo "" >> "$RPZ_TMP"

# Minimum size check to avoid "masterfile too small"
SIZE=$(wc -c < "$RPZ_TMP")
if [ "$SIZE" -lt 100 ]; then
    echo "ERROR: RPZ file too small ($SIZE bytes), stopping"
    exit 1
fi

# Optional BIND validation
if command -v named-checkzone >/dev/null 2>&1; then
    named-checkzone rpz.local "$RPZ_TMP"
fi

# Atomic move
mv "$RPZ_TMP" "$RPZ"
echo "RPZ built successfully, size: $SIZE bytes"

echo "==== OTHER FORMATS ===="
cp "$TMP/final.txt" "$OUT/domains.txt"
awk '{print "0.0.0.0 "$0}' "$TMP/final.txt" > "$OUT/hosts.txt"
awk '{print "address=/"$0"/0.0.0.0"}' "$TMP/final.txt" > "$OUT/dnsmasq.conf"
awk '{print "local-zone: \""$0"\" always_nxdomain"}' "$TMP/final.txt" > "$OUT/unbound.conf"

echo "==== COMPRESS ===="
gzip -kf "$OUT"/* || true

echo "==== SUCCESS ===="
