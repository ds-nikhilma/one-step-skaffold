# mle-skaffold-e2e

One command that skaffolds a lightning-core **LRO service, its worker and its
smoketest** into a shared cluster under your remotedev alias, runs the
smoketest against your freshly built LRO, and tears everything down again.

It replaces this manual four-step loop:

1. `dscore skaffold <worker> -n <ns> -c <ctx> -a <alias>`
2. `dscore skaffold <lro> -n <ns> -c <ctx> -a <alias>`
3. hand-edit the client `address` const in `services/<lro>/api.go` so the smoketest talks to `<lro>-<alias>`
4. `dscore skaffold <lro>-smoketest -n <ns> -c <ctx> -a <alias> -t smoketest`

Step 3 is applied automatically before the build and reverted on exit, so your
lightning-core working tree is left untouched.

Originally written for the MLE team under MLE-2266
([DS-DP-S/lightning-core#6252](https://github.com/DS-DP-S/lightning-core/pull/6252)).
It works for any worker-backed LRO service in lightning-core that has a deployed
smoketest CronJob — see [Per-service commands](#per-service-commands).

---

## Contents

- [Prerequisites](#prerequisites)
- [Install](#install)
- [Quick start](#quick-start)
- [Options](#options)
- [What it does, step by step](#what-it-does-step-by-step)
- [Worker resolution](#worker-resolution)
- [Per-service commands](#per-service-commands)
- [Testing two versioned workers at once](#testing-two-versioned-workers-at-once)
- [Logs, exit codes and teardown](#logs-exit-codes-and-teardown)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Verified services](#verified-services)
- [Maintaining this script](#maintaining-this-script)

---

## Prerequisites

You need all of these **before** running the script. Most failed first runs
come from the last three.

| Requirement | How to check / fix |
| --- | --- |
| A local **lightning-core** checkout | The script must be run from *inside* it (any subdirectory is fine). It reads `services/<service>/api.go`. |
| `dscore`, `skaffold`, `kubectl`, `git` on `PATH` | `command -v dscore skaffold kubectl git` |
| Kubecontext for the target cluster (default `lightning-d2`) | `kubectl config get-contexts -o name \| grep lightning-d2` — if missing, run `gcloud container clusters get-credentials ...` for the cluster |
| **Docker daemon running** | `docker info >/dev/null && echo ok` — on macOS: `open -a Docker` and wait for it to start. *The script does not check this*; dscore fails mid-build without it. |
| **Fresh gcloud credentials** | `gcloud auth login && gcloud auth application-default login`. Expired tokens show up as `Reauthentication failed. cannot prompt during non-interactive execution` from `kubectl`. The script cannot log in for you. |
| **Generated protos for the service** | `ls <lightning-core>/proto/generated/go/core/<service>` should exist. If not, see [Troubleshooting](#troubleshooting) (stale `.generated-rpcs.done`). |

The service itself must already be deployed in the target namespace: the
Deployment `<service>`, the Service `<service>`, the CronJob
`<service>-smoketest` and the worker Deployment. dscore *clones* live objects;
it does not create them from scratch.

## Install

```bash
git clone https://github.com/ds-nikhilma/mle-skaffold-e2e.git ~/tools/mle-skaffold-e2e

# Option A: put it on your PATH
mkdir -p ~/.local/bin
ln -s ~/tools/mle-skaffold-e2e/mle-skaffold-e2e.sh ~/.local/bin/mle-skaffold-e2e.sh
# make sure ~/.local/bin is on PATH (e.g. in ~/.zshrc):
#   export PATH="$HOME/.local/bin:$PATH"

# Option B: call it by absolute path
~/tools/mle-skaffold-e2e/mle-skaffold-e2e.sh --help
```

The script locates lightning-core from your **current directory**
(`git rev-parse --show-toplevel`), not from where the script lives. So always
`cd` into your lightning-core checkout first.

To update: `git -C ~/tools/mle-skaffold-e2e pull`.

## Quick start

```bash
cd ~/path/to/lightning-core
git switch <your-branch>            # the code you want to test

mle-skaffold-e2e.sh margin-line-detection -a nm
```

`-a` is your **remotedev alias** — use your initials, e.g. `nm`. Everything the
script creates is suffixed `-<alias>` (`margin-line-detection-nm`,
`margin-line-detection-worker-nm`, …), so two people can test the same service
at the same time without colliding. It must be a valid DNS label: lowercase
letters, digits and `-`.

A full run (cold image builds, rollout, smoketest, teardown) takes roughly
6–10 minutes. Expected end of a green run:

```
==> PASS — smoketest succeeded against margin-line-detection-nm
==> restored services/margin-line-detection/api.go
==> stopping smoketest (pgid …)
==> stopping margin-line-detection (pgid …)
==> stopping margin-line-detection-worker (pgid …)
```

…and exit code `0`.

## Options

```
mle-skaffold-e2e.sh <lro-service> -a <alias> [options]
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `<lro-service>` | — | Name of the LRO service (required), e.g. `parl` |
| `-a, --alias` | — | Remotedev alias (required), e.g. `nm` |
| `-n, --namespace` | `core` | Kubernetes namespace |
| `-c, --context` | `lightning-d2` | Kubecontext |
| `-w, --worker` | auto-detected | Worker Deployment name — needed when several workers match (see below) |
| `--no-worker` | off | Skip the worker; skaffold only the LRO and the smoketest |
| `--keep` | off | Leave the LRO and worker sessions running after the smoketest |
| `--timeout` | `1800` | Seconds to wait for the smoketest Job to finish |
| `-h, --help` | | Print usage |

## What it does, step by step

1. **Locate the source.** Finds `services/<service>/` in your checkout (exact
   name first, then the longest `services/` directory name contained in the
   service name — the same rule dscore uses) and its `api.go`.
2. **Preflight.** Checks the tools are on `PATH`, the kubecontext exists, the
   namespace is reachable (i.e. your gcloud session works), and the Deployment,
   Service and `-smoketest` CronJob exist.
3. **Resolve the worker** Deployment — see [Worker resolution](#worker-resolution).
4. **Patch `api.go`.** Rewrites the single `address = …` const to
   `"<service>-<alias>:50051"`. A backup is kept in `$TMPDIR` and written back
   on exit, whatever happens.
5. **Start the worker and the LRO** as two background `dscore skaffold`
   sessions, and wait for both `<name>-<alias>` Deployments to roll out
   (up to 20 minutes each, to allow for cold builds).
6. **Run the smoketest** as a third `dscore skaffold … -t smoketest` session,
   poll the Job `<service>-smoketest-<alias>` until it is `Complete` or
   `Failed`, and print its logs.
7. **Tear down.** Restore `api.go`, then stop all three sessions with a
   process-group `SIGINT` so dscore removes its aliased objects and unpatches
   the Istio VirtualServices. Finally it reports any alias objects or
   VirtualService routes that survived.

## Worker resolution

Worker naming isn't fully regular, so the script tries, in order:

1. Exact `<service>-worker` (e.g. `parl` → `parl-worker`).
2. Exact `<service minus -lro>-worker` (e.g. `cbct-segmentation-lro` → `cbct-segmentation-worker`).
3. Any Deployment whose name **starts with** either of those.

- An exact hit always wins.
- Exactly one prefix match is used automatically. If it ends in a version
  (`-v2.5.0`, `-v4.0`), the script skaffolds the base service and passes
  `--deployment <versioned-name>` to dscore.
- **Several prefix matches → the script stops and lists them.** These are live
  version or accelerator splits (`-v1.1.0` / `-v4.0.0`, `-l4` / `-t4`), and
  silently picking one would test the wrong thing. Pass `-w <name>` to choose.
- No match → the script stops. Pass `-w <name>`, or `--no-worker` if the
  service genuinely has no worker.

## Per-service commands

Run from inside your lightning-core checkout. Replace `nm` with your alias.

### MLE-owned, worker auto-detected

```bash
mle-skaffold-e2e.sh margin-line-detection -a nm
mle-skaffold-e2e.sh ai-scan-orientation-lro -a nm
mle-skaffold-e2e.sh di-segmentation-lro -a nm
mle-skaffold-e2e.sh cbct-anatomy-segmentation -a nm
mle-skaffold-e2e.sh cbct-anatomy-segmentation-computation -a nm
mle-skaffold-e2e.sh parl -a nm
mle-skaffold-e2e.sh parl-detection -a nm
```

### MLE-owned, two workers deployed side by side — `-w` picks the one to test

```bash
mle-skaffold-e2e.sh cbct-panoramic-curve-proposal -a nm -w cbct-panoramic-curve-proposal-worker-v4.0.0
mle-skaffold-e2e.sh cbct-segmentation-lro -a nm -w cbct-segmentation-worker-t4
mle-skaffold-e2e.sh tooth-recognition -a nm -w tooth-recognition-worker-v4.0
```

The other side of each split: `cbct-panoramic-curve-proposal-worker-v1.1.0`,
`cbct-segmentation-worker-l4`, `tooth-recognition-worker-v2.0`.

### Worker-backed, other teams

```bash
mle-skaffold-e2e.sh di-comparison -a nm              # oncosm
mle-skaffold-e2e.sh di-di-matching -a nm             # oncosm
mle-skaffold-e2e.sh di-dx-matching-computation -a nm # diagnosis-1
mle-skaffold-e2e.sh di-tooth-modeling -a nm          # treatment-applications-4
mle-skaffold-e2e.sh malware-scanner -a nm            # storage-and-sync
```

### Other options in practice

```bash
# a different namespace / cluster
mle-skaffold-e2e.sh parl -a nm -n core -c lightning-d2

# keep the LRO + worker running after the smoketest, e.g. to poke at them
mle-skaffold-e2e.sh parl -a nm --keep
# …later, stop them with the command the script prints:
#   kill -INT -- -<pgid1> -<pgid2>

# a service with no worker (LRO + smoketest only)
mle-skaffold-e2e.sh <service> -a nm --no-worker

# allow a slow smoketest more time
mle-skaffold-e2e.sh tooth-recognition -a nm -w tooth-recognition-worker-v4.0 --timeout 3600
```

## Testing two versioned workers at once

The script starts one worker. To have the smoketest hit **both** sides of a
version split:

1. Start the *other* worker yourself first, under the same alias, and **wait
   until it has rolled out**:
   ```bash
   dscore skaffold cbct-panoramic-curve-proposal-worker \
     --deployment cbct-panoramic-curve-proposal-worker-v1.1.0 \
     -n core -c lightning-d2 -a nm -t service
   ```
2. Then run the script for the remaining worker:
   ```bash
   mle-skaffold-e2e.sh cbct-panoramic-curve-proposal -a nm -w cbct-panoramic-curve-proposal-worker-v4.0.0
   ```
3. At the end the script reports your manual worker as a **leftover** — that's
   expected. Stop it with Ctrl+C in its terminal.

Don't start both at the same moment. Both sessions build the same image tag
(`<worker>-<alias>:remotedev-<tree hash>`) and race the push. The loser dies
after ~8s with `image … was found but does not provide any platform`, and on
exit it also removes the *other* session's VirtualService rules for the alias.

## Logs, exit codes and teardown

**Logs** for each dscore session are written to
`$TMPDIR/mle-skaffold-e2e/<alias>/` — `worker.log`, `lro.log`, `smoketest.log`.
Follow one live with `tail -f`. The smoketest Job's own output is printed to
the terminal at the end. Grab it promptly: the Job is deleted 5 minutes after
it finishes.

**Exit codes**

| Code | Meaning |
| --- | --- |
| `0` | Smoketest passed and teardown was clean |
| `1` | Smoketest Job reported `Failed`, a preflight/setup error, or teardown was incomplete |
| `2` | Smoketest didn't finish within `--timeout` |
| `3` | dscore exited before the smoketest Job was created (see `smoketest.log`) |
| `130` | Interrupted with Ctrl+C (teardown still runs) |
| `143` | Terminated with SIGTERM (teardown still runs) |

**Teardown** runs on every exit path — pass, fail, error or Ctrl+C. It sends
`SIGINT` to each dscore session's **process group**, which is what a terminal
Ctrl+C does. This matters: dscore ignores `SIGINT`/`SIGTERM` sent to its pid
alone, and only on a group signal does it run its cleanup (removing
`<name>-<alias>` objects and the `remotedev=<alias>` VirtualService rule). If a
session hasn't exited after 60s the script escalates to `SIGKILL` and warns you
that the VirtualService needs checking by hand.

If you ever stop a `--keep` session yourself, signal the group:

```bash
kill -INT -- -<pgid>    # works
kill -INT <pid>         # silently ignored by dscore
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `kubecontext 'lightning-d2' not found` | Run `gcloud container clusters get-credentials …` for the cluster. |
| `cannot reach namespace …` / `Reauthentication failed. cannot prompt during non-interactive execution` | gcloud tokens expired: `gcloud auth login && gcloud auth application-default login`, then rerun. |
| dscore build fails with a Docker connection error | Docker daemon isn't running: `open -a Docker` (macOS), wait, rerun. |
| `not inside a git repository` / `no source directory under services/ matches …` | You're not inside a lightning-core checkout. `cd` into it. |
| `no Deployment/Service/CronJob '<name>'` | The service isn't deployed in that namespace, or has no smoketest. Check `-n` / `-c`. |
| `several worker Deployments match` | Version/accelerator split. Pass `-w <name>` (see [Per-service commands](#per-service-commands)). |
| `no worker Deployment for '<service>'` | Pass `-w <name>`, or `--no-worker` if there really is none. |
| `expected exactly 1 'address =' const` | The service declares its client address differently. Patch `api.go` by hand and run the four dscore steps manually. |
| Build fails on a missing generated Go package | A stale sentinel makes `compile-go` skip generation. `cd services/<service> && rm -f .sync-protos.done .generated-rpcs.done && make generate-rpcs`, then rerun. |
| `image … was found but does not provide any platform` | Two sessions built the same image tag at once. See [Testing two versioned workers at once](#testing-two-versioned-workers-at-once). |
| Worker deployment wait hangs | Make sure you're on the latest version of this script. Older versions waited on the wrong object name for versioned workers. |
| `leftover resources in core` after the run | The script prints a ready-made `kubectl delete` command. Expected if you started an extra worker manually. |
| `VirtualServices still routing to the alias` | dscore didn't unpatch, usually after a `SIGKILL`. Edit the VirtualService and remove the `remotedev=<alias>` header-match rule. |
| `api.go` still modified after a crash | Shouldn't happen (restored on every exit), but if the shell was killed hard: `git restore services/<service>/api.go`. |

## Known limitations

- `di-dx-matching`, `margin-line-storage`, `pdf-exporter` and
  `xray-control-book` declare the client address in a shape the patcher doesn't
  recognise, so they're unsupported.
- `--no-worker` exists for services without a worker but has not been tested
  end-to-end.
- The `-lro` → worker name derivation (step 2 of
  [Worker resolution](#worker-resolution)) hasn't been exercised in a live run
  yet. `ai-scan-orientation-lro` and `di-segmentation-lro` use it.
- No automatic preflight check yet for Docker running or generated protos
  existing. Check them yourself (see [Prerequisites](#prerequisites)).
- Exit codes `130`/`143` were verified in an isolated harness, not in a full
  cluster run.
- Logs live under `$TMPDIR//mle-skaffold-e2e/` (double slash on macOS).
  Harmless.

## Verified services

End-to-end green runs on `lightning-d2` / `core` (smoketest PASS, exit 0, clean
teardown — `api.go` restored, all sessions exited, no alias objects, VirtualService
unpatched):

| Service | Date | Notes |
| --- | --- | --- |
| `margin-line-detection` | 2026-09-02 | user auth + s2s auth |
| `cbct-anatomy-segmentation-computation` | 2026-09-13 | worker auto-resolved (exact match) |
| `parl` | 2026-10-07 | worker auto-resolved |

Worker resolution was also checked (without running smoketests) against all
worker-backed services on `lightning-d2` / `core`.

## Maintaining this script

Things that will break it, and where to look:

- **A service changes how it declares its client address** → `patch_address`
  (expects exactly one line matching `^\s*address\s*=`).
- **dscore changes its object naming or flags** (`-t`, `--deployment`, alias
  suffix) → `start_session`, `wait_for_deployment`, `report_residue`.
- **dscore changes its signal handling** → `stop_session`. Today it needs a
  process-group `SIGINT`. The script uses `set -m` so each background session
  is its own process group, and `$!` doubles as the pgid.
- **New worker naming patterns** → `resolve_worker` / `detect_worker_versioning`.
- **Default cluster/namespace move** → `DEFAULT_KUBECONTEXT` / `DEFAULT_NAMESPACE`
  at the top of the script.

The script is plain Bash with no dependencies beyond the tools above. Run
`bash -n mle-skaffold-e2e.sh` (and `shellcheck` if you have it) after edits.
