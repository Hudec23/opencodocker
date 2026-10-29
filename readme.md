# opencode-docker

Containerized agentic coder using [opencode](https://github.com/anomalyco/opencode) with Docker-in-Docker (DinD). The agent receives a project directory, follows instructions in the repo, writes code from scratch, and can spin up Docker services to validate its work. Git push access is scoped to a single repo via a fine-grained token.

## How it works

```
┌─────────────────────────┐     tcp://oc-dind:2375
│  opencode-docker (agent) │──────────────────────►┌──────────────┐
│  --read-only             │                        │  oc-dind     │
│  --cap-drop ALL          │                        │  (privileged)│
│  /workspace (project)    │                        │  /workspace  │
└─────────────────────────┘                        └──────────────┘
         oc-net (private bridge)
```

The agent container is hardened (read-only FS, dropped caps, no new privileges). The DinD sidecar sits on the same private network — the agent talks to it via `DOCKER_HOST`. Both containers share the same `/workspace` mount so bind mounts inside agent-spawned containers resolve correctly.

## Prerequisites

- Docker (Desktop on Mac, Engine on Linux)
- Anthropic API key
- GitHub fine-grained PAT (for git push — see below)

## Quick start

```bash
# 1. Clone this repo
git clone https://github.com/Hudec23/opencode-docker
cd opencode-docker

# 2. Build the image
docker build -t opencode-docker .

# 3. Run against your project
export ANTHROPIC_API_KEY=sk-ant-...
export GH_TOKEN=github_pat_...

./run.sh --project /path/to/your/project
```

## Usage

```
./run.sh --project PATH [OPTIONS] [-- OPENCODE_ARGS...]

Required:
  --project PATH       Project directory mounted as /workspace

Options:
  --gh-token TOKEN     GitHub fine-grained PAT (or $GH_TOKEN)
  --anthropic-key KEY  Anthropic API key (or $ANTHROPIC_API_KEY)
  --config PATH        Path to opencode.json config file
  --keep               Keep dind running after agent exits (faster next run)
  --build              Force rebuild of Docker image

Pass-through:
  -- ARGS              Arguments forwarded to opencode
```

### Examples

```bash
# Basic run
./run.sh --project ~/myrepo

# With explicit keys
./run.sh --project ~/myrepo \
  --anthropic-key sk-ant-... \
  --gh-token github_pat_...

# Custom opencode config
cp opencode.json.example ~/myrepo/opencode.json
# edit ~/myrepo/opencode.json
./run.sh --project ~/myrepo --config ~/myrepo/opencode.json

# Keep dind between runs (faster iteration)
./run.sh --project ~/myrepo --keep
# ... later, clean up manually:
docker rm -f oc-dind && docker network rm oc-net

# Pass args to opencode
./run.sh --project ~/myrepo -- --help
```

## Git access setup

Create a **fine-grained PAT** on GitHub scoped to exactly one repo:

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. Resource owner: your org or account
3. Repository access: only the target repo
4. Permissions: **Contents** → Read and Write
5. Copy the token → pass as `GH_TOKEN`

The agent uses a credential helper (`agent.env`) so git operations inside the container authenticate automatically. The token never touches the project files.

## opencode.json

Copy `opencode.json.example` to your project or pass it via `--config`:

```json
{
  "model": "claude-sonnet-4-6",
  "provider": "anthropic"
}
```

If `--config` is omitted, opencode uses its built-in defaults.

## Security notes

| Concern | Mitigation |
|---|---|
| Agent escapes container | `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges` |
| DinD privileged escape | `oc-net` private bridge; only agent can reach it |
| TLS on DinD socket | Not needed — private network only |
| Linux host privileged risk | Use `--runtime=sysbox-runc` on DinD instead of `--privileged` |
| Mac/Windows Docker Desktop | VM boundary already isolates DinD from host |
| Token scope | Fine-grained PAT limits push to one repo |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Extends opencode image with `git`, `docker-cli`, `docker-cli-buildx` |
| `run.sh` | Parametrized launcher — sets up network, dind, and runs the agent |
| `agent.env` | Git identity and credential helper env vars (no secrets) |
| `opencode.json.example` | Sample opencode config to copy to your project |
