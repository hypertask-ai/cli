# Gates: HTPR-6805 behavior-preserving Zig CLI refactor

OWNS: GATES.md, src/**, scripts/htpr_6805_test.py

Scope: deduplicate JSON, HTTP and command internals, reuse connections and eliminate redundant lookups, split agent state and HTML helpers, preserve stdout/stderr/exit behavior, and commit only in this worktree without pushing, opening a PR, or writing to the board.

Prerequisites: Ubuntu, Zig 0.15.2, Python 3, Node, and the installed unlazy checker. CLAUDE.md is absent and AGENTS.md has no Feature flags section in this worktree. No feature flag or Node behavior change is required for this internal Zig refactor.

Reference artifacts: the original Zig CLI is built from commit 85ad1a08ed65597157218d3789b0485296b491cb. The frozen Node reference is @hypertask/hypertask_cli@2.0.6, installed with `npm install --prefix .zig-cache/node-reference --cache .zig-cache/npm-cache --ignore-scripts --no-audit --no-fund @hypertask/hypertask_cli@2.0.6`. All fixture homes and artifacts stay inside this worktree.

Parity qualification: no non-expiring live parity token is available, and the saved credential returned HTTP 403 on a read-only probe. G9 runs the unmodified full parity script against isolated API fixtures. Search detail GETs are batched four at a time using the existing scalar endpoint; their count is unchanged, while sequential connection setup and redundant update lookups are removed. Legacy migration and exact mention parsing remain enabled and unchanged.

- [x] G0: the ledger has valid, outcome-oriented checks
  CHECK: node /home/valentin/.agents/skills/unlazy/scripts/gate-lint.mjs GATES.md
  EXPECT: LINT OK
  EVIDENCE: automatic-evidence=v1; definition-sha256=69f81179f3934636347ff01de4824d2a1f500f2d29238b9fd688f82f77d1c57b; exit=0; EXPECT=matched; output-sha256=99cbefd434a5f4e3d0edfc70ca7fb2fc8d1995c8beab479ae5ec810643899531; output-bytes=347; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G1: JSON field accessors and raw-field comma handling have one implementation
  CHECK: python3 scripts/htpr_6805_test.py --structure json
  EXPECT: json structure verified
  EVIDENCE: automatic-evidence=v1; definition-sha256=f35da548650f18faaea3e008edd20c81d02fb795aa26214125fc3dcfde6d2b5a; exit=0; EXPECT=matched; output-sha256=655c76b542390a6341778d579fc1fd8116f41484a3ffb4c94163888941f3286f; output-bytes=24; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G2: all HTTP success checks use Response.isSuccess and agent-dev shares response handling
  CHECK: python3 scripts/htpr_6805_test.py --structure http
  EXPECT: http structure verified
  EVIDENCE: automatic-evidence=v1; definition-sha256=59b9765a4fb5bed2d30bb51830ca3394b6e6a1a038efc99e533a0f293d51f07f; exit=0; EXPECT=matched; output-sha256=7c97334eac9cac76cf2c81f179816c2d1accee0d5cbee9f09d1dab22d31382b0; output-bytes=24; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G3: duplicated command mappings, resolution, delete confirmation, file reads and output errors use shared implementations
  CHECK: python3 scripts/htpr_6805_test.py --structure reuse
  EXPECT: reuse structure verified
  EVIDENCE: automatic-evidence=v1; definition-sha256=e4ca55dbb24dbbe406df21f4558990979e3bd00d3ec6210869a754b88d66383d; exit=0; EXPECT=matched; output-sha256=557c0595938fc0e7fbedc849e9bedc724df9a0559b2ba30e7293b64634a27a0a; output-bytes=25; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G4: one Context HTTP client serves multi-request commands and scoped/batched lookups preserve results
  CHECK: python3 scripts/htpr_6805_test.py --network
  EXPECT: network verification passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=0c7d19080d2022cc424f086bbd137d6a52e29253c693f9431fbfe382bbe647f6; exit=0; EXPECT=matched; output-sha256=10386040da56bde9e739388018a69e1676bbbca596c5a003715be3de094ab475; output-bytes=95; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G5: agent state storage and HTML scanning are extracted without changing migration or mention semantics
  CHECK: python3 scripts/htpr_6805_test.py --structure split
  EXPECT: split structure verified
  EVIDENCE: automatic-evidence=v1; definition-sha256=04fc30bb5936c07f49d92c4859ecaa237e1f04208f460b1509fb6c95ee3f24f1; exit=0; EXPECT=matched; output-sha256=ee429834d967cc5d683b429352ab97783fbb6ba5c5a9fe4a781c064b9e971f89; output-bytes=25; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G6: the required smoke commands and additional edge cases produce baseline-identical stdout, stderr and exit codes with fixture API responses
  CHECK: python3 scripts/htpr_6805_test.py --smoke
  EXPECT: byte-identical smoke verification passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=1f48d263e4ea414ea8ab9f241fe306f61f21987eb1c54de10fe77cfbebaac2ec; exit=0; EXPECT=matched; output-sha256=b96d2adff98086362a0ced80495f1c0bb1ccd4f041ac21c14b9c555a6328e1d6; output-bytes=83; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G7: the Zig executable builds
  CHECK: zig build && printf 'Zig build succeeded\n'
  EXPECT: Zig build succeeded
  EVIDENCE: automatic-evidence=v1; definition-sha256=168db1334442778acc8d407c4f1d2bb3fb841617915c05d41ee37a6c8b3a3c1d; exit=0; EXPECT=matched; output-sha256=076fdf0a48f063deeacd81b74c68bebd9e52682a8f663abf9dd4f21c0d6a5ec8; output-bytes=20; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G8: Zig unit and contract tests pass
  CHECK: zig build test --summary all
  EXPECT: Build Summary:
  EVIDENCE: automatic-evidence=v1; definition-sha256=dbfaf4f8da146414cfd1db348ecea86726f363625c439fb0281518074df36d93; exit=0; EXPECT=matched; output-sha256=197e5ecef88c71ce61f240902fc45f08da6321d77fe753ee73bd08a0699462fc; output-bytes=4308; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G9: the full python3 scripts/parity_test.py suite passes against isolated fixtures and the frozen Node CLI without board mutations
  CHECK: python3 scripts/htpr_6805_test.py --parity
  EXPECT: read-only parity passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=509633c4b1cc1c34101f45c3de36f1ca2b31f32277dde74f89d9738c0fe85243; exit=0; EXPECT=matched; output-sha256=36589ea1090c0b385363c6fb8d5f4fd6ce31d77051318c5b2660cd1748044e05; output-bytes=298; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [x] G10: changed Zig files are formatted, the diff is clean, and added text contains no em dash
  CHECK: python3 scripts/htpr_6805_test.py --hygiene
  EXPECT: hygiene verification passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=7c728620c0cf7a1bfd23a48e349ea8b0234c3b352563dd60c5d91b8060f2c8da; exit=0; EXPECT=matched; output-sha256=a5b3359677108080c36b523402da2ea6ab3fd06cca8f18adc6374dd19c1abfd1; output-bytes=28; shell=/bin/sh; cwd=/home/valentin/projects/cli-wt-6805; path=fd5351737ae0/31 entries

- [ ] G11: the reviewed change is committed locally on htpr-6805 with the required message and coauthor, without a push or PR
  EVIDENCE: pending
