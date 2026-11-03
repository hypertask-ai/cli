# Gates: /ship

Scope: take this session's tickets end to end, live and verified.

- [x] HTPR-8433.ticket: The ticket exists on the board
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' ticket HTPR-8433
  EXPECT: ticket ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: automatic-evidence=v1; definition-sha256=905aa57eef92a9ece22dd75bb6354eba40378a27eeba8c8b1217f0a21d85592c; exit=0; EXPECT=matched; output-sha256=8d17ceac7d82fd2d508e2c28bd2fcf6931ed2b742384e96afd5c876e7c0ad828; output-bytes=10; shell=/bin/sh; cwd=/home/valentin/projects/cli-r2-8433; path=0dc1c466bd2e/32 entries

- [ ] HTPR-8433.deeper: A Deeper: agent activity names the field, raw source, method and outside proof, and its proof gate is a runnable CHECK
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' deeper HTPR-8433
  EXPECT: deeper ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.pr: The PR is named HTPR-NNNN [TYPE] description
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' pr HTPR-8433
  EXPECT: title ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.merged: The PR is merged into production
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' merged HTPR-8433
  EXPECT: merged ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.deployed: The Production deployment for the merge is success
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' deployed HTPR-8433
  EXPECT: deployed ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.proof: Live QA proof.md follows the verify-qa contract for the latest merge, with screenshots
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' proof HTPR-8433
  EXPECT: proof ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.docs: Docs page change is merged and live on docs.hypertask.ai, or a No user-visible change reason is recorded
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' docs HTPR-8433
  EXPECT: docs ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.done: The ticket is in the done column its board names
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' done HTPR-8433
  EXPECT: done ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.cleaned: This session removed its worktree and branch for the ticket (/clean-up)
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/projects/cli-r2-8433' '/home/valentin/.agents/skills/ship/scripts/ship-check' cleaned HTPR-8433
  EXPECT: cleaned ok
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending

- [ ] HTPR-8433.deeper-hint: The shipped fleet CLI names where a ticket's comments live when an agent guesses `task comments`
  CHECK: hypertask task comments 44 2>&1 | grep -F 'hypertask comment list <ticket>' >/dev/null && echo 'comment hint printed'
  EXPECT: comment hint printed
  CWD: /home/valentin/projects/cli-r2-8433
  EVIDENCE: pending
