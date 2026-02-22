#!/usr/bin/env bash
set -euo pipefail

WORK=work
OUT=public
TMP=$WORK/tmp

mkdir -p "$WORK" "$OUT" "$TMP"

# Safe empty file creator
safe_empty() {
    : > "$1"
}

fetch_list() {

    local sources_file="$1"
    local output_file="$2"

    safe_empty "$output_file"

    # If sources file missing or empty, exit cleanly
    [ -f "$sources_file" ] || return 0
    [ -s "$sources_file" ] || return 0

    while read -r url; do

        [ -z "$url" ] && continue

        echo "Downloading $url"

        if curl -fsSL "$url" >> "$output_file"; then
            echo >> "$output_file"
        else
            echo "WARNING: failed to download $url"
        fi

    done < "$sources_file"
}

extract_domains() {

    grep -v '^#' 2>/dev/null || true
} | grep -v '^!' \
  | grep -v '^@' \
  | sed 's/\r//' \
  | sed 's/^0.0.0.0 //' \
  | sed 's/^127.0.0.1 //' \
  | sed 's/^::1 //' \
  | awk '{print $1}' \
  | sed 's/^\.//' \
  | sed '/^$/d' \
  | grep -v localhost \
  | sort -u

echo "== Download blacklist =="

fetch_list blacklist-sources.txt "$TMP/black_raw.txt"

extract_domains < "$TMP/black_raw.txt" > "$TMP/black.txt" || safe_empty "$TMP/black.txt"

echo "Blacklist: $(wc -l < "$TMP/black.txt")"

echo "== Download whitelist =="

fetch_list whitelist-sources.txt "$TMP/white_raw.txt"

extract_domains < "$TMP/white_raw.txt" > "$TMP/white.txt" || safe_empty "$TMP/white.txt"

echo "Whitelist: $(wc -l < "$TMP/white.txt")"

echo "== Apply whitelist =="

if [ -s "$TMP/white.txt" ]; then

    comm -23 \
        "$TMP/black.txt" \
        "$TMP/white.txt" \
        > "$TMP/filtered.txt"

else

    cp "$TMP/black.txt" "$TMP/filtered.txt"

fi

echo "Filtered: $(wc -l < "$TMP/filtered.txt")"

echo "== Download wildcards =="

fetch_list wildcard-sources.txt "$TMP/wild_raw.txt"

extract_domains < "$TMP/wild_raw.txt" > "$TMP/wild.txt" || safe_empty "$TMP/wild.txt"

echo "Wildcards: $(wc -l < "$TMP/wild.txt")"

echo "== Expand wildcards =="

safe_empty "$TMP/wild_expanded.txt"

if [ -s "$TMP/wild.txt" ]; then

    while read -r domain; do
        echo "$domain"
        echo "*.$domain"
    done < "$TMP/wild.txt" | sort -u > "$TMP/wild_expanded.txt"

fi

echo "== Combine final list =="

cat \
    "$TMP/filtered.txt" \
    "$TMP/wild_expanded.txt" \
    2>/dev/null \
    | sort -u \
    > "$TMP/final.txt"

COUNT=$(wc -l < "$TMP/final.txt")

echo "Final count: $COUNT"

echo "== Generate serial =="

SERIAL=$(date +%Y%m%d%H)

RPZ="$OUT/rpz.zone"

cat > "$RPZ" <<EOF
\$TTL 2h
@   IN SOA localhost. root.localhost. (
        $SERIAL
        1h
        15m
        30d
        2h )
    IN NS localhost.

EOF

awk '{print $0 " CNAME ."}' "$TMP/final.txt" >> "$RPZ"

echo "== Additional formats =="

cp "$TMP/final.txt" "$OUT/domains.txt"

awk '{print "0.0.0.0 "$0}' \
"$TMP/final.txt" > "$OUT/hosts.txt"

awk '{print "local-zone: \""$0"\" always_nxdomain"}' \
"$TMP/final.txt" > "$OUT/unbound.conf"

awk '{print "address=/"$0"/0.0.0.0"}' \
"$TMP/final.txt" > "$OUT/dnsmasq.conf"

echo "== Compress =="

gzip -kf "$OUT"/*

echo "== COMPLETE SUCCESSFULLY =="
