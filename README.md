# one-step-skaffold

One command to skaffold a lightning-core LRO, its worker and its smoketest under
your alias, run the smoketest against your LRO, then tear it all down.

## Setup

```bash
git clone https://github.com/ds-nikhilma/one-step-skaffold.git ~/tools/one-step-skaffold
ln -s ~/tools/one-step-skaffold/one-step-skaffold.sh ~/.local/bin/   # or call it by full path
```

Before running:

- `dscore`, `skaffold`, `kubectl`, `git` installed
- Docker running
- Fresh gcloud login: `gcloud auth login && gcloud auth application-default login`

## Usage

Run from inside your lightning-core checkout:

```bash
one-step-skaffold.sh <service> -a <alias>

# e.g.
one-step-skaffold.sh margin-line-detection -a nm
```

| Flag | Default | |
| --- | --- | --- |
| `-a` | — | Your alias (required) |
| `-n` | `core` | Namespace |
| `-c` | `lightning-d2` | Kubecontext |
| `-w` | auto | Worker deployment, if more than one matches |
| `--no-worker` | | Skip the worker |
| `--keep` | | Don't tear down afterwards |
| `--timeout` | `1800` | Smoketest timeout (seconds) |

If a service has several workers (e.g. `-v1.1.0` / `-v4.0.0`), the script lists
them. Pick one with `-w`:

```bash
one-step-skaffold.sh tooth-recognition -a nm -w tooth-recognition-worker-v4.0
```

Exit code is `0` on pass. Logs are in `$TMPDIR/one-step-skaffold/<alias>/`.

## Troubleshooting

- **`Reauthentication failed`**: redo the gcloud login above.
- **Missing generated Go package**: `cd services/<service> && rm -f .sync-protos.done .generated-rpcs.done && make generate-rpcs`
- **Leftovers after a crash**: the script prints a `kubectl delete` command. Stop a `--keep` session with `kill -INT -- -<pgid>`, using the leading `-`. dscore ignores a plain pid kill.
