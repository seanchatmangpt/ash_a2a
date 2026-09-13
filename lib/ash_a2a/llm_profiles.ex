defmodule AshA2A.LLMProfiles do
  @moduledoc """
  Role-based LLM provider resolution: an Ash action declares an abstract
  role (e.g. `:semantic_reasoner`), never a provider/model string directly.
  `config :ash_a2a, :llm_profiles` maps that role to a concrete
  `req_llm`/`ash_ai` model spec + call options at runtime.

  This is the seal between capability semantics and provider identity:

      A2ACapabilityIdentity != ModelProviderIdentity

  Switching providers is a config change (`config/*.exs`), never a source
  change to any Ash action's `run(prompt(...))` call. No filesystem,
  network, or shell access happens in this module -- it is a pure config
  lookup, fail-closed (raises, naming the missing role, rather than
  silently defaulting to some provider) per the
  `CONFIGURATION_MISSING -> BLOCKED` discipline: a missing role
  configuration must never be papered over with a guessed provider.

  ## Configuration

      config :ash_a2a, :llm_profiles,
        semantic_reasoner: [
          provider: :zai_coder,
          model: "glm-5.3-flash",
          max_tokens: 4096
        ]

  ## Usage in an Ash action

      action :respond_to_prompt, :map do
        run(
          prompt(
            AshA2A.LLMProfiles.model_spec!(:semantic_reasoner),
            prompt: {...},
            req_llm_opts: AshA2A.LLMProfiles.req_llm_opts!(:semantic_reasoner)
          )
        )
      end

  The action's own source never names `zai_coder`, `groq`, `openai`, or any
  other provider -- only the role.
  """

  @type role :: atom()

  @doc """
  The `"provider:model"` spec string for `role`, e.g. `"zai_coder:glm-5.3-flash"`.
  Raises `ArgumentError` naming the missing role if unconfigured -- never
  silently falls back to a default provider.
  """
  @spec model_spec!(role()) :: String.t()
  def model_spec!(role) do
    profile = fetch_profile!(role)
    provider = Keyword.fetch!(profile, :provider)
    model = Keyword.fetch!(profile, :model)
    "#{provider}:#{model}"
  end

  @doc """
  The real call options (e.g. `max_tokens`, `timeout`) configured for
  `role`, suitable for merging into `req_llm_opts:`. Provider/model keys
  are stripped -- callers get only the options `prompt/2`'s `req_llm_opts:`
  actually accepts.
  """
  @spec req_llm_opts!(role()) :: keyword()
  def req_llm_opts!(role) do
    role
    |> fetch_profile!()
    |> Keyword.drop([:provider, :model])
  end

  defp fetch_profile!(role) when is_atom(role) do
    profiles = Application.get_env(:ash_a2a, :llm_profiles, [])

    case Keyword.fetch(profiles, role) do
      {:ok, profile} ->
        profile

      :error ->
        configured = profiles |> Keyword.keys() |> inspect()

        raise ArgumentError,
              "no LLM profile configured for role #{inspect(role)} -- " <>
                "add `config :ash_a2a, :llm_profiles, #{role}: [provider: ..., model: ...]`. " <>
                "Currently configured roles: #{configured}"
    end
  end
end
