#!/bin/bash

TB_API_BASE="${TB_API_BASE:-https://api.testingbot.com/v1}"
TB_WEB_BASE="${TB_WEB_BASE:-https://testingbot.com}"

# curl with Basic auth fed via a config file on stdin so credentials never
# appear in `ps` output
tb_curl() {
  printf 'user = "%s:%s"\n' "${TESTINGBOT_KEY}" "${TESTINGBOT_SECRET}" \
    | curl -fsS --retry 2 -K - "$@"
}

# PUT passed/failed (1/0) and a status message onto a test.
# $1 = WebDriver session ID (or numeric test ID), $2 = 1|0, $3 = message
tb_update_status() {
  tb_curl -X PUT \
    --data-urlencode "test[success]=$2" \
    --data-urlencode "test[status_message]=$3" \
    "${TB_API_BASE}/tests/$1"
}

tb_get_test() {
  tb_curl "${TB_API_BASE}/tests/$1"
}

# Lists tests in a build (string build identifier accepted). $1 = build id,
# $2 = offset
tb_get_build_tests() {
  tb_curl --get \
    --data-urlencode "count=500" \
    --data-urlencode "offset=${2:-0}" \
    "${TB_API_BASE}/builds/$1"
}

# Portable md5 (GNU md5sum / BSD md5)
tb_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  else
    printf '%s' "$1" | md5
  fi
}

# Share-URL auth hashes, per https://testingbot.com/support/other/sharing
tb_share_hash() {
  tb_md5 "${TESTINGBOT_KEY}:${TESTINGBOT_SECRET}:$1"
}

# $1 = session id, $2 = "true" for no-login share links
tb_test_url() {
  if [[ "$2" == "true" ]]; then
    echo "${TB_WEB_BASE}/tests/$1?auth=$(tb_share_hash "$1")"
  else
    echo "${TB_WEB_BASE}/members/tests/$1"
  fi
}

# Stable share video URL (the API's `video` field is an expiring signed URL)
tb_video_url() {
  echo "${TB_WEB_BASE}/tests/$1.mp4?auth=$(tb_share_hash "$1")"
}

# $1 = build identifier, $2 = "true" for share link
tb_build_url() {
  if [[ "$2" == "true" ]]; then
    echo "${TB_WEB_BASE}/builds/${TESTINGBOT_KEY}/$1?auth=$(tb_share_hash "$1")"
  else
    echo "${TB_WEB_BASE}/members/builds"
  fi
}
