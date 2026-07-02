# taskwarrior-sync-helper

`taskwarrior-sync-helper` is a small wrapper around `task sync` for
multi-device Taskwarrior setups.

It is designed for a folder that is shared between machines with Syncthing,
Dropbox, or a similar file sync tool. Each device runs the same script, but the
script only calls `task sync` when there is a useful reason to do so:

- the current device has local Taskwarrior changes to upload
- another device synced changes and this device has not pulled them yet
- this is the first run and no shared sync state exists yet

The helper can also run Nautical recovery tools after a successful sync. This
is useful when some devices complete Nautical recurrence tasks without running
Taskwarrior hooks, for example a hookless client, web UI, phone setup, or
automation.

## What It Does

On each run, `task_sync.sh`:

1. Checks `task due:today list` for Taskwarrior's `Sync required.` message.
2. Reads a shared `last_sync_state` file next to the script.
3. Decides whether the current device needs to run `task sync`.
4. Optionally checks internet connectivity before syncing.
5. Runs `task sync` only when needed.
6. Records which devices have already seen the latest synced changes.
7. Writes a per-device log file under `logs/`.
8. Optionally runs Nautical chain repair and reconcile tools.

The shared state file is intentional. The log files are per-device to avoid
conflicts when the folder is shared across machines.

## Nautical Support

Taskwarrior Nautical adds recurrence engines on top of Taskwarrior:

- `cp` chains create the next task from a period such as `3d`, `28h`, or `1w`.
- `anchor` recurrence creates the next task from calendar positions such as
  `w:mon,wed` or `m:2sat`.

Nautical normally uses Taskwarrior hooks to create and link the next task when a
recurring task is completed. Hookless systems can complete a Nautical task
without giving those hooks a chance to spawn the next task.

This helper can run:

- `nautical_chain_repair.py` to repair safe `prevLink`, `nextLink`, and `link`
  metadata gaps
- `nautical_reconcile.py` to handle hookless completions, including backfilling
  an existing child or spawning the missing next task when it can be computed
  safely

See the Nautical manual for the full recurrence model and recovery workflow.

```text
github.com/catanadj/taskwarrior-nautical/blob/main/Taskwarrior-Nautical-v4-Systems-Manual.pdf
```

## Files

- `task_sync.sh` - the sync helper
- `task_sync.conf` - shell-compatible configuration loaded by the script
- `last_sync_state` - generated shared state file
- `logs/task_sync_<device>.log` - generated per-device logs

## Requirements

- POSIX shell
- Taskwarrior with `task sync` already configured
- A shared folder synced between devices, such as Syncthing or Dropbox
- `python3` if Nautical recovery is enabled
- Nautical installed if Nautical recovery is enabled

The script also uses common system tools such as `hostname`, `whoami`, `grep`,
`cut`, `tail`, `ping`, and optionally `curl` or `wget` for connectivity checks.

## Installation

Put this repository in a folder that is synced to each device.

Make the script executable:

```sh
chmod +x task_sync.sh
```

Copy or edit `task_sync.conf` for your environment. The file is loaded from the
same directory as `task_sync.sh`.

Run the helper:

```sh
./task_sync.sh
```

After `task sync` works normally on the device, you can use this helper as the
command you run instead of calling `task sync` directly. The helper will still
call `task sync` when needed, but it avoids unnecessary sync attempts when the
shared state says the device is already current.

For regular use, run it from cron, a systemd timer, a launcher, Termux, or any
automation tool you already use.

## Configuration

`task_sync.conf` is a shell file, so keep assignments in `KEY=value` form with
no spaces around `=`.

Common options:

```sh
TASK_BIN=task
PYTHON_BIN=python3

NAUTICAL_CORE_PATH=~/.task

RUN_NAUTICAL_CHAIN_REPAIR=1
NAUTICAL_CHAIN_REPAIR_APPLY=1

RUN_NAUTICAL_RECONCILE=1
NAUTICAL_RECONCILE_APPLY=1

RUN_NAUTICAL_ON_NO_SYNC=0
SKIP_CONNECTIVITY_CHECK=0
MAX_LOG_SIZE=102400
```

### Per-Device Paths

When the same synced folder is used on different operating systems or directory
layouts, configure per-device overrides.

By default, devices are matched by hostname, with `user@hostname` as a fallback.
You can map those names to stable labels:

```sh
DEVICE_CONFIG_KEYS='
desktop-host=desktop
u0_a885@localhost=phone
'
```

Then define paths for each label:

```sh
DEVICE_NAUTICAL_CORE_PATHS='
desktop=/home/user/.task
phone=/storage/emulated/0/.task
'

DEVICE_LOG_DIRS='
phone=/storage/emulated/0/task-sync-logs
'

DEVICE_LOCK_DIRS='
phone=/data/data/com.termux/files/usr/tmp/task_sync.lock
'
```

Relative paths are resolved from the script directory. Absolute paths are used
as-is.

### Nautical Recovery Modes

By default, the sample config enables Nautical chain repair and reconcile after
a `task sync` run:

```sh
RUN_NAUTICAL_CHAIN_REPAIR=1
NAUTICAL_CHAIN_REPAIR_APPLY=1
RUN_NAUTICAL_RECONCILE=1
NAUTICAL_RECONCILE_APPLY=1
```

Set an `*_APPLY` option to `0` to run the corresponding Nautical tool in
dry-run mode:

```sh
NAUTICAL_RECONCILE_APPLY=0
```

Set `RUN_NAUTICAL_ON_NO_SYNC=1` if you also want recovery tools to run when the
helper decides that no Taskwarrior sync is needed.

When the current device already has local changes to upload, the helper runs
Nautical recovery before `task sync`. That way any missing recurrence tasks
spawned by `nautical_reconcile.py` are included in the same sync. When the
helper is only pulling changes from another device, it runs Nautical recovery
after `task sync` so it can repair or reconcile the newly pulled data.

## Decision Logic

The script runs `task sync` when one of these conditions is true:

- local Taskwarrior output says `Sync required.`
- `last_sync_state` says another system synced changes and this system is not
  listed in `SYNCED_SYSTEMS`
- no `last_sync_state` file exists yet

It skips `task sync` when:

- there are no local changes
- no other device has announced newer changes
- the current device is already listed as synced for the latest shared state

## Logs and State

Generated files are kept next to the script unless configured otherwise:

- `last_sync_state` tracks the most recent sync and which devices have pulled it
- `logs/task_sync_<device>.log` records one-line summaries per device
- `.task_sync.lock` prevents overlapping runs from the same shared script folder

Logs rotate to `.bak` when they exceed `MAX_LOG_SIZE`.

## Notes

- This helper does not replace Taskwarrior's sync configuration. `task sync`
  must already work on each device.
- If connectivity checks are unreliable on your network, set
  `SKIP_CONNECTIVITY_CHECK=1`.
- Nautical recovery can create tasks when reconcile runs with `--apply`. Use
  dry-run mode first if you are setting up a new environment.

## License

MIT. See [LICENSE](LICENSE).
