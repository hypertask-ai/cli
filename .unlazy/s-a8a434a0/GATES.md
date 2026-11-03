# Gates: /ship

Scope: take this session's tickets end to end, live and verified.

- [x] HTPR-8423.ticket: The ticket exists on the board
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' ticket HTPR-8423
  EXPECT: ticket ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: automatic-evidence=v1; definition-sha256=6254b83ffad5ad7ea0f6e8024743907b1e116bef89e020e07af333b36f36af1b; exit=0; EXPECT=matched; output-sha256=8d17ceac7d82fd2d508e2c28bd2fcf6931ed2b742384e96afd5c876e7c0ad828; output-bytes=10; shell=/bin/sh; cwd=/home/valentin/wt/runner4-8423-cli; path=0dc1c466bd2e/32 entries

- [ ] HTPR-8423.deeper: A Deeper: agent activity names the field, raw source, method and outside proof, and its proof gate is a runnable CHECK
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' deeper HTPR-8423
  EXPECT: deeper ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.pr: The PR is named HTPR-NNNN [TYPE] description
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' pr HTPR-8423
  EXPECT: title ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.merged: The PR is merged into production
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' merged HTPR-8423
  EXPECT: merged ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.deployed: The Production deployment for the merge is success
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' deployed HTPR-8423
  EXPECT: deployed ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.proof: Live QA proof.md follows the verify-qa contract for the latest merge, with screenshots
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' proof HTPR-8423
  EXPECT: proof ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.docs: Docs page change is merged and live on docs.hypertask.ai, or a No user-visible change reason is recorded
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' docs HTPR-8423
  EXPECT: docs ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.done: The ticket is in the done column its board names
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' done HTPR-8423
  EXPECT: done ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending

- [ ] HTPR-8423.cleaned: This session removed its worktree and branch for the ticket (/clean-up)
  CHECK: SHIP_REPO=hypertask-ai/cli SHIP_BASE=main SHIP_CHECKOUT='/home/valentin/wt/runner4-8423-cli' '/home/valentin/.agents/skills/ship/scripts/ship-check' cleaned HTPR-8423
  EXPECT: cleaned ok
  CWD: /home/valentin/wt/runner4-8423-cli
  EVIDENCE: pending
