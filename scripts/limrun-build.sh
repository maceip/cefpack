#!/usr/bin/env bash
# Build CEF for Android on a Limrun sandbox.
#
# The build is heavy: a checkout of Chromium, the build itself and its
# output need about 150 GB of disk and hours of CPU; a GitHub hosted runner
# has neither.  The build therefore runs on a Limrun sandbox, which has a
# terabyte of disk and dozens of cores.
#
# The build is started *detached*: the platform ends a command that runs for
# a long time without saying anything, and a build that is killed with it
# is a build that is lost.  A detached build keeps running, the log of it
# is read from here, and the bundle is pulled back when the log says that
# it is ready.
#
# The script does the whole round trip:
#
#   1. check the credit of the account — the build costs hours and the
#      account is billed by the minute;
#   2. create the sandbox and remember its id;
#   3. sync this repository into it;
#   4. start the build in it, detached;
#   5. read the log of the build until it is done;
#   6. pull the bundle back;
#   7. delete the sandbox, whatever happened.
#
# Environment:
#   LIM_API_KEY        the key of the account (required)
#   LIMRUN_TOOLS_DIR   where the Limrun CLI is installed
#   CEF_BUILD_TIMEOUT  how long the build may take, in seconds (default 6 h)
#   CEF_MIN_CREDIT     the minutes of credit the build needs (0: report only)
#   CEF_POLL           how long to wait between two reads of the log

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLS_DIR="${LIMRUN_TOOLS_DIR:-${ROOT}/tools}"
LIM="${TOOLS_DIR}/node_modules/.bin/lim"
TIMEOUT="${CEF_BUILD_TIMEOUT:-21600}"
MIN_CREDIT="${CEF_MIN_CREDIT:-0}"
POLL="${CEF_POLL:-60}"

# The command that runs in the sandbox.  The default is the build of the
# engine; the override exists to run a part of it, or to test the round
# trip without spending hours of credit.
BUILD_COMMAND="${CEF_BUILD_COMMAND:-./scripts/sandbox-build.sh}"

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
    # The versions are pinned to the pair that was run against this build.
    npm install --no-audit --no-fund --save-exact "@limrun/api@0.73.1" "lim@0.57.1"
  )
fi

echo "== 1. the account =="
# The account is reported before the build starts: which organization it is,
# how much credit it carries, and how much of that the build needs.  The
# balance is not always the thing that decides whether a build may run —
# an account that is paid after the fact reports no minutes and still
# accepts the sandbox — so the gate is off unless it is asked for.
ACCOUNT="$(curl -sf -H "Authorization: Bearer ${LIM_API_KEY}" https://api.limrun.com/v1/whoami | python3 "${HERE}/whoami.py")"
ORG_NAME="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f1)"
ORG_ID="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f2)"
CREDIT="$(printf '%s' "${ACCOUNT}" | cut -d'|' -f3)"
echo "the account is '${ORG_NAME}' (${ORG_ID}); it carries ${CREDIT} minutes of credit"
if [ "${MIN_CREDIT}" -gt 0 ]; then
  echo "the build needs ${MIN_CREDIT} minutes of it"
  if [ "${CREDIT}" -lt "${MIN_CREDIT}" ]; then
    echo "not enough credit: the build would be cut off halfway.  Top the account up" >&2
    echo "(https://console.limrun.com) and run this again." >&2
    exit 1
  fi
else
  echo "the balance is reported, not enforced: set CEF_MIN_CREDIT to enforce it"
fi

echo "== 2. the sandbox =="
# The hard timeout and the inactivity timeout are the same: the build runs
# for hours, and a sandbox that is put to sleep halfway through it would
# cost the whole checkout.  The hard timeout is what ends the run.
SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo local)"
CREATED="$("${LIM}" gradle create --display-name "cef-build-${SHORT}" --hard-timeout "${TIMEOUT}s" --inactivity-timeout "${TIMEOUT}s" --reuse-if-exists --json)"
# The answer of the CLI is {metadata, spec, status}; the id is in the
# metadata.
ID="$(printf '%s' "${CREATED}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["id"])')"
echo "the sandbox is ${ID}"

cleanup() {
  local exit_code=$?
  # A sandbox that **worked** is deleted: the tree of the sources is ten
  # gigabytes of somebody else's disk, and the bundle has been pulled out
  # of it.
  #
  # A sandbox whose build **failed** is kept.  The checkout of the sources
  # takes ten minutes and twenty-nine gigabytes, and a failure that is
  # fixed and tried again should not pay for it twice: the next run finds
  # the tree where it was, and `gclient` and the build continue from there.
  # The sandbox ends by itself when its timeout is over.
  if [ "${exit_code}" -eq 0 ]; then
    echo "== 7. the sandbox is deleted =="
    "${LIM}" gradle delete "${ID}" || true
  else
    echo "== 7. the sandbox is kept =="
    echo "the build failed; the sandbox ${ID} holds the tree of the sources and"
    echo "the logs of the build.  It ends by itself, and the next run reuses it:"
    echo "  lim gradle sync ${ROOT} --id ${ID} && lim gradle run --id ${ID} --no-sync -- ./scripts/sandbox-build.sh"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

echo "== 3. the sources are synced =="
"${LIM}" gradle sync "${ROOT}" --id "${ID}"

# The workspace of the sandbox carries the name of the directory that was
# synced, and the build runs in it.
WORKSPACE="/home/limrun/workspaces/$(basename "${ROOT}")"
LOG="${WORKSPACE}/build.log"

echo "== 4. the build is started =="
# The build runs detached, and says in the log when it is done.  A command
# that the platform ends takes the build with it; a detached one does not.
START="cd ${WORKSPACE} && nohup bash -c '${BUILD_COMMAND}; echo CEF-BUILD-EXIT:\$?' > build.log 2>&1 &"
"${LIM}" gradle run --id "${ID}" --no-sync --timeout 300 -- "${START}" || true
echo "the build is running in the sandbox"

echo "== 5. the log is read =="
# The log is read until it says that the build is done.  A read that the
# platform ends is simply read again.
#
# The memory of the container is read with every poll.  The container has
# a ceiling of sixteen gigabytes and the kernel kills a process when the
# ceiling is reached; the number that is read is the only account of how
# close the build came to it, and it is the account that the earlier runs
# did not have.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
LAST=""
DONE=0
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  sleep "${POLL}"
  OUT="$("${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 5 ${LOG} 2>/dev/null || true; echo \"memory: \$(awk '/^memory.current/{print \$2}' /sys/fs/cgroup/memory.current 2>/dev/null) of \$(awk '/^memory.max/{print \$2}' /sys/fs/cgroup/memory.max 2>/dev/null) bytes\"" 2>/dev/null || true)"
  if [ -n "${OUT}" ] && [ "${OUT}" != "${LAST}" ]; then
    printf '%s\n' "${OUT}"
    LAST="${OUT}"
  fi
  case "${OUT}" in
    *CEF-BUILD-EXIT:0*)
      DONE=1
      break
      ;;
    *CEF-BUILD-EXIT:*)
      echo "the build failed" >&2
      "${LIM}" gradle run --id "${ID}" --no-sync --timeout 180 -- "tail -n 40 ${LOG}" || true
      exit 1
      ;;
  esac
done
if [ "${DONE}" != "1" ]; then
  echo "the build did not finish in ${TIMEOUT} seconds" >&2
  exit 1
fi

echo "== 6. the bundle comes back =="
"${LIM}" gradle pull-file "cef-bundle.tar.gz" "${ROOT}/cef-bundle.tar.gz" --id "${ID}"
sha256sum "${ROOT}/cef-bundle.tar.gz" > "${ROOT}/cef-bundle.tar.gz.sha256"

echo
echo "the bundle is in ${ROOT}/cef-bundle.tar.gz"
