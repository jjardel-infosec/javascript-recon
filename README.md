# javascript-recon

Script enxuto de reconhecimento focado em duas coisas: **enumeração de subdomínios** e **download de arquivos JavaScript**. Ideal para a fase inicial de bug bounty onde o objetivo é mapear a superfície de ataque e coletar JS para análise estática de endpoints, tokens e lógica de negócio.

---

## Uso

```bash
# Modo interativo — o script pergunta o domínio
./recon-js.sh

# Passando o domínio direto
./recon-js.sh example.com
```

O script aceita o domínio das duas formas. No modo interativo, basta colar o domínio quando solicitado.

---

## O que o script faz

### Phase 1 — Subdomain Enumeration

Combina 8 fontes passivas + 1 ativa (brute force DNS):

| Ferramenta | Tipo | O que cobre |
|---|---|---|
| `subfinder -all` | Passivo | VirusTotal, Shodan, Censys, Chaos, URLScan, etc. (50+ fontes) |
| `amass` | Passivo | Certificados, DNS passivo, múltiplos data brokers (timeout: 3min) |
| `crt.sh` | Passivo | Certificate Transparency logs (todos os certificados emitidos) |
| Wayback CDX | Passivo | Subdomínios em URLs históricas do Wayback Machine |
| `gau` | Passivo | Wayback, CommonCrawl, OTX (AlienVault), URLScan.io |
| `chaos` | Passivo | Dataset público da ProjectDiscovery |
| `assetfinder` | Passivo | Facebook CT, crt.sh, grupos distintos do subfinder |
| `findomain` | Passivo | Facebook CT logs, VirusTotal, Shodan, Spyse |
| `puredns` (brute force) | **Ativo** | DNS brute force com `best-dns-wordlist.txt` — acha subdomínios que **nunca apareceram** em nenhuma fonte passiva (staging, dev, internal) |

Todas as fontes são mescladas e deduplicadas. O resultado final é salvo em:

```
/home/kali/01-All-Domains/<domain>.txt
```

Se o arquivo já existir de uma execução anterior, os novos subdomínios são **mergeados atomicamente** (sem duplicatas).

---

### Phase 2 — HTTP Probing

Usa `httpx` para detectar quais subdomínios estão realmente respondendo HTTP/HTTPS. Isso filtra o ruído antes do crawling de JS.

- **50 threads**, timeout de 10s por host
- Se `httpx` não estiver instalado, gera lista de URLs `https://` como fallback

---

### Phase 3 — JS URL Discovery

Coleta URLs de arquivos `.js` de múltiplas fontes:

| Ferramenta | Como descobre JS |
|---|---|
| `subjs` | Faz requisição nos hosts vivos e extrai tags `<script src="">` |
| `getJS` | Mesmo princípio, com resolução de caminhos relativos (`--complete`) |
| `katana` | Crawler ativo com JavaScript rendering (`-jc`), profundidade 2 (timeout: 5min) |
| `gau` | URLs históricas de JS no Wayback / CommonCrawl |
| Wayback CDX | Query direta por `*.js` no CDX API |

Todas as URLs são deduplicadas antes do download.

---

### Phase 4 — Download de JS

Baixa todos os arquivos `.js` descobertos para:

```
/home/kali/03-JS-Download/<domain>/
```

- **Nomenclatura dos arquivos**: `host_caminho_arquivo.js` (evita colisão entre subdomínios diferentes)
- **Limite**: 1.000 arquivos por execução (configurável na variável `MAX_DOWNLOADS`)
- **Idempotente**: se o arquivo já existiu em uma execução anterior, é pulado
- Arquivos vazios são removidos automaticamente

---

## Saída

```
/home/kali/01-All-Domains/
└── example.com.txt           ← todos os subdomínios (mergeado com histórico)

/home/kali/03-JS-Download/
└── example.com/
    ├── app.example.com_static_js_main.js
    ├── cdn.example.com_assets_chunk.123abc.js
    └── ...
```

---

## Dependências

### Obrigatórias

| Ferramenta | Instalação |
|---|---|
| `curl` | `apt install curl` |
| `python3` | `apt install python3` |

### Recomendadas (o script funciona sem, mas com menos cobertura)

| Ferramenta | Instalação |
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

### Wordlist para brute force DNS

O puredns usa a wordlist em `/home/kali/wordlists/best-dns-wordlist.txt`. Se não existir, o brute force é pulado. Para baixar:

```bash
# Assetnote best-dns-wordlist (recomendado)
wget -q https://wordlists-cdn.assetnote.io/data/manual/best-dns-wordlist.txt \
    -O /home/kali/wordlists/best-dns-wordlist.txt
```

---

## Por que brute force DNS importa?

Fontes passivas (crt.sh, Wayback, subfinder) só encontram subdomínios que **já foram expostos** em algum lugar — certificados emitidos, URLs rastreadas, bancos de dados públicos. Subdomínios como `staging-api.example.com`, `dev-admin.example.com` ou `internal.example.com` frequentemente nunca apparecem em nenhuma fonte passiva. O `puredns` resolve isso tentando cada palavra da wordlist via DNS, com filtro automático de wildcards.

---

## Segurança e boas práticas

- O domínio é validado por regex antes de qualquer execução (`^[a-z0-9]...$`)
- Arquivos temporários ficam em `/tmp/recon-js-<pid>-<timestamp>/` e são removidos automaticamente ao fim
- O merge de subdomínios usa `mktemp` + `mv` atômico para evitar leituras parciais
- Nenhuma credencial é persistida ou logada
