# hypertask, the native Hypertask CLI

`hypertask` implements the current Hypertask command catalog in Zig. It uses the same API routes and `~/.hypertask/config.json` as the Node implementation, while avoiding a Node startup for every command.

Ticket: https://app.hypertask.ai/detail/project-15/5726

## Command coverage

The embedded catalog contains **138 leaf commands**.

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

Browser login is not available in the native CLI. Obtain a JWT through the Hypertask web app, then pass it to `login --token`. Saved user tokens refresh automatically during their final seven days, including legacy tokens issued before refresh support.

Token lookup supports `--token`, `HT_TOKEN`, `HYPERTASKS_JWT_TOKEN`, and `~/.hypertask/config.json`. API URL lookup supports `--api-url`, `HYPERTASKS_API_URL`, and the saved config.

Do not give users or agents the JWT signing secret. An operator-issued emergency token must have a unique `jti`, a bounded `exp`, the configured issuer in `iss`, and the `mcp-api` audience in `aud`.

## Polling addressed messages

`messages poll` reads the inbox stream for the authenticated identity. Agent tokens return only that agent's notifications. Save `next_cursor` and pass it back with `--since` to receive only newer notifications.

```bash
hypertask messages poll
hypertask messages poll --since 123
```

## Reacting to comments

Add or remove your own emoji reaction without posting another comment:

```bash
hypertask comment react 216402 --emoji '✅'
hypertask comment unreact 216402 --emoji '✅'
```

Both commands call `POST /api/mcp/comments/{comment_id}/reactions` with `{"emoji":"✅","active":true|false}`. The server derives the reacting user from the bearer token and checks access to the comment's board.

## Correcting time entries

Use a negative log to subtract minutes from your latest completed whole-minute entry for a task. An exact subtraction deletes that entry; ambiguous partial-minute and oversized corrections are rejected.

```bash
hypertask time log RINT-32 -30
hypertask time update 119 --minutes 25 --note "Corrected"
hypertask time delete 119
```

Entry IDs are available from `hypertask time report`. `time edit` is an alias for `time update`.

## Install

Linux and macOS customers can install the latest checksum-verified release:

```bash
curl -fsSL https://raw.githubusercontent.com/hypertask-ai/cli/main/scripts/install.sh | sh
hypertask --version
```

Windows x64 binaries are available from [GitHub Releases](https://github.com/hypertask-ai/cli/releases). The npm v2 installer source is under `npm/`; publishing it is a separate owner-approved release step.

## Build from source

```bash
zig build -Doptimize=ReleaseFast
./scripts/install-fleet.sh zig-out/bin/hypertask
```

Merges to `main` install the same ReleaseFast binary automatically on the trusted fleet runner. Tags matching `v*` test all installers, cross-compile five customer binaries, and publish a GitHub release with SHA-256 checksums.

## Agent usage

Use `hypertask` for board operations:

```bash
hypertask tasks get HTPR-5726
hypertask tasks get 5726 --project 15
hypertask tasks move HTPR-5726 --section "In Progress"
hypertask comment add HTPR-5726 --text "<p>...</p>"
hypertask agents update --id <agent-id> --add-project 339
hypertask agents archive --id <agent-id>
hypertask agents delete --id <agent-id> --confirm
hypertask search "query" --project 15
```

Task identifiers come in three forms. `HTPR-5726` is the full ticket number and works
anywhere. A bare `5726` is the ticket number inside one board, so it needs `--project 15`;
without a project it is refused, because ticket numbers repeat across boards and internal
task ids share the same range. `id:37799` is the internal task id printed as `id` in JSON
output.

## Managed agent identity commands

The native CLI replaces the former `ht-agent` shell wrapper for agent-authored comments, assignment, lifecycle moves, handoffs, and durable polling:

```bash
export HT_AGENT_TOKEN='<managed-agent-token>'
export HT_AGENT_SLUG='dev-3'
export HT_AGENT_ID='<managed-agent-id>'
export HT_AGENT_NAME='Dev 3 (HT)'
export HT_AGENT_PROJECT_ID=15
export HT_AGENT_STATE_DIR="$HOME/.local/state/hypertask-dev-3/agent-cli"

hypertask agent say HTPR-5778 '<p>Working on it.</p>'
hypertask agent take HTPR-5778
hypertask agent move HTPR-5778 'In Progress'
hypertask agent poll
hypertask agent new-tickets --label Bug
```

`--token`, `HT_TOKEN`, and `HYPERTASKS_JWT_TOKEN` are also accepted. Ticket capability environment variables are checked before any request. Without `HT_AGENT_STATE_DIR`, durable state is isolated by API endpoint, project, and agent identity. On first use, seen, ticket, and watermark files migrate from `~/.config/hypertask-agents/<slug>.*` when present.

## Pull request checks

Every pull request to `main` runs ReleaseFast unit tests, installer tests, capability and architecture checks, and live read-only parity. The repository's auto-merge evaluator merges eligible same-repository changes only after the current `test` check passes.

## Verification

```bash
zig build test
python3 -m unittest scripts/parity_test_test.py
python3 scripts/parity_test.py --capabilities-only
python3 scripts/parity_test.py --architecture-only
python3 scripts/parity_test.py
```

`zig build test` runs unit tests plus golden-file HTTP tests against a local stub server. It does not need a token or contact the live API. The final command compares read-only JSON schemas, authentication sources, human output, and error behavior across both implementations.

Write parity is opt-in. It creates one clearly named throwaway task per implementation on board 15, comments, moves, assigns, renames, and archives each task. Cleanup retries the archive if an earlier command fails.

```bash
python3 scripts/parity_test.py --write --token "$HYPERTASKS_JWT_TOKEN"
```
