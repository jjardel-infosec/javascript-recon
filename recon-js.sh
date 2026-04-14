#!/usr/bin/env bash
# recon-js.sh — Lightweight subdomain enumeration + client-side asset download
# Usage: ./recon-js.sh <domain>

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

QUIET=0
DEBUG="${DEBUG:-0}"
RESUME=0
OUTPUT_JSON=1
OUTPUT_CSV=1
DOWNLOAD_INTERESTING_ASSETS=1
ENFORCE_DOMAIN_ALLOWLIST=0
TARGET=""
SCRIPT_NAME="$(basename "$0")"

ensure_bash_compat() {
    if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        printf '%s\n' "[-] $SCRIPT_NAME requires Bash 4 or newer." >&2
        exit 1
    fi
}

cleanup() {
    local exit_code="$?"

    trap - EXIT INT TERM HUP
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi

    exit "$exit_code"
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_non_negative_number() {
    [[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

normalize_positive_integer() {
    local value="${1:-}"
    local fallback="$2"

    if is_positive_integer "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

normalize_non_negative_integer() {
    local value="${1:-}"
    local fallback="$2"

    if is_non_negative_integer "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

normalize_non_negative_number() {
    local value="${1:-}"
    local fallback="$2"

    if is_non_negative_number "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

normalize_boolean_flag() {
    local value="${1:-}"
    local fallback="$2"

    case "$value" in
        0|1)
            printf '%s' "$value"
            ;;
        *)
            printf '%s' "$fallback"
            ;;
    esac
}

ok() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${GREEN}[+]${NC} $*"
}

warn() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${YELLOW}[!]${NC} $*"
}

info() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${CYAN}[*]${NC} $*"
}

err() {
    echo -e "${RED}[-]${NC} $*" >&2
}

debug() {
    [ "$DEBUG" -eq 1 ] || return 0
    echo -e "${CYAN}[debug]${NC} $*" >&2
}

print_usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options] <domain>

Options:
  --resume               Reuse previous output state where safe
  --allowlist            Enforce target-domain-only asset scope
  --js-only              Skip downloading non-JS interesting assets
  --no-json              Skip JSON manifest output
  --no-csv               Skip CSV report output
  -q, --quiet            Reduce console output
  -h, --help             Show this help

Environment overrides:
  RECON_PROFILE=safe|balanced|aggressive
  ALL_DOMAINS_DIR=<dir>
  JS_DOWNLOAD_DIR=<dir>
  DNS_WORDLIST=<path>
  TOOL_PARALLELISM=<n>
  ACTIVE_FETCH_CONCURRENCY=<n>
  GETJS_CONCURRENCY=<n>
  DOWNLOAD_CONCURRENCY=<n>
  HTTPX_THREADS=<n>
  MAX_DOWNLOADS=<n>
  MAX_ACTIVE_HOSTS=<n>
  ENABLE_HASHING=0|1
EOF
}

_validate_domain() {
    local value="${1,,}"
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

trim() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

_ensure_dir() {
    local dir="$1"

    if ! mkdir -p "$dir" 2>/dev/null; then
        err "Cannot create directory: $dir"
        err "Likely owned by root from a previous sudo run. Fix with:"
        err "  sudo chown -R $(whoami):$(whoami) $(dirname "$dir")"
        exit 1
    fi

    if ! [ -w "$dir" ]; then
        err "No write permission on: $dir"
        err "Fix with:"
        err "  sudo chown -R $(whoami):$(whoami) $dir"
        exit 1
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --resume)
                RESUME=1
                ;;
            --allowlist)
                ENFORCE_DOMAIN_ALLOWLIST=1
                ;;
            --js-only)
                DOWNLOAD_INTERESTING_ASSETS=0
                ;;
            --no-json)
                OUTPUT_JSON=0
                ;;
            --no-csv)
                OUTPUT_CSV=0
                ;;
            -q|--quiet)
                QUIET=1
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                err "Unknown option: $1"
                print_usage >&2
                exit 1
                ;;
            *)
                if [ -z "$TARGET" ]; then
                    TARGET="$1"
                else
                    err "Unexpected argument: $1"
                    print_usage >&2
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [ "$#" -gt 0 ] && [ -z "$TARGET" ]; then
        TARGET="$1"
    fi
}

apply_profile_defaults() {
    local tool_default active_default getjs_default download_default httpx_default max_hosts_default depth_default katana_timeout_default

    RECON_PROFILE="${RECON_PROFILE:-balanced}"

    case "$RECON_PROFILE" in
        safe)
            tool_default=3
            active_default=4
            getjs_default=3
            download_default=4
            httpx_default=20
            max_hosts_default=30
            depth_default=1
            katana_timeout_default=180
            ;;
        aggressive)
            tool_default=6
            active_default=8
            getjs_default=8
            download_default=12
            httpx_default=80
            max_hosts_default=140
            depth_default=3
            katana_timeout_default=420
            ;;
        *)
            tool_default=5
            active_default=6
            getjs_default=5
            download_default=8
            httpx_default=50
            max_hosts_default=75
            depth_default=2
            katana_timeout_default=300
            ;;
    esac

    TOOL_PARALLELISM="$(normalize_positive_integer "${TOOL_PARALLELISM:-$tool_default}" "$tool_default")"
    ACTIVE_FETCH_CONCURRENCY="$(normalize_positive_integer "${ACTIVE_FETCH_CONCURRENCY:-$active_default}" "$active_default")"
    GETJS_CONCURRENCY="$(normalize_positive_integer "${GETJS_CONCURRENCY:-$getjs_default}" "$getjs_default")"
    DOWNLOAD_CONCURRENCY="$(normalize_positive_integer "${DOWNLOAD_CONCURRENCY:-$download_default}" "$download_default")"
    HTTPX_THREADS="$(normalize_positive_integer "${HTTPX_THREADS:-$httpx_default}" "$httpx_default")"
    MAX_ACTIVE_HOSTS="$(normalize_positive_integer "${MAX_ACTIVE_HOSTS:-$max_hosts_default}" "$max_hosts_default")"
    KATANA_DEPTH="$(normalize_positive_integer "${KATANA_DEPTH:-$depth_default}" "$depth_default")"
    KATANA_TIMEOUT="$(normalize_positive_integer "${KATANA_TIMEOUT:-$katana_timeout_default}" "$katana_timeout_default")"

    HTTP_TIMEOUT="$(normalize_positive_integer "${HTTP_TIMEOUT:-10}" "10")"
    CONNECT_TIMEOUT="$(normalize_positive_integer "${CONNECT_TIMEOUT:-8}" "8")"
    DOWNLOAD_TIMEOUT="$(normalize_positive_integer "${DOWNLOAD_TIMEOUT:-25}" "25")"
    DOWNLOAD_RETRIES="$(normalize_non_negative_integer "${DOWNLOAD_RETRIES:-2}" "2")"
    MAX_DOWNLOADS="$(normalize_positive_integer "${MAX_DOWNLOADS:-1000}" "1000")"
    MAX_VERIFY="$(normalize_positive_integer "${MAX_VERIFY:-$(( MAX_DOWNLOADS * 3 ))}" "$(( MAX_DOWNLOADS * 3 ))")"
    WAYBACK_TIMEOUT="$(normalize_positive_integer "${WAYBACK_TIMEOUT:-30}" "30")"
    WAYBACK_LIMIT="$(normalize_positive_integer "${WAYBACK_LIMIT:-15000}" "15000")"
    CRTSH_TIMEOUT="$(normalize_positive_integer "${CRTSH_TIMEOUT:-30}" "30")"
    GAU_THREADS="$(normalize_positive_integer "${GAU_THREADS:-5}" "5")"
    ENABLE_HASHING="$(normalize_boolean_flag "${ENABLE_HASHING:-1}" "1")"
    VERIFICATION_ENABLED="$(normalize_boolean_flag "${VERIFICATION_ENABLED:-1}" "1")"
    MAX_REDIRECTS="$(normalize_positive_integer "${MAX_REDIRECTS:-5}" "5")"
    PER_HOST_DELAY="$(normalize_non_negative_number "${PER_HOST_DELAY:-0}" "0")"
    MAX_SITEMAPS="$(normalize_positive_integer "${MAX_SITEMAPS:-6}" "6")"
    CURL_USER_AGENT="${CURL_USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36}"

    if [ "$MAX_VERIFY" -lt "$MAX_DOWNLOADS" ]; then
        MAX_VERIFY="$MAX_DOWNLOADS"
    fi
}

throttle_jobs() {
    local max_jobs="$1"

    while [ "$(jobs -pr | wc -l | tr -d '[:space:]')" -ge "$max_jobs" ]; do
        wait -n 2>/dev/null || sleep 0.1
    done
}

safe_timeout() {
    local seconds="$1"
    shift

    if have_cmd timeout; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

make_work_dir() {
    local base_dir tmp_dir

    for base_dir in "${TMPDIR:-}" /tmp; do
        [ -n "$base_dir" ] || continue
        [ -d "$base_dir" ] || continue
        [ -w "$base_dir" ] || continue

        tmp_dir="$(mktemp -d "$base_dir/recon-js.${TARGET//./-}.XXXXXX" 2>/dev/null)" || continue
        if [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then
            printf '%s' "$tmp_dir"
            return 0
        fi
    done

    return 1
}

append_unique_line() {
    local file="$1"
    local line="$2"

    [ -n "$line" ] || return 0
    printf '%s\n' "$line" >> "$file"
}

record_raw_discovery() {
    local candidate="$1"
    local declared_type="$2"
    local source="$3"
    local referrer="$4"

    candidate="$(trim "$candidate")"
    referrer="$(trim "$referrer")"
    [ -n "$candidate" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$candidate" "$declared_type" "$source" "$referrer" >> "$RAW_DISCOVERY_TSV"
}

scheme_from_url() {
    local url="$1"
    printf '%s' "${url%%:*}"
}

origin_from_url() {
    local url="$1"
    local scheme rest host

    scheme="$(scheme_from_url "$url")"
    rest="${url#*://}"
    host="${rest%%/*}"
    printf '%s://%s' "$scheme" "$host"
}

relative_target_path() {
    local path="$1"
    if [ "$path" = "$TARGET_DIR" ]; then
        printf '.'
    else
        printf '%s' "${path#"$TARGET_DIR"/}"
    fi
}

compute_hash() {
    local file="$1"

    if [ "$ENABLE_HASHING" -ne 1 ]; then
        printf ''
        return 0
    fi

    if have_cmd sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have_cmd shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif have_cmd openssl; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        printf ''
    fi
}

make_asset_filename() {
    local url="$1"
    local asset_type="$2"
    local storage_dir="$3"
    local base ext hash_suffix filename path_part

    hash_suffix="$(python3 - "$url" <<'PY'
import hashlib
import sys

value = sys.argv[1]
print(hashlib.sha1(value.encode()).hexdigest()[:10])
PY
)"

    base="${url#*://}"
    base="${base%%#*}"
    base="${base//\?/_q_}"
    base="${base//&/_and_}"
    base="${base//=/__}"
    base="${base//:/_}"
    base="${base//;/_}"
    base="${base//\%/_}"
    base="${base//+/_}"
    base="${base//\//_}"
    base="${base//[^[:alnum:]_.-]/_}"
    base="$(printf '%s' "$base" | sed -E 's/_+/_/g; s/^_+//; s/_+$//')"
    [ -n "$base" ] || base="asset"

    case "$asset_type" in
        mjs)
            ext=".mjs"
            ;;
        ts)
            ext=".ts"
            ;;
        map)
            ext=".map"
            ;;
        wasm)
            ext=".wasm"
            ;;
        webmanifest)
            ext=".webmanifest"
            ;;
        manifest)
            ext=".json"
            ;;
        json)
            ext=".json"
            ;;
        robots)
            ext=".txt"
            ;;
        sitemap)
            ext=".xml"
            ;;
        *)
            ext=".js"
            ;;
    esac

    path_part="${base%.*}"
    filename="${path_part:0:165}-${hash_suffix}${ext}"

    if [ -e "$storage_dir/$filename" ]; then
        filename="${path_part:0:145}-${hash_suffix}-${asset_type}${ext}"
    fi

    printf '%s' "$filename"
}

priority_for_type() {
    case "$1" in
        js|mjs|service-worker)
            printf '10'
            ;;
        ts|map|manifest|wasm)
            printf '20'
            ;;
        json|webmanifest)
            printf '30'
            ;;
        *)
            printf '50'
            ;;
    esac
}

is_downloadable_type() {
    case "$1" in
        js|mjs|ts|map|json|webmanifest|wasm|manifest|service-worker)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_js_like_type() {
    case "$1" in
        js|mjs|ts|service-worker)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

seed_common_root_candidates() {
    local base_url="$1"
    local origin

    origin="$(origin_from_url "$base_url")"

    record_raw_discovery "$origin/manifest.json" "manifest" "common-root" "$base_url"
    record_raw_discovery "$origin/site.webmanifest" "webmanifest" "common-root" "$base_url"
    record_raw_discovery "$origin/asset-manifest.json" "manifest" "common-root" "$base_url"
    record_raw_discovery "$origin/sw.js" "service-worker" "common-root" "$base_url"
    record_raw_discovery "$origin/service-worker.js" "service-worker" "common-root" "$base_url"
    record_raw_discovery "$origin/ngsw.json" "manifest" "common-root" "$base_url"
    record_raw_discovery "$origin/ngsw-worker.js" "service-worker" "common-root" "$base_url"
}

extract_candidate_urls_from_text() {
    local file="$1"
    local base_url="$2"
    local source="$3"

    [ -s "$file" ] || return 0

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:absolute" "$base_url"
    done < <(grep -aoEi 'https?://[^"'"'"' <>()]+' "$file" 2>/dev/null | sed -E 's/[),.;]+$//' || true)

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "map" "$source:sourcemap" "$base_url"
    done < <(grep -aoE 'sourceMappingURL=[^[:space:]*]+' "$file" 2>/dev/null | sed -E 's/.*sourceMappingURL=//' || true)

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:code" "$base_url"
    done < <(
        grep -aoE '(importScripts|import|require|fetch|Worker|register)\([^)]*\)' "$file" 2>/dev/null \
            | grep -aoE '["'"'"'][^"'"'"']+["'"'"']' 2>/dev/null \
            | sed -E 's/^["'"'"'](.*)["'"'"']$/\1/' || true
    )

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:module" "$base_url"
    done < <(grep -aoE 'from[[:space:]]+["'"'"'][^"'"'"']+["'"'"']' "$file" 2>/dev/null | sed -E 's/^from[[:space:]]+["'"'"'](.*)["'"'"']$/\1/' || true)

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:path" "$base_url"
    done < <(grep -aoEi '(/[^"'"'"' <>()]+(\.(js|mjs|ts|map|json|webmanifest|wasm))([?#][^"'"'"' <>()]+)?)' "$file" 2>/dev/null || true)

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:relative" "$base_url"
    done < <(grep -aoEi '((\./|\.\./)[^"'"'"' <>()]+(\.(js|mjs|ts|map|json|webmanifest|wasm))([?#][^"'"'"' <>()]+)?)' "$file" 2>/dev/null || true)

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "$source:framework" "$base_url"
    done < <(grep -aoEi '(/(_next|_nuxt|_astro|_app/immutable)/[^"'"'"' <>()]+)' "$file" 2>/dev/null || true)
}

extract_urls_from_headers() {
    local file="$1"
    local base_url="$2"

    [ -s "$file" ] || return 0

    while IFS= read -r candidate; do
        record_raw_discovery "$candidate" "" "headers:link" "$base_url"
    done < <(grep -i '^Link:' "$file" 2>/dev/null | grep -aoE '<[^>]+>' | tr -d '<>' || true)
}

fetch_sitemap_urls() {
    local sitemap_url="$1"
    local output_file="$2"

    curl -ksS -L \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_TIMEOUT" \
        --max-redirs "$MAX_REDIRECTS" \
        -A "$CURL_USER_AGENT" \
        "$sitemap_url" 2>> "$RUN_LOG" \
        | grep -aoEi 'https?://[^<"[:space:]]+' \
        > "$output_file" || true
}

fetch_live_host_artifacts() {
    local base_url="$1"
    local origin request_id header_file body_file robots_file sitemap_tmp status

    [ -n "$base_url" ] || return 0

    origin="$(origin_from_url "$base_url")"
    request_id="$(python3 - "$base_url" <<'PY'
import hashlib
import sys

print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:12])
PY
)"

    header_file="$WORK_DIR/http/${request_id}.headers"
    body_file="$WORK_DIR/http/${request_id}.body"
    robots_file="$WORK_DIR/http/${request_id}.robots"
    sitemap_tmp="$WORK_DIR/http/${request_id}.sitemap"

    [ "$PER_HOST_DELAY" = "0" ] || sleep "$PER_HOST_DELAY"

    status="$(curl -ksS -L \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_TIMEOUT" \
        --max-redirs "$MAX_REDIRECTS" \
        -A "$CURL_USER_AGENT" \
        -D "$header_file" \
        -o "$body_file" \
        -w '%{http_code}' \
        "$base_url" 2>> "$RUN_LOG" || printf '000')"

    if [[ "$status" =~ ^(2|3) ]]; then
        extract_urls_from_headers "$header_file" "$base_url"
        extract_candidate_urls_from_text "$body_file" "$base_url" "html"
        seed_common_root_candidates "$base_url"
    fi

    status="$(curl -ksS -L \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$HTTP_TIMEOUT" \
        --max-redirs "$MAX_REDIRECTS" \
        -A "$CURL_USER_AGENT" \
        -o "$robots_file" \
        -w '%{http_code}' \
        "$origin/robots.txt" 2>> "$RUN_LOG" || printf '000')"

    if [ "$status" = "200" ] && [ -s "$robots_file" ]; then
        record_raw_discovery "$origin/robots.txt" "robots" "robots" "$base_url"

        while IFS= read -r sitemap_url; do
            sitemap_url="$(trim "$sitemap_url")"
            [ -n "$sitemap_url" ] || continue
            record_raw_discovery "$sitemap_url" "sitemap" "robots:sitemap" "$base_url"
        done < <(grep -i '^Sitemap:' "$robots_file" 2>/dev/null | sed -E 's/^[Ss]itemap:[[:space:]]*//' | head -n "$MAX_SITEMAPS")
    fi

    record_raw_discovery "$origin/sitemap.xml" "sitemap" "common-root" "$base_url"

    while IFS= read -r sitemap_url; do
        [ -n "$sitemap_url" ] || continue
        : > "$sitemap_tmp"
        fetch_sitemap_urls "$sitemap_url" "$sitemap_tmp"
        while IFS= read -r candidate; do
            record_raw_discovery "$candidate" "" "sitemap:loc" "$sitemap_url"
        done < "$sitemap_tmp"
    done < <(
        {
            grep -i '^Sitemap:' "$robots_file" 2>/dev/null | sed -E 's/^[Ss]itemap:[[:space:]]*//'
            printf '%s\n' "$origin/sitemap.xml"
        } | awk 'NF' | head -n "$MAX_SITEMAPS" | sort -u
    )
}

source_subfinder() {
    local outfile="$1"
    subfinder -d "$TARGET" -silent -all > "$outfile" 2>> "$RUN_LOG" || true
}

source_amass() {
    local outfile="$1"
    safe_timeout 180 amass enum -passive -d "$TARGET" -o "$outfile" >> "$RUN_LOG" 2>&1 || true
}

source_crtsh() {
    local outfile="$1"

    curl -ksS --max-time "$CRTSH_TIMEOUT" "https://crt.sh/?q=%25.$TARGET&output=json" 2>> "$RUN_LOG" \
        | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

seen = set()
for entry in data:
    for name in entry.get("name_value", "").splitlines():
        value = name.strip().lower().lstrip("*.").rstrip(".")
        if value:
            seen.add(value)

for item in sorted(seen):
    print(item)
' > "$outfile" 2>> "$RUN_LOG"
}

source_wayback_urls() {
    local outfile="$1"
    curl -ksS --max-time "$WAYBACK_TIMEOUT" \
        "https://web.archive.org/cdx/search/cdx?url=*.$TARGET/*&output=text&fl=original&collapse=urlkey&limit=$WAYBACK_LIMIT" \
        > "$outfile" 2>> "$RUN_LOG" || true
}

source_gau_urls() {
    local outfile="$1"
    printf '%s\n' "$TARGET" | gau --threads "$GAU_THREADS" --subs > "$outfile" 2>> "$RUN_LOG" || true
}

source_chaos() {
    local outfile="$1"
    chaos -d "$TARGET" -silent -o "$outfile" >> "$RUN_LOG" 2>&1 || true
}

source_assetfinder() {
    local outfile="$1"
    assetfinder --subs-only "$TARGET" > "$outfile" 2>> "$RUN_LOG" || true
}

source_findomain() {
    local outfile="$1"
    findomain -t "$TARGET" -q > "$outfile" 2>> "$RUN_LOG" || true
}

source_puredns() {
    local outfile="$1"
    puredns bruteforce "$DNS_WORDLIST" "$TARGET" -r /etc/resolv.conf --wildcard-tests 5 -q > "$outfile" 2>> "$RUN_LOG" || true
}

run_bg_function() {
    local name="$1"
    local outfile="$2"
    local func="$3"
    shift 3

    info "  [$name] running..."
    throttle_jobs "$TOOL_PARALLELISM"

    (
        "$func" "$outfile" "$@"
        [ -f "$outfile" ] || : > "$outfile"
    ) &

    BG_JOBS+=("$name|$outfile|$!")
}

wait_for_bg_jobs() {
    local spec name outfile pid
    for spec in "${BG_JOBS[@]:-}"; do
        IFS='|' read -r name outfile pid <<< "$spec"
        wait "$pid" || true
        [ -f "$outfile" ] || : > "$outfile"
        ok "  $name: $(wc -l < "$outfile" 2>/dev/null || printf '0') hits"
    done
    BG_JOBS=()
}

normalize_subdomain_lines() {
    while IFS= read -r line; do
        line="$(trim "$line")"
        line="${line,,}"
        line="${line#*. }"
        line="${line#\*.}"
        line="${line%.}"
        line="${line%% *}"
        [ -n "$line" ] || continue
        if _validate_domain "$line" && { [ "$line" = "$TARGET" ] || [[ "$line" == *".$TARGET" ]]; }; then
            printf '%s\n' "$line"
        fi
    done
}

extract_subdomains_from_urls_file() {
    local infile="$1"
    local outfile="$2"

    [ -s "$infile" ] || {
        : > "$outfile"
        return 0
    }

    sed -nE 's|https?://([^/:?#]+).*|\1|p' "$infile" 2>/dev/null | normalize_subdomain_lines | sort -u > "$outfile"
}

record_asset_urls_from_file() {
    local infile="$1"
    local source="$2"
    [ -s "$infile" ] || return 0

    while IFS= read -r line; do
        line="$(trim "$line")"
        [ -n "$line" ] || continue
        case "${line,,}" in
            http://*|https://*)
                record_raw_discovery "$line" "" "$source" ""
                ;;
        esac
    done < "$infile"
}

aggregate_discoveries() {
    local raw_file="$1"
    local output_file="$2"

    python3 - "$TARGET" "$ENFORCE_DOMAIN_ALLOWLIST" "$raw_file" > "$output_file" <<'PY'
import csv
import sys
from collections import defaultdict
from urllib.parse import urljoin, urlsplit, urlunsplit

target = sys.argv[1].lower()
enforce_allowlist = sys.argv[2] == "1"
raw_path = sys.argv[3]

interesting_keywords = (
    "manifest",
    "service-worker",
    "ngsw",
    "workbox",
    "sourcemap",
    "source-map",
    "bootstrap",
    "config",
    "runtime",
    "polyfills",
    "chunk",
    "vendor",
    "remoteentry",
    "/_next/",
    "/_nuxt/",
    "/_astro/",
    "/_app/immutable/",
)


def normalize(raw: str, base: str) -> str:
    candidate = raw.strip().strip("\"'")
    candidate = candidate.replace("&amp;", "&")
    candidate = candidate.rstrip(")],;>")
    if not candidate:
        return None
    lower = candidate.lower()
    if lower.startswith(("javascript:", "data:", "mailto:", "tel:", "blob:")):
        return None
    if candidate.startswith("//"):
        candidate = "https:" + candidate
    elif not lower.startswith(("http://", "https://")):
        if not base:
            return None
        candidate = urljoin(base, candidate)

    try:
        parsed = urlsplit(candidate)
    except Exception:
        return None

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None

    host = parsed.netloc.lower()
    path = parsed.path or "/"
    normalized = urlunsplit((parsed.scheme.lower(), host, path, parsed.query, ""))
    return normalized


def classify(url: str, declared: str) -> str:
    declared = (declared or "").strip().lower()
    if declared:
        return declared

    parsed = urlsplit(url)
    path = parsed.path.lower()
    name = path.rsplit("/", 1)[-1]

    if path.endswith(".mjs"):
        return "mjs"
    if path.endswith(".ts"):
        return "ts"
    if path.endswith(".map"):
        return "map"
    if path.endswith(".wasm"):
        return "wasm"
    if path.endswith(".webmanifest"):
        return "webmanifest"
    if name == "robots.txt":
        return "robots"
    if name.endswith(".xml") and "sitemap" in name:
        return "sitemap"
    if any(marker in path for marker in ("service-worker", "ngsw-worker", "/sw.js")):
        return "service-worker"
    if name in {"manifest.json", "asset-manifest.json", "site.webmanifest", "ngsw.json"}:
        return "manifest"
    if path.endswith(".json"):
        if "manifest" in name:
            return "manifest"
        return "json"
    if path.endswith(".js") or path.endswith(".cjs"):
        return "js"
    return "other"


def is_interesting(url: str, asset_type: str) -> bool:
    path = urlsplit(url).path.lower()
    if asset_type in {"map", "wasm", "json", "manifest", "webmanifest", "service-worker", "robots", "sitemap"}:
        return True
    return any(keyword in path for keyword in interesting_keywords)


rows = defaultdict(lambda: {"sources": set(), "referrers": set(), "type": "", "host": "", "interesting": False})

with open(raw_path, "r", encoding="utf-8", errors="ignore") as handle:
    reader = csv.reader(handle, delimiter="\t")
    for row in reader:
        if not row:
            continue
        while len(row) < 4:
            row.append("")
        candidate, declared_type, source, referrer = row[:4]
        normalized = normalize(candidate, referrer)
        if not normalized:
            continue
        host = urlsplit(normalized).netloc.lower()
        if enforce_allowlist and host != target and not host.endswith("." + target):
            continue
        asset_type = classify(normalized, declared_type)
        interesting = is_interesting(normalized, asset_type)
        if asset_type == "other" and not interesting:
            continue

        entry = rows[normalized]
        entry["sources"].add(source or "unknown")
        if referrer:
            entry["referrers"].add(referrer)
        entry["host"] = host
        entry["interesting"] = entry["interesting"] or interesting

        current_type = entry["type"]
        if not current_type or current_type == "other":
            entry["type"] = asset_type
        elif current_type == "json" and asset_type == "manifest":
            entry["type"] = asset_type

for url in sorted(rows):
    entry = rows[url]
    print(
        "\t".join(
            [
                url,
                entry["type"] or "other",
                ",".join(sorted(entry["sources"])),
                entry["host"],
                "|".join(sorted(entry["referrers"])),
                "1" if entry["interesting"] else "0",
            ]
        )
    )
PY
}

build_download_plan() {
    local discovered_file="$1"
    local exclude_file="$2"
    local output_file="$3"
    local remaining_limit="$4"
    local tmp_file="$WORK_DIR/download_plan.tmp"
    local url asset_type sources host referrers interesting status_code content_type content_length final_url verification_method

    : > "$tmp_file"

    while IFS=$'\t' read -r url asset_type sources host referrers interesting status_code content_type content_length final_url verification_method; do
        [ -n "$url" ] || continue
        is_downloadable_type "$asset_type" || continue
        if [ -n "${status_code:-}" ] && ! [[ "$status_code" =~ ^(2|3) ]]; then
            continue
        fi
        if [ "$DOWNLOAD_INTERESTING_ASSETS" -ne 1 ] && ! is_js_like_type "$asset_type"; then
            continue
        fi
        if [ -s "$exclude_file" ] && grep -Fqx "$url" "$exclude_file"; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(priority_for_type "$asset_type")" "$url" "$asset_type" "$sources" "$host" "$referrers" "$interesting" >> "$tmp_file"
    done < "$discovered_file"

    if [ -s "$tmp_file" ]; then
        sort -t $'\t' -k1,1n -k2,2 "$tmp_file" | head -n "$remaining_limit" > "$output_file"
    else
        : > "$output_file"
    fi
}

build_verification_queue() {
    local discovered_file="$1"
    local output_file="$2"
    local queue_limit="$3"
    local tmp_file="$WORK_DIR/verification_queue.tmp"
    local url asset_type sources host referrers interesting

    : > "$tmp_file"

    while IFS=$'\t' read -r url asset_type sources host referrers interesting; do
        [ -n "$url" ] || continue
        is_downloadable_type "$asset_type" || continue
        if [ "$DOWNLOAD_INTERESTING_ASSETS" -ne 1 ] && ! is_js_like_type "$asset_type"; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(priority_for_type "$asset_type")" "$url" "$asset_type" "$sources" "$host" "$referrers" "$interesting" >> "$tmp_file"
    done < "$discovered_file"

    if [ -s "$tmp_file" ]; then
        sort -t $'\t' -k1,1n -k2,2 "$tmp_file" | head -n "$queue_limit" > "$output_file"
    else
        : > "$output_file"
    fi
}

verify_candidate_urls() {
    local queue_file="$WORK_DIR/verification_queue.tsv"
    local queue_urls="$WORK_DIR/verification_urls.txt"
    local verify_json="$WORK_DIR/verification.jsonl"

    if [ "$VERIFICATION_ENABLED" -ne 1 ]; then
        warn "Phase 3b: Verification disabled — using discovered assets directly"
        return 0
    fi

    if [ ! -s "$DISCOVERED_TSV" ]; then
        warn "Phase 3b: No discovered assets available for verification"
        return 0
    fi

    if ! have_cmd httpx; then
        if [ -s "$VERIFIED_TSV" ]; then
            warn "Phase 3b: httpx not installed — reusing saved verified assets"
        else
            warn "Phase 3b: httpx not installed — skipping pre-download verification"
        fi
        return 0
    fi

    : > "$VERIFIED_TSV"
    : > "$VERIFICATION_FILTERED_TSV"

    info "Phase 3b: Verifying candidate assets"
    build_verification_queue "$DISCOVERED_TSV" "$queue_file" "$MAX_VERIFY"

    if [ ! -s "$queue_file" ]; then
        warn "  No candidate assets require verification"
        return 0
    fi

    cut -f2 "$queue_file" > "$queue_urls"
    : > "$verify_json"

    httpx -l "$queue_urls" \
        -silent \
        -json \
        -threads "$HTTPX_THREADS" \
        -timeout "$HTTP_TIMEOUT" \
        -follow-redirects \
        -status-code \
        -content-type \
        -content-length \
        -o "$verify_json" 2>> "$RUN_LOG" || true

    python3 - "$queue_file" "$verify_json" "$VERIFIED_TSV" "$VERIFICATION_FILTERED_TSV" <<'PY'
import csv
import json
import sys

queue_path, jsonl_path, verified_path, filtered_path = sys.argv[1:5]

queue = {}
with open(queue_path, "r", encoding="utf-8", errors="ignore") as handle:
    reader = csv.reader(handle, delimiter="\t")
    for row in reader:
        if len(row) < 7:
            continue
        _, url, asset_type, sources, host, referrers, interesting = row[:7]
        queue[url] = {
            "asset_type": asset_type,
            "sources": sources,
            "host": host,
            "referrers": referrers,
            "interesting": interesting,
        }


def get_value(record, *names):
    for name in names:
        if name in record and record[name] not in (None, ""):
            return record[name]
    return ""


verified_rows = []
filtered_rows = []
seen = set()

with open(jsonl_path, "r", encoding="utf-8", errors="ignore") as handle:
    for raw_line in handle:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            record = json.loads(raw_line)
        except Exception:
            continue

        original = str(get_value(record, "input", "url"))
        final_url = str(get_value(record, "url", "final_url", "final-url")) or original
        if original not in queue:
            if final_url in queue:
                original = final_url
            else:
                continue

        if original in seen:
            continue
        seen.add(original)

        meta = queue[original]
        status = str(get_value(record, "status_code", "status-code", "status"))
        content_type = str(get_value(record, "content_type", "content-type"))
        content_length = str(get_value(record, "content_length", "content-length"))

        base_row = [
            original,
            meta["asset_type"],
            meta["sources"],
            meta["host"],
            meta["referrers"],
            meta["interesting"],
            status,
            content_type,
            content_length,
            final_url or original,
            "httpx",
        ]

        if status.startswith(("2", "3")):
            verified_rows.append(base_row)
        else:
            filtered_rows.append(base_row + ["status-filtered"])

with open(verified_path, "w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
    writer.writerows(sorted(verified_rows, key=lambda row: row[0]))

with open(filtered_path, "w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
    writer.writerows(sorted(filtered_rows, key=lambda row: row[0]))
PY

    ok "  Verified assets: $(wc -l < "$VERIFIED_TSV" 2>/dev/null || printf '0')"
    if [ -s "$VERIFICATION_FILTERED_TSV" ]; then
        warn "  Filtered during verification: $(wc -l < "$VERIFICATION_FILTERED_TSV" 2>/dev/null || printf '0')"
    fi
}

download_candidate() {
    local url="$1"
    local asset_type="$2"
    local sources="$3"
    local host="$4"
    local referrers="$5"
    local interesting="$6"
    local storage_dir filename relative_path tmp_file header_file meta http_status content_type content_length final_url hash_value

    if is_js_like_type "$asset_type"; then
        storage_dir="$TARGET_DIR"
    else
        storage_dir="$INTERESTING_DIR"
    fi

    filename="$(make_asset_filename "$url" "$asset_type" "$storage_dir")"
    relative_path="$(relative_target_path "$storage_dir/$filename")"

    if [ -s "$storage_dir/$filename" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$asset_type" "$relative_path" "exists" "$sources" "$referrers" "$interesting" >> "$SKIPPED_RAW_TSV"
        return 0
    fi

    tmp_file="$WORK_DIR/downloads/${BASHPID}-${filename}.tmp"
    header_file="$WORK_DIR/downloads/${BASHPID}-${filename}.headers"

    meta="$(curl -ksS -L \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_TIMEOUT" \
        --max-redirs "$MAX_REDIRECTS" \
        --retry "$DOWNLOAD_RETRIES" \
        --retry-delay 2 \
        -A "$CURL_USER_AGENT" \
        -D "$header_file" \
        -o "$tmp_file" \
        -w '%{http_code}\t%{content_type}\t%{size_download}\t%{url_effective}' \
        "$url" 2>> "$RUN_LOG" || printf '000\t\t0\t')"

    IFS=$'\t' read -r http_status content_type content_length final_url <<< "$meta"
    final_url="$(trim "$final_url")"
    content_type="$(trim "$content_type")"
    content_length="$(trim "$content_length")"

    if [ "$http_status" = "429" ] || [ "$http_status" = "000" ] || [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file" "$header_file" 2>/dev/null || true
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$asset_type" "$http_status" "$content_type" "$content_length" "$final_url" "$sources" "empty-or-rate-limited" >> "$FAILED_RAW_TSV"
        return 0
    fi

    if ! [[ "$http_status" =~ ^(2|3) ]]; then
        rm -f "$tmp_file" "$header_file" 2>/dev/null || true
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$asset_type" "$http_status" "$content_type" "$content_length" "$final_url" "$sources" "http-failure" >> "$FAILED_RAW_TSV"
        return 0
    fi

    if [ -e "$storage_dir/$filename" ]; then
        rm -f "$tmp_file" "$header_file" 2>/dev/null || true
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$asset_type" "$relative_path" "exists" "$sources" "$referrers" "$interesting" >> "$SKIPPED_RAW_TSV"
        return 0
    fi

    if ! mv "$tmp_file" "$storage_dir/$filename"; then
        rm -f "$tmp_file" "$header_file" 2>/dev/null || true
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$asset_type" "$http_status" "$content_type" "$content_length" "$final_url" "$sources" "move-failure" >> "$FAILED_RAW_TSV"
        return 0
    fi

    rm -f "$header_file" 2>/dev/null || true
    hash_value="$(compute_hash "$storage_dir/$filename")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$url" "$asset_type" "$relative_path" "$http_status" "$content_type" "$content_length" "$final_url" "$hash_value" "$sources" "$referrers" >> "$DOWNLOADED_RAW_TSV"
}

extract_recursive_candidates() {
    local mapped_line local_path original_url absolute_path

    [ -s "$DOWNLOADED_RAW_TSV" ] || return 0

    while IFS=$'\t' read -r original_url asset_type local_path http_status content_type content_length final_url hash_value sources referrers; do
        [ -n "$local_path" ] || continue
        absolute_path="$TARGET_DIR/$local_path"

        case "$local_path" in
            _interesting/*)
                absolute_path="$TARGET_DIR/$local_path"
                ;;
            *)
                absolute_path="$TARGET_DIR/$local_path"
                ;;
        esac

        [ -f "$absolute_path" ] || continue

        case "$asset_type" in
            js|mjs|ts|map|json|manifest|webmanifest|service-worker)
                extract_candidate_urls_from_text "$absolute_path" "$final_url" "downloaded:$asset_type"
                ;;
        esac
    done < "$DOWNLOADED_RAW_TSV"
}

write_tsv_with_header() {
    local header="$1"
    local source_file="$2"
    local output_file="$3"

    {
        printf '%s\n' "$header"
        [ -s "$source_file" ] && cat "$source_file"
    } > "$output_file"
}

write_csv_and_json() {
    local tsv_file="$1"
    local csv_file="$2"
    local json_file="$3"

    python3 - "$tsv_file" "$csv_file" "$json_file" "$OUTPUT_CSV" "$OUTPUT_JSON" <<'PY'
import csv
import json
import sys

tsv_path, csv_path, json_path, write_csv, write_json = sys.argv[1:6]
rows = []

with open(tsv_path, "r", encoding="utf-8", errors="ignore") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    rows = list(reader)

if write_csv == "1":
    with open(csv_path, "w", encoding="utf-8", newline="") as handle:
        if rows:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        else:
            handle.write("")

if write_json == "1":
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=2)
PY
}

generate_reports() {
    local attempted_urls_file="$WORK_DIR/attempted_urls.txt"
    : > "$attempted_urls_file"

    [ -s "$DOWNLOADED_RAW_TSV" ] && cut -f1 "$DOWNLOADED_RAW_TSV" >> "$attempted_urls_file"
    [ -s "$FAILED_RAW_TSV" ] && cut -f1 "$FAILED_RAW_TSV" >> "$attempted_urls_file"
    [ -s "$SKIPPED_RAW_TSV" ] && cut -f1 "$SKIPPED_RAW_TSV" >> "$attempted_urls_file"
    sort -u "$attempted_urls_file" -o "$attempted_urls_file"

    write_tsv_with_header 'url	asset_type	sources	host	referrers	interesting' "$DISCOVERED_TSV" "$DISCOVERED_REPORT_TSV"
    write_tsv_with_header 'url	asset_type	sources	host	referrers	interesting	status_code	content_type	content_length	final_url	verification_method' "$VERIFIED_TSV" "$VERIFIED_REPORT_TSV"
    write_tsv_with_header 'url	asset_type	sources	host	referrers	interesting	status_code	content_type	content_length	final_url	verification_method	reason' "$VERIFICATION_FILTERED_TSV" "$VERIFICATION_FILTERED_REPORT_TSV"
    write_tsv_with_header 'url	asset_type	local_path	http_status	content_type	content_length	final_url	sha256	sources	referrers' "$DOWNLOADED_RAW_TSV" "$DOWNLOADED_REPORT_TSV"
    write_tsv_with_header 'url	asset_type	local_path	reason	sources	referrers	interesting' "$SKIPPED_RAW_TSV" "$SKIPPED_REPORT_TSV"
    write_tsv_with_header 'url	asset_type	http_status	content_type	content_length	final_url	sources	reason' "$FAILED_RAW_TSV" "$FAILED_REPORT_TSV"

    {
        printf 'url\tasset_type\tsources\thost\treferrers\tinteresting\n'
        awk -F '\t' 'NR > 0 && $2 !~ /^(js|mjs|ts|service-worker)$/ { print }' "$DISCOVERED_TSV" 2>/dev/null || true
    } > "$NON_JS_REPORT_TSV"

    {
        printf 'url\tasset_type\tsources\thost\treferrers\tinteresting\n'
        awk -F '\t' 'NR > 0 && $6 == 1 { print }' "$DISCOVERED_TSV" 2>/dev/null || true
    } > "$INTERESTING_REPORT_TSV"

    {
        [ -s "$DOWNLOADED_RAW_TSV" ] && awk -F '\t' '{ printf "%s %s %s %s %s\n", $3, $1, $2, $8, $9 }' "$DOWNLOADED_RAW_TSV"
    } > "$URL_MAP_FILE"

    cp "$LIVE_FILE" "$LIVE_REPORT" 2>/dev/null || :

    if [ "$OUTPUT_CSV" -eq 1 ] || [ "$OUTPUT_JSON" -eq 1 ]; then
        write_csv_and_json "$DISCOVERED_REPORT_TSV" "$REPORTS_DIR/discovered_urls.csv" "$REPORTS_DIR/discovered_urls.json"
        write_csv_and_json "$VERIFIED_REPORT_TSV" "$REPORTS_DIR/verified_urls.csv" "$REPORTS_DIR/verified_urls.json"
        write_csv_and_json "$VERIFICATION_FILTERED_REPORT_TSV" "$REPORTS_DIR/verification_filtered.csv" "$REPORTS_DIR/verification_filtered.json"
        write_csv_and_json "$DOWNLOADED_REPORT_TSV" "$REPORTS_DIR/downloaded_files.csv" "$REPORTS_DIR/downloaded_files.json"
        write_csv_and_json "$FAILED_REPORT_TSV" "$REPORTS_DIR/failed_downloads.csv" "$REPORTS_DIR/failed_downloads.json"
        write_csv_and_json "$SKIPPED_REPORT_TSV" "$REPORTS_DIR/skipped_duplicates.csv" "$REPORTS_DIR/skipped_duplicates.json"
        write_csv_and_json "$NON_JS_REPORT_TSV" "$REPORTS_DIR/non_js_assets.csv" "$REPORTS_DIR/non_js_assets.json"
        write_csv_and_json "$INTERESTING_REPORT_TSV" "$REPORTS_DIR/potential_interesting.csv" "$REPORTS_DIR/potential_interesting.json"
    fi
}

generate_framework_hints() {
    : > "$FRAMEWORK_REPORT"

    if grep -Eq '/_next/|_buildManifest|__NEXT_DATA__' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Next.js' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq '/_nuxt/|__NUXT__' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Nuxt' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq '/_astro/|astro-island' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Astro' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq '/_app/immutable/|__SVELTEKIT_' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'SvelteKit' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq '@vite/client|import.meta.env' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Vite' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq '__webpack_require__|webpackChunk|remoteEntry' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Webpack' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq 'ngsw.json|ngsw-worker|ng-version' "$DISCOVERED_TSV" "$TARGET_DIR"/*.js "$INTERESTING_DIR"/* 2>/dev/null; then
        printf '%s\n' 'Angular' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq 'react.production|__REACT_DEVTOOLS' "$TARGET_DIR"/*.js 2>/dev/null; then
        printf '%s\n' 'React' >> "$FRAMEWORK_REPORT"
    fi
    if grep -Eq 'vue.runtime|__VUE__' "$TARGET_DIR"/*.js 2>/dev/null; then
        printf '%s\n' 'Vue' >> "$FRAMEWORK_REPORT"
    fi

    sort -u "$FRAMEWORK_REPORT" -o "$FRAMEWORK_REPORT" 2>/dev/null || true
}

print_header() {
    echo ""
    echo "==========================================="
    echo "  recon-js.sh — $TARGET"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  profile: $RECON_PROFILE"
    echo "==========================================="
    echo ""
}

setup_paths() {
    ALL_DOMAINS_DIR="${ALL_DOMAINS_DIR:-$HOME/01-All-Domains}"
    JS_DOWNLOAD_ROOT="${JS_DOWNLOAD_DIR:-$HOME/03-JS-Download}"
    DNS_WORDLIST="${DNS_WORDLIST:-$HOME/wordlists/best-dns-wordlist.txt}"

    TARGET_DIR="$JS_DOWNLOAD_ROOT/$TARGET"
    REPORTS_DIR="$TARGET_DIR/reports"
    INTERESTING_DIR="$TARGET_DIR/_interesting"

    WORK_DIR="$(make_work_dir)" || {
        err "Unable to create a temporary work directory."
        exit 1
    }
    trap cleanup EXIT INT TERM HUP

    _ensure_dir "$ALL_DOMAINS_DIR"
    _ensure_dir "$TARGET_DIR"
    _ensure_dir "$REPORTS_DIR"
    _ensure_dir "$INTERESTING_DIR"

    mkdir -p "$WORK_DIR/subs" "$WORK_DIR/http" "$WORK_DIR/downloads"

    RUN_LOG="$REPORTS_DIR/run.log"
    if [ "$RESUME" -eq 1 ]; then
        printf '\n----- %s -----\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RUN_LOG"
    else
        : > "$RUN_LOG"
    fi

    SUBS_RAW="$WORK_DIR/subs"
    SUBS_FILE="$WORK_DIR/all_subs.txt"
    LIVE_FILE="$WORK_DIR/live_hosts.txt"
    RAW_DISCOVERY_TSV="$WORK_DIR/discovered_raw.tsv"
    DISCOVERED_TSV="$WORK_DIR/discovered.tsv"
    VERIFIED_TSV="$WORK_DIR/verified.tsv"
    VERIFICATION_FILTERED_TSV="$WORK_DIR/verification_filtered.tsv"
    ROUND1_PLAN="$WORK_DIR/download_plan_round1.tsv"
    ROUND2_PLAN="$WORK_DIR/download_plan_round2.tsv"
    DOWNLOADED_RAW_TSV="$WORK_DIR/downloaded_raw.tsv"
    FAILED_RAW_TSV="$WORK_DIR/failed_raw.tsv"
    SKIPPED_RAW_TSV="$WORK_DIR/skipped_raw.tsv"
    GAU_URLS_FILE="$WORK_DIR/gau_urls.txt"
    WAYBACK_URLS_FILE="$WORK_DIR/wayback_urls.txt"
    KATANA_FILE="$WORK_DIR/katana_urls.txt"

    SUBDOMAIN_REPORT="$ALL_DOMAINS_DIR/$TARGET.txt"
    LIVE_REPORT="$REPORTS_DIR/live_hosts.txt"
    DISCOVERED_REPORT_TSV="$REPORTS_DIR/discovered_urls.tsv"
    VERIFIED_REPORT_TSV="$REPORTS_DIR/verified_urls.tsv"
    VERIFICATION_FILTERED_REPORT_TSV="$REPORTS_DIR/verification_filtered.tsv"
    DOWNLOADED_REPORT_TSV="$REPORTS_DIR/downloaded_files.tsv"
    FAILED_REPORT_TSV="$REPORTS_DIR/failed_downloads.tsv"
    SKIPPED_REPORT_TSV="$REPORTS_DIR/skipped_duplicates.tsv"
    NON_JS_REPORT_TSV="$REPORTS_DIR/non_js_assets.tsv"
    INTERESTING_REPORT_TSV="$REPORTS_DIR/potential_interesting.tsv"
    FRAMEWORK_REPORT="$REPORTS_DIR/framework_hints.txt"
    URL_MAP_FILE="$TARGET_DIR/url_map.txt"

    : > "$SUBS_FILE"
    : > "$LIVE_FILE"
    : > "$RAW_DISCOVERY_TSV"
    : > "$DISCOVERED_TSV"
    : > "$VERIFIED_TSV"
    : > "$VERIFICATION_FILTERED_TSV"
    : > "$DOWNLOADED_RAW_TSV"
    : > "$FAILED_RAW_TSV"
    : > "$SKIPPED_RAW_TSV"
    : > "$WAYBACK_URLS_FILE"
    : > "$GAU_URLS_FILE"
    : > "$KATANA_FILE"
}

seed_resume_state() {
    if [ "$RESUME" -ne 1 ]; then
        return 0
    fi

    if [ -s "$SUBDOMAIN_REPORT" ]; then
        cat "$SUBDOMAIN_REPORT" > "$SUBS_FILE"
        info "Resuming with saved subdomains: $(wc -l < "$SUBS_FILE" 2>/dev/null || printf '0')"
    fi

    if [ -s "$DISCOVERED_REPORT_TSV" ]; then
        tail -n +2 "$DISCOVERED_REPORT_TSV" | while IFS=$'\t' read -r url asset_type sources host referrers interesting; do
            [ -n "$url" ] || continue
            printf '%s\t%s\t%s\t%s\n' "$url" "$asset_type" "resume" "$url" >> "$RAW_DISCOVERY_TSV"
        done
    fi

    if [ -s "$VERIFIED_REPORT_TSV" ]; then
        tail -n +2 "$VERIFIED_REPORT_TSV" > "$VERIFIED_TSV"
        info "Resuming with saved verified assets: $(wc -l < "$VERIFIED_TSV" 2>/dev/null || printf '0')"
    fi

    if [ -s "$DOWNLOADED_REPORT_TSV" ]; then
        tail -n +2 "$DOWNLOADED_REPORT_TSV" > "$DOWNLOADED_RAW_TSV"
        info "Resuming with saved downloaded assets: $(wc -l < "$DOWNLOADED_RAW_TSV" 2>/dev/null || printf '0')"
    fi

    if [ -s "$LIVE_REPORT" ]; then
        cp "$LIVE_REPORT" "$LIVE_FILE"
    fi
}

enumerate_subdomains() {
    local wayback_subs gau_subs historical_seed tmp_merge

    info "Phase 1: Subdomain Enumeration"
    BG_JOBS=()

    if have_cmd subfinder; then
        run_bg_function "subfinder" "$SUBS_RAW/subfinder.txt" source_subfinder
    else
        warn "  subfinder not installed — skipping"
    fi

    if have_cmd amass; then
        run_bg_function "amass" "$SUBS_RAW/amass.txt" source_amass
    else
        warn "  amass not installed — skipping"
    fi

    run_bg_function "crt.sh" "$SUBS_RAW/crtsh.txt" source_crtsh
    run_bg_function "wayback" "$WAYBACK_URLS_FILE" source_wayback_urls

    if have_cmd gau; then
        run_bg_function "gau" "$GAU_URLS_FILE" source_gau_urls
    else
        warn "  gau not installed — skipping"
    fi

    if have_cmd chaos; then
        run_bg_function "chaos" "$SUBS_RAW/chaos.txt" source_chaos
    else
        warn "  chaos not installed — skipping"
    fi

    if have_cmd assetfinder; then
        run_bg_function "assetfinder" "$SUBS_RAW/assetfinder.txt" source_assetfinder
    else
        warn "  assetfinder not installed — skipping"
    fi

    if have_cmd findomain; then
        run_bg_function "findomain" "$SUBS_RAW/findomain.txt" source_findomain
    else
        warn "  findomain not installed — skipping"
    fi

    if have_cmd puredns && [ -f "$DNS_WORDLIST" ]; then
        run_bg_function "puredns" "$SUBS_RAW/puredns.txt" source_puredns
    elif have_cmd puredns; then
        warn "  puredns installed but wordlist not found: $DNS_WORDLIST — skipping brute force"
    else
        warn "  puredns not installed — skipping DNS brute force"
    fi

    wait_for_bg_jobs

    wayback_subs="$WORK_DIR/wayback_subs.txt"
    gau_subs="$WORK_DIR/gau_subs.txt"
    extract_subdomains_from_urls_file "$WAYBACK_URLS_FILE" "$wayback_subs"
    extract_subdomains_from_urls_file "$GAU_URLS_FILE" "$gau_subs"

    {
        [ -s "$SUBDOMAIN_REPORT" ] && cat "$SUBDOMAIN_REPORT"
        cat "$SUBS_RAW"/*.txt 2>/dev/null || true
        [ -s "$wayback_subs" ] && cat "$wayback_subs"
        [ -s "$gau_subs" ] && cat "$gau_subs"
    } | normalize_subdomain_lines | sort -u > "$SUBS_FILE"

    tmp_merge="$(mktemp "$ALL_DOMAINS_DIR/.${TARGET//./_}.XXXXXX")"
    {
        [ -s "$SUBDOMAIN_REPORT" ] && cat "$SUBDOMAIN_REPORT"
        cat "$SUBS_FILE"
    } | normalize_subdomain_lines | sort -u > "$tmp_merge"
    mv "$tmp_merge" "$SUBDOMAIN_REPORT"

    ok "Total unique subdomains: $(wc -l < "$SUBS_FILE" 2>/dev/null || printf '0')"
    ok "Subdomains saved: $SUBDOMAIN_REPORT ($(wc -l < "$SUBDOMAIN_REPORT" 2>/dev/null || printf '0') total)"
}

probe_live_hosts() {
    info "Phase 2: HTTP Probing"

    if [ ! -s "$SUBS_FILE" ]; then
        warn "  No subdomains available — skipping live probing"
        return 0
    fi

    if have_cmd httpx; then
        info "  [httpx] probing $(wc -l < "$SUBS_FILE") subdomains..."
        httpx -l "$SUBS_FILE" -silent -threads "$HTTPX_THREADS" -timeout "$HTTP_TIMEOUT" -follow-redirects -o "$LIVE_FILE" 2>> "$RUN_LOG" || true
    else
        warn "  httpx not installed — falling back to http/https host list"
        while IFS= read -r sub; do
            printf 'https://%s\n' "$sub"
            printf 'http://%s\n' "$sub"
        done < "$SUBS_FILE" | sort -u > "$LIVE_FILE"
    fi

    if [ ! -s "$LIVE_FILE" ] && [ "$RESUME" -eq 1 ] && [ -s "$LIVE_REPORT" ]; then
        cp "$LIVE_REPORT" "$LIVE_FILE"
    fi

    sort -u "$LIVE_FILE" -o "$LIVE_FILE" 2>/dev/null || true
    ok "  Live hosts: $(wc -l < "$LIVE_FILE" 2>/dev/null || printf '0')"
}

run_parallel_getjs() {
    local limited_live="$1"

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        throttle_jobs "$GETJS_CONCURRENCY"
        (
            getJS --url "$url" --complete 2>> "$RUN_LOG" | while IFS= read -r found; do
                record_raw_discovery "$found" "" "getJS" "$url"
            done
        ) &
    done < "$limited_live"

    wait
}

run_parallel_live_fetch() {
    local limited_live="$1"

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        throttle_jobs "$ACTIVE_FETCH_CONCURRENCY"
        fetch_live_host_artifacts "$url" &
    done < "$limited_live"

    wait
}

discover_assets() {
    local limited_live="$WORK_DIR/live_hosts_limited.txt"

    info "Phase 3: Client-Side Asset Discovery"

    head -n "$MAX_ACTIVE_HOSTS" "$LIVE_FILE" > "$limited_live" 2>/dev/null || : > "$limited_live"

    if [ -s "$WAYBACK_URLS_FILE" ]; then
        record_asset_urls_from_file "$WAYBACK_URLS_FILE" "wayback"
    fi

    if [ -s "$GAU_URLS_FILE" ]; then
        record_asset_urls_from_file "$GAU_URLS_FILE" "gau"
    fi

    if have_cmd subjs && [ -s "$limited_live" ]; then
        info "  [subjs] extracting from live hosts..."
        subjs -i "$limited_live" 2>> "$RUN_LOG" | while IFS= read -r found; do
            record_raw_discovery "$found" "" "subjs" ""
        done
    else
        warn "  subjs not installed or no live hosts — skipping"
    fi

    if have_cmd getJS && [ -s "$limited_live" ]; then
        info "  [getJS] extracting from live hosts..."
        run_parallel_getjs "$limited_live"
    else
        warn "  getJS not installed or no live hosts — skipping"
    fi

    if have_cmd katana && [ -s "$limited_live" ]; then
        info "  [katana] crawling (depth $KATANA_DEPTH, timeout ${KATANA_TIMEOUT}s)..."
        safe_timeout "$KATANA_TIMEOUT" katana -list "$limited_live" -silent -jc -d "$KATANA_DEPTH" -o "$KATANA_FILE" >> "$RUN_LOG" 2>&1 || true
        record_asset_urls_from_file "$KATANA_FILE" "katana"
    else
        warn "  katana not installed or no live hosts — skipping"
    fi

    if [ -s "$limited_live" ]; then
        info "  [html/service-worker/manifest] fetching root pages, robots, and sitemaps..."
        run_parallel_live_fetch "$limited_live"
    fi

    aggregate_discoveries "$RAW_DISCOVERY_TSV" "$DISCOVERED_TSV"
    ok "  Discovered candidate assets: $(wc -l < "$DISCOVERED_TSV" 2>/dev/null || printf '0')"
}

download_plan() {
    local plan_file="$1"
    local round_label="$2"
    local count url asset_type sources host referrers interesting

    count="$(wc -l < "$plan_file" 2>/dev/null || printf '0')"
    if [ "$count" -eq 0 ]; then
        warn "  No assets scheduled for $round_label download"
        return 0
    fi

    info "Phase 4: Downloading assets ($round_label, $count planned)"

    while IFS=$'\t' read -r _priority url asset_type sources host referrers interesting; do
        [ -n "$url" ] || continue
        throttle_jobs "$DOWNLOAD_CONCURRENCY"
        download_candidate "$url" "$asset_type" "$sources" "$host" "$referrers" "$interesting" &
    done < "$plan_file"

    wait
}

summarize() {
    local js_download_count interesting_count failed_count skipped_count total_discovered total_verified

    total_discovered=$(( $(wc -l < "$DISCOVERED_TSV" 2>/dev/null || printf '0') ))
    total_verified=$(( $(wc -l < "$VERIFIED_TSV" 2>/dev/null || printf '0') ))
    js_download_count=$(awk -F '\t' '$2 ~ /^(js|mjs|ts|service-worker)$/ { count++ } END { print count+0 }' "$DOWNLOADED_RAW_TSV" 2>/dev/null)
    interesting_count=$(awk -F '\t' '$2 !~ /^(js|mjs|ts|service-worker)$/ { count++ } END { print count+0 }' "$DOWNLOADED_RAW_TSV" 2>/dev/null)
    failed_count=$(wc -l < "$FAILED_RAW_TSV" 2>/dev/null || printf '0')
    skipped_count=$(wc -l < "$SKIPPED_RAW_TSV" 2>/dev/null || printf '0')

    echo ""
    echo "==========================================="
    ok "  DONE — $TARGET"
    ok "  Subdomains         : $SUBDOMAIN_REPORT ($(wc -l < "$SUBDOMAIN_REPORT" 2>/dev/null || printf '0') total)"
    ok "  Discovered URLs    : $DISCOVERED_REPORT_TSV ($total_discovered entries)"
    ok "  Verified URLs      : $VERIFIED_REPORT_TSV ($total_verified entries)"
    ok "  Downloaded JS-like : $js_download_count"
    ok "  Interesting assets : $interesting_count"
    [ "$failed_count" -gt 0 ] && warn "  Failed downloads   : $failed_count"
    [ "$skipped_count" -gt 0 ] && warn "  Skipped duplicates : $skipped_count"
    ok "  URL Map            : $URL_MAP_FILE"
    ok "  Reports            : $REPORTS_DIR/"
    echo "==========================================="
    echo ""
    info "Next steps:"
    echo "  jsecret -d $TARGET_DIR"
    echo "  jsecret -f $DISCOVERED_REPORT_TSV"
    echo "  grep 'filename.js' $URL_MAP_FILE"
    echo ""
}

maybe_notify() {
    if have_cmd notify-send; then
        notify-send "recon-js ✓" "Scan complete for $TARGET\n▸ Subdomains: $(wc -l < "$SUBDOMAIN_REPORT" 2>/dev/null || printf '0')\n▸ Downloaded JS-like: $(awk -F '\t' '$2 ~ /^(js|mjs|ts|service-worker)$/ { count++ } END { print count+0 }' "$DOWNLOADED_RAW_TSV" 2>/dev/null)" >/dev/null 2>&1 || true
    fi
}

main() {
    local attempted_urls remaining_budget download_source_file

    ensure_bash_compat
    parse_args "$@"

    if [ -z "$TARGET" ]; then
        echo ""
        echo -e "${CYAN}[?]${NC} Target domain (e.g. example.com): "
        read -r TARGET
        TARGET="$(trim "${TARGET,,}")"
    else
        TARGET="$(trim "${TARGET,,}")"
    fi

    if [ -z "$TARGET" ]; then
        err "No domain provided."
        print_usage >&2
        exit 1
    fi

    if ! _validate_domain "$TARGET"; then
        err "Invalid target domain: '$TARGET'"
        exit 1
    fi

    apply_profile_defaults
    setup_paths
    print_header
    seed_resume_state

    enumerate_subdomains
    probe_live_hosts
    discover_assets
    verify_candidate_urls

    download_source_file="$DISCOVERED_TSV"
    [ -s "$VERIFIED_TSV" ] && download_source_file="$VERIFIED_TSV"

    build_download_plan "$download_source_file" /dev/null "$ROUND1_PLAN" "$MAX_DOWNLOADS"
    download_plan "$ROUND1_PLAN" "round 1"

    extract_recursive_candidates
    aggregate_discoveries "$RAW_DISCOVERY_TSV" "$DISCOVERED_TSV"
    verify_candidate_urls

    download_source_file="$DISCOVERED_TSV"
    [ -s "$VERIFIED_TSV" ] && download_source_file="$VERIFIED_TSV"

    attempted_urls="$WORK_DIR/attempted_urls.txt"
    : > "$attempted_urls"
    [ -s "$DOWNLOADED_RAW_TSV" ] && cut -f1 "$DOWNLOADED_RAW_TSV" >> "$attempted_urls"
    [ -s "$FAILED_RAW_TSV" ] && cut -f1 "$FAILED_RAW_TSV" >> "$attempted_urls"
    [ -s "$SKIPPED_RAW_TSV" ] && cut -f1 "$SKIPPED_RAW_TSV" >> "$attempted_urls"
    sort -u "$attempted_urls" -o "$attempted_urls" 2>/dev/null || true

    remaining_budget=$(( MAX_DOWNLOADS - $(wc -l < "$attempted_urls" 2>/dev/null || printf '0') ))
    if [ "$remaining_budget" -gt 0 ]; then
        build_download_plan "$download_source_file" "$attempted_urls" "$ROUND2_PLAN" "$remaining_budget"
        download_plan "$ROUND2_PLAN" "round 2"
    fi

    generate_reports
    generate_framework_hints
    summarize
    maybe_notify
}

main "$@"
