#!/bin/bash

# shellcheck disable=SC2034 # consumed by hooks/pre-command
TUNNEL_DEFAULT_DOWNLOAD_URL="https://testingbot.com/downloads/testingbot-tunnel.zip"

# Downloads and caches the tunnel jar; prints the jar path.
# Uses an atomic mktemp+mv so a concurrent job on the same agent never sees a
# partial jar, and flock (when available) to avoid duplicate downloads.
tunnel_download() {
  local url="$1"
  local cache_dir="$2"
  local jar="${cache_dir}/testingbot-tunnel.jar"

  if [[ -f "${jar}" ]]; then
    echo "${jar}"
    return 0
  fi

  mkdir -p "${cache_dir}"
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9
      tunnel_download_fresh "${url}" "${jar}"
    ) 9>"${cache_dir}/.download.lock"
  else
    tunnel_download_fresh "${url}" "${jar}"
  fi

  [[ -f "${jar}" ]] || return 1
  echo "${jar}"
}

tunnel_download_fresh() {
  local url="$1"
  local jar="$2"

  # Another job may have finished the download while we waited on the lock
  [[ -f "${jar}" ]] && return 0

  local tmp
  tmp="$(mktemp -d)"
  tb_log "Downloading TestingBot tunnel from ${url}" >&2
  curl -fsSL --retry 5 -o "${tmp}/tunnel.zip" "${url}"
  unzip -o -q "${tmp}/tunnel.zip" -d "${tmp}"

  local extracted
  extracted="$(find "${tmp}" -name '*.jar' -print | head -n1)"
  if [[ -z "${extracted}" ]]; then
    rm -rf "${tmp}"
    tb_die "Downloaded archive from ${url} does not contain a jar file"
  fi

  mv "${extracted}" "${jar}"
  rm -rf "${tmp}"
}

# Starts the tunnel in the background and records its PID.
# Credentials are read by the tunnel from TESTINGBOT_KEY/TESTINGBOT_SECRET in
# the environment — never passed as arguments (keeps them out of `ps`).
tunnel_start() {
  local jar="$1"
  local state_dir="$2"
  shift 2

  local -a cmd=(
    java -jar "${jar}"
    --readyfile "${state_dir}/ready"
    --logfile "${state_dir}/tunnel.log"
  )
  if [[ -n "${TESTINGBOT_TUNNEL_IDENTIFIER:-}" ]]; then
    cmd+=(--tunnel-identifier "${TESTINGBOT_TUNNEL_IDENTIFIER}")
  fi
  if [[ $# -gt 0 ]]; then
    cmd+=("$@")
  fi

  tb_log "Starting TestingBot tunnel"
  nohup "${cmd[@]}" >>"${state_dir}/tunnel.log" 2>&1 &
  echo $! >"${state_dir}/tunnel.pid"
}

# Waits for the tunnel readyfile, failing fast when the process dies
tunnel_wait_ready() {
  local state_dir="$1"
  local timeout="$2"
  local pid
  pid="$(cat "${state_dir}/tunnel.pid")"
  local interval="${TESTINGBOT_PLUGIN_POLL_INTERVAL:-1}"

  local waited=0
  while [[ ! -f "${state_dir}/ready" ]]; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      tb_warn "TestingBot tunnel process died before becoming ready"
      return 1
    fi
    if [[ "${waited}" -ge "${timeout}" ]]; then
      tb_warn "TestingBot tunnel did not become ready within ${timeout}s"
      return 1
    fi
    sleep "${interval}"
    waited=$((waited + 1))
  done

  tb_log "TestingBot tunnel is ready"
}

# Gracefully stops the tunnel: SIGTERM (the JVM deregisters via its shutdown
# hook; SIGINT is unusable here — bash starts `&` jobs with SIGINT ignored),
# wait up to 15s, then SIGKILL. Safe to call when nothing is running.
tunnel_stop() {
  local state_dir="$1"
  local pid_file="${state_dir}/tunnel.pid"

  [[ -f "${pid_file}" ]] || return 0
  local pid
  pid="$(cat "${pid_file}")"

  if kill -0 "${pid}" 2>/dev/null; then
    tb_log "Stopping TestingBot tunnel (pid ${pid})"
    kill -TERM "${pid}" 2>/dev/null || true

    local waited=0
    while kill -0 "${pid}" 2>/dev/null && [[ "${waited}" -lt 15 ]]; do
      sleep "${TESTINGBOT_PLUGIN_POLL_INTERVAL:-1}"
      waited=$((waited + 1))
    done

    if kill -0 "${pid}" 2>/dev/null; then
      tb_warn "Tunnel did not exit after SIGTERM; sending SIGKILL"
      kill -9 "${pid}" 2>/dev/null || true
    fi
  fi

  rm -f "${pid_file}"
}
