#!/usr/bin/env bash
#
# Skaffold an LRO service, its worker and its smoketest in one command, with the
# smoketest pointed at the freshly skaffolded LRO.
#
# Replaces the manual four-step loop:
#   1. dscore skaffold <worker>    -n <ns> -c <ctx> -a <alias>
#   2. dscore skaffold <lro>       -n <ns> -c <ctx> -a <alias>
#   3. hand-edit the client address in services/<lro>/api.go
#   4. dscore skaffold <lro>-smoketest -n <ns> -c <ctx> -a <alias> -t smoketest
#
# The address edit in step 3 is applied automatically before the build and
# reverted on exit, so the working tree is left untouched.
#
# Usage:  one-step-skaffold.sh <lro-service> -a <alias> [options]
#
# Params:  <lro-service>   Name of the LRO service, e.g. cbct-panoramic-curve-proposal
#          -a, --alias     Remotedev alias (required), e.g. nm
#          -n, --namespace Kubernetes namespace (default: core)
#          -c, --context   Kubecontext (default: lightning-d2)
#          -w, --worker    Worker name (default: auto-detected in the namespace)
#              --no-worker Skip the worker; only skaffold the LRO and smoketest
#              --keep      Leave the skaffold sessions running after the smoketest
#              --timeout   Seconds to wait for the smoketest job (default: 1800)
#
# Requires: dscore, skaffold, kubectl, git — and an authenticated gcloud session.
#
set -euo pipefail

# Job control. Without it every background job inherits this script's process
# group, and dscore cannot then be interrupted -- see start_session/stop_session.
set -m

# Line range of the Usage/Params block above, printed by usage().
readonly USAGE_FIRST_LINE=15
readonly USAGE_LAST_LINE=26

readonly DEFAULT_NAMESPACE="core"
readonly DEFAULT_KUBECONTEXT="lightning-d2"
readonly DEFAULT_SMOKETEST_TIMEOUT=1800
readonly SERVICE_PORT="50051"
# dscore builds the image before the Deployment appears; allow for a cold build.
readonly ROLLOUT_TIMEOUT=1200
readonly TEARDOWN_GRACE=60

LRO=""
ALIAS=""
NAMESPACE="$DEFAULT_NAMESPACE"
KUBECONTEXT="$DEFAULT_KUBECONTEXT"
WORKER=""
WORKER_SERVICE=""
WORKER_DEPLOYMENT=""
RUN_WORKER=true
KEEP=false
SMOKETEST_TIMEOUT="$DEFAULT_SMOKETEST_TIMEOUT"

REPO_ROOT=""
API_FILE=""
API_BACKUP=""
LOG_DIR=""
LAST_PID=""
WORKER_PID=""
LRO_PID=""
SMOKETEST_PID=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n "${USAGE_FIRST_LINE},${USAGE_LAST_LINE}p" "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--alias)     ALIAS="${2:-}";            shift 2 ;;
      -n|--namespace) NAMESPACE="${2:-}";        shift 2 ;;
      -c|--context)   KUBECONTEXT="${2:-}";      shift 2 ;;
      -w|--worker)    WORKER="${2:-}";           shift 2 ;;
      --timeout)      SMOKETEST_TIMEOUT="${2:-}"; shift 2 ;;
      --no-worker)    RUN_WORKER=false;          shift ;;
      --keep)         KEEP=true;                 shift ;;
      -h|--help)      usage 0 ;;
      -*)             die "unknown flag: $1 (try --help)" ;;
      *)
        [[ -z "$LRO" ]] || die "unexpected argument: $1 (service already set to '$LRO')"
        LRO="$1"; shift ;;
    esac
  done

  [[ -n "$LRO" ]]   || { warn "missing <lro-service>"; usage 1; }
  [[ -n "$ALIAS" ]] || { warn "missing -a/--alias"; usage 1; }
  [[ "$ALIAS" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || die "alias '$ALIAS' is not a valid DNS label; it becomes part of the k8s object name"
  [[ "$SMOKETEST_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be a whole number of seconds"
}

kc() { kubectl --context "$KUBECONTEXT" -n "$NAMESPACE" "$@"; }

# Locate the source directory holding the LRO client, mirroring how dscore's
# detectServiceFolder resolves a service name: exact match first, then the
# longest directory name contained in the service name.
detect_service_dir() {
  local name="$1" best="" entry
  if [[ -d "$REPO_ROOT/services/$name" ]]; then
    printf '%s' "$REPO_ROOT/services/$name"
    return 0
  fi
  for entry in "$REPO_ROOT"/services/*/; do
    entry="$(basename "$entry")"
    if [[ "$name" == *"$entry"* && ${#entry} -gt ${#best} ]]; then best="$entry"; fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s' "$REPO_ROOT/services/$best"
}

preflight() {
  local bin
  for bin in dscore skaffold kubectl git; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not on PATH"
  done

  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBECONTEXT" \
    || die "kubecontext '$KUBECONTEXT' not found; run 'gcloud container clusters get-credentials ...' first"

  kc get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || die "cannot reach namespace '$NAMESPACE' on '$KUBECONTEXT' — is your gcloud session still valid? Try 'gcloud auth login'"

  # dscore clones the live objects, so each must already exist exactly once.
  kc get deployment "$LRO" >/dev/null 2>&1 \
    || die "no Deployment '$LRO' in $NAMESPACE — dscore skaffold clones an existing deployment"
  kc get service "$LRO" >/dev/null 2>&1 \
    || die "no Service '$LRO' in $NAMESPACE"
  kc get cronjob "${LRO}-smoketest" >/dev/null 2>&1 \
    || die "no CronJob '${LRO}-smoketest' in $NAMESPACE — this service has no deployed smoketest"

  if [[ "$RUN_WORKER" == true ]]; then
    resolve_worker
  fi
}

# Worker naming is not fully regular. Two things vary:
#   the stem   — parl pairs with parl-worker, but cbct-segmentation-lro pairs
#                with cbct-segmentation-worker (the -lro suffix is dropped);
#   the suffix — several services deploy version- or accelerator-tagged workers
#                (cbct-panoramic-curve-proposal-worker-v4.0.0,
#                cbct-segmentation-worker-t4, tooth-recognition-worker-v2.0).
# So: try both stems, prefer an exact <stem> hit, otherwise prefix-match. When
# more than one tagged worker matches we refuse to guess — silently picking a
# side of a live version/accelerator split would test the wrong thing.
#
# For versioned workers (MLE-2461+), sets:
#   WORKER_SERVICE    — the base service name for dscore skaffold (directory name)
#   WORKER_DEPLOYMENT — the versioned deployment name for kubectl checks
#   WORKER            — the name to display (same as WORKER_DEPLOYMENT)
resolve_worker() {
  local prefixes=("${LRO}-worker") prefix name
  local -a matches=()
  [[ "${LRO%-lro}-worker" == "${LRO}-worker" ]] || prefixes+=("${LRO%-lro}-worker")

  if [[ -n "$WORKER" ]]; then
    kc get deployment "$WORKER" >/dev/null 2>&1 \
      || die "no Deployment '$WORKER' in $NAMESPACE"
    # User provided explicit worker name — detect if it's versioned
    detect_worker_versioning "$WORKER"
    return 0
  fi

  # Try exact match first (unversioned deployment)
  for prefix in "${prefixes[@]}"; do
    if kc get deployment "$prefix" >/dev/null 2>&1; then
      WORKER="$prefix"
      WORKER_SERVICE="$prefix"
      WORKER_DEPLOYMENT="$prefix"
      return 0
    fi
  done

  # Look for versioned deployments
  for prefix in "${prefixes[@]}"; do
    while IFS= read -r name; do
      if [[ -n "$name" ]]; then matches+=("$name"); fi
    done < <(kc get deployments -o custom-columns=:.metadata.name --no-headers 2>/dev/null \
               | grep -E "^${prefix}" || true)
  done

  case "${#matches[@]}" in
    0) die "no worker Deployment for '$LRO' in $NAMESPACE (tried: ${prefixes[*]}) — pass -w <name> or --no-worker" ;;
    1)
      WORKER="${matches[0]}"
      detect_worker_versioning "$WORKER"
      ;;
    *)
      # Multiple versioned workers found
      die "several worker Deployments match '$LRO' in $NAMESPACE: ${matches[*]} — pick one with -w <name>"
      ;;
  esac
}

# Detect if a worker deployment is versioned and set WORKER_SERVICE/WORKER_DEPLOYMENT accordingly.
# Versioned deployments follow the pattern: <base-name>-v<major>.<minor>.<patch>
detect_worker_versioning() {
  local worker_name="$1"

  # Check if the name ends with a version pattern like -v2.5.0 or -v2.4.0
  if [[ "$worker_name" =~ ^(.+)-(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
    # Versioned worker: margin-line-detection-worker-v2.5.0
    WORKER_SERVICE="${BASH_REMATCH[1]}"    # margin-line-detection-worker
    WORKER_DEPLOYMENT="$worker_name"        # margin-line-detection-worker-v2.5.0
    log "detected versioned worker: service='$WORKER_SERVICE', deployment='$WORKER_DEPLOYMENT'"
  else
    # Unversioned worker or other suffix (t4, etc.)
    WORKER_SERVICE="$worker_name"
    WORKER_DEPLOYMENT="$worker_name"
  fi
}

# Repoint the LRO client at the aliased pod. Rewrites the whole right-hand side
# of the `address` const so it works across all three shapes used in the repo
# (serviceName + externalServicePort, serviceName + ":" + servicePort, ...).
patch_address() {
  local target="${LRO}-${ALIAS}:${SERVICE_PORT}" hits tmp
  hits="$(grep -c -E '^[[:space:]]*address[[:space:]]*=' "$API_FILE" || true)"
  [[ "$hits" -eq 1 ]] \
    || die "expected exactly 1 'address =' const in ${API_FILE#"$REPO_ROOT/"}, found $hits — patch it by hand"

  API_BACKUP="$(mktemp "${TMPDIR:-/tmp}/one-step-skaffold-api.XXXXXX")"
  cp "$API_FILE" "$API_BACKUP"

  tmp="$(mktemp "${TMPDIR:-/tmp}/one-step-skaffold-sed.XXXXXX")"
  sed -E "s|^([[:space:]]*address[[:space:]]*=[[:space:]]*).*\$|\1\"${target}\"|" "$API_FILE" >"$tmp"
  # Write through rather than mv, so the file keeps its own mode and inode.
  cat "$tmp" >"$API_FILE"
  rm -f "$tmp"

  log "patched ${API_FILE#"$REPO_ROOT/"} -> address = \"${target}\""
}

restore_address() {
  [[ -n "$API_BACKUP" && -f "$API_BACKUP" ]] || return 0
  cat "$API_BACKUP" >"$API_FILE"
  rm -f "$API_BACKUP"
  API_BACKUP=""
  log "restored ${API_FILE#"$REPO_ROOT/"}"
}

# Launch a blocking `dscore skaffold` in the background. The pid is returned via
# the LAST_PID global rather than stdout: command substitution would run the
# launch in a subshell and reparent the job away from this script.
#
# `set -m` at the top of the script makes each of these jobs a process group
# leader, so its pid doubles as the pgid of the whole dscore -> dscore-dev ->
# skaffold -> kubectl tree. stop_session relies on that.
#
# For versioned workers, accepts an optional 4th parameter: the deployment name.
# When provided, adds --deployment flag to dscore skaffold.
start_session() {
  local name="$1" type="$2" logfile="$3" deployment="${4:-}"
  : >"$logfile"

  if [[ -n "$deployment" ]]; then
    dscore skaffold "$name" --deployment "$deployment" -n "$NAMESPACE" -c "$KUBECONTEXT" -a "$ALIAS" -t "$type" \
      >"$logfile" 2>&1 </dev/null &
  else
    dscore skaffold "$name" -n "$NAMESPACE" -c "$KUBECONTEXT" -a "$ALIAS" -t "$type" \
      >"$logfile" 2>&1 </dev/null &
  fi
  LAST_PID=$!
}

# Returns 0 while any process in pgid $1 is still alive.
group_alive() {
  ps -eo pgid= -o pid= 2>/dev/null | awk -v g="$1" '$1==g {found=1} END {exit !found}'
}

# dscore installs a SIGINT handler that unpatches the Istio VirtualServices it
# added, so interrupt rather than terminate and give it time to finish.
#
# The signal MUST go to the process group (`-pid`), which is what a terminal
# Ctrl+C does. Signalling the dscore pid alone is silently ignored -- neither it
# nor the dscore-dev layer acts on it -- and the VirtualService stays patched.
stop_session() {
  local pid="$1" label="$2"
  [[ -n "$pid" ]] || return 0
  group_alive "$pid" || return 0
  log "stopping $label (pgid $pid)"
  kill -INT -- "-$pid" 2>/dev/null || true

  local waited=0
  while group_alive "$pid" && (( waited < TEARDOWN_GRACE )); do
    sleep 1; waited=$((waited + 1))
  done
  group_alive "$pid" || return 0

  warn "$label ignored SIGINT after ${TEARDOWN_GRACE}s; escalating to SIGKILL"
  warn "dscore's VirtualService unpatch will not have run -- verify manually"
  kill -KILL -- "-$pid" 2>/dev/null || true
  sleep 2
  if group_alive "$pid"; then
    warn "$label (pgid $pid) survived SIGKILL"
    return 1
  fi
  return 1
}

# Report anything dscore left behind. Best-effort: never changes the exit code
# on its own, but a dirty cluster after a clean teardown is worth shouting about.
report_residue() {
  local leftovers
  leftovers="$(kc get deployment,service -o name 2>/dev/null | grep -- "-${ALIAS}\$" || true)"
  [[ -n "$leftovers" ]] && {
    warn "leftover resources in $NAMESPACE:"
    warn "$leftovers"
    warn "delete with: kubectl --context $KUBECONTEXT -n $NAMESPACE delete $(tr '\n' ' ' <<<"$leftovers")"
  }

  local patched
  patched="$(kc get virtualservice -o \
    jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.spec.http[*].route[*].destination.host}{'\n'}{end}" \
    2>/dev/null | grep -E -- "-${ALIAS}([[:space:]]|\$)" || true)"
  [[ -n "$patched" ]] && {
    warn "VirtualServices still routing to the alias (dscore did not unpatch):"
    warn "$patched"
  }
  return 0
}

cleanup() {
  # Signal traps pass 128+signo; on a plain EXIT fall back to the script's status.
  local rc=${1:-$?}
  trap - EXIT INT TERM
  local torn_down=true

  restore_address
  stop_session "$SMOKETEST_PID" "smoketest" || torn_down=false
  if [[ "$KEEP" == true ]]; then
    local groups=""
    [[ -n "${LRO_PID:-}" ]] && groups+=" -$LRO_PID"
    [[ -n "${WORKER_PID:-}" ]] && groups+=" -$WORKER_PID"
    if [[ -n "$groups" ]]; then
      warn "--keep set: leaving the LRO and worker sessions running."
      warn "stop them with: kill -INT --$groups"
      warn "(the leading '-' targets the process group; signalling the pid alone is ignored)"
    fi
  else
    stop_session "$LRO_PID" "$LRO" || torn_down=false
    stop_session "$WORKER_PID" "$WORKER" || torn_down=false
    report_residue
  fi

  if [[ "$torn_down" != true ]]; then
    warn "teardown was incomplete -- see the warnings above"
    (( rc == 0 )) && rc=1
  fi
  exit "$rc"
}

wait_for_deployment() {
  local name="$1" pid="$2" logfile="$3"
  local deployment="${name}-${ALIAS}"
  log "waiting for deployment/$deployment (tail -f $logfile)"

  local waited=0
  until kc get deployment "$deployment" >/dev/null 2>&1; do
    kill -0 "$pid" 2>/dev/null \
      || { warn "--- last 40 lines of $logfile ---"; tail -40 "$logfile" >&2; \
           die "dscore exited before deployment/$deployment appeared"; }
    (( waited < ROLLOUT_TIMEOUT )) || die "deployment/$deployment never appeared after ${ROLLOUT_TIMEOUT}s"
    sleep 5; waited=$((waited + 5))
  done

  kc rollout status "deployment/$deployment" --timeout="${ROLLOUT_TIMEOUT}s" >&2 \
    || die "deployment/$deployment failed to become ready"
  log "deployment/$deployment is ready"
}

# Poll rather than `kubectl wait`, which cannot wait on Complete OR Failed.
wait_for_job() {
  local job="$1" pid="$2" waited=0 state
  while (( waited < SMOKETEST_TIMEOUT )); do
    if kc get job "$job" >/dev/null 2>&1; then
      state="$(kc get job "$job" \
        -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)"
      case "$state" in
        *Complete*) return 0 ;;
        *Failed*)   return 1 ;;
      esac
    elif ! kill -0 "$pid" 2>/dev/null; then
      return 3
    fi
    sleep 5; waited=$((waited + 5))
  done
  return 2
}

dump_job_logs() {
  local job="$1"
  # overrideJobValues sets ttlSecondsAfterFinished=300, so grab these promptly.
  printf '\n\033[1;34m==>\033[0m smoketest logs (%s)\n' "$job" >&2
  kc logs "job/$job" -c "$job" --tail=-1 2>/dev/null \
    || kc logs "job/$job" --all-containers --tail=-1 2>/dev/null \
    || warn "could not read logs for job/$job (pod may already be gone)"
}

main() {
  parse_args "$@"

  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repository — run this from within lightning-core"

  local service_dir
  service_dir="$(detect_service_dir "$LRO")" \
    || die "no source directory under services/ matches '$LRO'"
  API_FILE="$service_dir/api.go"
  [[ -f "$API_FILE" ]] || die "${API_FILE#"$REPO_ROOT/"} not found"

  preflight

  log "service   : $LRO"
  if [[ "$RUN_WORKER" == true ]]; then
    log "worker    : $WORKER"
  else
    log "worker    : (skipped)"
  fi
  log "smoketest : ${LRO}-smoketest"
  log "target    : $NAMESPACE @ $KUBECONTEXT, alias '$ALIAS'"

  LOG_DIR="${TMPDIR:-/tmp}/one-step-skaffold/${ALIAS}"
  mkdir -p "$LOG_DIR"
  log "logs      : $LOG_DIR"

  trap cleanup EXIT
  trap 'cleanup 130' INT
  trap 'cleanup 143' TERM
  patch_address

  if [[ "$RUN_WORKER" == true ]]; then
    # For versioned workers, pass both service name and deployment name
    if [[ "$WORKER_SERVICE" != "$WORKER_DEPLOYMENT" ]]; then
      start_session "$WORKER_SERVICE" service "$LOG_DIR/worker.log" "$WORKER_DEPLOYMENT"
      WORKER_PID="$LAST_PID"
    else
      start_session "$WORKER" service "$LOG_DIR/worker.log"
      WORKER_PID="$LAST_PID"
    fi
  fi
  start_session "$LRO" service "$LOG_DIR/lro.log"; LRO_PID="$LAST_PID"

  if [[ "$RUN_WORKER" == true ]]; then
    wait_for_deployment "$WORKER_DEPLOYMENT" "$WORKER_PID" "$LOG_DIR/worker.log"
  fi
  wait_for_deployment "$LRO" "$LRO_PID" "$LOG_DIR/lro.log"

  local job="${LRO}-smoketest-${ALIAS}"
  log "running smoketest against ${LRO}-${ALIAS}:${SERVICE_PORT}"
  start_session "${LRO}-smoketest" smoketest "$LOG_DIR/smoketest.log"
  SMOKETEST_PID="$LAST_PID"

  local rc=0
  wait_for_job "$job" "$SMOKETEST_PID" || rc=$?
  dump_job_logs "$job"

  case "$rc" in
    0) log "PASS — smoketest succeeded against ${LRO}-${ALIAS}" ;;
    1) warn "FAIL — smoketest job $job reported Failed" ;;
    2) warn "TIMEOUT — smoketest job $job did not finish within ${SMOKETEST_TIMEOUT}s" ;;
    3) warn "--- last 40 lines of $LOG_DIR/smoketest.log ---"
       tail -40 "$LOG_DIR/smoketest.log" >&2
       # dscore's cronjob path falls through to SkaffoldService, which always
       # fails for a smoketest target; that error is expected and harmless.
       warn "ABORTED — dscore exited before job $job was created" ;;
  esac

  return "$rc"
}

main "$@"
