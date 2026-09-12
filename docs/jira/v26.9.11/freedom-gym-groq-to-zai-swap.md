# Swap Groq for Z.AI in live LLM fixtures (freedom-gym)

## Summary

Converted the FreedomGym Chicago-AI live-LLM tests and shared fixture from
Groq to Z.AI's `zai_coder` provider (via `req_llm` native support), per
explicit request to replace this repo's Groq usage. The named, visible skip
guard now keys off `ZAI_API_KEY` (read from `~/.env`) instead of
`GROQ_API_KEY`. No mock LLM client was introduced; the real live call was
preserved (Chicago-style testing discipline: real collaborator, not a mock).

## Status

Done - already merged/committed.

## Commits

- c1f8570 test(freedom-gym): swap Groq for Z.AI in live LLM fixtures

## Changes

- `test/ash_a2a_freedom_gym_llm_test.exs` — updated (52 lines changed, mix of
  additions/removals) to use the Z.AI provider path instead of Groq.
- `test/ash_a2a_freedom_gym_zai_test.exs` — updated (14 lines changed) for
  the Z.AI-specific test coverage.
- `test/support/freedom_gym_llm_fixture.ex` — updated (48 lines changed) to
  swap the shared fixture's provider from Groq to Z.AI's `zai_coder`.
- Net diff: 3 files changed, 80 insertions(+), 34 deletions(-).
- Skip condition changed from `GROQ_API_KEY` to `ZAI_API_KEY` (sourced from
  `~/.env`) as the environment gate for the live-LLM tests.

## Verification

None stated beyond the commit message's own claim that "real live call
preserved" and "no mock LLM client introduced." No test run output, CI
status, or lint results are recorded in the commit message.

## Related

- No PR number or branch name mentioned in the commit subject.
- Claude-Session referenced in the commit message: https://claude.ai/code/session_018iXTYcpGbgf23MZYLe6TCU
