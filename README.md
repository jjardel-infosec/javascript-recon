# javascript-recon

Lightweight reconnaissance script focused on two things: **subdomain enumeration** and **JavaScript file downloads**. Perfect for the initial phase of bug bounty hunting where the goal is to map the attack surface and collect JS for static analysis of endpoints, tokens, and business logic.

---

## Usage

```bash
# Interactive mode — the script asks for the domain
./recon-js.sh

# Passing the domain directly
./recon-js.sh example.com
```

The script works both ways. In interactive mode, simply paste the domain when prompted.

---

## What the script does

### Phase 1 — Subdomain Enumeration

Combines 8 passive sources + 1 active (DNS brute force):

| Tool | Type | Coverage |
|---|---|---|
| `subfinder -all` | Passive | VirusTotal, Shodan, Censys, Chaos, URLScan, etc. (50+ sources) |
| `amass` | Passive | Certificates, passive DNS, multiple data brokers (timeout: 3min) |
| `crt.sh` | Passive | Certificate Transparency logs (all issued certificates) |
| Wayback CDX | Passive | Subdomains from historical URLs in Wayback Machine |
| `gau` | Passive | Wayback, CommonCrawl, OTX (AlienVault), URLScan.io |
| `chaos` | Passive | ProjectDiscovery public dataset |
| `assetfinder` | Passive | Facebook CT, crt.sh, distinct groups from subfinder |
| `findomain` | Passive | Facebook CT logs, VirusTotal, Shodan, Spyse |
| `puredns` (brute force) | **Active** | DNS brute force with `best-dns-wordlist.txt` — finds subdomains that **never appeared** in any passive source (staging, dev, internal) |

All sources are merged and deduplicated. The final result is saved to:

```
/home/kali/01-All-Domains/<domain>.txt
```

If the file already exists from a previous run, new subdomains are **atomically merged** (no duplicates).

---

### Phase 2 — HTTP Probing

Uses `httpx` to detect which subdomains are actually responding with HTTP/HTTPS. This filters noise before JS crawling.

- **50 threads**, 10s timeout per host
- If `httpx` isn't installed, generates `https://` URLs as fallback

---

### Phase 3 — JS URL Discovery

Collects JavaScript `.js` file URLs from multiple sources:

| Tool | How it discovers JS |
|---|---|
| `subjs` | Makes requests to live hosts and extracts `<script src="">` tags |
| `getJS` | Same principle, with relative path resolution (`--complete`) |
| `katana` | Active crawler with JavaScript rendering (`-jc`), depth 2 (timeout: 5min) |
| `gau` | Historical JS URLs from Wayback / CommonCrawl |
| Wayback CDX | Direct query for `*.js` in CDX API |

All URLs are deduplicated before download.

---

### Phase 4 — JS Download

Downloads all discovered `.js` files to:

```
/home/kali/03-JS-Download/<domain>/
```

- **File naming**: `host_path_filename.js` (prevents collision between different subdomains)
- **Limit**: 1,000 files per run (configurable in `MAX_DOWNLOADS` variable)
- **Idempotent**: if a file already exists from a previous run, it's skipped
- Empty files are automatically removed

---

## Output

```
/home/kali/01-All-Domains/
└── example.com.txt           ← all subdomains (merged with history)

/home/kali/03-JS-Download/
└── example.com/
    ├── app.example.com_static_js_main.js
    ├── cdn.example.com_assets_chunk.123abc.js
    └── ...
```

---

## Dependencies

### Required

| Tool | Installation |
|---|---|
| `curl` | `apt install curl` |
| `python3` | `apt install python3` |

### Recommended (script works without, but with less coverage)

| Tool | Installation |
|---|---|
| `subfinder` | `go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest` |
| `amass` | `go install github.com/owasp-amass/amass/v4/...@master` |
| `assetfinder` | `go install github.com/tomnomnom/assetfinder@latest` |
| `findomain` | [github.com/findomain/findomain/releases](https://github.com/findomain/findomain/releases) |
| `chaos` | `go install github.com/projectdiscovery/chaos-client/cmd/chaos@latest` |
| `httpx` | `go install github.com/projectdiscovery/httpx/cmd/httpx@latest` |
| `gau` | `go install github.com/lc/gau/v2/cmd/gau@latest` |
| `katana` | `go install github.com/projectdiscovery/katana/cmd/katana@latest` |
| `subjs` | `go install github.com/lc/subjs@latest` |
| `getJS` | `go install github.com/003random/getJS@latest` |
| `puredns` | `go install github.com/d3mondev/puredns/v2@latest` |

### Wordlist for DNS brute force

Puredns uses the wordlist at `/home/kali/wordlists/best-dns-wordlist.txt`. If it doesn't exist, brute force is skipped. To download:

```bash
# Assetnote best-dns-wordlist (recommended)
wget -q https://wordlists-cdn.assetnote.io/data/manual/best-dns-wordlist.txt \
    -O /home/kali/wordlists/best-dns-wordlist.txt
```

---

## Why DNS brute force matters

Passive sources (crt.sh, Wayback, subfinder) only find subdomains that have **already been exposed** somewhere — issued certificates, crawled URLs, public databases. Subdomains like `staging-api.example.com`, `dev-admin.example.com`, or `internal.example.com` often never appear in any passive source. `puredns` solves this by attempting each word in the wordlist via DNS, with automatic wildcard filtering.

---

## Security and best practices

- The domain is validated by regex before any execution (`^[a-z0-9]...$`)
- Temporary files live in `/tmp/recon-js-<pid>-<timestamp>/` and are automatically removed at the end
- Subdomain merging uses `mktemp` + atomic `mv` to prevent partial reads
- No credentials are persisted or logged

---

## Ethical and Responsible Use Statement

The javascript-recon and jsecret tools were developed exclusively to support legitimate information security activities, including authorized penetration testing, bug bounty programs, technical audits, and academic research.

Your use must be strictly aligned with the following principles:

**Prior Authorization**
The tools must be used only on assets, systems, or environments for which formal and documented authorization exists.

**Legal and Regulatory Compliance**
You are entirely responsible for ensuring that use complies with all applicable laws, including data protection legislation and cybercrime statutes.

**Respect for Confidentiality and Integrity**
It is prohibited to access, collect, store, or disclose sensitive data without justified technical necessity and without explicit authorization.

**Proportional and Responsible Use**
The exploitation of vulnerabilities must be limited to what is necessary for technical validation, avoiding operational impacts, service unavailability, or any form of harm.

**Accountability**
Misuse of these tools may result in civil, administrative, and criminal sanctions, being entirely the user's responsibility.

The purpose of these tools is to contribute to the strengthening of system security and user privacy, promoting ethical and responsible practices in the offensive security ecosystem.
