#!/usr/bin/env bash
# Orchestrate the multi-ABI cefpack-android.aar build on a Limrun sandbox.
#
# Uses a stable sandbox display name (cefpack-aar-${CEF_SANDBOX_KEY:-v020}) with
# --reuse-if-exists so incremental retries reuse the 30 GB Chromium checkout and
# compiled Ninja objects instead of starting over, and deletes the sandbox once
# the verified AAR and bundle have been pulled back.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLS_DIR="${LIMRUN_TOOLS_DIR:-${ROOT}/tools}"
LIM="${TOOLS_DIR}/node_modules/.bin/lim"
TIMEOUT="${CEF_BUILD_TIMEOUT:-21600}"
MIN_CREDIT="${CEF_MIN_CREDIT:-0}"
POLL="${CEF_POLL:-30}"
SANDBOX_KEY="${CEF_SANDBOX_KEY:-v020}"
BUILD_COMMAND="${CEF_BUILD_COMMAND:-./scripts/build-cefpack-aar.sh}"

if [ -z "${LIM_API_KEY:-}" ]; then
  echo "no LIM_API_KEY: the account of the build is unknown" >&2
  exit 1
fi
export LIM_API_KEY

if [ ! -x "${LIM}" ]; then
  echo "== installing the Limrun CLI =="
  mkdir -p "${TOOLS_DIR}"
  (
    cd "${TOOLS_DIR}"
    [ -f package.json ] || printf '{"name":"cef-build-tools","private":true}\n' > package.json
    npm install --no-audit --no-fund --save-exact "@limrun/api@0.73.1" "lim@0.57.1"
  )
fi

echo "== 1. checking Limrun account =="
ACCOUNT="$(curl -sf -H "Authorization: Bearer ${LIM_API_KEY}" https://api.limrun.com/v1/whoami | python3 "${HERE}/whoami.py")"
ORG_NAME="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f1)"
ORG_ID="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f2)"
CREDIT="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f3)"
echo "account '${ORG_NAME}' (${ORG_ID}); credit=${CREDIT} minutes"
if [ "${MIN_CREDIT}" -gt 0 ] && [ "${CREDIT}" -lt "${MIN_CREDIT}" ]; then
  echo "not enough credit (${CREDIT} < ${MIN_CREDIT})" >&2
  exit 1
fi

echo "== 2. creating or reusing Limrun sandbox (cefpack-aar-${SANDBOX_KEY}) =="
LISTED="$("${LIM}" gradle list --json 2>/dev/null || echo "[]")"
ID="$(printf '%s' "${LISTED}" | python3 -c '
import json, sys
target = sys.argv[1]
raw = sys.stdin.read().strip()
items = []
if raw:
    try:
        parsed = json.loads(raw)
        items = parsed if isinstance(parsed, list) else parsed.get("items", [parsed])
    except Exception:
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith("{"):
                try:
                    items.append(json.loads(line))
                except Exception:
                    pass
for item in items:
    meta = item.get("metadata", {}) if isinstance(item, dict) else {}
    name = meta.get("displayName") or item.get("displayName") or ""
    sid = meta.get("id") or item.get("id") or ""
    if name == target and sid:
        print(sid)
        sys.exit(0)
' "cefpack-aar-${SANDBOX_KEY}")"

REUSING=0
if [ -n "${ID}" ]; then
  REUSING=1
  echo "reusing existing warm sandbox id: ${ID}"
else
  CREATED="$("${LIM}" gradle create --display-name "cefpack-aar-${SANDBOX_KEY}" --hard-timeout "${TIMEOUT}s" --inactivity-timeout "${TIMEOUT}s" --reuse-if-exists --json)"
  ID="$(printf '%s' "${CREATED}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["id"])')"
  echo "created new sandbox id: ${ID}"
fi

cleanup() {
  local exit_code=$?
  if [ "${exit_code}" -eq 0 ]; then
    echo "== 7. deleting completed sandbox ${ID} =="
    "${LIM}" gradle delete "${ID}" || true
  else
    echo "== 7. keeping sandbox ${ID} for fast incremental resume =="
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

WORKSPACE="/home/limrun/workspaces/$(basename "${ROOT}")"
LOG="${WORKSPACE}/build-aar.log"
COMMIT_REF="${GITHUB_SHA:-$(git rev-parse HEAD)}"

echo "== 3. syncing repository into sandbox (reusing=${REUSING}, ref=${COMMIT_REF}) =="
if [ "${REUSING}" = "1" ]; then
  # Warm sandboxes hold ~500,000 Chromium files in ${WORKSPACE}/cef-source, which causes
  # `lim gradle sync` directory diffing to exceed Node undici's 300s headersTimeout.
  # Stream the exact commit tarball directly into ${WORKSPACE} in <2s instead.
  "${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- \
    "mkdir -p ${WORKSPACE} && curl -fsSL --retry 3 https://codeload.github.com/maceip/cefpack/tar.gz/${COMMIT_REF} | tar -xz --strip-components=1 -C ${WORKSPACE} && chmod +x ${WORKSPACE}/scripts/*.sh"
else
  "${LIM}" gradle sync "${ROOT}" --id "${ID}"
fi

echo "== 4. starting detached AAR build =="
START="cd ${WORKSPACE} && rm -f build-aar.log && nohup bash -c '${BUILD_COMMAND}; echo CEFPACK-AAR-EXIT:\$?' > build-aar.log 2>&1 &"
"${LIM}" gradle run --id "${ID}" --no-sync --timeout 300 -- "${START}" || true
echo "detached build started in ${WORKSPACE}"

echo "== 5. polling build progress & cgroup memory =="
DEADLINE=$(( $(date +%s) + TIMEOUT ))
LAST=""
DONE=0
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  sleep "${POLL}"
  OUT="$("${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 12 ${LOG} 2>/dev/null || true; echo \"[cgroup] current=\$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo ?) peak=\$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo ?) max=\$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo ?)\"" 2>/dev/null || true)"
  if [ -n "${OUT}" ] && [ "${OUT}" != "${LAST}" ]; then
    printf '%s\n---\n' "${OUT}"
    LAST="${OUT}"
  fi
  case "${OUT}" in
    *CEFPACK-AAR-EXIT:0*)
      DONE=1
      break
      ;;
    *CEFPACK-AAR-EXIT:*)
      echo "the AAR build failed; dumping last 120 lines of ${LOG}:" >&2
      "${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 120 ${LOG}" || true
      exit 1
      ;;
  esac
done

if [ "${DONE}" != "1" ]; then
  echo "the AAR build timed out after ${TIMEOUT} seconds" >&2
  "${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 120 ${LOG}" || true
  exit 1
fi

echo "== 6. pulling cefpack-android.aar & cef-bundle.tar.gz from sandbox =="
"${LIM}" gradle pull-file "cefpack-android.aar" "${ROOT}/cefpack-android.aar" --id "${ID}"
"${LIM}" gradle pull-file "cef-bundle.tar.gz" "${ROOT}/cef-bundle.tar.gz" --id "${ID}"
sha256sum "${ROOT}/cefpack-android.aar" > "${ROOT}/cefpack-android.aar.sha256"
sha256sum "${ROOT}/cef-bundle.tar.gz" > "${ROOT}/cef-bundle.tar.gz.sha256"

python3 "${ROOT}/embedder/assemble_aar.py" --self-test >/dev/null
python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, "embedder")
import assemble_aar
assemble_aar.verify_aar(Path("cefpack-android.aar"), require_x64=True)
print("Pulled cefpack-android.aar passed full host-side verification!")
'

ls -lh "${ROOT}/cefpack-android.aar" "${ROOT}/cef-bundle.tar.gz"
cat "${ROOT}/cefpack-android.aar.sha256" "${ROOT}/cef-bundle.tar.gz.sha256"
