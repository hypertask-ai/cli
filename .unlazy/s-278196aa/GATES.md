# Gates: /ship

Scope: take this session's tickets end to end, live and verified.

- [x] HTPR-8351.ticket: The ticket exists on the board
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' ticket HTPR-8351
  EXPECT: ticket ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: automatic-evidence=v1; definition-sha256=1160e50964ac17b653c311c4325841173b2a984a598d707ba5463c0d7f95c10a; exit=0; EXPECT=matched; output-sha256=8d17ceac7d82fd2d508e2c28bd2fcf6931ed2b742384e96afd5c876e7c0ad828; output-bytes=10; shell=/bin/sh; cwd=/home/valentin/.local/state/runner5-8351/wt; path=0dc1c466bd2e/32 entries

- [ ] HTPR-8351.deeper: A Deeper: agent activity names the field, raw source, method and outside proof, and its proof gate is a runnable CHECK
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' deeper HTPR-8351
  EXPECT: deeper ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.pr: The PR is named HTPR-NNNN [TYPE] description
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' pr HTPR-8351
  EXPECT: title ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.merged: The PR is merged into production
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' merged HTPR-8351
  EXPECT: merged ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.deployed: The Production deployment for the merge is success
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' deployed HTPR-8351
  EXPECT: deployed ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.proof: Live QA proof.md follows the verify-qa contract for the latest merge, with screenshots
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' proof HTPR-8351
  EXPECT: proof ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.docs: Docs page change is merged and live on docs.hypertask.ai, or a No user-visible change reason is recorded
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' docs HTPR-8351
  EXPECT: docs ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.done: The ticket is in the done column its board names
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' done HTPR-8351
  EXPECT: done ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending

- [ ] HTPR-8351.cleaned: This session removed its worktree and branch for the ticket (/clean-up)
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/.local/state/runner5-8351/wt' '/home/valentin/.agents/skills/ship/scripts/ship-check' cleaned HTPR-8351
  EXPECT: cleaned ok
  CWD: /home/valentin/.local/state/runner5-8351/wt
  EVIDENCE: pending
