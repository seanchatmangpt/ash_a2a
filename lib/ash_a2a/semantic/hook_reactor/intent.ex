defmodule AshA2A.Semantic.HookReactor.Intent do
  @moduledoc """
  A candidate SemanticIntent produced by a fired Knowledge Hook.

      HookOutput ⇒ SemanticIntent        SemanticIntent ⇏ Authority

  The struct deliberately has no authority field: an intent names *what* a
  hook asks for (capability + input), never *who may* do it. Authority is
  decided later, per intent, by the configured `AshA2A.Authority.Broker`, and
  consequence only happens if `AshA2A.CommandBus` admits the resulting
  command. `standing` is always `:candidate`.

  ## Identity (RFC-SA2A-002 §62)

  `intent_id` is a SHA-256 over the admitted hook digest, the canonical
  (RDFC-1.0) digest of the triggering delta and the intent template -- not
  over the delta's bytes, its triple order, its prefix labels or its blank
  node labels, and not over the generation or wall-clock time. The same
  admitted hook over the same delta therefore always yields the same intent,
  and the command routed for it (`command_id/1`) carries that identity into
  `AshA2A.CommandBus`'s claim/replay protection, so duplicate delivery cannot
  multiply consequence.
  """

  alias AshA2A.Semantic.HookReactor.Hook

  @enforce_keys [
    :intent_id,
    :hook_id,
    :hook_revision,
    :hook_digest,
    :delta_digest,
    :generation,
    :capability_id,
    :input
  ]
  defstruct [
    :intent_id,
    :hook_id,
    :hook_revision,
    :hook_digest,
    :delta_digest,
    :generation,
    :capability_id,
    :input,
    standing: :candidate
  ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          hook_id: String.t(),
          hook_revision: pos_integer(),
          hook_digest: String.t(),
          delta_digest: String.t(),
          generation: pos_integer(),
          capability_id: String.t(),
          input: map(),
          standing: :candidate
        }

  @doc "Builds the candidate intent for `hook` firing over the delta with `delta_digest`."
  @spec build(Hook.t(), String.t(), String.t(), pos_integer()) :: t()
  def build(%Hook{} = hook, hook_digest, delta_digest, generation)
      when is_binary(hook_digest) and is_binary(delta_digest) do
    template = Map.new(hook.intent.input, fn {k, v} -> {to_string(k), v} end)

    intent_id =
      {"sa2a-hook-intent/1", hook.id, hook.revision, hook_digest, delta_digest,
       hook.intent.capability_id, Enum.sort(template)}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %__MODULE__{
      intent_id: intent_id,
      hook_id: hook.id,
      hook_revision: hook.revision,
      hook_digest: hook_digest,
      delta_digest: delta_digest,
      generation: generation,
      capability_id: hook.intent.capability_id,
      input: Map.put(template, "cause", intent_id)
    }
  end

  @doc "The command identity an intent is routed under."
  @spec command_id(t()) :: String.t()
  def command_id(%__MODULE__{intent_id: id}), do: "hook-intent-" <> id
end
