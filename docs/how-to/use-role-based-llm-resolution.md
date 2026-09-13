# How to Add an LLM-Backed Action Without Hardcoding a Provider

`AshA2A.LLMProfiles` lets an Ash action declare an abstract **role** (e.g.
`:semantic_reasoner`) instead of a concrete `provider:model` string. Runtime
config (`config/*.exs`) resolves the role to a real `req_llm`/`ash_ai` model
spec. The action's source never names `zai_coder`, `groq`, `openai`, or any
other provider — switching providers becomes a config-only change.

## 1. Configure the role

In `config/config.exs` (or `config/test.exs`, `config/runtime.exs`):

```elixir
config :ash_a2a, :llm_profiles,
  semantic_reasoner: [
    provider: :zai_coder,
    model: "glm-5.3-flash",
    max_tokens: 4096
  ]
```

The `:provider` and `:model` keys are combined into the `"provider:model"`
spec string `prompt/2` expects. Every other key (`:max_tokens` above, or
`:timeout`, etc.) is passed through as a real call option.

## 2. Reference the role from an Ash action

Call `AshA2A.LLMProfiles.model_spec!/1` for the model spec and
`AshA2A.LLMProfiles.req_llm_opts!/1` for the call options, inside a
`prompt/2` action `run`:

```elixir
defmodule MyApp.SemanticReasoner do
  use Ash.Resource,
    domain: MyApp.SemanticReasonerDomain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshA2A, AshAi]

  actions do
    action :respond_to_prompt, :map do
      argument(:prompt_text, :string, allow_nil?: false)

      constraints(
        fields: [
          answer: [type: :string, allow_nil?: false]
        ]
      )

      run(
        prompt(
          AshA2A.LLMProfiles.model_spec!(:semantic_reasoner),
          prompt: {
            "You are a semantic reasoner. Answer in one short sentence.",
            "<%= @input.arguments.prompt_text %>"
          },
          req_llm_opts: AshA2A.LLMProfiles.req_llm_opts!(:semantic_reasoner)
        )
      )
    end
  end

  a2a do
    skill(:respond_to_prompt, :respond_to_prompt)
  end
end
```

Nothing in this module names `zai_coder` or `glm-5.3-flash` — only the role
`:semantic_reasoner`. This mirrors the real fixture in
`test/support/llm_profiles_fixture.ex`
(`AshA2A.Test.Fixture.SemanticReasoner`), exercised end to end by
`test/ash_a2a_llm_profiles_test.exs` with a real, live LLM call over a real
`A2A.Agent.call/2` dispatch.

## 3. Switch providers with a config-only change

To move `:semantic_reasoner` from `zai_coder` to a different provider, edit
only the config:

```elixir
config :ash_a2a, :llm_profiles,
  semantic_reasoner: [
    provider: :groq,
    model: "llama-3.3-70b",
    max_tokens: 2048
  ]
```

No `.ex` file changes. The action's `run(prompt(...))` call is unchanged —
`model_spec!/1` and `req_llm_opts!/1` re-resolve to the new provider the next
time the action runs.

## What happens if you forget to configure the role

`AshA2A.LLMProfiles` is fail-closed: an unconfigured role raises
`ArgumentError` naming exactly which role is missing, rather than silently
falling back to a default provider. From
`test/ash_a2a_llm_profiles_test.exs`:

```elixir
assert_raise ArgumentError, ~r/no LLM profile configured for role :nonexistent_role/, fn ->
  AshA2A.LLMProfiles.model_spec!(:nonexistent_role)
end
```

The raised message also lists every role that *is* currently configured, so
the fix is visible immediately:

```
no LLM profile configured for role :nonexistent_role -- add
`config :ash_a2a, :llm_profiles, nonexistent_role: [provider: ..., model: ...]`.
Currently configured roles: [:semantic_reasoner]
```

This is a deliberate design choice: a missing role configuration must never
be papered over with a guessed provider. If you see this error, add the
missing role's `provider:`/`model:` (and any call options) to
`config :ash_a2a, :llm_profiles` for the environment you're running in.
