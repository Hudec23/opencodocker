# opencode-docker

Containerized agentic coder using [opencode](https://github.com/anomalyco/opencode) with Docker-in-Docker. The agent receives a project directory, follows instructions in the repo, writes code from scratch, and can spin up Docker services to validate its work. Git push access is scoped to a single repo via a fine-grained PAT.

## How it works

```
oc-net-NAME (--internal, no direct internet)
┌──────────────────────────────────────────────────────┐
│                                                      │
│  agent          tcp://oc-dind-NAME:2375              │
│  (hardened) ──────────────────────────► dind ────────┼──► internet
│             │                           (privileged) │   (docker pull)
│             │  http://oc-proxy-NAME:PORT             │
│             └──────────────────────► nginx proxy ────┼──► VLLM_ENDPOINT only
│                                                      │
└──────────────────────────────────────────────────────┘
                                    oc-ext-NAME (internet-facing, proxy + dind only)
```

Agent runs on an `--internal` bridge — no direct internet access. The nginx proxy is the only egress path for API calls, and it forwards to exactly one host:port (`VLLM_ENDPOINT`). DinD gets a second network interface for docker image pulls.

## Prerequisites

- Docker (Desktop on Mac, Engine on Linux)
- Anthropic API key and/or vLLM endpoint
- GitHub fine-grained PAT (for git push — see [Git access setup](#git-access-setup))

## Quick start

```bash
git clone https://github.com/Hudec23/opencode-docker
cd opencode-docker

# configure keys once
cp .env.example .env
nano .env

# drop your project here (or pass --project PATH)
cp -r ~/mycode project/

# run
./run.sh
```

The script builds the image on first run, creates all containers and networks, waits for dind to be ready, then drops you into the agent. On exit it cleans everything up.

## Configuration

All keys live in `.env` (gitignored). Copy from the example and fill in:

```bash
# Anthropic — needed if opencode.json uses any anthropic/* model
ANTHROPIC_API_KEY=sk-ant-...

# vLLM — set both if using a local vLLM server
VLLM_ENDPOINT=http://192.168.1.10:8000
VLLM_API_KEY=your-key-or-any-string-if-no-auth

# GitHub — needed for git push inside the agent
GH_TOKEN=github_pat_...
```

At least one of `ANTHROPIC_API_KEY` or `VLLM_API_KEY` must be set.

## Usage

```
./run.sh [OPTIONS] [-- OPENCODE_ARGS...]

  --project PATH       Project directory → /workspace  (default: ./project)
  --anthropic-key KEY  Anthropic API key               (or $ANTHROPIC_API_KEY)
  --vllm-key KEY       vLLM API key                    (or $VLLM_API_KEY)
  --vllm-endpoint URL  vLLM server address             (or $VLLM_ENDPOINT)
  --gh-token TOKEN     GitHub fine-grained PAT         (or $GH_TOKEN)
  --config PATH        Path to opencode.json config file
  --instance NAME      Instance suffix — set this to run multiple agents
                       simultaneously (default: project basename)
  --keep               Keep containers after run (faster next start)
  --build              Force rebuild of opencode-docker image
  -- ARGS              Pass-through args forwarded to opencode
```

### Examples

```bash
# Default: uses ./project and .env
./run.sh

# Explicit project path
./run.sh --project ~/myrepo

# Custom opencode config
./run.sh --project ~/myrepo --config ~/myrepo/opencode.json

# Keep containers between runs (skip dind startup wait)
./run.sh --keep
# clean up manually later:
docker rm -f oc-dind-project oc-proxy-project && docker network rm oc-net-project oc-ext-project

# Two agents in parallel (separate terminals)
./run.sh --project ~/repo1
./run.sh --project ~/repo2
```

## vLLM proxy

When `VLLM_ENDPOINT` is set, `run.sh` starts an nginx proxy (`oc-proxy-NAME`) on the internal network that forwards TCP to your vLLM server. The agent never knows the real IP — it calls `http://oc-proxy-NAME:PORT` and the proxy forwards to `VLLM_ENDPOINT`.

**Config in `.env`:**
```bash
VLLM_ENDPOINT=http://192.168.1.10:8000   # your real vLLM address
VLLM_API_KEY=your-key
```

**`opencode.json` picks it up automatically** via the `VLLM_BASE_URL` env var that `run.sh` injects:
```json
"options": {
  "baseURL": "{env:VLLM_BASE_URL}/v1",
  "apiKey": "{env:VLLM_API_KEY}"
}
```

`run.sh` sets `VLLM_BASE_URL=http://oc-proxy-NAME:PORT` inside the container. Change the IP in `.env` — on next run the proxy restarts pointing to the new target; `opencode.json` needs no changes.

**What the agent can and cannot reach:**

| Destination | Agent | Proxy | dind |
|---|---|---|---|
| `VLLM_ENDPOINT` host:port | via proxy only | direct | no |
| Internet (other) | blocked | blocked | yes (docker pull) |
| dind socket | yes | no | — |
| Host filesystem | no | no | no |

## opencode.json

Copy `opencode.json.example` and pass it via `--config`, or place it in the project dir. The example ships with a full vLLM provider config. Minimal Anthropic-only config:

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

The agent uses a credential helper (`agent.env`) — git push authenticates automatically. The token is passed as an env var and never written to the project files.

## Security notes

| Concern | Mitigation |
|---|---|
| Agent calls arbitrary internet | `oc-net` is `--internal`; blocked at network level |
| Agent calls non-vLLM hosts | nginx proxy forwards to exactly one host:port |
| Agent escapes container | `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges` |
| DinD privileged escape | isolated to `oc-net`/`oc-ext`; agent has no shell on dind |
| TLS on DinD socket | not needed — private bridge only |
| Linux host privileged risk | use `--runtime=sysbox-runc` on dind instead of `--privileged` |
| Token scope | fine-grained PAT limits push to one repo |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Extends opencode with `git`, `docker-cli`, `docker-cli-buildx` |
| `run.sh` | Launcher — builds image, manages networks/proxy/dind, runs agent |
| `agent.env` | Git identity + credential helper (no secrets, safe to commit) |
| `.env.example` | Key template — copy to `.env` and fill in |
| `opencode.json.example` | Full vLLM provider config with permission rules |
| `project/` | Default project directory (contents gitignored) |
