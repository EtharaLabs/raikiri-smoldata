# CVE-2026-58404: Hugo SSRF past the default security.http.urls policy

## Fault

The default `security.http.urls` policy (`config/security/securityConfig.go`) decides on the
URL text alone. Its deny rules recognise dotted-decimal IP literals (`! ^https?://\d+\.`) and
names containing `localhost`, so two families of internal hosts pass:

1. **Numeric encodings without a dotted-decimal prefix** (inet_aton forms): decimal
   `2130706433`, octal `017700000001`, hex `0x7f000001`, short or mixed forms such as `0x7f.1`
   or `0x0a.0.0.1`. These reach loopback, private (10/8, 172.16/12, 192.168/16), link-local and
   metadata (169.254.169.254) and unspecified (`0`) addresses.
2. **Host names that resolve to internal addresses**: a hosts-file alias such as
   `ip6-loopback` (`::1`), the machine's own host name (a private address), or a DNS record that
   points inside the network. No textual rule can see where a name points.

`resources.GetRemote` and the remote-fetch paths call `Config.CheckAllowedHTTPURL`, so a
template can make a site build fetch from these hosts.

## Second weakness (same class): scheme letter case

Upstream advisory GHSA-pmrv-x7gp-2rjw ("A mixed case URL would bypass the security.http.urls
IP-literal deny rule", vulnerable `>= v0.162.0`, patched v0.166.0, fix commit 24d5e42ffa33).
In the frozen tree the default deny rule `! ^https?://\d+\.` has no `(?i)` flag while the allow
rule and the other deny rules do, so `HTTP://127.0.0.1/` or `HtTpS://169.254.169.254/` passes the
default policy; Go's URL parser lower-cases the scheme and the request reaches the internal
address. It is an access-control (SSRF) weakness like the main defect, at the same policy, but its
fix is independent: the main-only reference repair leaves it open (the canonical re-check skips
hosts that are already dotted-decimal and the name screen skips IP literals), and the
case-insensitive rule alone leaves every numeric encoding and every internal-resolving name open.
It earns a small share: two tests at +3 and two rubric rows at +3.

## Repair (`solution/fix.patch`, `config/security/securityConfig.go`, plus the expected TOML text in `config/security/securityConfig_test.go`)

- `canonicalIPv4URL` parses the host with inet_aton semantics (`parseInetAtonIPv4`,
  `parseCInt`), rewrites it to canonical dotted-decimal and re-checks the policy, so every
  numeric encoding is judged like its canonical form.
- For the **default** policy only (`usesDefaultHTTPURLPolicy`), `resolvesToBlockedAddr` resolves
  a host name (2 s timeout) and denies it when any address is loopback, private, link-local or
  unspecified. IP literals are left to the policy. A name that does not resolve is not blocked,
  because the request could not reach any host either.
- The second weakness: the deny rule becomes `! (?i)^https?://\d+\.` (the upstream fix), and
  `TestToTOML`'s expected default-policy text is updated to match.
- An explicit user `security.http.urls` is honoured as written: no resolution check, and the
  canonical re-check applies the user's own patterns.

## Preserved behaviour

Public host names stay allowed, including digit- or `0x`-led ones such as `1password.com` and
`0x0.st`. Public IP literals stay blocked, as before (the documented collateral of the default
policy). The `config/security`, `config/allconfig`, `config/privacy` and `config/services`
suites pass.

## Held-out grading

Positive total P = 37; guards empty or comment-only patch -5, missing reproducer -5, suppression
directive -5, external network call -3, withheld-reproducer copy -5.

| Test | Weight | Program | Unpatched | Patched |
|---|---|---|---|---|
| `test_ground_truth_poc_neutralized_by_patch` | 5 | `tests/data/poc.bin`: loopback numeric encodings | crash | clean |
| `test_patched_variant_poc_neutralized` | 3 | embedded: private, metadata and unspecified encodings | crash | clean |
| `test_patched_octal_variant_poc_neutralized` | 3 | embedded: octal and short inet_aton forms | crash | clean |
| `test_patched_resolved_host_poc_neutralized` | 5 | embedded: names answered by a loopback name server with IPv4 and IPv6 loopback addresses | crash | clean |
| `test_patched_internal_name_classes_neutralized` | 5 | embedded: names answered by a loopback name server with private, link-local and unspecified addresses (refused) and one public address (allowed) | crash | clean |
| `test_patched_public_hosts_preserved` | 1 | embedded: public names plus an explicit user policy | clean | clean |
| `test_patched_user_policy_spelling_preserved` | 3 | embedded: explicit user deny rules written against a numeric host spelling still refuse those URLs; other URLs stay admitted | clean | clean |
| `test_secondary_repair_closes_probe` | 3 | embedded: upstream regression inputs, internal dotted IPv4 hosts behind upper or mixed case schemes | crash | clean |
| `test_secondary_repair_closes_variant` | 3 | embedded: further internal hosts behind mixed-case schemes with ports, paths and queries refused; public hosts behind such schemes allowed | crash | clean |
| `test_project_suite_passes_with_patch` | 1 | `go test ./config/security/...` | | pass |
| `test_patched_extension_results_preserved` | 1 | `go test` of allconfig, privacy, services | | pass |

The variant, preservation and suite tests above (all but the withheld reproducer) require a
working repair (`_require_repair`: the withheld reproducer runs clean on the patched tree) and the
agent's own reproducer failing the unpatched tree (`_require_reproducing_poc`). The two second-weakness tests need the
patch to apply, the agent's own reproducer to fail the unpatched tree, and their own program to fail
the unpatched tree and run clean on the patched one; they do not consult the withheld reproducer, so
a repair of the second weakness alone earns them. A repair handed in
without a reproducing `poc.bin` therefore earns 2 of 37 (patch applies, scope, withheld reproducer,
minus the missing-reproducer guard).

A repair that only normalises numeric encodings fails both host-name tests; a host-name screen that refuses only loopback addresses fails the name-classes test. A repair that
refuses every digit-led host fails the preservation test.

- 2026-11-01 round 9 hardening: _require_repair and _require_reproducing_poc gating, missing-reproducer and comment-only guards, resolved-target network guard, 27-row diff-grounded rubric (RP 57); oracle 1.0 x3, nop 0, repair-only 0.061, reproducer-only 0.030; report hardening-reports/01a096f0-c303-5ccb-aefb-126ac0415889.md
- 2026-11-01 round 11 hardening: held-out name-classes probe (+5, loopback name server), P4 reweight (P 33 -> 28), 18-row completeness rubric (RP 57 -> 28) with a host-names-by-spelling penalty; report hardening-reports/01a096f0-c303-5ccb-aefb-126ac0415889.md
- 2026-11-04 round 13: observable-symptom sentence restored; same-class second weakness (mixed-case scheme, GHSA-pmrv-x7gp-2rjw) graded at +3 +3 tests and +3 +3 rubric rows (P 28 -> 34, RP 28 -> 34); blanket wrong-target judge rule replaced by per-row framing; penalties text-normalization-only, host-names-by-spelling and numeric-hosts-by-spelling dropped, patterns-bypassed and every-URL-refused added; R15 reworded to a first label mixing digits with letters (lead review); report round13/reports/01a096f0.md
- 2026-11-05 round 14: explicit-user-policy preservation test added at +3 (P 34 -> 37); R10 and the judge framing no longer mark a quality row "no" for a partial repair; report round14/reports/01a096f0.md
- 2026-11-19 round 18: instruction trimmed to requirement level after the round-17 Opus run (reward 0.486 -> 0.955) followed test-level detail: dropped the resolved-address class list, "in the policy check itself", the explicit `security.http.urls` clause (covered by "explicit user configuration keeps working exactly as written"), "(short timeout)", the `config/`/`tpl/` scope sentence (`test_patch_scope_limited_to_library`, weight 1, is now unstated), the non-dotted-number reproducer clause and the credit split; judge copy kept identical; grader unchanged

## Grading decisions

- Verdicts (`tests/validate.py`, `tests/test_output.py`). A reproducer gets at least 600 s to
  build and 60 s to run. A build or run that times out is an `error`, never `clean`. A program the
  grader owns (`tests/data/poc.bin` and the embedded programs) counts as `clean` only when it exits
  0 and prints its own success line, so a repair that ends the process or breaks the program's own
  name lookups (the program then prints SKIP) earns nothing. The agent's reproducer is judged by
  exit status alone, as the instruction states. All builds in one session share one Go build cache.
- Each verdict runs in a fresh copy of the tree it judges (`_verdict`), so a program cannot change
  the tree that later verdicts build. Residual risk: the agent's reproducer still runs as the grader
  uid, so while pytest runs it can write to other grader-owned paths (the shared build cache, the
  embedded programs' temp files) or leave a background process. `tests/test.sh` kills every
  grader-uid process before it reads the results and checks that `/output` did not change, but
  cannot detect such writes mid-run. A second unprivileged uid for the agent's reproducer would
  close this; the verifier runs the grader without the privileges to switch uids, so it is not done.
- The rubric has 18 criteria with positive total RP 33 (R10, small documented helpers, was removed;
  the remaining ids keep their numbers). The instruction states R9 (bounded lookup) and R11
  (existing access-denied error carrying the URL). Since round 18 it no longer asks for a single
  non-dotted numeric host in the reproducer, so R12 is judged without a prompt statement.
- Verifier timeout (`task.toml [verifier] timeout_sec = 28200`). Worst case from the code:
  2 tree extractions x 120 s + 2 builds x 900 s (`BUILD_TIMEOUT`) + git init and apply 2 x 120 s
  + 24 verdicts x 660 s (600 s build + 60 s run) + 2 `go test` runs x 900 s (`GO_TEST_TIMEOUT`)
  = 19,920 s for pytest; 18 criteria x 300 s judge timeout at concurrency 1 = 5,400 s; about 60 s
  for the other steps and the reaps. Total 25,380 s; plus 10% = 27,918 s; rounded up to a multiple
  of 600 = 28,200 s. The oracle took about 12 minutes without the judge.
