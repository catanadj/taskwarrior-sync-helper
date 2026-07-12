# taskwarrior-sync-helper

Small `task sync` helper for people who use Taskwarrior on more than one
device.

Put this folder somewhere shared by Syncthing, Dropbox, or similar. Run
`task_sync.sh` instead of running `task sync` directly. It checks whether sync
is actually needed, runs it when useful, and uses per-device generation signals
so each device knows whether it already pulled the latest changes.

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

No config is required for the safe defaults. To customize them, create a local
config outside the synchronized folder:

```sh
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/taskwarrior-sync-helper"
mkdir -p "$config_dir"
cp task_sync.conf.example "$config_dir/config"
```

You can also use `--config /path/to/config` or set `TASK_SYNC_CONFIG`. An old
`task_sync.conf` beside the script is intentionally ignored unless selected
explicitly, because sourced configuration is executable shell and should not
come from a synchronized folder.

Each device needs a stable, unique sync identity. The default is
`user@hostname`. If that can change, configure `DEVICE_SYNC_IDS` as shown in
`task_sync.conf.example`. Never reuse one sync identity on two devices.

For regular use, call `task_sync.sh` from cron, systemd, Termux, a launcher, or
whatever you currently use to run `task sync`.

## Main Config

The local config is a shell file. Use `KEY=value`, with no spaces around `=`.

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
FORCE_SYNC_INTERVAL_SECONDS=86400
```

If different devices use different paths, use the per-device examples already
included in `task_sync.conf.example`.

## Command Options

```text
--config PATH   Use an explicit configuration file
--force         Sync even when no local or signaled changes exist
--status        Show STATUS=SYNC_LOCAL, SYNC_REMOTE, or UP_TO_DATE without sync
--no-nautical   Disable Nautical recovery for this run
--help          Show built-in usage
```

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

## Coordination Behavior

Each device writes only its own file under `sync_signals/` and advances its
generation after uploading local changes. Other devices compare those shared
generations with a cursor stored outside the synchronized folder.

The cursor records the snapshot captured before `task sync`. If another signal
arrives while sync is running, it remains unacknowledged and triggers another
sync. A locally persisted pending generation also ensures that a process crash
after upload cannot lose the notification.

A full sync also runs after `FORCE_SYNC_INTERVAL_SECONDS` without a successful
sync. The daily default catches changes from clients that bypass the helper or
notifications missed by the file-sharing service. Set it to `0` to disable this
fallback.

## Generated Files

- `sync_signals/<device>.signal` - shared, single-writer device generations
- `$XDG_STATE_HOME/taskwarrior-sync-helper/...` - local cursor, generation, and
  pending-publication state plus per-device logs; falls back to `~/.local/state`
- `$XDG_RUNTIME_DIR/taskwarrior-sync-helper-<device>.lock` - local lock directory
  while the script is running; falls back to `$TMPDIR`, then `/tmp`

An existing `last_sync_state` from an older version is not modified. On the
first upgraded run, its presence causes one conservative migration sync and a
new local cursor is created.

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
read or modify your real task database. GitHub Actions runs the suite with both
the system shell and BusyBox, along with POSIX syntax checks and ShellCheck.

## License

MIT. See [LICENSE](LICENSE).
