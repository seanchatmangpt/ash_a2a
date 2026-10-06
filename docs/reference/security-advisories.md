# Security Advisories Disposition

Dispositions of dependency vulnerability scanner findings for this repository.
Regenerate the findings with:

```bash
mix hex.audit                       # hex dependency CVE audit
mix sobelow --exit high             # sobelow static analysis gate stage (.check.exs)
trivy fs --scanners vuln,secret .   # filesystem vuln + secret scan
```

Scanner snapshot: 2026-10-05, branch `feat/tck-vuln-hardening`, HEAD `8621455`
(cowlib dispositions re-evidenced 2026-10-05 at HEAD `b85fb120`; `mix.lock`
unchanged between the two).

## Fixed

| CVE | Dependency | Severity | Fix | Review date |
|---|---|---|---|---|
| CVE-2026-94201 (EEF-CVE-2026-94201) | ash | HIGH | Bumped ash 3.34.0 -> 3.34.4 (patch-level, within existing `~> 3.33 and >= 3.33.11` constraint); atom-table exhaustion via `unsafe_to_atom?` filtering closed. Pulled ex_ast 0.13.2 and spark 2.7.6 transitively. | 2026-11-05 |

## Open dispositions (ACCEPT-TYPED)

| CVE | Dependency | Installed | Severity | Disposition | Notes | Review date |
|---|---|---|---|---|---|---|
| EEF-CVE-2026-43966 (GHSA-w4f7-4cxr-rv3c) | cowlib 2.20.0 | 2.20.0 | MEDIUM | ACCEPT-TYPED:NOT-EXPOSED | HTTP response splitting via non-VCHAR bytes in `cow_http_struct_hd:escape_string/2`. No fixed release exists (2.20.0 is the latest cowlib on hex.pm) and no patched fork exists, so no `mix deps.update` is lawful. NOT-EXPOSED (dependency path + usage shape): cowlib reaches the runtime closure only via `grpc_server ~> 1.0` -> `cowboy 2.19.0` -> `cowlib` (plus `grpc_server`'s direct `cowlib ~> 2.14` pin; `mix deps.tree`, 2026-10-05). `cow_http_struct_hd` is referenced by NO module in the shipped closure — `grep -rn cow_http_struct_hd deps/cowboy/src` returns 0 hits; structured-header parsing is HTTP/3-only surface, and cowboy 2.x serves HTTP/1+HTTP/2 over TCP/TLS. ash_a2a `lib/` makes no direct cowlib calls. Usage-shaped exposure: nil. | 2026-11-05 |
| EEF-CVE-2026-43969 (GHSA-g2wm-735q-3f56) | cowlib 2.20.0 | 2.20.0 | LOW | ACCEPT-TYPED:NOT-EXPOSED | Cookie request-header injection via unvalidated encoder in `cow_cookie:cookie/1`. No fixed release exists (2.20.0 is latest on hex.pm) and no patched fork exists. NOT-EXPOSED (usage shape, same dependency path as EEF-CVE-2026-43966): `cow_cookie:cookie/1` is a cookie-pair *encoder* (list of pairs -> iodata) with ZERO callers in the shipped closure — `grep -rn ':cookie(' deps/cowlib/src deps/cowboy/src` (excluding parse/setcookie) finds no call site; cowboy parses request cookies through the validated `cow_cookie:parse_cookie/1` (`deps/cowboy/src/cowboy_req.erl:461,524`). ash_a2a never calls cowlib directly. Usage-shaped exposure: nil even when a host opts into the gRPC endpoint. | 2026-11-05 |

## Out-of-scope (vendored third-party tree, not root lock)

Findings inside `deps/protobuf` (vendored upstream checkout, per `mix.exs:495-497`),
scanned by trivy but not part of the ash_a2a root `mix.lock` resolution:

- `deps/protobuf/deps/google_protobuf/examples/go/go.mod` — CVE-2024-24786, golang.org/protobuf v1.27.1 (MEDIUM, fixed in 1.33.0) — Go example code, not shipped runtime.
- `deps/protobuf/deps/google_protobuf/python/docs/requirements.txt` — 5x jinja2 MEDIUM (CVE-2024-22195/34064/56201/56326, 2025-27516) — Python docs requirements, not shipped runtime.
- `deps/protobuf/mix.lock` — hackney 1.25.0, CVE-2026-47069/47071/47075/47076 (1 HIGH, 2 MEDIUM, 1 LOW) — upstream protobuf package's own lock; consumed here as a vendored source tree, hackney not in root resolution.

## Static analysis (sobelow, `--exit high`)

GREEN against the gate threshold. Low-confidence directory-traversal notices in
`lib/ash_a2a/spg_conformance.ex:71,193` and `lib/ash_a2a/standing_ref.ex:363` are
low-confidence findings below the `--exit high` gate and involve path variables
bounded by the conformance-runner file layout, not unbounded user input. No
high-confidence findings. No config weakening.

## Secrets

trivy secret scanner: 0 findings.
