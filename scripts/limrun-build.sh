#!/usr/bin/env bash
# Build CEF for Android on a Limrun sandbox.
#
# The build is heavy: a checkout of Chromium, the build itself and its output
# need about 150 GB of disk and hours of CPU.  A GitHub hosted runner has
# neither, so the build runs on a Limrun Gradle sandbox, which has a
# terabyte of disk and dozens of cores.
#
# The script does the whole round trip:
#
#   1. check the credit of the account — the build costs hours and the
#      account is billed by the minute, so it fails closed when there is not
#      enough of it;
#   2. create the sandbox and remember its id;
#   3. sync this repository into it;
#   4. run the build in it;
#   5. pull the bundle back;
#   6. delete the sandbox, whatever happened.
#
# Environment:
#   LIM_API_KEY        the key of the account (required)
#   LIMRUN_TOOLS_DIR   where the Limrun CLI is installed
#   CEF_BUILD_TIMEOUT  how long the build may take, in seconds (default 6 h)
#   CEF_MIN_CREDIT     the minutes of credit the build needs before it starts;
#                      0 (the default) means that the balance is only reported

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "${ROOT}"

TOOLS_DIR="${LIMRUN_TOOLS_DIR:-${ROOT}/tools}"
LIM="${TOOLS_DIR}/node_modules/.bin/lim"
TIMEOUT="${CEF_BUILD_TIMEOUT:-21600}"
MIN_CREDIT="${CEF_MIN_CREDIT:-0}"
# The command that runs in the sandbox.  The default is the build of the
# engine; the override exists to run a part of it, or to test the round
# trip without spending hours of credit.
BUILD_COMMAND="${CEF_BUILD_COMMAND:-./scripts/install-toolchain.sh \"\$HOME/trap-toolchain\" && . \"\$HOME/trap-toolchain/env.sh\" && ./scripts/build-android.sh && tar -czf cef-bundle.tar.gz -C cef-bundle .}"

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
    # The versions are pinned to the pair that was run against this build:
    # `lim 0.57.3` with `@limrun/api 0.73.2` ends the command that runs in
    # the sandbox after about a minute, with an exit code of -1, and the
    # build of the engine dies with it.  The pair below carries the
    # checkout of Chromium to its end.
    npm install --no-audit --no-fund --save-exact "@limrun/api@0.73.1" "lim@0.57.1"
  )
fi

echo "== 1. the account =="
# The account is reported before the build starts: which organization it is,
# how much credit it carries, and how much of that the build needs.  The
# balance is not always the thing that decides whether a build may run —
# an account that is paid after the fact reports no minutes and still
# accepts the sandbox — so the gate is off unless it is asked for.
ACCOUNT="$(curl -sf -H "Authorization: Bearer ${LIM_API_KEY}" \
  https://api.limrun.com/v1/whoami |
  python3 -c 'import json,sys; o=json.load(sys.stdin)["organization"]; print("%s|%s|%s" % (o.get("displayName") or o["id"], o["id"], o["creditMinutes"]))')"
ORG_NAME="${ACCOUNT%%|*}"
REST="${ACCOUNT#*|}"
ORG_ID="${REST%%|*}"
CREDIT="${REST##*|}"
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
CREATED="$("${LIM}" gradle create \
  --display-name "cef-build-$(git rev-parse --short HEAD 2>/dev/null || echo local)" \
  --hard-timeout "${TIMEOUT}s" \
  --inactivity-timeout "${TIMEOUT}s" \
  --reuse-if-exists \
  --json)"
# The answer of the CLI is {metadata, spec, status}; the id is in the
# metadata.
ID="$(printf '%s' "${CREATED}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"]["id"])')"
echo "the sandbox is ${ID}"

cleanup() {
  local exit_code=$?
  echo "== 6. the sandbox is deleted =="
  "${LIM}" gradle delete "${ID}" || true
  exit "${exit_code}"
}
trap cleanup EXIT

echo "== 3. the sources are synced =="
"${LIM}" gradle sync "${ROOT}" --id "${ID}"

echo "== 4. the build =="
# The project is synced into a workspace of the sandbox, named after the
# directory it was synced from.  The build script is the same one that a
# developer runs by hand.
REMOTE_ROOT="$("${LIM}" gradle run --id "${ID}" --no-sync --quiet --timeout 120 -- 'pwd' | tail -1)"
# The path is the one of the sandbox, so it is checked as a path and not as
# a directory of this machine.
case "${REMOTE_ROOT}" in
  /home/limrun/workspaces/*) ;;
  *)
    echo "the sandbox has no workspace at '${REMOTE_ROOT}'" >&2
    exit 1
    ;;
esac
echo "the build runs in ${REMOTE_ROOT}"
"${LIM}" gradle run --id "${ID}" --no-sync --timeout "${TIMEOUT}" -- \
  "cd '${REMOTE_ROOT}' && ${BUILD_COMMAND}"

echo "== 5. the bundle comes back =="
"${LIM}" gradle pull-file "cef-bundle.tar.gz" "${ROOT}/cef-bundle.tar.gz" --id "${ID}"
sha256sum "${ROOT}/cef-bundle.tar.gz" > "${ROOT}/cef-bundle.tar.gz.sha256"

echo
echo "the bundle is in ${ROOT}/cef-bundle.tar.gz"
