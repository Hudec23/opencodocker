#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load .env if present (never committed — see .gitignore)
[[ -f "$SCRIPT_DIR/.env" ]] && set -o allexport && source "$SCRIPT_DIR/.env" && set +o allexport

IMAGE=opencode-docker
PROXY_LISTEN_PORT=8080

PROJECT=""
INSTANCE=""
GH_TOKEN="${GH_TOKEN:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
VLLM_API_KEY="${VLLM_API_KEY:-}"
VLLM_ENDPOINT="${VLLM_ENDPOINT:-}"
BLOCK_LOCAL="${BLOCK_LOCAL:-false}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
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
  --vllm-endpoint URL  vLLM server URL to proxy   (or \$VLLM_ENDPOINT)
  --gh-token TOKEN     GitHub fine-grained PAT     (or \$GH_TOKEN)

Options (network):
  --block-local        Block agent from reaching LAN/private IPs (Linux only,
                       requires root). Set ALLOWED_HOSTS in .env for exceptions.
                       (or set BLOCK_LOCAL=true in .env)

Options (misc):
  --config PATH        Path to opencode.json config file
  --instance NAME      Instance suffix for containers/networks
                       (default: project basename — lets you run multiple agents)
  --keep               Keep containers after run (faster next start)
  --build              Force rebuild of opencode-docker image
  -h, --help           Show this help

Pass-through:
  -- ARGS              Arguments forwarded to opencode inside the container

Examples:
  $(basename "$0")
  $(basename "$0") --project ~/myrepo --block-local
  $(basename "$0") -- run --standalone --auto "Read task.md and implement it"
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
        --block-local)   BLOCK_LOCAL=true; shift ;;
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

[[ -z "$INSTANCE" ]] && INSTANCE="$(basename "$PROJECT")"
INSTANCE="$(echo "$INSTANCE" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"
[[ -z "$INSTANCE" ]] && die "instance name is empty after sanitizing — pass --instance NAME"

NETWORK="oc-net-${INSTANCE}"
DIND_NAME="oc-dind-${INSTANCE}"
PROXY_NAME="oc-proxy-${INSTANCE}"
AGENT_NAME="oc-agent-${INSTANCE}"
PROXY_CONF="/tmp/oc-proxy-${INSTANCE}.conf"
AGENT_IP_FILE="/tmp/oc-agent-ip-${INSTANCE}"
NET_SUBNET=""

# Refuse to clobber another live run that maps to the same instance name
# (e.g. ~/a/app and ~/b/app both default to "app").
if [[ "$(docker inspect -f '{{.State.Running}}' "$AGENT_NAME" 2>/dev/null || true)" == "true" ]]; then
    _other="$(docker inspect -f '{{index .Config.Labels "opencode.project"}}' "$DIND_NAME" 2>/dev/null || true)"
    die "instance '$INSTANCE' already running${_other:+ for $_other} — pass --instance NAME"
fi

# Parse VLLM_ENDPOINT → upstream host for nginx Host header + SNI
VLLM_UPSTREAM_HOST=""
VLLM_IS_HTTPS=false
if [[ -n "$VLLM_ENDPOINT" ]]; then
    [[ "$VLLM_ENDPOINT" == https://* ]] && VLLM_IS_HTTPS=true
    _stripped="${VLLM_ENDPOINT#http://}"
    _stripped="${_stripped#https://}"
    _stripped="${_stripped%%/*}"
    VLLM_UPSTREAM_HOST="${_stripped}"
fi

# ── iptables (--block-local) ──────────────────────────────────────────────────
# Rules are scoped to the source IPs of the agent and dind. dind needs them too:
# containers the agent launches inside dind are NATed to dind's IP on oc-net.
# The nginx proxy is not restricted (it only forwards to VLLM_ENDPOINT).
# ALLOWED_HOSTS (.env, comma-separated) are accepted before private ranges are dropped.

if $BLOCK_LOCAL; then
    if ! command -v iptables &>/dev/null; then
        echo "warning: iptables not found — --block-local requires Linux. Skipping."
        BLOCK_LOCAL=false
    elif ! iptables -L DOCKER-USER &>/dev/null; then
        echo "warning: cannot access DOCKER-USER chain — run as root for --block-local. Skipping."
        BLOCK_LOCAL=false
    fi
fi

add_iptables_rules() {
    local ip="$1" label="$2"
    echo "iptables: blocking LAN from $label ($ip)..."
    # DROP private ranges first (they land below ACCEPT rules due to -I ordering)
    for range in "169.254.0.0/16" "100.64.0.0/10" "192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8"; do
        iptables -I DOCKER-USER -s "$ip" -d "$range" -j DROP
    done
    # ACCEPT own bridge subnet (agent, dind + proxy live there, and it falls inside 172.16/12)
    [[ -n "$NET_SUBNET" ]] && iptables -I DOCKER-USER -s "$ip" -d "$NET_SUBNET" -j ACCEPT
    # ACCEPT allowlist — each -I goes to top, ending up above all DROPs
    if [[ -n "$ALLOWED_HOSTS" ]]; then
        IFS=',' read -ra _hosts <<< "$ALLOWED_HOSTS"
        for host in "${_hosts[@]}"; do
            host="${host// /}"
            [[ -z "$host" ]] && continue
            iptables -I DOCKER-USER -s "$ip" -d "$host" -j ACCEPT
            echo "iptables: allowed $host for $label"
        done
    fi
}

remove_iptables_rules() {
    local ip="$1" label="$2"
    echo "iptables: removing rules for $label ($ip)..."
    if [[ -n "$ALLOWED_HOSTS" ]]; then
        IFS=',' read -ra _hosts <<< "$ALLOWED_HOSTS"
        for host in "${_hosts[@]}"; do
            host="${host// /}"
            [[ -z "$host" ]] && continue
            iptables -D DOCKER-USER -s "$ip" -d "$host" -j ACCEPT 2>/dev/null || true
        done
    fi
    [[ -n "$NET_SUBNET" ]] && { iptables -D DOCKER-USER -s "$ip" -d "$NET_SUBNET" -j ACCEPT 2>/dev/null || true; }
    for range in "169.254.0.0/16" "100.64.0.0/10" "192.168.0.0/16" "172.16.0.0/12" "10.0.0.0/8"; do
        iptables -D DOCKER-USER -s "$ip" -d "$range" -j DROP 2>/dev/null || true
    done
}

# ── nginx proxy config ────────────────────────────────────────────────────────
write_proxy_conf() {
    local ssl_directives=""
    if $VLLM_IS_HTTPS; then
        ssl_directives="
            proxy_ssl_server_name on;
            proxy_ssl_name        ${VLLM_UPSTREAM_HOST};
            proxy_ssl_verify      off;"
    fi
    cat > "$PROXY_CONF" <<NGINXEOF
events {}
http {
    server {
        listen ${PROXY_LISTEN_PORT};
        location / {
            proxy_pass          ${VLLM_ENDPOINT};
            proxy_set_header    Host ${VLLM_UPSTREAM_HOST};
            proxy_http_version  1.1;
            proxy_set_header    Connection "";
            proxy_buffering     off;
            proxy_cache         off;
            proxy_read_timeout  600s;
            proxy_send_timeout  600s;
            client_max_body_size 50m;${ssl_directives}
        }
    }
}
NGINXEOF
}

# ── Build image ───────────────────────────────────────────────────────────────
if $BUILD || ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "Building $IMAGE..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# ── Cleanup trap ──────────────────────────────────────────────────────────────
WATCHER_PID=""
DIND_IP=""
CLEANED=false
cleanup() {
    [[ "$CLEANED" == true ]] && return
    CLEANED=true
    [[ -n "$WATCHER_PID" ]] && kill "$WATCHER_PID" 2>/dev/null || true
    if $BLOCK_LOCAL && [[ -f "$AGENT_IP_FILE" ]]; then
        remove_iptables_rules "$(cat "$AGENT_IP_FILE")" agent
        rm -f "$AGENT_IP_FILE"
    fi
    if $BLOCK_LOCAL && [[ -n "$DIND_IP" ]]; then
        remove_iptables_rules "$DIND_IP" dind
    fi
    $KEEP && return
    echo "Cleaning up..."
    docker rm -f "$AGENT_NAME" 2>/dev/null || true
    docker rm -f "$DIND_NAME"  2>/dev/null || true
    docker rm -f "$PROXY_NAME" 2>/dev/null || true
    docker network rm "$NETWORK" 2>/dev/null || true
    rm -f "$PROXY_CONF"
}
trap cleanup EXIT INT TERM

# ── Network ───────────────────────────────────────────────────────────────────
docker network inspect "$NETWORK" &>/dev/null || docker network create "$NETWORK"
NET_SUBNET="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK")"

# ── Proxy (nginx) ─────────────────────────────────────────────────────────────
start_proxy() {
    echo "Starting proxy → ${VLLM_ENDPOINT}..."
    write_proxy_conf
    docker run -d --name "$PROXY_NAME" \
        --network "$NETWORK" \
        --label "opencode.vllm_endpoint=$VLLM_ENDPOINT" \
        -v "$PROXY_CONF:/etc/nginx/nginx.conf:ro" \
        nginx:alpine
}

if [[ -n "$VLLM_ENDPOINT" ]]; then
    if docker inspect "$PROXY_NAME" &>/dev/null; then
        PROXY_ENDPOINT="$(docker inspect -f '{{index .Config.Labels "opencode.vllm_endpoint"}}' "$PROXY_NAME" 2>/dev/null || true)"
        if [[ "$PROXY_ENDPOINT" != "$VLLM_ENDPOINT" ]]; then
            echo "vLLM endpoint changed — restarting proxy..."
            docker rm -f "$PROXY_NAME"
            start_proxy
        elif [[ "$(docker inspect -f '{{.State.Running}}' "$PROXY_NAME")" != "true" ]]; then
            write_proxy_conf && docker start "$PROXY_NAME"
        else
            echo "proxy already running → ${VLLM_ENDPOINT}"
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

echo -n "Waiting for dind..."
for _ in {1..60}; do
    docker exec "$DIND_NAME" docker info &>/dev/null && break
    sleep 1
    echo -n "."
done
docker exec "$DIND_NAME" docker info &>/dev/null || die "dind failed to start within 60s"
echo " ready"

# Block LAN for dind before the agent exists, so nothing launched via dind can
# reach it. Remove first in case a crashed previous run left rules behind.
if $BLOCK_LOCAL; then
    DIND_IP="$(docker inspect -f \
        "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" "$DIND_NAME")"
    [[ -z "$DIND_IP" ]] && die "could not determine dind IP for --block-local"
    remove_iptables_rules "$DIND_IP" dind >/dev/null
    add_iptables_rules "$DIND_IP" dind
fi

# ── Agent ─────────────────────────────────────────────────────────────────────
docker rm -f "$AGENT_NAME" 2>/dev/null || true
rm -f "$AGENT_IP_FILE"

# Background watcher: once agent container starts, get its IP and add iptables rules.
# Runs concurrently with docker run — rules are applied within ~100ms of start.
if $BLOCK_LOCAL; then
    (
        i=0
        while [[ $i -lt 100 ]]; do
            ip=$(docker inspect -f \
                "{{(index .NetworkSettings.Networks \"${NETWORK}\").IPAddress}}" \
                "$AGENT_NAME" 2>/dev/null || true)
            if [[ -n "$ip" ]]; then
                echo "$ip" > "$AGENT_IP_FILE"
                add_iptables_rules "$ip" agent
                break
            fi
            sleep 0.1
            ((i++)) || true
        done
        [[ -f "$AGENT_IP_FILE" ]] || echo "warning: agent IP not found within 10s — LAN NOT blocked" >&2
    ) &
    WATCHER_PID=$!
fi

ARGS=(
    docker run --rm -it
    --name "$AGENT_NAME"
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
[[ -n "${BRAVE_API_SEARCH_KEY:-}" ]] && ARGS+=(-e "BRAVE_API_SEARCH_KEY=$BRAVE_API_SEARCH_KEY")

if [[ -n "$VLLM_ENDPOINT" ]]; then
    ARGS+=(-e "VLLM_BASE_URL=http://${PROXY_NAME}:${PROXY_LISTEN_PORT}")
fi

if [[ -n "$OPENCODE_CONFIG" ]]; then
    [[ ! -f "$OPENCODE_CONFIG" ]] && die "config file not found: $OPENCODE_CONFIG"
    OPENCODE_CONFIG="$(cd "$(dirname "$OPENCODE_CONFIG")" && pwd)/$(basename "$OPENCODE_CONFIG")"
    ARGS+=(-v "$OPENCODE_CONFIG:/opt/opencode.json:ro" -e OPENCODE_CONFIG=/opt/opencode.json)
fi

ARGS+=("$IMAGE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

"${ARGS[@]}"
