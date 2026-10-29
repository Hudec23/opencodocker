# opencode-docker

Containerized agentic coder using [opencode](https://github.com/anomalyco/opencode) with Docker-in-Docker. The agent receives a project directory, follows instructions in the repo, writes code from scratch, and can spin up Docker services to validate its work. Git push access is scoped to a single repo via a fine-grained PAT.

## How it works

```
oc-net-NAME (shared bridge — all containers + internet)
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  agent           tcp://oc-dind-NAME:2375                    │
│  (hardened) ─────────────────────────────► dind ───────────►│ internet
│             │                              (privileged)     │ (docker pull,
│             │  http://oc-proxy-NAME:8080                    │  npm, apt...)
│             └──────────────────────────► nginx proxy ──────►│ VLLM_ENDPOINT
│                                                             │
└─────────────────────────────────────────────────────────────┘
  [--block-local] iptables rules on host, scoped to agent source IP
  DROP 10/8, 172.16/12, 192.168/16 — ACCEPT ALLOWED_HOSTS first
```

Agent is hardened (read-only FS, dropped caps). DinD gives the agent a Docker daemon isolated from the host. nginx proxy handles vLLM routing (Host header + SNI for tunnels). Optional iptables rules block LAN access from the agent at kernel level on Linux.

## Prerequisites

- Docker (Desktop on Mac, Engine on Linux)
- Anthropic API key and/or vLLM endpoint
- GitHub fine-grained PAT (for git push — see [Git access setup](#git-access-setup))
- Root access for `--block-local` on Linux

## Quick start

```bash
git clone https://github.com/Hudec23/opencode-docker
cd opencode-docker

cp .env.example .env
nano .env          # fill in keys

cp -r ~/mycode project/   # or pass --project PATH

./run.sh
```

The script builds the image on first run, creates all containers and networks, waits for dind, then drops you into the agent. On exit it cleans everything up.

## Configuration

All config lives in `.env` (gitignored). Copy from example and fill in:

```bash
ANTHROPIC_API_KEY=sk-ant-...          # needed for anthropic/* models
VLLM_ENDPOINT=https://your-tunnel     # your vLLM server (http or https)
VLLM_API_KEY=your-key                 # or any string if no auth
GH_TOKEN=github_pat_...               # single-repo push access

BLOCK_LOCAL=false                     # set true on Linux to block LAN (see below)
ALLOWED_HOSTS=                        # comma-separated IPs allowed through LAN block
```

At least one of `ANTHROPIC_API_KEY` or `VLLM_API_KEY` must be set.

## Usage

```
./run.sh [OPTIONS] [-- OPENCODE_ARGS...]

  --project PATH       Project directory → /workspace  (default: ./project)
  --anthropic-key KEY  Anthropic API key               (or $ANTHROPIC_API_KEY)
  --vllm-key KEY       vLLM API key                    (or $VLLM_API_KEY)
  --vllm-endpoint URL  vLLM server URL                 (or $VLLM_ENDPOINT)
  --gh-token TOKEN     GitHub fine-grained PAT         (or $GH_TOKEN)
  --block-local        Block agent from LAN (Linux/root only, or $BLOCK_LOCAL)
  --config PATH        Path to opencode.json config file
  --instance NAME      Instance suffix (default: project basename)
  --keep               Keep containers after run
  --build              Force rebuild of opencode-docker image
  -- ARGS              Pass-through args to opencode
```

### Examples

```bash
./run.sh                                          # uses ./project and .env
./run.sh --project ~/myrepo
./run.sh -- run --standalone --auto "Read task.md and implement it"
./run.sh --keep                                   # skip dind startup on next run

# manual cleanup after --keep:
docker rm -f oc-agent-project oc-dind-project oc-proxy-project
docker network rm oc-net-project

# two agents in parallel
./run.sh --project ~/repo1
./run.sh --project ~/repo2
```

## vLLM proxy

When `VLLM_ENDPOINT` is set, `run.sh` starts an nginx proxy (`oc-proxy-NAME`) that forwards to your vLLM server. The agent calls `http://oc-proxy-NAME:8080` — nginx rewrites the `Host` header and sends SNI correctly for HTTPS tunnels (ngrok, cloudflare, etc.).

`opencode.json` picks up the proxy URL automatically via `VLLM_BASE_URL`:

```json
"options": {
  "baseURL": "{env:VLLM_BASE_URL}/v1",
  "apiKey": "{env:VLLM_API_KEY}"
}
```

Change `VLLM_ENDPOINT` in `.env` → proxy restarts on next run, `opencode.json` unchanged.

## LAN isolation (Linux)

By default the agent has full internet access (needed for MCP servers, webfetch, npm/pip inside dind). On Linux production machines you can block the agent from reaching other hosts on your LAN using iptables.

### How it works

`run.sh` adds rules to Docker's `DOCKER-USER` chain scoped to the **agent container's source IP only**. The nginx proxy and dind have different source IPs — their traffic is unaffected, so vLLM (via proxy) and docker image pulls (via dind) continue to work.

Rule order in `DOCKER-USER`:
```
ACCEPT  <source: agent IP>  <dest: ALLOWED_HOSTS>   ← checked first
DROP    <source: agent IP>  <dest: 10.0.0.0/8>
DROP    <source: agent IP>  <dest: 172.16.0.0/12>
DROP    <source: agent IP>  <dest: 192.168.0.0/16>
DROP    <source: agent IP>  <dest: 100.64.0.0/10>   ← CGNAT
DROP    <source: agent IP>  <dest: 169.254.0.0/16>  ← link-local
```

Rules are added ~100ms after container start and removed on exit. No persistent state.

### Setup

**1. Enable in `.env`:**
```bash
BLOCK_LOCAL=true

# Add any local IPs the agent is allowed to reach.
# Not needed if VLLM_ENDPOINT is a public tunnel URL (ngrok, cloudflare, etc.)
# — the proxy reaches vLLM, the agent never touches the local IP directly.
ALLOWED_HOSTS=192.168.1.50,10.0.0.5
```

**2. Run as root (or configure sudoers):**
```bash
sudo ./run.sh
```

Or give just iptables permission without full root:
```bash
# /etc/sudoers.d/opencode-docker
yourusername ALL=(ALL) NOPASSWD: /sbin/iptables
```
Then prefix iptables calls — or simply run the whole script as root on a dedicated agent machine.

**3. Verify rules are applied:**
```bash
sudo iptables -L DOCKER-USER -n -v
# Look for rules with the agent container IP as source
```

### Updating the allowlist

Edit `ALLOWED_HOSTS` in `.env` and restart the agent. Rules are rebuilt from scratch each run — no manual iptables editing needed.

```bash
# .env
ALLOWED_HOSTS=192.168.1.50,192.168.1.51,10.0.1.100/24
```

Supports individual IPs and CIDR ranges. Changes take effect on next `./run.sh`.

### Mac / Windows

iptables is not available on Docker Desktop (containers run inside a VM). `--block-local` prints a warning and is skipped. LAN isolation on Mac requires alternative approaches (not implemented).

## opencode.json

Copy `opencode.json.example` via `--config` or place it in the project dir. Minimal Anthropic-only config:

```json
{
  "model": "anthropic/claude-sonnet-4-6",
  "provider": "anthropic"
}
```

See [opencode.ai/config](https://opencode.ai/config.json) for the full schema.

## Git access setup

Create a **fine-grained PAT** scoped to exactly one repo:

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Repository access: **only the target repo**
3. Permissions: **Contents** → Read and Write
4. Set `GH_TOKEN` in `.env`

The agent uses a credential helper (`agent.env`) — git push authenticates automatically. The token is never written to project files.

## Security notes

| Concern | Mitigation |
|---|---|
| Agent reaches LAN services | `--block-local` iptables rules (Linux); Docker Desktop VM provides partial isolation on Mac |
| Agent escapes container | `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges` |
| Agent escapes to host Docker | DinD — agent-spawned containers live inside `oc-dind`, never touch host daemon |
| DinD privileged escape | private bridge; agent has no shell access to dind |
| TLS on DinD socket | not needed — private network only |
| Linux host privileged risk | use `--runtime=sysbox-runc` on dind instead of `--privileged` |
| vLLM token leakage | token passed as env var, never written to disk or project |
| Git token scope | fine-grained PAT limits push to one repo |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Extends opencode with `git`, `docker-cli`, `docker-cli-buildx` |
| `run.sh` | Launcher — image build, network, proxy, dind, iptables, agent |
| `agent.env` | Git identity + credential helper (no secrets, safe to commit) |
| `.env.example` | Config template — copy to `.env` |
| `opencode.json.example` | Full vLLM provider config with permission rules |
| `project/` | Default project directory (contents gitignored) |
