# htz — native Hypertask CLI (Zig)

Drop-in fast path for agent-heavy Hypertask CLI usage.
Ticket: https://app.hypertask.ai/detail/project-15/5726

## Why

Every Node `hypertask` invocation boots V8 (~0.7–1.0s CPU, ~100MB RSS).
With several agents polling, that burns real VPS cores. `htz` is a ~7MB
statically linked Zig binary using `std.http` against the same `/api/mcp/*`
endpoints and the same `~/.hypertask/config.json` token file.

### Measured on Contabo (2026-08-26)

| workload | wall | user CPU | peak RSS |
|---|---:|---:|---:|
| `htz --help` | 0.000s | 0.000s | 0.3 MB |
| `hypertask --help` (Node) | 0.91s | 0.81s | 102 MB |
| `htz tasks get` | 0.27s | 0.006s | 1.3 MB |
| `hypertask tasks get` (Node) | 1.10s | 0.96s | 108 MB |
| 5× parallel `htz get` | 0.35s | 0.04s | 4 MB |
| 5× parallel Node get | 2.0s | **5.9s** | 116 MB |

## Install (this VPS)

```bash
cd ~/projects/hypertask-cli-zig
zig build -Doptimize=ReleaseFast
cp -f zig-out/bin/htz ~/.local/bin/htz

# Route hot `hypertask` subcommands through htz; fall back to Node for the rest
ln -sfn ~/.npm-global/lib/node_modules/@hypertask/hypertask_cli/dist/hypertask_cli.js \
  ~/.npm-global/bin/hypertask-node
install -m 755 scripts/hypertask-shim ~/.npm-global/bin/hypertask
```

After install, `hypertask tasks get …` / `comment …` / `status` hit `htz`
automatically (≈0 user CPU). Unsupported commands still use Node.

## Commands (MVP)

```bash
htz status
htz tasks get HTPR-5726 --project 15
htz tasks list --project 15
htz tasks create --project 15 --title "..." --section Triage
htz tasks move HTPR-5726 --section "In Progress"
htz tasks update HTPR-5726 --assignee 6
htz comment list HTPR-5726 --project 15
htz comment add HTPR-5726 --text "<p>hi</p>" --project 15
htz project list
htz section list --project 15
htz raw GET '/mcp/tasks?ticket_number=HTPR-5726&project_id=15'
```

Auth overrides: `--token`, `HT_TOKEN`, `HYPERTASKS_JWT_TOKEN`.

## Not yet (falls through to Node via shim)

Login, pages, attachments, agents, webhooks, inbox, AI write, pretty tables.

## Next

- Grow command parity for remaining agent workflows
- Optional musl/libcurl static build if needed
- GitHub release binaries
