# javascript-recon

Lightweight Bash reconnaissance focused on practical client-side collection for bug bounty and authorized web recon. The workflow stays simple: enumerate subdomains, identify live hosts, discover frontend assets, download what matters, and keep the output usable for later analysis.

The current implementation still preserves the original `./recon-js.sh [domain]` usage, but it now discovers and tracks more than obvious `.js` files.

## Usage

```bash
# Interactive mode
./recon-js.sh

# Direct mode
./recon-js.sh example.com

# Resume a prior run safely
./recon-js.sh --resume example.com

# Keep asset scope on the target domain only
./recon-js.sh --allowlist example.com

# Download JS-like files only
./recon-js.sh --js-only example.com
```

## What It Collects

The project still prioritizes JavaScript recon, but it now expands discovery into adjacent client-side assets that are useful during review.

Discovered asset classes:

- `.js`
- `.mjs`
- publicly exposed `.ts`
- `.map`
- `.json`
- `.webmanifest`
- `.wasm`
- service workers
- manifest and asset-manifest files
- framework chunk/runtime assets

Discovery sources:

- passive subdomain sources: `subfinder`, `amass`, `crt.sh`, `gau`, `wayback`, `chaos`, `assetfinder`, `findomain`
- optional DNS brute force via `puredns`
- live-host probing with `httpx`
- live asset extraction with `subjs`, `getJS`, and `katana`
- HTML parsing for script, preload, and manifest hints
- header parsing for `Link:` preload/modulepreload hints
- `robots.txt` and `sitemap.xml`
- `sourceMappingURL` comments
- one recursive pass over downloaded text assets to catch referenced chunks, maps, manifests, and related files

Modern frontend coverage is intentionally lightweight but useful. The script now detects common patterns from Webpack, Vite, Next.js, Nuxt, React, Angular, Vue, Astro, and SvelteKit without turning into a full stack fingerprinting framework.

## Workflow

### Phase 1 — Subdomain Enumeration

Subdomain sources run with bounded parallelism, then merge into:

```text
$HOME/01-All-Domains/<domain>.txt
```

Existing history is merged atomically, so reruns stay additive and predictable.

### Phase 2 — HTTP Probing

`httpx` is used when present. If it is missing, the script falls back to building `https://` and `http://` URLs from the subdomain list so the rest of the pipeline can still run.

### Phase 3 — Client-Side Asset Discovery

This phase now separates raw discovery from normalized discovery. Candidate URLs are collected from historical sources, crawlers, root page fetches, robots/sitemaps, and downloaded files, then normalized and deduplicated with source attribution intact.

### Phase 3b — Candidate Verification

When `httpx` is available, the script verifies prioritized asset candidates before download and records:

- HTTP status
- content type
- content length
- final URL after redirects

Verified assets move into a dedicated report, and obviously filtered responses are tracked separately. If `httpx` is missing, the script falls back to the discovered asset set instead of aborting.

### Phase 4 — Download

Download stays lightweight, but the implementation is more deliberate now:

- bounded parallel downloads
- collision-resistant filenames with stable URL-based suffixes
- JS-like assets kept in the target directory root
- interesting non-JS assets stored in `_interesting/`
- metadata captured during download: status, content-type, content-length, final URL, optional hash
- failed downloads and skipped duplicates tracked separately

## Output Layout

```text
$HOME/01-All-Domains/
└── example.com.txt

$HOME/03-JS-Download/
└── example.com/
    ├── app.example.com_static_js_main-3c7b4b61c2.js
    ├── cdn.example.com_assets_vendor-ff1287a4c1.js
    ├── _interesting/
    │   ├── app.example.com_manifest-a8712d0f66.json
    │   └── app.example.com_service-worker-ccd7d93433.js
    ├── url_map.txt
    └── reports/
        ├── discovered_urls.tsv
        ├── verified_urls.tsv
        ├── verification_filtered.tsv
        ├── downloaded_files.tsv
        ├── failed_downloads.tsv
        ├── skipped_duplicates.tsv
        ├── non_js_assets.tsv
        ├── potential_interesting.tsv
        ├── live_hosts.txt
        ├── framework_hints.txt
        └── run.log
```

If JSON/CSV output is enabled, matching `.csv` and `.json` report files are also generated in `reports/`.

## Reports

The structured reports are designed for downstream tooling, triage, and repeatable workflows.

- `discovered_urls.tsv`: normalized candidate URLs with asset type, host, sources, referrers, and interesting flag
- `verified_urls.tsv`: pre-download verified assets with HTTP metadata when `httpx` is available
- `verification_filtered.tsv`: candidates filtered out during verification because they did not pass the status check
- `downloaded_files.tsv`: successful downloads with metadata and local path
- `failed_downloads.tsv`: failed or empty downloads with reason and observed metadata
- `skipped_duplicates.tsv`: assets skipped because the local file already existed
- `non_js_assets.tsv`: discovered non-JS assets such as maps, manifests, JSON, and WASM
- `potential_interesting.tsv`: files that are likely worth manual review even if they are not plain JS
- `framework_hints.txt`: lightweight frontend fingerprint hints
- `url_map.txt`: local file to source URL mapping for offline-to-live traceability

## Options

```text
--resume        Reuse previous state where safe
--allowlist     Keep asset scope on the target domain suffix only
--js-only       Skip downloading non-JS interesting assets
--no-json       Skip JSON report output
--no-csv        Skip CSV report output
-q, --quiet     Reduce console output
```

## Environment Overrides

The project keeps its defaults lightweight, but the tuning surface is now clearer.

```bash
RECON_PROFILE=safe|balanced|aggressive
ALL_DOMAINS_DIR=$HOME/01-All-Domains
JS_DOWNLOAD_DIR=$HOME/03-JS-Download
DNS_WORDLIST=$HOME/wordlists/best-dns-wordlist.txt
TOOL_PARALLELISM=5
ACTIVE_FETCH_CONCURRENCY=6
GETJS_CONCURRENCY=5
DOWNLOAD_CONCURRENCY=8
HTTPX_THREADS=50
MAX_ACTIVE_HOSTS=75
MAX_DOWNLOADS=1000
MAX_VERIFY=3000
ENABLE_HASHING=1
```

`safe`, `balanced`, and `aggressive` are internal tuning profiles selected with `RECON_PROFILE`. They are intentionally env-driven for now so the CLI stays small.

## Dependencies

### Required

| Tool | Why |
|---|---|
| `bash` (4+) | required shell runtime for the script and installer |
| `curl` | HTTP fetches, downloads, metadata capture |
| `python3` | URL normalization and report generation |

### Recommended

| Tool | Role |
|---|---|
| `subfinder` | passive subdomain discovery |
| `amass` | passive subdomain discovery |
| `assetfinder` | passive subdomain discovery |
| `findomain` | optional passive source |
| `chaos` | passive subdomain discovery |
| `httpx` | live host probing |
| `gau` | historical URL collection |
| `katana` | active crawling |
| `subjs` | live JS extraction |
| `getJS` | live JS extraction with relative-path resolution |
| `puredns` | DNS brute force |

Install the dependency set with:

```bash
./install.sh
```

### DNS Wordlist

The default brute-force wordlist path is:

```text
$HOME/wordlists/best-dns-wordlist.txt
```

If that file is missing, `puredns` is skipped without stopping the run.

## Operational Notes

- The script validates the target domain before running any source.
- Temporary files are created with `mktemp -d` and cleaned automatically.
- Output directories are checked for write access before work starts.
- Missing optional tools degrade coverage, not the whole run.
- `--resume` reuses prior discovered, verified, and downloaded state where it is safe to do so.
- Download writes are predictable and use temporary files before moving into place.
- The downloader captures failures separately instead of letting one bad source abort the run.
- `--allowlist` is optional because real-world frontend assets often live on CDNs.

## Practical Follow-Up

```bash
# Offline secret review against downloaded files
jsecret -d $HOME/03-JS-Download/example.com

# Live-URL-oriented review using discovered URL report
jsecret -f $HOME/03-JS-Download/example.com/reports/discovered_urls.tsv

# Map a local finding back to the source URL
grep 'filename.js' $HOME/03-JS-Download/example.com/url_map.txt
```

## Ethical And Responsible Use

Use this project only for authorized security work, such as bug bounty programs, internal testing, audits, and research with documented permission.

- Prior authorization is required.
- Legal and contractual scope still applies.
- Keep collection proportional to the task.
- Treat downloaded client-side assets as potentially sensitive.
- You are responsible for how and where the tooling is used.
