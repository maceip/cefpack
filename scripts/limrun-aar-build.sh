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
SANDBOX_SCAN="$(printf '%s' "${LISTED}" | python3 -c '
import datetime, json, re, sys

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

def parse_dur_sec(val):
    if not val or not isinstance(val, str):
        return None
    total = 0
    matched = False
    for num, unit in re.findall(r"(\d+)([smhd])", val.strip()):
        matched = True
        n = int(num)
        total += n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return total if matched else None

def parse_iso(val):
    if not val or not isinstance(val, str):
        return None
    try:
        return datetime.datetime.fromisoformat(val.replace("Z", "+00:00"))
    except Exception:
        return None

now = datetime.datetime.now(datetime.timezone.utc)
reuse_id = ""
stale_ids = []

for item in items:
    if not isinstance(item, dict):
        continue
    meta = item.get("metadata") or {}
    spec = item.get("spec") or {}
    status = item.get("status") or {}
    name = meta.get("displayName") or item.get("displayName") or ""
    sid = meta.get("id") or item.get("id") or ""
    if not sid or not name.startswith("cefpack-aar-"):
        continue
    state = str(status.get("state") or status.get("phase") or item.get("state") or "").lower()
    if state in ("terminated", "terminating", "deleted", "failed"):
        continue
    created = parse_iso(meta.get("createdAt") or item.get("createdAt"))
    hard_sec = parse_dur_sec(spec.get("hardTimeout"))
    remaining = None
    if created is not None and hard_sec is not None:
        remaining = (created + datetime.timedelta(seconds=hard_sec) - now).total_seconds()
    if name == target:
        if remaining is not None and remaining < 7200:
            stale_ids.append(sid)
        elif not reuse_id:
            reuse_id = sid
    else:
        stale_ids.append(sid)

print("REUSE=" + reuse_id)
print("STALE=" + ",".join(stale_ids))
' "cefpack-aar-${SANDBOX_KEY}")"

ID="$(printf '%s\n' "${SANDBOX_SCAN}" | sed -n 's/^REUSE=//p' | head -n 1)"
STALE_IDS="$(printf '%s\n' "${SANDBOX_SCAN}" | sed -n 's/^STALE=//p' | head -n 1)"

if [ -n "${STALE_IDS}" ]; then
  IFS=',' read -r -a STALE_ARR <<< "${STALE_IDS}"
  for OLD_ID in "${STALE_ARR[@]}"; do
    if [ -n "${OLD_ID}" ]; then
      echo "deleting superseded/expiring sandbox ${OLD_ID}..."
      "${LIM}" gradle delete "${OLD_ID}" >/dev/null 2>&1 || true
    fi
  done
fi

REUSING=0
if [ -n "${ID}" ]; then
  REUSING=1
  echo "reusing existing warm sandbox id: ${ID}"
else
  # Use a 12h hard-timeout and 2h inactivity-timeout so active polled builds never
  # hit a premature 6h wall-clock cutoff across incremental resumes, while idle
  # sandboxes still auto-expire cleanly.
  CREATED="$("${LIM}" gradle create --display-name "cefpack-aar-${SANDBOX_KEY}" --hard-timeout "43200s" --inactivity-timeout "7200s" --reuse-if-exists --json)"
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
  # Stop any lingering detached build from a canceled prior workflow run before updating sources.
  "${LIM}" gradle run --id "${ID}" --no-sync --timeout 60 -- \
    "pkill -INT ninja 2>/dev/null || true; sleep 1; pkill -TERM -f build-cefpack-aar.sh 2>/dev/null || true; sleep 1" || true
  # Warm sandboxes hold ~500,000 Chromium files in ${WORKSPACE}/cef-source, which causes
  # `lim gradle sync` directory diffing to exceed Node undici's 300s headersTimeout.
  # Stream the exact commit tarball directly into ${WORKSPACE} in <2s instead.
  "${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- \
    "mkdir -p ${WORKSPACE} && curl -fsSL --retry 3 https://codeload.github.com/maceip/cefpack/tar.gz/${COMMIT_REF} | tar -xz --strip-components=1 -C ${WORKSPACE} && chmod +x ${WORKSPACE}/scripts/*.sh"
else
  "${LIM}" gradle sync "${ROOT}" --id "${ID}"
fi

echo "== 4. starting detached AAR build =="
START="cd ${WORKSPACE} && rm -f build-aar.log && setsid bash -c '${BUILD_COMMAND}; echo CEFPACK-AAR-EXIT:\$?' </dev/null >build-aar.log 2>&1 & sleep 2"
"${LIM}" gradle run --id "${ID}" --no-sync --timeout 60 -- "${START}"
echo "detached build started in ${WORKSPACE}"

echo "== 5. polling build progress & cgroup memory =="
DEADLINE=$(( $(date +%s) + TIMEOUT ))
LAST=""
DONE=0
POLL_FAILURES=0
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  sleep "${POLL}"
  if OUT="$("${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 12 ${LOG} 2>/dev/null || true; RUNNING=\$(pgrep -f build-cefpack-aar.sh >/dev/null 2>&1 && echo 1 || echo 0); echo \"[cgroup] running=\${RUNNING} current=\$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo ?) peak=\$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo ?) max=\$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo ?)\"" 2>&1)"; then
    POLL_FAILURES=0
  else
    POLL_FAILURES=$(( POLL_FAILURES + 1 ))
    echo "poll warning (${POLL_FAILURES}/5): ${OUT}" >&2
    if [ "${POLL_FAILURES}" -ge 5 ]; then
      echo "sandbox ${ID} became unreachable after ${POLL_FAILURES} consecutive poll errors" >&2
      exit 1
    fi
    continue
  fi
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
    *"[cgroup] running=0 "*)
      SETTLE="$("${LIM}" gradle run --id "${ID}" --no-sync --timeout 120 -- "tail -n 120 ${LOG} 2>/dev/null || true" 2>/dev/null || true)"
      case "${SETTLE}" in
        *CEFPACK-AAR-EXIT:0*)
          DONE=1
          break
          ;;
        *)
          echo "build-cefpack-aar.sh exited unexpectedly without CEFPACK-AAR-EXIT:0; last 120 log lines:" >&2
          printf '%s\n' "${SETTLE}" >&2
          exit 1
          ;;
      esac
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
