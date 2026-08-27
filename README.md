# htz, the native Hypertask CLI

`htz` implements the current Hypertask command catalog in Zig. It uses the same API routes and `~/.hypertask/config.json` as the Node CLI, while avoiding a Node startup for every command.

Ticket: https://app.hypertask.ai/detail/project-15/5726

## Command coverage

The embedded catalog contains **132 leaf commands** — full parity with `@hypertask/hypertask_cli` v1.13.25.

```bash
htz capabilities --json
```

JSON is the default output. Pass `--human` for the minimal human-readable mode.

## Authentication

```bash
htz login --token '<jwt>'
htz status
htz logout
```

Browser login is not available in the native CLI. Obtain a JWT through the Hypertask web app, then pass it to `login --token`.

Token lookup supports `--token`, `HT_TOKEN`, `HYPERTASKS_JWT_TOKEN`, and `~/.hypertask/config.json`. API URL lookup supports `--api-url`, `HYPERTASKS_API_URL`, and the saved config.

## Build and install

```bash
zig build -Doptimize=ReleaseFast
install -m 755 zig-out/bin/htz ~/.local/bin/htz
```

## Agent usage

Use `htz` directly instead of the Node `hypertask` binary for board operations:

```bash
htz tasks get HTPR-5726 --project 15
htz tasks move HTPR-5726 --section "In Progress"
htz comment add HTPR-5726 --text "<p>...</p>"
htz search "query" --project 15
```

Browser login still requires the Node CLI once (`hypertask login`); after that `htz` reads the same token file.

## Verification

```bash
zig build test
python3 scripts/parity_test.py --capabilities-only
python3 scripts/parity_test.py --architecture-only
python3 scripts/parity_test.py
```

The final command runs a read-only subset against both CLIs and compares exit codes.
