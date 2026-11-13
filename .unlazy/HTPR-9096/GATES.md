# Gates: HTPR-9096 unknown-command reply stops claiming the program is missing

OWNS: src/output.zig, src/command_tests.zig, src/version.zig, README.md, .unlazy/HTPR-9096/**

Scope: `hypertask task comments <ticket>` replies with the unknown word, the real commands and where a ticket's comments are read, and no longer prints `hypertask: command not found`. Released as native CLI 0.2.68 and proven on the installed fleet binary.

- [ ] G1: The ticket exists on board 15 and is assigned to Runner 8 in In Progress
  CHECK: vcc task get HTPR-9096 --json
  EXPECT: "ticketNumber":"HTPR-9096"
  EVIDENCE: pending

- [ ] G2: The misleading line is gone from source and a regression test covers the reply
  CHECK: bash -c '! grep -q "\"command not found\"" src/output.zig && grep -q "does not exist" src/output.zig'
  EXPECT: (exit 0)
  EVIDENCE: pending

- [ ] G3: A Zig test drives `task comments` through the router and asserts the reply names the command, the real commands and the comment path, without a missing-program line
  CHECK: grep -q "unknown command reply never claims the program is missing" src/command_tests.zig
  EXPECT: (exit 0)
  EVIDENCE: pending

- [ ] G4: CI test job green on the pushed head (Zig tests and failure-output contract run there)
  CHECK: ~/.local/lib/hypertask/runner-pickup/ci-wait --repo hypertask-ai/cli
  EXPECT: all checks passed
  EVIDENCE: pending

- [ ] G5: The PR is merged into main
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT=/home/valentin/projects/hypertask-cli-zig ~/.agents/skills/ship/scripts/ship-check merged
  EXPECT: merged ok
  EVIDENCE: pending

- [ ] G6: The latest CLI release contains the merge commit
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT=/home/valentin/projects/hypertask-cli-zig ~/.agents/skills/ship/scripts/ship-check deployed
  EXPECT: deployed ok
  EVIDENCE: pending

- [ ] G7: The installed fleet binary carries the release and answers the repro with the new text and no missing-program line
  CHECK: bash -c 'hypertask --version | grep -q "0.2.68" && h=$(hypertask task comments HTPR-9096 2>&1) && echo "$h" | grep -q "unknown command: comments" && echo "$h" | grep -q "a ticket.s comments are read with: hypertask comment list" && echo "$h" | grep -q "that command does not exist" && ! echo "$h" | grep -q "command not found" && echo "reply ok"'
  EXPECT: reply ok
  EVIDENCE: pending

- [ ] G8: The ticket is in its done column with the outcome and the release link
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT=/home/valentin/projects/hypertask-cli-zig ~/.agents/skills/ship/scripts/ship-check done HTPR-9096
  EXPECT: done ok
  EVIDENCE: pending

- [ ] G9: This session's worktree and branch for the ticket are removed
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT=/home/valentin/projects/hypertask-cli-zig ~/.agents/skills/ship/scripts/ship-check cleaned HTPR-9096
  EXPECT: cleaned ok
  EVIDENCE: pending
