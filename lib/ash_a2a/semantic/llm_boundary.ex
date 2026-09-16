defmodule AshA2A.Semantic.LlmBoundary do
  @moduledoc """
  RFC S40, the fundamental relation, enforced structurally:

      LLMOutput => Candidate        and NEVER        LLMOutput => Standing

  This module is the single seam through which raw model output becomes a
  term the rest of `AshA2A` will touch. It has exactly one constructor
  (`candidate/3`) and that constructor hard-codes
  `standing: :candidate, authority: :none` -- there is no option, config
  key, or alternate clause that produces anything else. "The LLM cannot
  grant itself standing" is therefore a property of the type, not of a
  policy check.

  ## The seven prohibited effects

  An LLM MUST NOT, by model output alone:

    1. `:admit_fact` -- admit a fact (move anything from candidate to
       admitted standing).
    2. `:create_canonical_identity` -- mint canonical semantic identity
       (a graph digest, a canonical id). Canonical identity comes from
       RFC S12 canonicalization over a real graph, never from a model
       asserting a hash.
    3. `:grant_authority` -- issue or widen an `AshA2A.Authority`.
    4. `:alter_canonical_state` -- commit to canonical state.
    5. `:promote_own_rule` -- promote its own proposed rule into the
       admitted rule set.
    6. `:modify_root_manifest` -- edit a Root Manifest.
    7. `:execute_consequential_do` -- execute consequential DO in Strict.

  `attempt/2` is a total function over those seven: **every** clause
  returns `{:error, ...}`. There is no success clause to find, no
  `:force` option, and no privileged caller. A future regression that
  wanted to permit one of these would have to add a success clause,
  which is exactly the kind of change a reviewer can see.

  ## The claim scan

  `candidate/3` additionally refuses raw output that *asks* for any of
  the seven, by scanning the decoded model payload at any depth for the
  specific keys a model would have to emit to claim one (`"standing"`,
  `"authority"`, `"graph_digest"`, `"root_manifest"`, ...). This is
  belt-and-braces, not the primary mechanism: even if the scan missed a
  key, the constructed `Resolution` still carries
  `standing: :candidate, authority: :none`, because those fields are not
  read from the payload at all. The scan exists so a model that *tries*
  produces a loud, typed, receiptable refusal instead of a silently
  ignored field.

  The scan matches **exact** keys only. `"authorities"` (the plural key
  `AshA2A.Semantic.Admission` already requires on a real semantic IR) is
  deliberately not a match, so this boundary does not break the existing
  `AshA2A.Semantic.Compiler` payload shape.
  """

  alias AshA2A.Semantic.Unknown
  alias AshA2A.Semantic.Unknown.Resolution

  @prohibited_effects ~w(
    admit_fact
    create_canonical_identity
    grant_authority
    alter_canonical_state
    promote_own_rule
    modify_root_manifest
    execute_consequential_do
  )a

  # Exact payload keys that would constitute a model claiming one of the
  # seven prohibited effects, mapped to the effect each one claims.
  @claim_keys %{
    "standing" => :admit_fact,
    "admitted" => :admit_fact,
    "admission" => :admit_fact,
    "canonical_id" => :create_canonical_identity,
    "canonical_identity" => :create_canonical_identity,
    "graph_digest" => :create_canonical_identity,
    "authority" => :grant_authority,
    "token_id" => :grant_authority,
    "authority_grant" => :grant_authority,
    "canonical_state" => :alter_canonical_state,
    "commit" => :alter_canonical_state,
    "promote_rule" => :promote_own_rule,
    "rule_promotion" => :promote_own_rule,
    "root_manifest" => :modify_root_manifest,
    "execute" => :execute_consequential_do,
    "dispatch" => :execute_consequential_do
  }

  @doc "The seven effects an LLM may never produce by model output alone (RFC S40)."
  @spec prohibited_effects() :: [atom()]
  def prohibited_effects, do: @prohibited_effects

  @doc """
  Total refusal function over the seven prohibited effects. Every listed
  effect returns `{:error, ...}`; an unrecognized effect atom also fails
  closed (`:unknown_llm_effect`) rather than defaulting to permitted.
  """
  @spec attempt(atom(), term()) :: {:error, map()}
  def attempt(effect, payload \\ nil)

  def attempt(effect, payload) when effect in @prohibited_effects do
    {:error,
     %{
       code: :llm_effect_refused,
       effect: effect,
       detail: detail(effect),
       payload: payload
     }}
  end

  def attempt(effect, payload) do
    {:error,
     %{
       code: :unknown_llm_effect,
       effect: effect,
       detail: "unrecognized effect fails closed; LLM output is never permitted by default",
       payload: payload
     }}
  end

  @doc """
  The sole constructor turning raw model output into something the rest
  of the system will accept: an `AshA2A.Semantic.Unknown.Resolution`
  with `standing: :candidate, authority: :none`, always.

  `resolver` records which kind of resolver produced the payload (RFC
  S37: resolution may come from an LLM, a human, a prover, a search, a
  synthesis, or an experiment -- and the result returns as CANDIDATE in
  every case, so every kind goes through this same constructor).

  Refuses with `:llm_standing_claim_refused` (carrying the offending key
  and the prohibited effect it maps to) when the payload itself claims
  one of the seven.
  """
  @spec candidate(Unknown.t(), Unknown.resolver_kind(), map()) ::
          {:ok, Resolution.t()} | {:error, map()}
  def candidate(%Unknown{} = unknown, resolver, payload)
      when is_map(payload) and not is_struct(payload) do
    case scan_claim(payload) do
      nil ->
        Resolution.new(unknown, resolver, payload)

      {key, effect} ->
        {:error,
         %{
           code: :llm_standing_claim_refused,
           key: key,
           effect: effect,
           detail: detail(effect),
           class: unknown.class
         }}
    end
    |> emit_candidate(unknown, resolver)
  end

  def candidate(%Unknown{} = unknown, resolver, payload) do
    {:error, %{code: :llm_output_not_a_map, payload: payload}}
    |> emit_candidate(unknown, resolver)
  end

  # `[:ash_a2a, :semantic, :llm_boundary, :candidate]`: the boundary's
  # decision over one piece of resolver output -- the candidate it built
  # (with the standing/authority that candidate actually carries) or the
  # typed refusal (RFC-SA2A-002 §79/§81 evidence). Observational only.
  defp emit_candidate(result, %Unknown{} = unknown, resolver) do
    meta =
      case result do
        {:ok, %Resolution{} = resolution} ->
          %{
            outcome: :candidate,
            standing: resolution.standing,
            authority: resolution.authority,
            fingerprint: resolution.fingerprint
          }

        {:error, reason} ->
          %{
            outcome: :refused,
            code: Map.get(reason, :code),
            effect: Map.get(reason, :effect),
            key: Map.get(reason, :key)
          }
      end

    :telemetry.execute(
      [:ash_a2a, :semantic, :llm_boundary, :candidate],
      %{count: 1},
      Map.merge(meta, %{class: unknown.class, resolver: resolver})
    )

    result
  end

  @doc """
  Structural re-check of an already-built resolution. Returns `:ok` only
  for `standing: :candidate, authority: :none`; anything else is
  `:llm_authority_ceiling_violated`. Mirrors the `fence/1` idiom
  `AshA2A.Semantic.Admission` and `AshA2A.Planning` already use.
  """
  @spec fence(Resolution.t()) :: :ok | {:error, map()}
  def fence(%Resolution{standing: :candidate, authority: :none}), do: :ok

  def fence(%Resolution{} = resolution) do
    {:error,
     %{
       code: :llm_authority_ceiling_violated,
       standing: resolution.standing,
       authority: resolution.authority
     }}
  end

  @doc """
  Real recursive scan of a decoded model payload for an exact claim key
  at any depth. Returns `{key, effect}` for the first match (maps are
  walked key-first so the shallowest claim wins deterministically for a
  single-level payload), or `nil`.

  Only ever walks **plain** maps and lists; any other term -- structs
  included -- is not a container and not a match, so the scan never
  raises on arbitrary decoded input.

  A struct is deliberately a leaf, not a container: `is_map/1` is true
  for a struct but `Enumerable` is not implemented for most of them
  (`DateTime`, `Decimal`, `AshA2A.Authority`, ...), so walking one with
  `Enum.find_value/2` raises `Protocol.UndefinedError`. A raise here is
  strictly worse than a miss, because it *pre-empts* the refusal the
  scan exists to produce: a payload carrying both a struct value and a
  forged `"authority"` key would crash instead of refusing whenever map
  iteration reached the struct first, making the refusal
  order-dependent. Struct fields are never model-decoded JSON anyway --
  a decoder produces plain maps -- so treating a struct as a leaf loses
  no real claim.
  """
  @spec scan_claim(term()) :: {String.t(), atom()} | nil
  def scan_claim(value) when is_struct(value), do: nil

  def scan_claim(value) when is_map(value) and not is_struct(value) do
    Enum.find_value(value, fn {key, nested} ->
      case Map.fetch(@claim_keys, normalize_key(key)) do
        {:ok, effect} -> {normalize_key(key), effect}
        :error -> scan_claim(nested)
      end
    end)
  end

  def scan_claim(value) when is_list(value), do: Enum.find_value(value, &scan_claim/1)
  def scan_claim(_other), do: nil

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp detail(:admit_fact),
    do: "model output may not admit a fact; admission is deterministic (LLMOutput => Candidate)"

  defp detail(:create_canonical_identity),
    do: "canonical semantic identity comes from canonicalization over a real graph, not a model"

  defp detail(:grant_authority),
    do: "authority is bound to a principal by a broker; model output never issues or widens it"

  defp detail(:alter_canonical_state),
    do: "canonical state changes only through the receipted consequence boundary"

  defp detail(:promote_own_rule),
    do: "a model may not promote its own proposed rule into the admitted rule set"

  defp detail(:modify_root_manifest),
    do: "a Root Manifest is not editable by model output"

  defp detail(:execute_consequential_do),
    do: "consequential DO in Strict requires admitted authority; model output carries none"
end
