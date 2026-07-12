# taskwarrior-sync-helper

Small `task sync` helper for people who use Taskwarrior on more than one
device.

Put this folder somewhere shared by Syncthing, Dropbox, or similar. Run
`task_sync.sh` instead of running `task sync` directly. It checks whether sync
is actually needed, runs it when useful, and keeps a small shared state file so
each device knows whether it already pulled the latest changes.

It can also run Taskwarrior Nautical recovery tools. This matters when you
complete Nautical recurring tasks on a client that does not run hooks, such as
WingTask or another hookless/mobile setup.

## Requirements

- Taskwarrior with `task sync` already working on each device
- POSIX shell
- a synced/shared folder for this repo
- `python3` and Nautical, only if Nautical recovery is enabled

Taskwarrior 3 uses its `Sync backlog transactions` statistic to detect local
operations, including with a local-directory sync backend. Taskwarrior 2 falls
back to its `Sync required` reminder.

## Setup

```sh
chmod +x task_sync.sh
./task_sync.sh
```

Edit `task_sync.conf` if your paths or options differ.

To use a config elsewhere, set `TASK_SYNC_CONFIG=/path/to/task_sync.conf`.

For regular use, call `task_sync.sh` from cron, systemd, Termux, a launcher, or
whatever you currently use to run `task sync`.

## Main Config

`task_sync.conf` is a shell file. Use `KEY=value`, with no spaces around `=`.

Common settings:

```sh
TASK_BIN=task
PYTHON_BIN=python3
NAUTICAL_CORE_PATH=~/.task

RUN_NAUTICAL_CHAIN_REPAIR=0
NAUTICAL_CHAIN_REPAIR_APPLY=0

RUN_NAUTICAL_RECONCILE=0
NAUTICAL_RECONCILE_APPLY=0

RUN_NAUTICAL_ON_NO_SYNC=0
```

If different devices use different paths, use the per-device examples already
included in `task_sync.conf`.

## Nautical Behavior

When local changes need to be uploaded, the script runs Nautical recovery before
`task sync`. That way tasks spawned by `nautical_reconcile.py` are synced in the
same run.

When the script is only pulling changes from another device, Nautical recovery
runs after `task sync`, so it works on the newly pulled data.

The recovery tools used are:

- `nautical_chain_repair.py`
- `nautical_reconcile.py`

Nautical recovery is disabled by default. Enable a `RUN_NAUTICAL_*` option to
run a tool in dry-run mode, then set its `*_APPLY` option to `1` only when you
are ready for it to modify tasks. A missing or failing enabled recovery tool
causes the helper to fail instead of silently continuing.

## Generated Files

- `last_sync_state` - shared sync state
- `logs/task_sync_<device>.log` - per-device log
- `$XDG_RUNTIME_DIR/taskwarrior-sync-helper-<device>.lock` - local lock directory
  while the script is running; falls back to `$TMPDIR`, then `/tmp`

## Notes

- This does not configure Taskwarrior sync for you. Make sure `task sync` works
  first.
- The helper calls `task sync` directly and uses its exit status; this supports
  network and local-directory sync backends without a separate connectivity
  probe.
- Nautical reconcile can create tasks when apply mode is enabled.

## Tests

Run the isolated regression suite with:

```sh
./tests/test_task_sync.sh
```

The suite uses a fake Taskwarrior command and temporary directories; it does not
read or modify your real task database.

## License

MIT. See [LICENSE](LICENSE).
