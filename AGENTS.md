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

The fleet destination is `~/.local/bin/hypertask`. Install also replaces whichever `hypertask` wins `PATH` when that is a different file, and it replaces `~/.npm-global/bin/hypertask` when that file exists even if this job's PATH is empty. Agent wrappers run `hypertask` from a login PATH, and npm-global often sits first. Destination symlinks are kept; the target is replaced. GATES G5 is `cmp` against the destination, `command -v hypertask` when it exists, and the npm-global wrapper when it exists.

The `Install fleet CLI` workflow runs ReleaseFast tests, installer tests, and the build on GitHub-hosted `ubuntu-latest`. The self-hosted fleet runner only downloads the binary and existing installer from that run's artifact, authenticates `SHA256SUMS` against the build job output and verifies both files with `sha256sum --check --strict`, installs atomically, and checks the installed version against the build job output. It never runs Zig, builds, or tests.

Only the canonical repository's `main` ref can run fleet jobs. The five-minute schedule first reads the recorded installed commit on the fleet runner without checkout or repository code; unchanged commits skip the hosted build and installation. Pushes and manual dispatch on `main` always build.

For a manual recovery install, download the `fleet-cli` artifact from a successful hosted build on `main`, verify `SHA256SUMS` against that build job's `checksums_sha256` output, then run `sha256sum --check --strict SHA256SUMS` from the artifact directory. Both files must pass before running:

```bash
chmod 755 /path/to/fleet-cli/hypertask
bash /path/to/fleet-cli/install-fleet.sh /path/to/fleet-cli/hypertask
```

## Both implementations are live: fix behaviour in both

While the Node implementation still exists, a change to how a command behaves belongs in both implementations. The Node source is `~/projects/hypertask-mcp`, code under `CLI/cli_anything/hypertask/`, tests via `npx vitest run cli_anything/hypertask/tests/`.

Say in your PR which implementation you covered. A fix in one implementation only is half a fix, and the gap stays invisible until someone hits it. Real example: https://app.hypertask.ai/detail/project-15/5661 was fixed in Node, and https://app.hypertask.ai/detail/project-15/5746 exists purely because the same bug is still live here.

## Known gap

The native CLI prints raw JSON for every command. The Node implementation prints readable tables. That is the one thing stopping a human from switching, and it is phase 2 of the retirement plan.
