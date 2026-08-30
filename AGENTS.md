# Agent guide: the native Hypertask CLI

`hypertask` is the Zig implementation of the Hypertask CLI. It is meant to replace the Node implementation (`@hypertask/hypertask_cli`, source in `valentinyeo/hypertask-mcp`). Retirement plan: https://app.hypertask.ai/detail/project-15/5747

Any agent can work in this repo. There are no specialist agents.

## Build, test, run

```bash
zig build              # builds; requires zig 0.15.2, already on PATH
zig build test         # unit tests
./zig-out/bin/hypertask status
./zig-out/bin/hypertask capabilities --json    # full command catalogue
```

`hypertask` talks to the same `/api/mcp/*` routes and reads the same token file as the Node implementation.

## Shipping a change

Branch off `main`, push, open a PR with base `main`, and enable auto-merge (`gh pr merge --auto --squash`). Auto-merge is on for this repo. There is no branch protection, so a green PR merges itself.

The installed binary at `~/.local/bin/hypertask` is what the fleet actually runs. After a merge, rebuild and install it, or the fix ships to nobody:

```bash
zig build && cp zig-out/bin/hypertask ~/.local/bin/hypertask
```

## Both implementations are live: fix behaviour in both

While the Node implementation still exists, a change to how a command behaves belongs in both implementations. The Node source is `~/projects/hypertask-mcp`, code under `CLI/cli_anything/hypertask/`, tests via `npx vitest run cli_anything/hypertask/tests/`.

Say in your PR which implementation you covered. A fix in one implementation only is half a fix, and the gap stays invisible until someone hits it. Real example: https://app.hypertask.ai/detail/project-15/5661 was fixed in Node, and https://app.hypertask.ai/detail/project-15/5746 exists purely because the same bug is still live here.

## Known gap

The native CLI prints raw JSON for every command. The Node implementation prints readable tables. That is the one thing stopping a human from switching, and it is phase 2 of the retirement plan.
