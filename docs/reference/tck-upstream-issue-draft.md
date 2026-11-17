# Draft upstream issue for a2aproject/a2a-tck (not posted)

This is the text prepared for a report to `a2aproject/a2a-tck`. It has NOT been
posted anywhere; a maintainer of this repository decides whether and when to
file it. It is the evidence behind the entry in
`scripts/tck_expected_failures.json` (see [TCK suite](tck-suite.md)).

---

**Title:** `HTTP_JSON-SVC-001` (SHOULD, `application/a2a+json`) and `HTTP_JSON-ERR-001` (MUST) cannot both pass on an error response

**Environment:** a2a-tck `104a7b4ae0d83f65c075e3793e322953a830eaba`, Python 3.15,
`./run_tck.py --transport jsonrpc,http_json,grpc`, a v1.1 server that passes
everything else (99 pass / 1 fail / 18 not tested / 6 skipped / 9 manual at
requirement level).

**Summary:** two checks constrain the Content-Type of the same HTTP+JSON error
response in ways no media type can satisfy without a workaround.

1. `HTTP_JSON-SVC-001` (SHOULD, spec 11.1; test
   `tests/compatibility/http_json/test_problem_details.py::TestHttpJsonErrorMediaType::test_error_content_type`)
   calls `tck/validators/http_json/content_type.py::uses_a2a_media_type`, which
   requires the media type (the part before `;`, lower-cased) to be exactly
   `application/a2a+json`.
2. `HTTP_JSON-ERR-001` (MUST, spec 11.6; test
   `tests/compatibility/core_operations/test_error_handling.py::TestRestErrorStructure::test_error_uses_aip193_format`)
   requires the substring `application/json` in the error response's
   Content-Type (`if "application/json" not in ct: errors.append(...)`), and the
   spec text for 11.6 only describes the body (`google.rpc.Status`), not a
   media type.

`application/a2a+json` does not contain `application/json`, so a response
passing (1) fails (2) and vice versa. The only strings passing both carry a
parameter whose value is `application/json` (for example
`application/a2a+json; profile="application/json"`), but section 14.1.1 of the
specification registers `application/a2a+json` with "Optional parameters:
None", so that is not a conforming value. An implementation must therefore pick
between failing a SHOULD and failing a MUST; we keep `application/json` so the
MUST holds, and the SHOULD check fails (two tests: success and error responses,
`TestRestFormat::test_response_content_type` and the error test above).

The specification's own example (section 11.6, "Error Response Example") shows
an error response with `Content-Type: application/a2a+json`, and other examples
use `application/problem+json`; the substring check in ERR-001 matches neither.

**Suggested fix (either):**

- change the ERR-001 check to accept any JSON media type
  (`application/json`, `application/a2a+json`, `application/*+json`), matching
  what 11.6 actually says, which makes both requirements satisfiable; or
- drop the media-type assertion from ERR-001 and leave it to SVC-001.

**Impact:** a server cannot reach a clean run on this TCK commit without
violating the spec's registered media type, and `run_tck.py` exits 1 for any
conformant implementation that chooses the MUST.
