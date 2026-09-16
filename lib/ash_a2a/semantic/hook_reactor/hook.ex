defmodule AshA2A.Semantic.HookReactor.Hook do
  @moduledoc """
  A Knowledge Hook as a semantic artifact (RFC-SA2A-002 §61).

  A hook is a condition over a graph delta plus an intent *template*. It
  carries no authority and performs no actuation: when it fires, the only
  thing it can produce is a candidate `AshA2A.Semantic.HookReactor.Intent`
  (RFC-SA2A-001 knowledge hooks: `Hook ≠ DO`, `HookOutput ⇒ SemanticIntent`,
  `SemanticIntent ⇏ Authority`).

  ## Fields

    * `:id`, `:revision` -- hook identity
    * `:trigger` -- an N3 document holding exactly one denial rule
      `{ BODY } => false .` (plus optional `@prefix` lines), evaluated by the
      real GraphLaw engine over the delta alone
    * `:guard` -- optional second denial rule of the same shape, evaluated
      over the post-state (base ∪ every delta admitted so far)
    * `:witness` -- a Turtle graph the author claims satisfies trigger (and
      guard); meta-admission checks that claim against the real engine
    * `:condition_digest` -- the author-declared condition identity; must
      equal `condition_digest/1` of the trigger and guard actually carried
    * `:intent` -- `%{capability_id: String.t(), input: map()}`; never
      authority
    * `:provenance` -- `%{source: String.t(), author: String.t()}`

  Trigger and guard are independent boolean conditions: the engine's
  N3_DENIAL dialect reports whether a denial body has *any* binding, not the
  bindings themselves, so no variable is shared between them.
  """

  alias AshA2A.Authority

  @enforce_keys [:id, :revision, :trigger, :witness, :intent, :provenance]
  defstruct [:id, :revision, :trigger, :guard, :witness, :condition_digest, :intent, :provenance]

  @type t :: %__MODULE__{
          id: String.t(),
          revision: pos_integer(),
          trigger: String.t(),
          guard: String.t() | nil,
          witness: String.t(),
          condition_digest: String.t() | nil,
          intent: %{capability_id: String.t(), input: map()},
          provenance: map()
        }

  @type refusal :: %{required(:code) => atom(), optional(:detail) => term()}

  @id_format ~r/^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$/
  @denial ~r/\A\s*\{[^{}]*\}\s*=>\s*false\s*\.\s*\z/s
  @prefix_line ~r/^\s*@prefix\s+[A-Za-z0-9_\-]*:\s*<[^>\s]*>\s*\.\s*$/m
  @comment_line ~r/^\s*#.*$/m

  @doc "Builds a hook, declaring its condition identity from the carried trigger/guard."
  @spec new(keyword() | map()) :: t()
  def new(fields) do
    hook = struct!(__MODULE__, Map.new(fields))
    %{hook | condition_digest: hook.condition_digest || condition_digest(hook)}
  end

  @doc "Condition identity: SHA-256 over the trigger and guard text actually carried."
  @spec condition_digest(t()) :: String.t()
  def condition_digest(%__MODULE__{trigger: trigger, guard: guard}) do
    sha256(["sa2a-hook-condition/1", 0, to_string(trigger), 0, to_string(guard)])
  end

  @doc """
  Full hook identity: id, revision, condition, witness, intent template and
  provenance. Admission records this digest; any later mutation of any of
  those fields yields a different digest and therefore no admitted standing.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = hook) do
    term =
      {"sa2a-hook/1", hook.id, hook.revision, hook.trigger, hook.guard, hook.witness,
       hook.condition_digest, canonical(hook.intent), canonical(hook.provenance)}

    term |> :erlang.term_to_binary([:deterministic]) |> sha256()
  end

  @doc """
  Structural meta-admission checks that need no engine (§61): identity,
  provenance, condition shape, condition identity, intent shape, and the
  absence of any authority in the intent template.
  """
  @spec validate(t() | term()) :: :ok | {:error, refusal()}
  def validate(%__MODULE__{} = hook) do
    with :ok <- identity(hook),
         :ok <- provenance(hook.provenance),
         :ok <- condition_shape(:trigger, hook.trigger),
         :ok <- guard_shape(hook.guard),
         :ok <- condition_identity(hook),
         :ok <- intent_shape(hook.intent),
         :ok <- no_authority(hook.intent) do
      witness(hook.witness)
    end
  end

  def validate(other), do: {:error, %{code: :hook_identity_invalid, detail: inspect(other)}}

  defp identity(%__MODULE__{id: id, revision: revision}) do
    if is_binary(id) and Regex.match?(@id_format, id) and is_integer(revision) and revision > 0,
      do: :ok,
      else: {:error, %{code: :hook_identity_invalid, detail: %{id: id, revision: revision}}}
  end

  defp provenance(%{} = provenance) do
    source = Map.get(provenance, :source) || Map.get(provenance, "source")
    author = Map.get(provenance, :author) || Map.get(provenance, "author")

    if non_empty?(source) and non_empty?(author),
      do: :ok,
      else: {:error, %{code: :hook_provenance_missing, detail: "source and author are required"}}
  end

  defp provenance(_), do: {:error, %{code: :hook_provenance_missing, detail: "no provenance"}}

  defp guard_shape(nil), do: :ok
  defp guard_shape(guard), do: condition_shape(:guard, guard)

  @doc false
  @spec condition_shape(atom(), term()) :: :ok | {:error, refusal()}
  def condition_shape(role, text) when is_binary(text) do
    body =
      text
      |> String.replace(@comment_line, "")
      |> String.replace(@prefix_line, "")

    if Regex.match?(@denial, body),
      do: :ok,
      else:
        {:error,
         %{
           code: :hook_condition_invalid,
           detail: "#{role} must be exactly one `{ BODY } => false .` denial rule"
         }}
  end

  def condition_shape(role, _),
    do: {:error, %{code: :hook_condition_invalid, detail: "#{role} is not text"}}

  defp condition_identity(%__MODULE__{condition_digest: declared} = hook) do
    actual = condition_digest(hook)

    if declared == actual,
      do: :ok,
      else:
        {:error,
         %{code: :hook_condition_identity_mismatch, detail: %{declared: declared, actual: actual}}}
  end

  defp intent_shape(%{capability_id: capability, input: input})
       when is_binary(capability) and capability != "" and is_map(input),
       do: :ok

  defp intent_shape(other), do: {:error, %{code: :hook_intent_invalid, detail: inspect(other)}}

  defp no_authority(intent) do
    if carries_authority?(intent),
      do:
        {:error,
         %{
           code: :hook_authority_forbidden,
           detail: "a hook intent template may not carry authority"
         }},
      else: :ok
  end

  defp carries_authority?(%Authority{}), do: true

  defp carries_authority?(%{} = map) when not is_struct(map) do
    Enum.any?(map, fn {k, v} -> authority_key?(k) or carries_authority?(v) end)
  end

  defp carries_authority?(list) when is_list(list), do: Enum.any?(list, &carries_authority?/1)

  defp carries_authority?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> carries_authority?()

  defp carries_authority?(_), do: false

  defp authority_key?(k) when is_atom(k) or is_binary(k),
    do: String.downcase(to_string(k)) in ["authority", "grant", "token_id"]

  defp authority_key?(_), do: false

  defp witness(text) when is_binary(text) do
    case RDF.Turtle.read_string(text) do
      {:ok, %RDF.Graph{} = graph} ->
        if RDF.Graph.triple_count(graph) > 0,
          do: :ok,
          else: {:error, %{code: :hook_witness_invalid, detail: "witness graph is empty"}}

      {:error, reason} ->
        {:error, %{code: :hook_witness_invalid, detail: inspect(reason)}}
    end
  rescue
    error -> {:error, %{code: :hook_witness_invalid, detail: Exception.message(error)}}
  end

  defp witness(_), do: {:error, %{code: :hook_witness_invalid, detail: "witness is not text"}}

  defp canonical(%{} = map) when not is_struct(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha256(iodata), do: :crypto.hash(:sha256, iodata) |> Base.encode16(case: :lower)
end
