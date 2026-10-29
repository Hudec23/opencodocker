Sidecar

Add the Docker CLI to the image with this Dockerfile:

dockerfile

FROM ghcr.io/anomalyco/opencode:2.2.0
USER root
RUN apk add --no-cache docker-cli docker-cli-buildx
bash
docker build -t opencode-docker .

Start a private daemon:

bash
docker network create oc-net
docker run -d --name oc-dind --privileged --network oc-net \
  -e DOCKER_TLS_CERTDIR="" \
  -v "$PWD/project:/workspace" \
  docker:dind

Run OpenCode against it. This is the same command as before, with three changes: the network, DOCKER_HOST, and the new image.

bash
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
  -e GIT_AUTHOR_NAME="opencode-agent" -e GIT_AUTHOR_EMAIL="agent@localhost" \
  -e GIT_COMMITTER_NAME="opencode-agent" -e GIT_COMMITTER_EMAIL="agent@localhost" \
  -e GIT_CONFIG_COUNT=1 \
  -e GIT_CONFIG_KEY_0=credential.helper \
  -e GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
  opencode-docker

Clean up afterwards:

bash
docker rm -f oc-dind && docker network rm oc-net

Gotchas

Bind mounts resolve on the daemon, not in the agent’s container. When the agent runs docker run -v /workspace/x:/x, the path is looked up inside oc-dind. That’s why the project is mounted into the sidecar at the same /workspace path.
No TLS on the daemon. DOCKER_TLS_CERTDIR="" turns TLS off. That’s acceptable only because oc-net is a private network with just these two containers on it.
--privileged on the sidecar is a real escape risk if the agent does something hostile inside it. On a Linux host, run the sidecar with --runtime=sysbox-runc instead of --privileged to close that gap.
On Docker Desktop (Mac/Windows), everything already runs inside a VM, which softens the privileged risk somewhat.
