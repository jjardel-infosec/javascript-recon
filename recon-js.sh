#!/bin/bash
# recon-js.sh — Lightweight subdomain enumeration + JS file download
# Usage: ./recon-js.sh <domain>
#
# Outputs:
#   Subdomains  → $HOME/01-All-Domains/<domain>.txt
#   JS Files    → $HOME/03-JS-Download/<domain>/

set -uo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

# ── Validate target ─────────────────────────────────────────────────────────
_validate_domain() {
    echo "$1" | grep -qP '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
}

TARGET="${1:-}"

# If no argument was passed, ask interactively
if [ -z "$TARGET" ]; then
    echo ""
    echo -e "${CYAN}[?]${NC} Target domain (e.g. example.com): "
    read -r TARGET
    TARGET="$(echo "$TARGET" | tr '[:upper:]' '[:lower:]' | xargs)"
fi

if [ -z "$TARGET" ]; then
    err "No domain provided."
    echo "Usage: $0 <domain>"
    exit 1
fi

# Accept only valid domain characters (no path, no protocol, no spaces)
if ! _validate_domain "$TARGET"; then
    err "Invalid target domain: '$TARGET'"
    exit 1
fi

# ── Precompute escaped domain for regex patterns ────────────────────────────
TARGET_RE="$(echo "$TARGET" | sed 's/\./\\./g')"

# ── Output directories (override via env vars if needed) ────────────────────
ALL_DOMAINS_DIR="${ALL_DOMAINS_DIR:-$HOME/01-All-Domains}"
JS_DOWNLOAD_DIR="${JS_DOWNLOAD_DIR:-$HOME/03-JS-Download}/$TARGET"
DNS_WORDLIST="${DNS_WORDLIST:-$HOME/wordlists/best-dns-wordlist.txt}"
WORK_DIR="/tmp/recon-js-$$-$(date +%s)"

mkdir -p "$ALL_DOMAINS_DIR" "$JS_DOWNLOAD_DIR" "$WORK_DIR/subs"

# Cleanup on exit
trap 'rm -rf "$WORK_DIR"' EXIT

SUBS_RAW="$WORK_DIR/subs"
SUBS_FILE="$WORK_DIR/all_subs.txt"
LIVE_FILE="$WORK_DIR/live.txt"
JS_URLS_FILE="$WORK_DIR/js_urls.txt"

touch "$SUBS_FILE" "$LIVE_FILE" "$JS_URLS_FILE"

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  recon-js.sh — $TARGET"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================="
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Subdomain Enumeration
# ═══════════════════════════════════════════════════════════════════════════
info "Phase 1: Subdomain Enumeration"

# subfinder — passive, multi-source
if command -v subfinder &>/dev/null; then
    info "  [subfinder] running..."
    subfinder -d "$TARGET" -silent -all -o "$SUBS_RAW/subfinder.txt" 2>/dev/null || true
    ok "  subfinder: $(wc -l < "$SUBS_RAW/subfinder.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  subfinder not installed — skipping"
fi

# amass — passive only (3-min cap to stay lightweight)
if command -v amass &>/dev/null; then
    info "  [amass] running (passive, 3min timeout)..."
    timeout 180 amass enum -passive -d "$TARGET" \
        -o "$SUBS_RAW/amass.txt" 2>/dev/null || true
    [ ! -f "$SUBS_RAW/amass.txt" ] && touch "$SUBS_RAW/amass.txt"
    ok "  amass: $(wc -l < "$SUBS_RAW/amass.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  amass not installed — skipping"
fi

# crt.sh — certificate transparency logs
info "  [crt.sh] querying..."
curl -s --max-time 30 "https://crt.sh/?q=%25.$TARGET&output=json" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    seen = set()
    for entry in data:
        for name in entry.get('name_value','').split('\n'):
            name = name.strip().lower().lstrip('*.')
            if name and '.' in name:
                seen.add(name)
    for n in sorted(seen): print(n)
except: pass
" > "$SUBS_RAW/crtsh.txt" 2>/dev/null || touch "$SUBS_RAW/crtsh.txt"
ok "  crt.sh: $(wc -l < "$SUBS_RAW/crtsh.txt" 2>/dev/null || echo 0) subdomains"

# Wayback Machine — extract subdomains from CDX API
info "  [wayback] querying..."
curl -s --max-time 30 \
    "https://web.archive.org/cdx/search/cdx?url=*.$TARGET/*&output=text&fl=original&collapse=urlkey&limit=10000" \
    2>/dev/null \
    | sed -nE "s|https?://([a-zA-Z0-9._-]+\.$TARGET_RE)[/\"'?].*|\1|p" \
    | sort -u > "$SUBS_RAW/wayback_subs.txt" 2>/dev/null || touch "$SUBS_RAW/wayback_subs.txt"
ok "  wayback: $(wc -l < "$SUBS_RAW/wayback_subs.txt" 2>/dev/null || echo 0) subdomains"

# gau — extracts subdomains from Wayback, CommonCrawl, OTX and URLScan
if command -v gau &>/dev/null; then
    info "  [gau] querying historical sources..."
    echo "$TARGET" | gau --threads 5 --subs 2>/dev/null \
        | sed -nE "s|https?://([a-zA-Z0-9._-]+\.$TARGET_RE)[/\"'?].*|\1|p" \
        | sort -u > "$SUBS_RAW/gau_subs.txt" 2>/dev/null || touch "$SUBS_RAW/gau_subs.txt"
    ok "  gau: $(wc -l < "$SUBS_RAW/gau_subs.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  gau not installed — skipping"
fi

# chaos — ProjectDiscovery public dataset
if command -v chaos &>/dev/null; then
    info "  [chaos] running..."
    chaos -d "$TARGET" -silent -o "$SUBS_RAW/chaos.txt" 2>/dev/null || true
    ok "  chaos: $(wc -l < "$SUBS_RAW/chaos.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  chaos not installed — skipping"
fi

# assetfinder — fast passive, distinct sources from subfinder
if command -v assetfinder &>/dev/null; then
    info "  [assetfinder] running..."
    assetfinder --subs-only "$TARGET" 2>/dev/null \
        | grep -iE "(^|\.)$TARGET_RE$" \
        > "$SUBS_RAW/assetfinder.txt" || true
    ok "  assetfinder: $(wc -l < "$SUBS_RAW/assetfinder.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  assetfinder not installed — skipping"
fi

# findomain — covers FB CT logs, VirusTotal, Shodan, etc.
if command -v findomain &>/dev/null; then
    info "  [findomain] running..."
    findomain -t "$TARGET" -q 2>/dev/null \
        > "$SUBS_RAW/findomain.txt" || true
    ok "  findomain: $(wc -l < "$SUBS_RAW/findomain.txt" 2>/dev/null || echo 0) subdomains"
else
    warn "  findomain not installed — skipping"
fi

# puredns — DNS brute force (finds subs never exposed through passive sources)
if command -v puredns &>/dev/null && [ -f "$DNS_WORDLIST" ]; then
    info "  [puredns] DNS brute force (wordlist: $(wc -l < "$DNS_WORDLIST") words)..."
    puredns bruteforce "$DNS_WORDLIST" "$TARGET" \
        -r /etc/resolv.conf \
        --wildcard-tests 5 \
        -q \
        2>/dev/null > "$SUBS_RAW/puredns.txt" || true
    ok "  puredns: $(wc -l < "$SUBS_RAW/puredns.txt" 2>/dev/null || echo 0) subdomains"
elif command -v puredns &>/dev/null && [ ! -f "$DNS_WORDLIST" ]; then
    warn "  puredns installed but wordlist not found: $DNS_WORDLIST — skipping brute force"
else
    warn "  puredns not installed — skipping DNS brute force"
fi

# Merge + deduplicate — keep only lines that match *.<target> or <target>
cat "$SUBS_RAW/"*.txt 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' \
    | grep -E "(^|\.)$TARGET_RE$" \
    | sort -u > "$SUBS_FILE"

TOTAL_SUBS=$(wc -l < "$SUBS_FILE")
ok "Total unique subdomains: $TOTAL_SUBS"

# ── Save subdomains to $ALL_DOMAINS_DIR/<domain>.txt ───────────────────────
DEST_SUBS="$ALL_DOMAINS_DIR/$TARGET.txt"
if [ -f "$DEST_SUBS" ]; then
    # Merge with existing history, deduplicate atomically
    TMP_MERGE=$(mktemp "$ALL_DOMAINS_DIR/.${TARGET}.XXXXXX")
    { cat "$DEST_SUBS"; cat "$SUBS_FILE"; } | sort -u > "$TMP_MERGE"
    mv "$TMP_MERGE" "$DEST_SUBS"
else
    cp "$SUBS_FILE" "$DEST_SUBS"
fi
ok "Subdomains saved: $DEST_SUBS ($(wc -l < "$DEST_SUBS") total)"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: HTTP Probing (live host detection)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "Phase 2: HTTP Probing"

if command -v httpx &>/dev/null && [ -s "$SUBS_FILE" ]; then
    info "  [httpx] probing $(wc -l < "$SUBS_FILE") subdomains..."
    httpx -l "$SUBS_FILE" -silent -threads 50 -timeout 10 -o "$LIVE_FILE" 2>/dev/null || true
    ok "  Live hosts: $(wc -l < "$LIVE_FILE")"
else
    warn "  httpx not installed — building fallback URL list from subdomains"
    while IFS= read -r sub; do
        echo "https://$sub"
    done < "$SUBS_FILE" | sort -u > "$LIVE_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: JS URL Discovery
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "Phase 3: JS URL Discovery"

# subjs — extract JS URLs from live hosts (preferred)
if command -v subjs &>/dev/null && [ -s "$LIVE_FILE" ]; then
    info "  [subjs] extracting JS links from live hosts..."
    subjs -i "$LIVE_FILE" 2>/dev/null | grep -iE '\.js(\?|$)' | sort -u >> "$JS_URLS_FILE" || true
    ok "  subjs: $(wc -l < "$JS_URLS_FILE") JS URLs so far"
fi

# getJS — fallback for JS extraction
if command -v getJS &>/dev/null && [ -s "$LIVE_FILE" ]; then
    info "  [getJS] crawling live hosts..."
    while IFS= read -r url; do
        getJS --url "$url" --complete 2>/dev/null \
            | grep -iE '\.js(\?|$)' >> "$JS_URLS_FILE" || true
    done < "$LIVE_FILE"
fi

# katana — active crawl (depth 2, JS-focused)
if command -v katana &>/dev/null && [ -s "$LIVE_FILE" ]; then
    info "  [katana] crawling (depth 2, 5min timeout)..."
    timeout 300 katana -list "$LIVE_FILE" -silent -jc -d 2 \
        -o "$WORK_DIR/katana.txt" 2>/dev/null || true
    grep -iE '\.js(\?|$)' "$WORK_DIR/katana.txt" 2>/dev/null \
        | sort -u >> "$JS_URLS_FILE" || true
fi

# gau — historical JS URLs from Wayback / CommonCrawl
if command -v gau &>/dev/null; then
    info "  [gau] fetching historical JS URLs..."
    echo "$TARGET" | gau --threads 5 2>/dev/null \
        | grep -iE '\.js(\?|$)' \
        | sort -u >> "$JS_URLS_FILE" || true
fi

# Wayback CDX — JS files specifically
info "  [wayback CDX] fetching JS file URLs..."
curl -s --max-time 30 \
    "https://web.archive.org/cdx/search/cdx?url=*.$TARGET/*.js*&output=text&fl=original&collapse=urlkey&limit=5000" \
    2>/dev/null \
    | grep -iE '\.js(\?|$)' \
    | sort -u >> "$JS_URLS_FILE" || true

# Final deduplicate
sort -u "$JS_URLS_FILE" -o "$JS_URLS_FILE"
JS_COUNT=$(wc -l < "$JS_URLS_FILE")
ok "Total unique JS URLs (raw): $JS_COUNT"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3b: Verify JS URLs (filter 404s, redirects, non-JS responses)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "Phase 3b: Verifying JS URLs (filtering dead links and redirects)..."

JS_URLS_VERIFIED="$WORK_DIR/js_urls_verified.txt"
touch "$JS_URLS_VERIFIED"

if command -v httpx &>/dev/null && [ "$JS_COUNT" -gt 0 ]; then
    # Keep only HTTP 200 responses with JavaScript content-type
    httpx -l "$JS_URLS_FILE" \
        -silent \
        -threads 50 \
        -timeout 10 \
        -status-code \
        -no-fallback \
        -mc 200 \
        -o "$JS_URLS_VERIFIED" 2>/dev/null || true

    # httpx output: "<url> [200]" — extract just the URL
    sed -i 's/ \[.*//g' "$JS_URLS_VERIFIED" 2>/dev/null || true
    sort -u "$JS_URLS_VERIFIED" -o "$JS_URLS_VERIFIED"

    VERIFIED_COUNT=$(wc -l < "$JS_URLS_VERIFIED")
    ok "  Verified live JS URLs: $VERIFIED_COUNT (removed $(( JS_COUNT - VERIFIED_COUNT )) dead/redirect URLs)"
    JS_URLS_FILE="$JS_URLS_VERIFIED"
    JS_COUNT=$VERIFIED_COUNT
else
    warn "  httpx not available or no URLs — skipping verification (dead links may be scanned)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Download JS Files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
info "Phase 4: Downloading JS files → $JS_DOWNLOAD_DIR"

if [ "$JS_COUNT" -eq 0 ]; then
    warn "No JS URLs found — skipping download"
else
    # Cap at 1000 to stay lightweight
    MAX_DOWNLOADS=1000
    if [ "$JS_COUNT" -gt "$MAX_DOWNLOADS" ]; then
        warn "  Capping download to first $MAX_DOWNLOADS of $JS_COUNT URLs"
        DOWNLOAD_LIST=$(head -n "$MAX_DOWNLOADS" "$JS_URLS_FILE")
    else
        DOWNLOAD_LIST=$(cat "$JS_URLS_FILE")
    fi

    DOWNLOADED=0
    FAILED=0
    URL_MAP_FILE="$JS_DOWNLOAD_DIR/url_map.txt"
    : > "$URL_MAP_FILE"  # truncate/create

    while IFS= read -r js_url; do
        [ -z "$js_url" ] && continue

        # Build filename: host + path, with unsafe chars replaced
        filename=$(echo "$js_url" \
            | sed -E 's|https?://||' \
            | sed -E 's|[?&=#:].*||' \
            | tr '/' '_' \
            | sed 's/__*/_/g' \
            | sed 's/^_//; s/_$//')
        # Ensure .js extension and cap length
        filename="${filename%.js}"
        filename="${filename:0:180}.js"

        # Record filename → original URL mapping (for traceability)
        echo "$filename $js_url" >> "$URL_MAP_FILE"

        # Skip if already downloaded (idempotent re-runs)
        if [ -f "$JS_DOWNLOAD_DIR/$filename" ]; then
            DOWNLOADED=$((DOWNLOADED + 1))
            continue
        fi

        if curl -s --max-time 15 --retry 1 --retry-delay 2 \
                -o "$JS_DOWNLOAD_DIR/$filename" "$js_url" 2>/dev/null; then
            if [ -s "$JS_DOWNLOAD_DIR/$filename" ]; then
                DOWNLOADED=$((DOWNLOADED + 1))
            else
                rm -f "$JS_DOWNLOAD_DIR/$filename"
                FAILED=$((FAILED + 1))
            fi
        else
            rm -f "$JS_DOWNLOAD_DIR/$filename" 2>/dev/null || true
            FAILED=$((FAILED + 1))
        fi
    done <<< "$DOWNLOAD_LIST"

    ok "Downloaded: $DOWNLOADED JS files"
    ok "URL map  : $URL_MAP_FILE"
    [ "$FAILED" -gt 0 ] && warn "Failed/empty: $FAILED"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
ok "  DONE — $TARGET"
ok "  Subdomains : $DEST_SUBS"
ok "               ($(wc -l < "$DEST_SUBS") total)"
ok "  JS Files   : $JS_DOWNLOAD_DIR/"
ok "               ($(find "$JS_DOWNLOAD_DIR" -name '*.js' 2>/dev/null | wc -l) files)"
ok "  URL Map    : $JS_DOWNLOAD_DIR/url_map.txt"
echo "==========================================="
echo ""
info "Next steps:"
echo "  # Scan downloaded files (fast, offline — filename shown as target):"
echo "  jsecret -d $JS_DOWNLOAD_DIR"
echo ""
echo "  # Scan live URLs (URL shown in output, easier to verify findings):"
echo "  jsecret -f $JS_URLS_FILE"
echo ""
echo "  # Look up original URL for a finding from a local scan:"
echo "  grep 'filename.js' $JS_DOWNLOAD_DIR/url_map.txt"
echo ""
