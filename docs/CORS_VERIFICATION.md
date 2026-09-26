# FR-11 cross-origin change — what is checked, and how to check it

This document is the durable half of FR-11's verification: what the checks are,
where they live and how to run them. It deliberately records **no run results**.
The outcome of any particular run — which checks passed, which were not run,
the captured output — belongs in that run's pull request description, because a
result committed here is stale the moment someone runs the stack and then
misinforms every later reader.

## The change

Four one-line edits: `extensions.cors.allowedOrigins` goes from `- '*'` to
`- 'http://localhost:3000'` in `ntrada.yml`, `ntrada.docker.yml`,
`ntrada-async.yml` and `ntrada-async.docker.yml`, keeping `allowCredentials:
true`. A wildcard origin and credentialled requests are mutually exclusive in
the Fetch Standard, so the wildcard had to go for the browser client to work at
all. `http://localhost:3000` is the local `Pacco.Web` development origin.

## The two obligations, and what discharges each

SPECIFICATION.md §19 counts FR-11's verification obligation as **"1 four-file
byte-identity diff, plus 2 cross-origin browser checks"** — two halves,
discharged by different things.

| Obligation | Criterion | Discharged by | Needs a running stack |
| --- | --- | --- | --- |
| four-file byte-identity diff | AC-15 (static) | `./scripts/verify-cors-config.sh` | no |
| allowed-origin cross-origin check | AC-16 (runtime) | `./scripts/verify-cors-runtime.sh`, and `npm run verify:cors-browser` in `Pacco.Web` | **yes** |
| disallowed-origin cross-origin check | AC-16 (runtime) | the same two commands | **yes** |

⚠️ The allowed-origin check alone does **not** discharge AC-16. A wildcard
configuration passes it, so the disallowed-origin half — and the direct
comparison of the two responses' `Access-Control-Allow-Origin` headers — is what
makes the check evidence of anything.

⚠️ Where the stack is unavailable the runtime rows are reported as **not run**,
never as passed (`LOW_LEVEL_SPEC-13652-wave-1.md` §L.6.2).
`verify-cors-runtime.sh` exits **2** for "not run", kept distinct from **1** for
"failed", so no CI wrapper can mistake an absent stack for a pass.

## Running the checks

### AC-15 — static, no stack required

```
./scripts/verify-cors-config.sh
```

Asserts that the `extensions.cors` block is byte-identical across the four
files, that `allowedOrigins` holds exactly one entry, that the entry is a
concrete `scheme://host:port` origin, that no `'*'` survives, that
`allowCredentials`, `allowedMethods`, `allowedHeaders` and `exposedHeaders`
still hold their expected values, and that no logout or revoke route has
appeared. Exit 0 = pass, 1 = fail.

The expected values in check 5 are literals, not a diff against the base ref: a
deliberate future change to any of those keys is expected to update the literal
in the guard in the same commit.

### The guards' own tests

```
./scripts/tests/cors-guard.test.sh
```

A check that cannot fail on a broken configuration is worse than none, so the
guards are themselves tested. The suite drives the header parsing over recorded
responses, runs the static guard over mutated copies of the four files — a
restored wildcard, a second origin, single-file drift, a flipped
`allowCredentials`, an injected sign-out route — and runs the runtime check
against a local mock edge presenting the compliant header shape and four
non-compliant ones. It also measures and enforces line coverage of the three
shell modules; see `scripts/tests/lib/bashcov.sh` for why coverage is measured
that way in a repository with no test project.

🚫 A green run of this suite is **not** AC-16. The mock edge stands in for the
gateway so the instrument can be proven; AC-16 is a statement about the real
gateway.

### AC-16 — runtime, needs the stack

1. Start the backend stack so the gateway listens on `http://localhost:5000`.
2. Header-level check, from this repository:

   ```
   ./scripts/verify-cors-runtime.sh
   # or: ./scripts/verify-cors-runtime.sh <gateway-url> <allowed-origin> <disallowed-origin>
   ```

   It sends a preflight `OPTIONS` and a `POST /identity/sign-in` from both the
   allowed and a disallowed origin and asserts that
   `Access-Control-Allow-Origin` echoes the allowed origin exactly, that
   `Access-Control-Allow-Credentials: true` accompanies it, that no response
   carries a `*`, that the disallowed origin's responses are unreadable to the
   page, and that the two origins receive different headers on both the
   preflight and the POST.

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

## Where the guard runs in CI

`.travis.yml` runs `./scripts/tests/cors-guard.test.sh` and
`./scripts/verify-cors-config.sh` as their own steps, ahead of
`./scripts/build.sh`, so the FR-11 regression check does not depend on the
pinned .NET toolchain. `./scripts/test.sh` runs both again and then invokes
`dotnet test` **only** where a test project exists — this repository declares
none, and an unconditional `dotnet test` would leave a permanently failing step
in which the guards' own result could not be read.

⚠️ Travis builds `master` and `develop` only. On a feature branch the guards are
run by hand with the commands above. Extending `branches.only` to feature
branches is a CI-policy change outside the change surface
`LOW_LEVEL_SPEC-13652-wave-1.md` §L.5 step 7 authorises for FR-11, so it is left
for explicit approval as a separate change rather than carried here.

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
