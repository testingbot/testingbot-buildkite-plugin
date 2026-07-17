#!/bin/bash
# End-to-end self-test: drives a real TestingBot browser session through the
# tunnel to a web server that only exists on this agent, proving the full
# tunnel + status-update + annotation flow.
set -euo pipefail

workdir="$(mktemp -d)"
cat >"${workdir}/index.html" <<'HTML'
<!DOCTYPE html>
<html><head><title>Buildkite E2E OK</title></head>
<body><h1>Served from the Buildkite agent, reached through the TestingBot tunnel</h1></body></html>
HTML
(cd "${workdir}" && exec python3 -m http.server 8123) >/dev/null 2>&1 &
server_pid=$!
disown
trap 'kill "${server_pid}" 2>/dev/null || true; rm -rf "${workdir}"' EXIT

# Chrome bypasses the tunnel proxy for "localhost", so use this machine's
# private IP — unreachable from the internet, only resolvable via the tunnel
local_ip="$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("8.8.8.8", 80)); print(s.getsockname()[0])')"

payload="$(jq -n \
  --arg key "${TESTINGBOT_KEY}" \
  --arg secret "${TESTINGBOT_SECRET}" \
  --arg build "${TESTINGBOT_BUILD}" \
  '{capabilities: {alwaysMatch: {browserName: "chrome",
    "tb:options": {key: $key, secret: $secret, build: $build, name: "plugin e2e — tunnel to localhost"}}}}')"

echo "--- Creating TestingBot browser session"
resp="$(curl -fsS -X POST "https://hub.testingbot.com/wd/hub/session" \
  -H "Content-Type: application/json" -d "${payload}")"
sid="$(echo "${resp}" | jq -r '.value.sessionId')"
echo "session: ${sid}"
echo "${sid}" >>"${TESTINGBOT_SESSIONS_FILE}"

echo "--- Navigating remote browser to http://${local_ip}:8123 (through the tunnel)"
curl -fsS -X POST "https://hub.testingbot.com/wd/hub/session/${sid}/url" \
  -H "Content-Type: application/json" -d "{\"url\": \"http://${local_ip}:8123/\"}" >/dev/null

title=""
for _ in 1 2 3 4 5; do
  sleep 2
  title="$(curl -fsS "https://hub.testingbot.com/wd/hub/session/${sid}/title" | jq -r '.value')"
  [[ "${title}" == "Buildkite E2E OK" ]] && break
done
echo "page title seen by remote browser: ${title}"

curl -fsS -X DELETE "https://hub.testingbot.com/wd/hub/session/${sid}" >/dev/null

[[ "${title}" == "Buildkite E2E OK" ]]
