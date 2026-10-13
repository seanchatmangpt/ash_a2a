# refusal-vocabulary-pack

**Class/Profile:** EvidencePack · projection · **Authority:** SELECT/CONSTRUCT, no DO (consequential actuation stays behind BRCE admission).
**Identity:** `urn:refusal-vocabulary:` — canonical FAIL-CLOSED crosswalk from erlmcp's integer refusal codes (`erlmcp_refusal.hrl`, 1001-1089) to ash_a2a's RFC-SA2A-001 S42 refusal classes (18) plus the JSON-RPC error law.

Capability command (from the pack dir):

```bash
cd packs/refusal-vocabulary-pack && ggen sync run && python3 verify.py
```

Evidence boundary: totality/coverage gates (`gates/040_totality.rq`,
`gates/050_valve_totality.rq`) prove 51/51 codes placed, exactly one class
each, all 18 classes targeted. Fourth column: ash_a2a transport-native atoms
(`server_busy`/`rate_limited`) crosswalked onto S42 classes at the
spec-reserved -32000 server-implementation wire code
(`gates/060_a2a_wire_totality.rq`; adjudication in `ontology.ttl` at
`rv:code-rate-limited`). Negative witness: -31999 stays outside the law set
(`negative_witness_31999_refuses` in the projected rust gate suite).
Contract details and the ash_a2a differential
court (4 FORCED placements, 1069 adjudicated deviation):
`docs/reference/refusal-crosswalk.md`. Classification vocabulary only — no
runtime actuation authority.
