#!/bin/bash
# install.sh — Download required wordlist for recon-js.sh DNS brute force
# Run once before using recon-js.sh

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

WORDLIST_DIR="$HOME/wordlists"
WORDLIST="$WORDLIST_DIR/best-dns-wordlist.txt"
WORDLIST_URL="https://wordlists-cdn.assetnote.io/data/manual/best-dns-wordlist.txt"

echo ""
echo "==========================================="
echo "  recon-js — dependency installer"
echo "==========================================="
echo ""

# ── Wordlist ─────────────────────────────────────────────────────────────────
mkdir -p "$WORDLIST_DIR"

if [ -f "$WORDLIST" ]; then
    ok "Wordlist already present: $WORDLIST ($(wc -l < "$WORDLIST") words)"
else
    info "Downloading best-dns-wordlist (~134 MB) from Assetnote..."
    if curl -fL --progress-bar "$WORDLIST_URL" -o "$WORDLIST"; then
        ok "Saved to $WORDLIST ($(wc -l < "$WORDLIST") words)"
    else
        err "Download failed. Try manually:"
        echo "  curl -fL $WORDLIST_URL -o $WORDLIST"
        exit 1
    fi
fi

# ── Check Go tools ────────────────────────────────────────────────────────────
echo ""
info "Checking recommended tools..."

TOOLS=(subfinder amass assetfinder findomain chaos httpx gau katana subjs puredns dnsx)
MISSING=()

for tool in "${TOOLS[@]}"; do
    if command -v "$tool" &>/dev/null; then
        ok "  $tool"
    else
        warn "  $tool — NOT FOUND"
        MISSING+=("$tool")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    warn "Missing tools: ${MISSING[*]}"
    echo ""
    echo "Install with:"
    echo "  go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    echo "  go install github.com/owasp-amass/amass/v4/...@master"
    echo "  go install github.com/tomnomnom/assetfinder@latest"
    echo "  go install github.com/projectdiscovery/chaos-client/cmd/chaos@latest"
    echo "  go install github.com/projectdiscovery/httpx/cmd/httpx@latest"
    echo "  go install github.com/lc/gau/v2/cmd/gau@latest"
    echo "  go install github.com/projectdiscovery/katana/cmd/katana@latest"
    echo "  go install github.com/lc/subjs@latest"
    echo "  go install github.com/d3mondev/puredns/v2@latest"
    echo "  go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    echo "  # findomain: https://github.com/findomain/findomain/releases"
else
    ok "All tools found."
fi

echo ""
ok "Setup complete. Run: ./recon-js.sh"
echo ""
