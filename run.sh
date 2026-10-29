#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=opencode-docker

PROJECT=""
INSTANCE=""
GH_TOKEN="${GH_TOKEN:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OPENCODE_CONFIG=""
KEEP=false
BUILD=false
EXTRA_ARGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") --project PATH [OPTIONS] [-- OPENCODE_ARGS...]

Required:
  --project PATH       Project directory mounted as /workspace in the agent

Options:
  --gh-token TOKEN     GitHub fine-grained PAT with push access (or \$GH_TOKEN)
  --anthropic-key KEY  Anthropic API key (or \$ANTHROPIC_API_KEY)
  --config PATH        Path to opencode.json config file
  --instance NAME      Instance name suffix for network/dind (default: project basename)
                       Use this to run multiple agents simultaneously
  --keep               Keep dind container after run (faster next start)
  --build              Force rebuild of Docker image
  -h, --help           Show this help

Pass-through:
  -- ARGS              Arguments forwarded to opencode inside the container

Environment variables:
  GH_TOKEN             GitHub fine-grained PAT scoped to a single repo (push)
  ANTHROPIC_API_KEY    Anthropic API key

Notes:
  GH_TOKEN should be a fine-grained PAT with Contents read+write on the target
  repo. The agent uses a credential helper so git operations inside the
  container authenticate automatically.

  dind is started with --privileged on a private bridge network. No TLS is
  used because oc-net is isolated. See readme.md for security notes.

Examples:
  $(basename "$0") --project ~/myrepo
  $(basename "$0") --project ~/myrepo --config ~/myrepo/opencode.json
  GH_TOKEN=ghp_xxx $(basename "$0") --project ~/myrepo -- --help
  # run two agents in parallel (different terminals):
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
        --config)        OPENCODE_CONFIG="$2"; shift 2 ;;
        --keep)          KEEP=true; shift ;;
        --build)         BUILD=true; shift ;;
        --)              shift; EXTRA_ARGS=("$@"); break ;;
        -h|--help)       usage ;;
        *)               die "unknown option: $1" ;;
    esac
done

[[ -z "$PROJECT" ]]           && die "--project is required"
[[ -z "$ANTHROPIC_API_KEY" ]] && die "ANTHROPIC_API_KEY not set (use --anthropic-key or env var)"
[[ ! -d "$PROJECT" ]]         && die "project directory not found: $PROJECT"

PROJECT="$(cd "$PROJECT" && pwd)"

# Derive instance name from project basename if not set
[[ -z "$INSTANCE" ]] && INSTANCE="$(basename "$PROJECT")"
# Sanitize: lowercase, strip non-alphanumeric except dash
INSTANCE="$(echo "$INSTANCE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"

NETWORK="oc-net-${INSTANCE}"
DIND_NAME="oc-dind-${INSTANCE}"

# Build image if missing or --build requested
if $BUILD || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building $IMAGE..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# Network
docker network inspect "$NETWORK" &>/dev/null || docker network create "$NETWORK"

# dind — start, restart if stopped, detect project change
if docker inspect "$DIND_NAME" &>/dev/null; then
    RUNNING="$(docker inspect -f '{{.State.Running}}' "$DIND_NAME")"
    DIND_PROJECT="$(docker inspect -f '{{index .Config.Labels "opencode.project"}}' "$DIND_NAME" 2>/dev/null || true)"
    if [[ "$DIND_PROJECT" != "$PROJECT" ]]; then
        echo "Project path changed — restarting dind..."
        docker rm -f "$DIND_NAME"
        RUNNING=false
    elif [[ "$RUNNING" != "true" ]]; then
        echo "Restarting stopped dind..."
        docker start "$DIND_NAME"
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

# Cleanup on exit
CLEANED=false
cleanup() {
    [[ "$CLEANED" == true ]] && return
    CLEANED=true
    $KEEP && return
    echo "Cleaning up..."
    docker rm -f "$DIND_NAME" 2>/dev/null || true
    docker network rm "$NETWORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Assemble docker run args
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
    -e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
)

[[ -n "$GH_TOKEN" ]] && ARGS+=(-e "GH_TOKEN=$GH_TOKEN")

if [[ -n "$OPENCODE_CONFIG" ]]; then
    [[ ! -f "$OPENCODE_CONFIG" ]] && die "config file not found: $OPENCODE_CONFIG"
    OPENCODE_CONFIG="$(cd "$(dirname "$OPENCODE_CONFIG")" && pwd)/$(basename "$OPENCODE_CONFIG")"
    ARGS+=(-v "$OPENCODE_CONFIG:/opt/opencode.json:ro" -e OPENCODE_CONFIG=/opt/opencode.json)
fi

ARGS+=("$IMAGE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

"${ARGS[@]}"
