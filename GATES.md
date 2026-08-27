# Gates: full Hypertask CLI parity

OWNS: GATES.md, README.md, build.zig, src/**, scripts/**

Scope: implement every current Node CLI leaf command in the native Zig CLI, preserve its command grammar and API routes, build it, install it, and add a read-only parity check

- [ ] G1: the Zig capability tree matches every current Node CLI leaf command and option
  CHECK: python3 scripts/parity_test.py --capabilities-only
  EXPECT: capability parity passed
  EVIDENCE: pending

- [ ] G2: the modular Zig implementation compiles and its unit tests pass in ReleaseFast mode
  CHECK: zig build test -Doptimize=ReleaseFast && echo "ReleaseFast build and tests passed"
  EXPECT: ReleaseFast build and tests passed
  EVIDENCE: pending

- [ ] G3: the required read-only parity subset matches Node CLI exit behavior
  CHECK: python3 scripts/parity_test.py
  EXPECT: read-only parity passed
  EVIDENCE: pending

- [ ] G4: the source tree contains the requested parser, JSON, HTTP, resolver, router, and per-domain command modules
  CHECK: python3 scripts/parity_test.py --architecture-only
  EXPECT: architecture check passed
  EVIDENCE: pending

- [ ] G5: the installed htz binary is byte-identical to the ReleaseFast build artifact
  CHECK: cmp zig-out/bin/htz "$HOME/.local/bin/htz" && echo "installed binary verified"
  EXPECT: installed binary verified
  EVIDENCE: pending

- [ ] G6: every non-local leaf command maps to the Node CLI HTTP method, path, query keys, and JSON body fields
  EVIDENCE: pending
