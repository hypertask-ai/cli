# Gates: HTPR-6834 comment attachments

OWNS: GATES.md, build.zig, src/attachments.zig, src/commands/comment.zig, scripts/attachment_contract_test.py

Scope: https://app.hypertask.ai/detail/project-15/6834. Work only in `/home/valentin/projects/cli-htpr-6834` on `agent/htpr-6834-multi-attach`. Never modify the main checkout, stash, reset, install globally, or merge. Linux with Zig 0.15.2, Python 3, Node, and GitHub CLI.

- [x] G0: the ledger has valid, explicit acceptance oracles
  CHECK: node /home/valentin/.agents/skills/unlazy/scripts/gate-lint.mjs GATES.md
  EXPECT: LINT OK
  EVIDENCE: automatic-evidence=v1; definition-sha256=69f81179f3934636347ff01de4824d2a1f500f2d29238b9fd688f82f77d1c57b; exit=0; EXPECT=matched; output-sha256=91362f470dd97eceb162d7a7ce58c5a645aa3fb7173b5ec2f6641514cfa53247; output-bytes=791; shell=/bin/sh; cwd=/home/valentin/projects/cli-htpr-6834; path=fd5351737ae0/31 entries

- [x] G1: onboarding, ticket claim, and attachment path inspection are complete
  EVIDENCE: Read unlazy SKILL.md, gate template and format, CLI AGENTS.md, app CLAUDE.md, and board communication contract. App quickstart is absent and hosted wiki requires Cloudflare login. Ticket is already assigned to this vcc agent and In Progress; agent comment 265043 records this session claim. Wrapper fallback exports HT_TOKEN from its own vcc agent credentials; no token printed. Traced args.parse/getAll, common.optionList, comment.run, attachment upload, Context.fetch, and output failure propagation.

- [x] G2: a regression fails before the fix and identifies the root cause
  EVIDENCE: Before implementation, zig build test failed 2 new regressions (128/130 passed): an empty successful attachment response was accepted, and all three flags used one request instead of three. /tmp/htpr-6834-evidence/unit-before.log records the red run. Installed binary also fails the new local contract test on aggregate decoded payload above 3 MiB (/tmp/htpr-6834-evidence/contract-before.log). Repeated flags are retained; original 3765325-byte webm becomes more than 5 MB of base64 JSON. Server constants cap inline data at 3 MiB and transport at 5 MiB; MIME octet-stream is allowed.

- [x] G3: Zig unit regressions and existing tests pass
  CHECK: zig build test && printf 'HTPR6834_UNIT_OK\n'
  EXPECT: HTPR6834_UNIT_OK
  EVIDENCE: automatic-evidence=v1; definition-sha256=2cb00316ad1dc5a140aa5c702220bed36a9d82ee4820004b13399a268d647862; exit=0; EXPECT=matched; output-sha256=ecacaf07f8018ca233d142308bcdb2f193b4a1cb51e2c577db8cc3b25d5163bd; output-bytes=2818; shell=/bin/sh; cwd=/home/valentin/projects/cli-htpr-6834; path=fd5351737ae0/31 entries

- [x] G4: the fixed local binary builds successfully
  CHECK: zig build && test -x zig-out/bin/hypertask && printf 'HTPR6834_BUILD_OK\n'
  EXPECT: HTPR6834_BUILD_OK
  EVIDENCE: automatic-evidence=v1; definition-sha256=0af7c50db33af986073d786c8bd6d4a71b0f8f01e2bcb632a223ac1e125b4c3b; exit=0; EXPECT=matched; output-sha256=ca1dd9906122043611f52903a59edc816c32bdfe8e6b00f60c3327dd65058ef0; output-bytes=18; shell=/bin/sh; cwd=/home/valentin/projects/cli-htpr-6834; path=fd5351737ae0/31 entries

- [x] G5: attachment contract checks preserve all files and reject named failures without silent success
  CHECK: python3 scripts/attachment_contract_test.py
  EXPECT: attachment contract tests passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=a2a2b66dd379be3c63dbd84357343a851c5068cdf442c3aa332deea93e2882cd; exit=0; EXPECT=matched; output-sha256=eb10a5d5bec9f5a79fd634991c8974bf6190cd5136c7855503198cfb308b515a; output-bytes=33; shell=/bin/sh; cwd=/home/valentin/projects/cli-htpr-6834; path=fd5351737ae0/31 entries

- [x] G6: required CLI parity remains intact
  CHECK: python3 scripts/parity_test.py
  EXPECT: negative parity passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=4c513d21f7f518d34a8cc5ec1fa762f40ab8f0c1feb8c9a0b0e77c6f847e2006; exit=0; EXPECT=matched; output-sha256=360d140779e155f4a3ff20770bba6e5418b706f4b93dd034320443bda688a58d; output-bytes=233; shell=/bin/sh; cwd=/home/valentin/projects/cli-htpr-6834; path=fd5351737ae0/31 entries

- [x] G7: installed and locally built behavior have bounded live evidence on the authorized ticket
  EVIDENCE: Installed 0.2.4 created comment 265043 with zero persisted attachments and returned HTTP 413 FUNCTION_PAYLOAD_TOO_LARGE, exit 4, not silent success. Fixed local binary rejects original 3765325-byte c.webm by name, exit 1, before any comment is created; explains 3 MiB and HTTPS URL alternative. A successful bounded live test uses two distinct 69-byte PNGs and a 5179-byte clip from the supplied webm: comment 265046 has exactly 3 persisted attachment IDs 21558, 21559, 21560, exit 0. Approved CLI reread confirms persistence. Exactly 3 comments created, IDs 265043, 265046, and handoff 265054; all have the required prefix and are only on the authorized ticket. Final approved CLI reread confirms the before/after attachment IDs and counts. Evidence in /tmp/htpr-6834-evidence/; built binary reports the same vcc agent ID 85b985ac-afe8-41a3-a1ac-d9549a9310c7.

- [x] G8: final diff is reviewed, requested commit is pushed, and correctly formatted main-base PR remains unmerged
  EVIDENCE: Reviewed production diff, attachment HTTP tests, formatting, and git diff --check. Commit e70eb01a841eddf70317d5682985d627b58d0d58 has requested BUGFIX message and exact Claude Opus 5.5 co-author trailer; git ls-remote confirms the pushed branch. PR https://github.com/hypertask-ai/cli/pull/105 targets main, is OPEN, and has no auto-merge request. gh pr view verifies exact requested title and body against /tmp/htpr-6834-evidence/pr-body.md, all required sections, exact first sentence/footer, and no em dashes. No merge or global installation performed. A follow-up evidence-only commit records completed gates.

- [x] G9: all gates are reverified and final report contains all requested outcomes below 20 lines
  EVIDENCE: Reread all requested outcomes and manually reverified claim, red tests, original HTTP 413 behavior, fixed three-file persistence, named oversized-file failure without a new comment, exact three-comment maximum, pushed commit trailer, and open unmerged main-base PR metadata. All five runnable gates reran with current definitions and passed at timeout 300, including full parity; /tmp/htpr-6834-evidence/gates-reverification.log records the run. Earlier parity timeout 120 was insufficient, not a skipped test. Final draft has 8 lines and contains root cause, all changed files, tests, live before/after with the remaining API size limitation, all gate counts, PR URL, and worktree.

## Depth tree

1. Establish protocol and trace parsing, upload, linking, and error propagation.
2. Prove failure, implement the smallest correction, and exercise file failures.
3. Build, run unit and parity checks, verify bounded live results, then commit and open the PR without merging.
