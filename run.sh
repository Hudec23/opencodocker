#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load .env if present (never committed — see .gitignore)
[[ -f "$SCRIPT_DIR/.env" ]] && set -o allexport && source "$SCRIPT_DIR/.env" && set +o allexport

IMAGE=opencode-docker

PROJECT=""
INSTANCE=""
GH_TOKEN="${GH_TOKEN:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
VLLM_API_KEY="${VLLM_API_KEY:-}"
VLLM_ENDPOINT="${VLLM_ENDPOINT:-}"
OPENCODE_CONFIG=""
KEEP=false
BUILD=false
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- OPENCODE_ARGS...]

Options (project):
  --project PATH       Project directory mounted as /workspace (default: ./project)

Options (keys — all readable from .env):
  --anthropic-key KEY  Anthropic API key          (or \$ANTHROPIC_API_KEY)
  --vllm-key KEY       vLLM API key               (or \$VLLM_API_KEY)
  --vllm-endpoint URL  vLLM base URL to proxy to  (or \$VLLM_ENDPOINT)
                       e.g. http://192.168.1.10:8000
                       Agent is isolated from internet; this is the only
                       external host it can reach.
  --gh-token TOKEN     GitHub fine-grained PAT     (or \$GH_TOKEN)

Options (misc):
  --config PATH        Path to opencode.json config file
  --instance NAME      Instance suffix for containers/networks
                       (default: project basename — lets you run multiple agents)
  --keep               Keep containers after run (faster next start)
  --build              Force rebuild of opencode-docker image
  -h, --help           Show this help

Pass-through:
  -- ARGS              Arguments forwarded to opencode inside the container

Network isolation:
  oc-net-NAME   --internal bridge (agent, proxy, dind) — no direct internet
  oc-ext-NAME   regular bridge (proxy + dind only) — internet access
  oc-proxy-NAME socat container forwarding only to VLLM_ENDPOINT
  oc-dind-NAME  Docker-in-Docker for agent-spawned containers

Examples:
  $(basename "$0")
  $(basename "$0") --project ~/myrepo
  $(basename "$0") --project ~/myrepo --config ~/myrepo/opencode.json
  # two agents in parallel (different terminals):
  $(basename "$0") --project ~/repo1
  $(basename "$0") --project ~/repo2
EOF
    exit 0
}

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --project)       PROJECT="$2"; shift 2 ;;
        --instance)      INSTANCE="$2"; shift 2 ;;
        --gh-token)      GH_TOKEN="$2"; shift 2 ;;
        --anthropic-key) ANTHROPIC_API_KEY="$2"; shift 2 ;;
        --vllm-key)      VLLM_API_KEY="$2"; shift 2 ;;
        --vllm-endpoint) VLLM_ENDPOINT="$2"; shift 2 ;;
        --config)        OPENCODE_CONFIG="$2"; shift 2 ;;
        --keep)          KEEP=true; shift ;;
        --build)         BUILD=true; shift ;;
        --)              shift; EXTRA_ARGS=("$@"); break ;;
        -h|--help)       usage ;;
        *)               die "unknown option: $1" ;;
    esac
done

[[ -z "$PROJECT" ]] && PROJECT="$SCRIPT_DIR/project"
[[ ! -d "$PROJECT" ]] && die "project directory not found: $PROJECT"
[[ -z "$ANTHROPIC_API_KEY" && -z "$VLLM_API_KEY" ]] && \
    die "no API key set — need ANTHROPIC_API_KEY or VLLM_API_KEY"

PROJECT="$(cd "$PROJECT" && pwd)"

# Derive instance name from project basename if not set
[[ -z "$INSTANCE" ]] && INSTANCE="$(basename "$PROJECT")"
INSTANCE="$(echo "$INSTANCE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"

NETWORK="oc-net-${INSTANCE}"      # --internal: agent cannot reach internet directly
EXT_NETWORK="oc-ext-${INSTANCE}"  # regular: proxy + dind for image pulls
DIND_NAME="oc-dind-${INSTANCE}"
PROXY_NAME="oc-proxy-${INSTANCE}"

# Parse VLLM_ENDPOINT into host + port for socat
VLLM_TARGET_HOST=""
VLLM_TARGET_PORT=""
if [[ -n "$VLLM_ENDPOINT" ]]; then
    _stripped="${VLLM_ENDPOINT#http://}"
    _stripped="${_stripped#https://}"
    _stripped="${_stripped%%/*}"          # strip any path
    VLLM_TARGET_HOST="${_stripped%%:*}"
    VLLM_TARGET_PORT="${_stripped##*:}"
    [[ "$VLLM_TARGET_PORT" == "$VLLM_TARGET_HOST" ]] && VLLM_TARGET_PORT=80
fi

# Build agent image if missing or --build requested
if $BUILD || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building $IMAGE..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# ── Networks ─────────────────────────────────────────────────────────────────
# oc-net: internal — recreate if it exists but isn't internal (legacy cleanup)
if docker network inspect "$NETWORK" &>/dev/null; then
    IS_INTERNAL="$(docker network inspect -f '{{.Internal}}' "$NETWORK")"
    if [[ "$IS_INTERNAL" != "true" ]]; then
        echo "Recreating $NETWORK as --internal..."
        docker network rm "$NETWORK"
        docker network create --internal "$NETWORK"
    fi
else
    docker network create --internal "$NETWORK"
fi

# oc-ext: regular bridge for internet-facing containers
docker network inspect "$EXT_NETWORK" &>/dev/null || \
    docker network create "$EXT_NETWORK"

# ── Proxy (socat) ─────────────────────────────────────────────────────────────
start_proxy() {
    echo "Starting proxy → ${VLLM_TARGET_HOST}:${VLLM_TARGET_PORT}..."
    docker run -d --name "$PROXY_NAME" \
        --network "$NETWORK" \
        --label "opencode.vllm_endpoint=$VLLM_ENDPOINT" \
        alpine/socat \
        "TCP-LISTEN:${VLLM_TARGET_PORT},fork,reuseaddr" \
        "TCP:${VLLM_TARGET_HOST}:${VLLM_TARGET_PORT}"
    docker network connect "$EXT_NETWORK" "$PROXY_NAME"
}

if [[ -n "$VLLM_ENDPOINT" ]]; then
    if docker inspect "$PROXY_NAME" &>/dev/null; then
        PROXY_ENDPOINT="$(docker inspect -f '{{index .Config.Labels "opencode.vllm_endpoint"}}' "$PROXY_NAME" 2>/dev/null || true)"
        if [[ "$PROXY_ENDPOINT" != "$VLLM_ENDPOINT" ]]; then
            echo "vLLM endpoint changed — restarting proxy..."
            docker rm -f "$PROXY_NAME"
            start_proxy
        elif [[ "$(docker inspect -f '{{.State.Running}}' "$PROXY_NAME")" != "true" ]]; then
            docker start "$PROXY_NAME"
            docker network connect "$EXT_NETWORK" "$PROXY_NAME" 2>/dev/null || true
        else
            echo "proxy already running → ${VLLM_TARGET_HOST}:${VLLM_TARGET_PORT}"
        fi
    else
        start_proxy
    fi
fi

# ── DinD ──────────────────────────────────────────────────────────────────────
if docker inspect "$DIND_NAME" &>/dev/null; then
    DIND_PROJECT="$(docker inspect -f '{{index .Config.Labels "opencode.project"}}' "$DIND_NAME" 2>/dev/null || true)"
    if [[ "$DIND_PROJECT" != "$PROJECT" ]]; then
        echo "Project path changed — restarting dind..."
        docker rm -f "$DIND_NAME"
    elif [[ "$(docker inspect -f '{{.State.Running}}' "$DIND_NAME")" != "true" ]]; then
        echo "Restarting stopped dind..."
        docker start "$DIND_NAME"
        docker network connect "$EXT_NETWORK" "$DIND_NAME" 2>/dev/null || true
    else
        echo "dind already running"
    fi
fi

if ! docker inspect "$DIND_NAME" &>/dev/null; then
    echo "Starting dind..."
    docker run -d --name "$DIND_NAME" \
        --privileged \
        --network "$NETWORK" \
        -e DOCKER_TLS_CERTDIR="" \
        --label "opencode.project=$PROJECT" \
        -v "$PROJECT:/workspace" \
        docker:dind
    docker network connect "$EXT_NETWORK" "$DIND_NAME"
fi

# Wait for dockerd inside dind
echo -n "Waiting for dind..."
for _ in {1..60}; do
    docker exec "$DIND_NAME" docker info &>/dev/null && break
    sleep 1
    echo -n "."
done
docker exec "$DIND_NAME" docker info &>/dev/null || die "dind failed to start within 60s"
echo " ready"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
CLEANED=false
cleanup() {
    [[ "$CLEANED" == true ]] && return
    CLEANED=true
    $KEEP && return
    echo "Cleaning up..."
    docker rm -f "$DIND_NAME"  2>/dev/null || true
    docker rm -f "$PROXY_NAME" 2>/dev/null || true
    docker network rm "$NETWORK"     2>/dev/null || true
    docker network rm "$EXT_NETWORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Agent ─────────────────────────────────────────────────────────────────────
ARGS=(
    docker run --rm -it
    --network "$NETWORK"
    -e "DOCKER_HOST=tcp://${DIND_NAME}:2375"
    --read-only --tmpfs /tmp:rw,exec,size=1g
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp/home
    --cap-drop ALL
    --security-opt no-new-privileges
    -v "$PROJECT:/workspace"
    -w /workspace
    --env-file "$SCRIPT_DIR/agent.env"
)

[[ -n "$ANTHROPIC_API_KEY" ]] && ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[[ -n "$VLLM_API_KEY" ]]      && ARGS+=(-e "VLLM_API_KEY=$VLLM_API_KEY")
[[ -n "$GH_TOKEN" ]]          && ARGS+=(-e "GH_TOKEN=$GH_TOKEN")

# When proxy is active, point agent at it instead of the real endpoint
if [[ -n "$VLLM_ENDPOINT" ]]; then
    ARGS+=(-e "VLLM_BASE_URL=http://${PROXY_NAME}:${VLLM_TARGET_PORT}")
fi

if [[ -n "$OPENCODE_CONFIG" ]]; then
    [[ ! -f "$OPENCODE_CONFIG" ]] && die "config file not found: $OPENCODE_CONFIG"
    OPENCODE_CONFIG="$(cd "$(dirname "$OPENCODE_CONFIG")" && pwd)/$(basename "$OPENCODE_CONFIG")"
    ARGS+=(-v "$OPENCODE_CONFIG:/opt/opencode.json:ro" -e OPENCODE_CONFIG=/opt/opencode.json)
fi

ARGS+=("$IMAGE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

"${ARGS[@]}"
