# FR-11 cross-origin change — verification record

SPECIFICATION.md §19 counts FR-11's verification obligation as **"1 four-file
byte-identity diff, plus 2 cross-origin browser checks"**. That is two halves,
and they are discharged by two different things:

| Obligation | Acceptance criterion | Discharged by | Status |
| --- | --- | --- | --- |
| four-file byte-identity diff | AC-15 (static) | `./scripts/verify-cors-config.sh`, run from `./scripts/test.sh` on every CI build | **PASSED** |
| 2 cross-origin browser checks | AC-16 (runtime) | `./scripts/verify-cors-runtime.sh` here, and `Pacco.Web/scripts/cors-browser-check.mjs` in the client repository | **NOT RUN** |

> **AC-16: not run — no Docker Compose stack available.**
>
> Both runtime checks need a gateway answering on `http://localhost:5000`, which
> means the Docker Compose stack. No such stack runs in this environment, so the
> two cross-origin browser checks did not execute. Per
> `LOW_LEVEL_SPEC-13652-wave-1.md` §L.6.2, an affected §L.6.A row in this
> situation is reported as **"not run"** and **never as passed**. AC-16 is
> therefore open, and this section is the explicit disclosure of that.

## What changed, and why a guard was added here

The change itself is four one-line edits: `extensions.cors.allowedOrigins`
goes from `- '*'` to `- 'http://localhost:3000'` in `ntrada.yml`,
`ntrada.docker.yml`, `ntrada-async.yml` and `ntrada-async.docker.yml`, keeping
`allowCredentials: true`. A wildcard origin and credentialled requests are
mutually exclusive in the CORS specification, so the wildcard had to go for the
browser client to work at all.

The regression guard lives **in this repository**. An earlier revision asserted
byte identity only from the client repository's Jest suite, which meant a
regression in an `ntrada*.yml` could land here without anything in this
repository's own build noticing. `scripts/verify-cors-config.sh` needs no
toolchain — plain `bash` and `awk` — so it runs before `dotnet test` in
`scripts/test.sh` and fails the build even though this repository has no test
project. That satisfies ADR-004 §2 obligation 1: the artefact that can break the
contract carries the check for it.

`.travis.yml` now also builds `feature/*` branches, so the guard actually runs on
the branch where `ntrada*.yml` is edited rather than only after a merge.
`scripts/dockerize.sh` exits early when the branch carries no tag, so widening
the branch filter produces no stray images.

## Commands run, and their output

### AC-15 — static byte-identity and exact-origin guard: PASSED

```
$ ./scripts/verify-cors-config.sh
Edge cross-origin configuration guard (AC-15 / FR-11)

  PASS  cors block is byte-identical across all four ntrada*.yml files
  PASS  ntrada.yml allows exactly one origin
  PASS  ntrada.yml names a concrete origin with scheme, host and port (http://localhost:3000)
  PASS  ntrada.yml retains no wildcard origin
  PASS  ntrada.yml leaves allowCredentials true
  PASS  ntrada.yml leaves allowedMethods untouched
  ... (37 assertions in total, 1 cross-file + 9 per file x 4 files)

RESULT: PASS — allowed origin is 'http://localhost:3000' in all four files.

NOTE: this guard is the STATIC half of FR-11 (AC-15) only. The runtime half
      (AC-16) is ./scripts/verify-cors-runtime.sh and needs a running
      gateway; a passing static guard is NOT evidence that the browser path
      works.

$ echo $?
0
```

The guard was also confirmed to fail: temporarily restoring `- '*'` in one file
produced 5 `FAIL` lines and exit status 1, so the `PASS` above is not vacuous.

### AC-16 — runtime cross-origin checks: NOT RUN

```
$ ./scripts/verify-cors-runtime.sh
Edge cross-origin runtime check (AC-16 / FR-11)
  gateway            : http://localhost:5000
  allowed origin     : http://localhost:3000
  disallowed origin  : http://localhost:3999

RESULT: NOT RUN — the gateway did not answer at http://localhost:5000. Start the Docker Compose stack (docs: §L.12.3) and re-run.
        AC-16 (FR-11) is NOT discharged by this run. It must be reported
        as 'not run', never as passed (§L.6.2).

$ echo $?
2
```

Exit status **2 means NOT RUN** and is deliberately distinct from 1 (failed), so
no CI wrapper can mistake an absent stack for a pass.

## How to discharge AC-16 when a stack is available

1. Start the backend stack so the gateway listens on `http://localhost:5000`.
2. Header-level check, from this repository:

   ```
   ./scripts/verify-cors-runtime.sh
   # or: ./scripts/verify-cors-runtime.sh <gateway-url> <allowed-origin> <disallowed-origin>
   ```

   It sends a preflight `OPTIONS` and a `POST /identity/sign-in` from both the
   allowed and a disallowed origin and asserts that
   `Access-Control-Allow-Origin` echoes the allowed origin exactly, is
   absent or non-matching for the disallowed one, and that the two responses
   differ — which is what a surviving wildcard would fail.

3. Browser-level check, from the client repository, which is the one §19
   literally asks for:

   ```
   cd <the Pacco.Web checkout>
   npm run verify:cors-browser
   ```

   It drives headless Chromium from two page origins and records the verdict
   the browser's own CORS implementation reached.

Neither script sends a real credential: the probe body is
`{"email":"","password":""}`. SPECIFICATION.md AC-7 keeps credentials out of the
repository, and the browser takes its CORS decision before the response body
matters — a `400` from the identity service is a perfectly good "the browser let
me read the response" result.

## Out of scope, stated so it is not mistaken for an omission

- **No logout, sign-out or revoke route is added**, and JWT validation and
  revocation behaviour is unchanged. Sign-out in Pacco.Web is a client-side
  session discard; the already-issued token stays valid at the platform level
  until it expires. `verify-cors-config.sh` asserts this, so a later change
  cannot smuggle such a route in unnoticed.
- **No Dev, QA, Staging or Production origins are configured.** No such frontend
  environments exist yet; their origins, gateway URLs, DNS names and deployment
  targets are to be defined later, and inventing them now would be fabrication.
  The single allowlisted origin is the local Pacco.Web development origin.
