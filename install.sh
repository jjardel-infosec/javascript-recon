#!/usr/bin/env bash
# install.sh — Install the lightweight dependency set for recon-js.sh

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_NAME="$(basename "$0")"

ensure_bash_compat() {
    if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
        printf '%s\n' "[-] $SCRIPT_NAME requires Bash 4 or newer." >&2
        exit 1
    fi
}

ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; }

_detect_pkg_manager() {
    if command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v brew >/dev/null 2>&1; then
        echo "brew"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo ""
    fi
}

_install_pkg() {
    local pkg_name="$1"
    local pkg_mgr="$2"

    case "$pkg_mgr" in
        apt)
            info "Installing $pkg_name via apt..."
            sudo apt-get update -qq && sudo apt-get install -y "$pkg_name" >> "$INSTALL_LOG" 2>&1
            ;;
        brew)
            info "Installing $pkg_name via brew..."
            brew install "$pkg_name" >> "$INSTALL_LOG" 2>&1
            ;;
        pacman)
            info "Installing $pkg_name via pacman..."
            sudo pacman -S --noconfirm "$pkg_name" >> "$INSTALL_LOG" 2>&1
            ;;
        dnf)
            info "Installing $pkg_name via dnf..."
            sudo dnf install -y "$pkg_name" >> "$INSTALL_LOG" 2>&1
            ;;
        yum)
            info "Installing $pkg_name via yum..."
            sudo yum install -y "$pkg_name" >> "$INSTALL_LOG" 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

_go_bin_path() {
    if [ -n "${GOBIN:-}" ]; then
        printf '%s' "$GOBIN"
    elif command -v go >/dev/null 2>&1; then
        go env GOPATH 2>/dev/null | awk '{print $1 "/bin"}'
    else
        printf '%s' "$HOME/go/bin"
    fi
}

_tool_accessible() {
    local tool_name="$1"
    local go_bin

    if command -v "$tool_name" >/dev/null 2>&1; then
        return 0
    fi

    go_bin="$(_go_bin_path)"
    [ -x "$go_bin/$tool_name" ]
}

_install_go_tool() {
    local go_import="$1"
    local tool_name="$2"

    if ! command -v go >/dev/null 2>&1; then
        warn "Go not found. Cannot auto-install $tool_name"
        return 1
    fi

    info "Installing $tool_name via go install..."
    if go install "$go_import" >> "$INSTALL_LOG" 2>&1; then
        if _tool_accessible "$tool_name"; then
            return 0
        fi

        warn "  $tool_name installed, but it may not be on PATH yet"
        warn "  Add this to PATH: $(_go_bin_path)"
        return 0
    fi

    return 1
}

_download_wordlist() {
    local tmp_file
    local attempt

    tmp_file="$(mktemp "$WORDLIST_DIR/.best-dns-wordlist.XXXXXX")" || return 1

    for attempt in 1 2 3; do
        info "Downloading best-dns-wordlist (~134 MB) from Assetnote... attempt $attempt/3"
        if curl -fL --retry 2 --retry-delay 2 --connect-timeout 15 --progress-bar "$WORDLIST_URL" -o "$tmp_file" >> "$INSTALL_LOG" 2>&1; then
            mv "$tmp_file" "$WORDLIST"
            ok "Saved to $WORDLIST ($(wc -l < "$WORDLIST") words)"
            return 0
        fi
    done

    rm -f "$tmp_file" 2>/dev/null || true
    return 1
}

WORDLIST_DIR="${WORDLIST_DIR:-$HOME/wordlists}"
WORDLIST="$WORDLIST_DIR/best-dns-wordlist.txt"
WORDLIST_URL="https://wordlists-cdn.assetnote.io/data/manual/best-dns-wordlist.txt"
INSTALL_LOG="$WORDLIST_DIR/install.log"

ensure_bash_compat

declare -A TOOLS_GO
TOOLS_GO[subfinder]="github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
TOOLS_GO[amass]="github.com/owasp-amass/amass/v4/...@master"
TOOLS_GO[assetfinder]="github.com/tomnomnom/assetfinder@latest"
TOOLS_GO[chaos]="github.com/projectdiscovery/chaos-client/cmd/chaos@latest"
TOOLS_GO[httpx]="github.com/projectdiscovery/httpx/cmd/httpx@latest"
TOOLS_GO[gau]="github.com/lc/gau/v2/cmd/gau@latest"
TOOLS_GO[katana]="github.com/projectdiscovery/katana/cmd/katana@latest"
TOOLS_GO[subjs]="github.com/lc/subjs@latest"
TOOLS_GO[getJS]="github.com/003random/getJS@latest"
TOOLS_GO[puredns]="github.com/d3mondev/puredns/v2@latest"

declare -A TOOLS_PKG
TOOLS_PKG[curl]="curl"
TOOLS_PKG[python3]="python3"

MANUAL_TOOLS=("findomain")
FAILED_GO=()
FAILED_PKG=()

echo ""
echo "==========================================="
echo "  recon-js — dependency installer"
echo "==========================================="
echo ""

mkdir -p "$WORDLIST_DIR"
: > "$INSTALL_LOG"

if [ -s "$WORDLIST" ]; then
    ok "Wordlist already present: $WORDLIST ($(wc -l < "$WORDLIST") words)"
else
    if ! _download_wordlist; then
        err "Download failed after 3 attempts. Try manually:"
        echo "  curl -fL $WORDLIST_URL -o $WORDLIST"
        echo ""
        echo "Installer log: $INSTALL_LOG"
        exit 1
    fi
fi

echo ""
info "Checking system tools..."
echo ""

PKG_MGR="$(_detect_pkg_manager)"

for tool in "${!TOOLS_PKG[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "  $tool ✓"
        continue
    fi

    warn "  $tool — installing..."
    if [ -z "$PKG_MGR" ]; then
        err "  $tool — no supported package manager found"
        FAILED_PKG+=("$tool")
    elif _install_pkg "${TOOLS_PKG[$tool]}" "$PKG_MGR"; then
        ok "  $tool ✓ (installed)"
    else
        err "  $tool — failed to install"
        FAILED_PKG+=("$tool")
    fi
done

echo ""
info "Checking Go-based recon tools..."
echo ""

for tool in "${!TOOLS_GO[@]}"; do
    if _tool_accessible "$tool"; then
        ok "  $tool ✓"
        continue
    fi

    warn "  $tool — installing..."
    if _install_go_tool "${TOOLS_GO[$tool]}" "$tool"; then
        ok "  $tool ✓ (installed or already available via Go bin)"
    else
        err "  $tool — failed to install"
        FAILED_GO+=("$tool")
    fi
done

echo ""
info "Manual-only tools"
for tool in "${MANUAL_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "  $tool ✓"
    else
        warn "  $tool — install manually from GitHub releases if you want that source"
    fi
done

echo ""
if [ ${#FAILED_PKG[@]} -gt 0 ]; then
    err "Missing system tools: ${FAILED_PKG[*]}"
fi

if [ ${#FAILED_GO[@]} -gt 0 ]; then
    err "Failed Go installs: ${FAILED_GO[*]}"
    echo "Manual installation commands:"
    for tool in "${FAILED_GO[@]}"; do
        echo "  go install ${TOOLS_GO[$tool]}"
    done
fi

if [ ${#FAILED_PKG[@]} -eq 0 ] && [ ${#FAILED_GO[@]} -eq 0 ]; then
    ok "All required tools found or installed."
fi

echo ""
ok "Setup complete. Run: ./recon-js.sh"
echo "Installer log: $INSTALL_LOG"
echo ""
