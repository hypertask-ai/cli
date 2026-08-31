# hypertask, the native Hypertask CLI

`hypertask` implements the current Hypertask command catalog in Zig. It uses the same API routes and `~/.hypertask/config.json` as the Node implementation, while avoiding a Node startup for every command.

Ticket: https://app.hypertask.ai/detail/project-15/5726

## Command coverage

The embedded catalog contains **137 leaf commands**.

```bash
hypertask capabilities --json
```

JSON is the default output. Pass `--human` for the minimal human-readable mode.

## Authentication

```bash
hypertask login --token '<jwt>'
hypertask status
hypertask logout
```

Browser login is not available in the native CLI. Obtain a JWT through the Hypertask web app, then pass it to `login --token`.

Token lookup supports `--token`, `HT_TOKEN`, `HYPERTASKS_JWT_TOKEN`, and `~/.hypertask/config.json`. API URL lookup supports `--api-url`, `HYPERTASKS_API_URL`, and the saved config.

## Correcting time entries

Use a negative log to subtract minutes from your latest completed whole-minute entry for a task. An exact subtraction deletes that entry; ambiguous partial-minute and oversized corrections are rejected.

```bash
hypertask time log RINT-32 -30
hypertask time update 119 --minutes 25 --note "Corrected"
hypertask time delete 119
```

Entry IDs are available from `hypertask time report`. `time edit` is an alias for `time update`.

## Build and install

```bash
zig build -Doptimize=ReleaseFast
install -m 755 zig-out/bin/hypertask ~/.local/bin/hypertask
```

## Agent usage

Use `hypertask` for board operations:

```bash
hypertask tasks get HTPR-5726 --project 15
hypertask tasks move HTPR-5726 --section "In Progress"
hypertask comment add HTPR-5726 --text "<p>...</p>"
hypertask agents update --id <agent-id> --add-project 339
hypertask search "query" --project 15
```

## Verification

```bash
zig build test
python3 scripts/parity_test.py --capabilities-only
python3 scripts/parity_test.py --architecture-only
python3 scripts/parity_test.py
```

The final command runs a read-only subset against both implementations and compares exit codes.
