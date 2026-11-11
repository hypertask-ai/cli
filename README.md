# hypertask, the native Hypertask CLI

`hypertask` implements the current Hypertask command catalog in Zig. It uses the same API routes and `~/.hypertask/config.json` as the Node implementation, while avoiding a Node startup for every command.

Ticket: https://app.hypertask.ai/detail/project-15/5726

## Command coverage

The embedded catalog contains **138 leaf commands**.

```bash
hypertask capabilities --json
```

JSON is the default output. Pass `--human` for the minimal human-readable mode.

`hypertask create-board` is a shorthand for `hypertask project create-board` and accepts the same flags, manifest input, and help.

`hypertask activity` is the same command as `hypertask comment`: `hypertask activity add HTPR-1 --text "note"` writes that ticket's agent log (no `--kind`, nobody is notified), and `hypertask task agent-log HTPR-1` reads it back.

`hypertask label` is the same command as `hypertask labels`, like every other root that accepts both forms, so `hypertask label list --project 15` prints JSON instead of an unknown-command list.

`hypertask ticket` is the same command as `hypertask task`, so `hypertask ticket get HTPR-1` reads a ticket instead of answering `unknown command: ticket` with the whole command list.

`hypertask task view` is an alias for `hypertask task get`, next to `task show`. A wrong command is answered as a command: `hypertask task lst HTPR-1 --project 15` prints `unknown command: lst`, the commands that do exist, and `did you mean: list`, instead of blaming the flag that followed it.

A guess from the wrong command says where the work lives: `hypertask task comments 44` prints `unknown command: comments`, the commands that do exist, and `a ticket's comments are read with: hypertask comment list <ticket>`.

Help names where a topic's help lives. `hypertask help task`, `hypertask --help task` and `hypertask task --help` all print that command's page, `hypertask help features` keeps its own command, and any other topic with no command path names `hypertask capabilities --json`, instead of replying `unknown command`. `hypertask help` with no topic prints the top-level page, which ends with the list of commands.

## Failure contract

A command exits `0` only when it did what its arguments requested. Every failure except a helper write refusal prints what happened and one `Next:` action. Invalid finite values also list the accepted values.

Exit codes are stable:

- `1`: unknown command or local runtime failure
- `2`: missing or invalid command input
- `3`: helpers are refused board writes; report changes to your runner instead
- `4`: server rejection, permission failure, or missing server-side item

Scripts may use the exit code category, while people and agents should follow the `Next:` line.

## Release notes: native 0.2.63

- `hypertask search --query "free text"` now runs the search that the help always listed. The positional form, `hypertask search "free text"`, still works, and the help shows the query as optional (HTPR-8869).

## Release notes: native 0.2.62

- `task link --type` help now lists the three relation types, `RelatedTo` (the default), `BlockedBy` and `BlockedTo`, so an agent stops guessing a value that the server rejects (HTPR-8779).

## Release notes: native 0.2.61

- `project github 15` accepts the board as a positional argument again; 0.2.60 refused it with "unexpected argument: 15" (HTPR-8951).

## Release notes: native 0.2.60

- `project github <board>` lists the GitHub repositories connected to a board, and `project github <board> set --repository-ids 123,456` replaces them. The current settings version is read first, so one command is enough. Board admins only (HTPR-8951).

## Release notes: native 0.2.59

- A pool runner started by `fleet/runner` as `hax` in print mode, with or without `timeout` in between, may write to the board. A `hax` print-mode process that runner starts, and any `hax` print-mode process outside `fleet/runner`, still cannot (HYCI-210).

## Release notes: native 0.2.58

- `task update --assignee` accepts an agent display name such as `"Runner 4"` and resolves it on the ticket's board, instead of failing with `invalid integer` (HTPR-8776).

## Release notes: native 0.2.57

- `comment add` accepts comment HTML as an optional positional after the ticket, matching `--text` / `--body` (HTPR-8764).

## Release notes: native 0.2.52

- `task assign` and `task unassign` take `--agent <name|id>`, so an agent assigns itself by the name it knows: `hypertask task assign HTPR-8538 --agent "Runner 3"` resolves that display name on the ticket's own board and sends its agent id. `me` is the calling agent, the same request as `--self`. An unknown, duplicated or person name is refused before anything is written (HTPR-8538).

## Release notes: native 0.2.51

- `--ticket` is the same flag as `--task` on `task get`, `comment list` and `comment add`, so an agent that names a ticket with `--ticket HTPR-1` reaches it instead of `unknown option: --ticket`. `--task` works unchanged, the positional still wins, and the missing-argument line names both (HTPR-8539).

## Release notes: native 0.2.50

- `task get` accepts `--fields <names>`, the same projection `task list` takes: `hypertask task get HTPR-8535 --fields title,section` answers only those two keys instead of the whole ticket with its description and comments. A read with no `--fields` is unchanged (HTPR-8535).

## Release notes: native 0.2.49

- A write refuses a bare number with no `--project` instead of writing to another board's ticket: `activity add 1172` and `comment add 1172` answer `nothing was written: 1172 is task id 1172: HTPR-481 on Hypertask` and ask for the ticket number or `id:1172`, so a note lands on the ticket you named or nowhere. Reads still name the ticket and continue. `--project`, ticket keys and `id:<n>` write as before (HTPR-8537).

## Release notes: native 0.2.48

- `task list` accepts `--assignee`, the name every other task command already uses for the same filter, so an agent that guesses `--assignee 6` gets that person's tasks instead of `unknown option`. `--assigned-to` works unchanged (HTPR-8518).

## Release notes: native 0.2.47

- `task get` and `comment add` take the ticket as `--task <id-or-ticket>`, as `comment list` already did, so one ticket has one name on all three commands. The positional still wins when both are given (HTPR-8509).

## Release notes: native 0.2.46

- A stray value after a type flag is refused with the options that would have taken it, so `hypertask pages append 265 --markdown "$(cat file.md)"` answers `options that take a value: --content <content>, --markdown-file <path>, ...` instead of only `accepted arguments: id` (HTPR-8401).

## Release notes: native 0.2.45

- `hypertask ticket` is the same command as `hypertask task`, so `hypertask ticket get HTPR-1`, `hypertask ticket list --project 15` and `hypertask help ticket get` work the way an agent that says "ticket" expects instead of answering `unknown command: ticket` with the whole command list (HTPR-8503).
- `hypertask help <command path>` prints that command's own page, the same page as `<command path> --help`, so a help request no longer answers `unknown command: feedback` with `valid commands: features`. `hypertask help` with no topic prints the top-level page, which now ends with the list of commands (HTPR-8495).

## Release notes: native 0.2.43

- `task move` takes the destination section as its second argument, so `hypertask task move HTPR-8388 "Flag: Everyone"` works like `agent move` instead of refusing the section and listing no working form (HTPR-8388).

## Release notes: native 0.2.40

- `hypertask feedback list` no longer files a junk ticket: a listing word (`list`, `ls`, `show`, `get`, `status`) is refused before the request, and the error names `hypertask task list --project 15 --label ai-feedback` as the way to read filed feedback (HTPR-8432).

- `task get 8288` names the flags that reach the ticket when a bare number is no task id, instead of only `Task not found or access denied`, so a ticket number no longer needs `--project` guessed (HTPR-8288).
- Every `task` subcommand that takes a ticket now accepts `--project <id>`, so `relations`, `related`, `description-history`, `description-restore`, `link`, `unlink`, `assign` and `move-to-inbox` read the ticket a board index names instead of refusing the flag (HTPR-8409).

## Release notes: native 0.2.39

- `comment list` names the ticket and board a bare number read landed on, and `comment add` names it before the write, so `--task 908` no longer reads or writes another board's ticket in silence (HTPR-8483).

## Release notes: native 0.2.38

- `hypertask --help features` reaches its topic instead of `unknown command: features`, and any other topic with no command path names `hypertask capabilities --json` (HTPR-8434).

## Release notes: native 0.2.37

- `pages create` takes `--project <id>`, so an agent that types the flag from `task` and `pages list` gets the ticket on the board it named instead of `unknown option --project` (HTPR-8474).

## Release notes: native 0.2.37

- `hypertask --help features` now reaches its topic instead of `unknown command: features`. 0.2.36 answered a help topic only after the command path was accepted, so a topic that is not a command never got that far (HTPR-8434).

## Release notes: native 0.2.36

- Asking for help on a topic no longer says the command is missing: `hypertask --help features` answers `live product features: hypertask help features`, and any other topic with no command path names `hypertask capabilities --json` (HTPR-8434).
- A board read answers with the word for a column and names `hypertask section list`, instead of `unknown command: board` (HTPR-8462).

## Release notes: native 0.2.35

- `hypertask task comments 44` now answers with where a ticket's comments are read (`hypertask comment list <ticket>`) next to `unknown command: comments`, instead of leaving an agent to guess which root owns comments (HTPR-8433).

## Release notes: native 0.2.34

- `comment list` takes the ticket as `--task <id-or-ticket>` as well as the positional, so the flag agents already type on `pages` and `task update` works here too; the positional wins when both are given, and the missing-identifier error now names both forms (HTPR-8438).

## Release notes: native 0.2.33

- `hypertask label` is the same command as `hypertask labels`, so `hypertask label list --project 15 --json` prints JSON instead of an unknown-command list (HTPR-8351).
- `task get` reads the tasks array, so a bare number names the ticket it landed on (HTPR-8423).

## Release notes: native 0.2.32

- This release also carries the 0.2.31 change: `task get` names the ticket and board a bare number landed on (HTPR-8423).

## Release notes: native 0.2.31

- `task get` names the ticket and board a bare number landed on, so a number read on another board is visible instead of silent (HTPR-8423).

## Release notes: native 0.2.30

- A wrong command is answered as a command: `task lst HTPR-1 --project 15` says `unknown command: lst` with the real commands and `did you mean: list`, instead of blaming the flag that followed it. `task view` is an alias of `task get`, next to `task show` (HTPR-8379).
- `task waiting-on <ticket> --user none` and `task blocker-comment <ticket> --comment-id none` take `--reason <text>` and send it, so an agent can clear a blocker the way the server asks: with a reason of 500 characters or fewer. The flag is refused on the paths that do not clear a blocker (HTPR-8424).

## Release notes: native 0.2.29

- A bare number with no `--project` is still the internal task id, and the command now names the ticket and board it landed on, so a number read on another board is visible instead of silent (HTPR-8423).


## Release notes: native 0.2.28

- `pages create`, `pages update` and `pages append` read page content from a file with `--content-file <path>` or `--html-file <path>`, so an HTML report bigger than one command-line string can be published. `--html-file` marks the page content type `html` (HTPR-8311).

## Release notes: native 0.2.27

- `task agent-log` and `task move` accept `--project <board id>`, so a bare number reads or moves the ticket on the board you name instead of another board's task with that ID (HTPR-8336).
- New `chat listen` and `chat reply`, so an agent can attach to in-app chat (HTPR-7742).
- An unknown command now names the closest real command (HTPR-8206).
- Clearing the waiting person clears the comment marker.
- Mark or clear blocking comments with `task blocker-comment`.
- Fleet updates follow the GitHub release. npm stays unchanged.

## Release notes: native 0.2.26 / npm 2.0.13

- New `task waiting-on <ticket> --user <id|agent|me|none>` sets or clears who a ticket is blocked by, with the same checks as the app's Blocked by person (HTPR-7723). An agent id waits on that agent (HTPR-8917).
- npm `@hypertask/hypertask_cli@2.0.13` installs native `0.2.26`. Release the `v0.2.26` binaries before the separate owner-approved npm publish. GitHub release notes are generated from commits; this repository has no separate changelog.

## Reading comments and activity

```bash
hypertask --json comment list HTPR-7546 --include-activity --limit 5
hypertask --json comment list --task HTPR-7546 --project 15
```

Activity is opt-in; omit `--include-activity` to read comments only. The ticket is either the positional argument or `--task`; the positional wins when both are given. Unrecognized options are rejected before authentication or HTTP requests.

## Reading a ticket's agent log

```bash
hypertask tasks agent-log HTPR-7620
hypertask task agent-log 35007 --limit 100 --agent 11111111-1111-4111-8111-111111111111
hypertask task agent-log 1529 --project 2060
hypertask tasks agent-log HTPR-7620 --human
```

Reads `GET /api/mcp/tasks/{ticket-or-task-id}/agent-activity` without changing the ticket. Numeric identifiers are task IDs, not board indexes. Add `--project <board id>` to read a number as that board's index; the CLI resolves it there and reads the task it names. `task move` takes the same `--project`, so a bare board number moves the ticket on its own board instead of wherever that task ID lives. Returns `activities` newest first, including `agentName`, `type`, `text`, and `createdAt`. JSON is the default; `--human` uses the standard readable format. `--limit` defaults to 20 and must be an integer from 1 to 100; `--agent` filters by agent UUID (`agent_id`).

## Authentication

```bash
hypertask login --code ABCD-2345
hypertask login --token '<jwt>'
hypertask status
hypertask logout
```

`hypertask login --code` signs an agent in with the five-minute code from https://app.hypertask.ai/login/agent. You approve that code in the browser before the agent receives its new board. A copied token still works: obtain a JWT in the Hypertask web app, then pass it to `login --token`. Saved user tokens refresh automatically during their final seven days, including legacy tokens issued before refresh support.

After saving the token, login shows your identity, starting board, and the server's suggested commands to try next (three commands on older servers). Use `hypertask login --token '<jwt>' --human` for a readable guide (JSON is the default). The optional guide waits at most about 1.5 seconds; if the server is unavailable, the token is still saved and login succeeds.

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

Positive `time log` requests accept `--note <text>`, `--date <YYYY-MM-DD>` and
`--timezone-offset-minutes <n>` (the same local-date offset convention as
`time update`). Negative corrections do not accept these metadata flags.
Unknown time-command flags are rejected.

`time update` accepts any combination of `--minutes`, `--date` and `--note`;
at least one is required. Omitted fields are not sent, and `--note ""` clears
the note. A timezone offset alone is not a change.

```bash
hypertask --json time log RINT-86 30 --date 2026-09-30 --note "x"
hypertask time update 119 --note "Corrected"
hypertask time update 119 --date 2026-09-30 --timezone-offset-minutes -60
```

**Server compatibility:** the current MCP server's `/api/mcp/time/log` route
only reads task and minutes, ignoring note/date/timezone fields. Its
`/api/mcp/time/update` route accepts note/date/timezone fields but still requires
minutes (1–1440). The CLI sends the fields above, but creation metadata and
updates without minutes require server changes before they work end to end.
The server interprets dates at local noon and trims notes to 500 characters
(empty notes become null).

## Updating pages

`pages update` and `pages append` keep the existing page content type unless
`--canvas` (HTML canvas), `--html`, or `--markdown` is passed. The CLI omits
`content_type` when no type flag is given; `pages create` still defaults to Markdown.
`--markdown-file` reads content unchanged and does not select a content type.

```bash
hypertask pages update 265 --markdown-file report.html
hypertask pages update 265 --markdown-file report.html --canvas
hypertask pages update 265 --content "# Report" --markdown
```

This relies on the server preserving the existing type when `content_type` is
omitted. Servers that default omitted types to Markdown need a matching fix;
until then, pass `--canvas` explicitly when updating an HTML canvas page.

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

To move fleet install to a pull timer, run `bash scripts/fleet-pull-install.sh` as the VPS user (preview with `--dry-run`). It installs local copies of the pull script and existing installer, then enables `hypertask-fleet-pull.timer`: first check two minutes after boot, then every 15 minutes. The timer pulls the latest published release, checks its SHA-256 checksum and exact version, and records `installed-tag` and `installed-sha256` in `~/.local/state/hypertask-cli/`. Matching state and binary skip asset downloads. Failed updates preserve the installed copies. Updates follow releases, not merges to `main`.

The timer needs Bash, curl, jq, GNU coreutils, flock, and a running systemd user manager. Inspect it with `systemctl --user status hypertask-fleet-pull.timer` and `journalctl --user -u hypertask-fleet-pull.service`. The checksum is supplied by the same GitHub release as the binary. GitHub-hosted CI retains the ReleaseFast baseline x86_64 build check and runs the isolated fleet installer and pull tests.

Tags matching `v*` test all installers, cross-compile five customer binaries, and publish a GitHub release with SHA-256 checksums.

## Agent usage

Use `hypertask` for board operations:

```bash
hypertask tasks get HTPR-5726
hypertask tasks get 5726 --project 15
hypertask tasks move HTPR-5726 --section "In Progress"
hypertask tasks move HTPR-5726 "In Progress"
hypertask task waiting-on HTPR-7723 --user me
hypertask task blocker-comment HTPR-7723 --comment-id 101
hypertask task waiting-on HTPR-7723 --user none --reason "Answered on the ticket"
hypertask comment add HTPR-5726 --text "<p>...</p>"

Bare comment text may also follow the ticket: `hypertask comment add HTPR-5726 "<p>...</p>"` (same as `--text` / `--body`).
hypertask agents update --id <agent-id> --name "Ops Script"
hypertask agents update --id <agent-id> --add-project 339
hypertask agents archive --id <agent-id>
hypertask agents delete --id <agent-id> --confirm
hypertask projects update <project-id> --title "New board title"
hypertask projects archive <project-id>
hypertask projects delete <project-id> --yes
hypertask search "query" --project 15
```

`task waiting-on <ticket> --user <id|agent|me|none>` sets the person or agent a ticket is blocked by. `me` uses the current user (not the agent); an agent id waits on that agent; `none` clears both the person and blocking comment. `tasks` is also accepted. Use `--project <id>` with a bare ticket number, or a numeric internal task ID without `--project`. `--json` and `--human` use the standard write-command output.

`task blocker-comment <ticket> --comment-id <id|none>` marks the blocking question. A new comment ID replaces the previous marker. `--comment-id none` removes only the comment marker, and `--reason <text>` says why. Neither operation changes the waiting person. Comments must belong to the same ticket. The server still enforces access and feature availability.

Runners: after handling an answer, run `vcc task waiting-on <ticket> --user none --reason "<why>"`. This clears both the name and red border. An agent must give a reason the server accepts (500 characters or fewer); a person clearing from the app does not need one. To mark the question, use `vcc task blocker-comment <ticket> --comment-id <comment-id>`. Clearing only the red border is `vcc task blocker-comment <ticket> --comment-id none --reason "<why>"`.

`comment add --kind question|qa|done` posts a question, QA result, or completion comment for people. Without `--kind`, no kind is sent; the server may save agent chatter to the agent log without notifying anyone. The CLI explains log routing, or returns the unchanged response with `--json`. `--attach` marks the create request with `has_attachments: true` so supporting servers keep it as a comment. If an older server still routes it to the log, requested attachments are not uploaded; use `--kind` to attach them to a comment.

`projects update` renames a board you can edit. `projects archive` is reversible with `--restore`. `projects delete` permanently deletes the board, its tasks, notifications, and memberships, so it refuses to run without `--yes`.

Board reads take the board as `--project <id>`, the same as the task commands, or as the positional id: `project manifest`, `project members`, `project sections`, `project labels`, `project playbook`, and `project instructions` all accept both. Naming a different board twice is an error, and naming none is an error.


Task identifiers come in four forms:

- `HTPR-5726` is the full ticket number and works anywhere.
- A bare `37799` is the internal task `id` from `tasks list` / JSON (`id: 37799`).
  The command names the ticket and board it landed on, so a number read on another
  board is visible instead of silent.
  With `--project`, the CLI also tries that number as the board index (`uniqueIndex`)
  and refuses to guess when both forms point at different tasks.
- `https://app.hypertask.ai/detail/project-15/5726` is a ticket link copied from the
  app. The board and the ticket number are read from the link, so a link pasted into
  any command that takes a ticket works like `5726 --project 15`. A `--project` that
  names a different board is an error.
- `id:37799` forces the internal task id.

Board-wide unassign:

```bash
hypertask tasks unassign --project 15 --assignee 6 --all
```

`--labels` replaces the ticket's whole label set. Repeatable means you can pass the
flag more than once in that one call, not that it appends to labels already on
the ticket. Use `--add-label` / `--remove-label` (or `--add-labels` /
`--remove-labels`) to keep the rest:

```bash
hypertask tasks update HTPR-5726 --labels CLI,BUG
hypertask tasks update HTPR-5726 --add-label QA
hypertask tasks update HTPR-5726 --remove-label BUG
hypertask tasks update HTPR-5726 --labels ""
hypertask tasks update HTPR-5726 --clear-labels
```

`--labels ""` and `--clear-labels` remove every label. Do not combine clearing
with nonempty `--labels`, `--add-label(s)`, or `--remove-label(s)`.

That snapshots Normal, Archive, and Deleted tasks assigned to that person, then
unassigns each one. The command exits nonzero if any task fails.

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

hypertask agents webhook get --agent <agent-id>
hypertask agents webhook configure --agent <agent-id> --url https://agent.example/webhook --event chat.message --event comment.mention
hypertask agents webhook rotate-secret --agent <agent-id>
```

`--token`, `HT_TOKEN`, and `HYPERTASKS_JWT_TOKEN` are also accepted. Ticket capability environment variables are checked before any request. Without `HT_AGENT_STATE_DIR`, durable state is isolated by API endpoint, project, and agent identity. On first use, seen, ticket, and watermark files migrate from `~/.config/hypertask-agents/<slug>.*` when present.

## Local agent development loop

Run an agent handler on this machine, receive real webhooks, and re-send a run you already recorded. Both commands need the `htpr-6124-agent-dev-loop` flag switched on for the account that owns the agent.

```bash
export WEBHOOK_SECRET='<the secret hypertask webhook configure printed>'

# Borrow the agent's webhook for one session. Ctrl-C puts the old URL back.
hypertask agent dev --agent <agent-id> --port 3000

# Re-send one recorded run to the handler, signed the way the server signs.
hypertask agent replay <run-id> --url http://localhost:3000/
```

`agent dev` starts a `cloudflared` quick tunnel, or reuses your own public tunnel with `--tunnel-url https://...`. It saves the agent's previous webhook URL before changing anything and restores it on Ctrl-C, when the tunnel exits, or on the next `agent dev` after a crash. It restores only while the live URL is still the one it installed, so a change made elsewhere in the meantime is never overwritten.

The tunnel exposes the whole port, not just `--path`. Serve only the agent handler on it, never a general development server.

The webhook secret is read from `HYPERTASK_WEBHOOK_SECRET` or `WEBHOOK_SECRET` and never from an argument, because argv is readable by any process and lands in shell history. `agent replay` reads the agent's last 25 recorded deliveries; if a run reaches that edge it says so with `"partial": true` instead of pretending a suffix is the whole run.

Preview mode is an SDK option, not a CLI flag: set `dryRun: true` on `createAgent`, or run the handler with `HYPERTASK_DRY_RUN=1`, and every ticket write is printed and skipped.

## Pull request checks

Every pull request to `main` runs ReleaseFast unit tests, installer tests, capability and architecture checks, and live read-only parity. Live parity authenticates with `HYPERTASK_PARITY_TOKEN`, which must be a non-expiring agent JWT with read access to board 15 (`hypertask agents create --name 'CLI Live Parity' --project 15 --role read`). The repository's auto-merge evaluator merges eligible same-repository changes only after the current `test` check passes.

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for bug reports, ideas, and our contribution policy.

### Blockers

`hypertask blockers` lists blockers waiting on the authenticated user. It is an alias for `hypertask inbox list --waiting-on me`. Use `--user <me|user-id>` to select a user (`--waiting-on` is also accepted), repeat `--project <id>` to filter boards, and use `--state waiting|answered|no-question` to filter by state.

JSON is returned unchanged by default (or with `--json`). Use `--human` for a compact tab-separated table, including when piped. Question and recommendation text is shortened; links remain complete. Use JSON for full text and all fields.

```bash
hypertask blockers --project 15 --project 16 --state waiting --human
hypertask inbox list --waiting-on 42 --json
```

### Recover a revoked login

`hypertask status` verifies the selected token with the server. A revoked or expired
login exits nonzero with `authenticated: false` and the server's reason. If the
server cannot be reached, status says `unverified`, not logged in. Status never
refreshes a token or changes your saved login.

An owner or a management key with write access can renew an **existing** agent:

```sh
hypertask agents rotate-token --id <agent-id> --management-key <owner-management-key>
```

This shows the replacement token once and invalidates the old token. It preserves
the agent's identity and board grants. Never create a second identity to recover
access. On the affected machine, run `hypertask login --token <new-token>`, or
replace the environment/explicit token if that is how the session authenticates.
A revoked token cannot recover itself with `token refresh`.

Owners can also open https://app.hypertask.ai/agents to manage the same agent.
Run `hypertask update` to check the latest published native release and get the
install command. It checks without sending your login to GitHub.

- HTPR-8861 CLI: a revoked login looks fine and gives no next step — native 0.2.54
  verifies status and explains owner recovery.
- HTPR-8756 CLI: `hypertask context <ticket>` was rejected — native 0.2.55
  accepts the ticket and returns that ticket's context.
