# Commit map for the workflow-implemented lanes

Lane agents staged their own files with `git add` before the coordinator committed, so the
first lane commit (6e27ead) absorbed every staged file, not only the crypto lane. History is
never rewritten here; this map states what each commit really contains. Base: e2e02eb.

| Commit | Subject as committed | What it actually contains |
|---|---|---|
| 6e27ead | feat(crypto): sa2a_crypto ... verify certificate signatures | sa2a_crypto/ (21 files); authority_service/ (24); sa2a-approver/ (16); test/support (37, mostly the C2 court harness fixtures); k8s/ (8, authority/actuator manifests); c2 certificate rewire and tests; config/runtime.exs, prod.exs, dev.exs; mix.exs path dep |
| e9f0c60 | feat(crypto): key registry ... quorum | sa2a_crypto registry, nonce store, quorum; SignerSet delegation |
| efb6a0b | feat(profile): SecurityProfile ... boot enforcement | SecurityProfile, boot wiring, SECURITY.md (remaining profile files are in 6e27ead) |
| 83e479d | fix(egress): SSRF admission ... | OCEL forwarder SSRF admission, HDDL timeout, ERC sanitization |
| c961c6c | fix(safe-exec): SafeExec and CallbackRegistry | SafeExec allowlist, CallbackRegistry, converted call sites |
| 9d27c5d | ci(release): single release path ... | release.yml only publisher, dry-run, Dependabot, Scorecard, policy tests |
| 1208944 | feat(chicago): graph-derived closure court | closure court (rest of its files are in 6e27ead) |
| c787167 | feat(conformance): verify_conformance --profile | profile verifier modules and tests |
| 2eac4a1 | docs: configuration truth ... | docs, governed test helper, docs-truth test |
| fb93152 | feat(actuator): separate minimal Actuator project | actuator/ (42 files) |
| de9c31c | test(c2): compromise court harness | the court's mix task and tests (fixtures are in 6e27ead) |

## See Also

- `docs/conformance/v26.9.28-conformance-report.md`
- `docs/jira/v26.9.28-kernel/_LANES_V3.md`
