#!/bin/bash
docker run --rm -it \
  --network oc-net \
  -e DOCKER_HOST=tcp://oc-dind:2375 \
  --read-only --tmpfs /tmp:rw,exec,size=1g \
  --user "$(id -u):$(id -g)" -e HOME=/tmp/home \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD/project:/workspace" -w /workspace \
  -v "$PWD/opencode.json:/opt/opencode.json:ro" \
  -e OPENCODE_CONFIG=/opt/opencode.json \
  -e ANTHROPIC_API_KEY \
  -e GH_TOKEN \
  --env-file agent.env \
  opencode-docker "$@"
