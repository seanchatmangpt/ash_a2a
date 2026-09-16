defmodule AshA2A.Authority.Decision do
  @moduledoc """
  A host-portable, canonically-serializable authority decision (RFC-SA2A-001
  S28 authority ceiling, S30 typed refusal, S60 decision evidence).

  This module exists for one reason: so the authority verdict for a command
  can be *re-derived on a host that shares no code with the BEAM* and be
  shown to reach the identical typed refusal. It is a function of a
  serializable envelope plus the deciding host's own clock -- no process
  state, no registry lookup.

  ## Three things the caller is deliberately not allowed to decide

  Every one of these was a reproduced fail-OPEN defect in the first version
  of this module, and each is now closed on *both* hosts (see
  `test/support/hosts/authority_host.mjs` and the shared conformance vectors
  at `test/support/hosts/authority_decision_conformance.json`):

    * **Presence is required, absence never binds.** `binds?/2` used to
      compare fields with `==`, so an authority object with *no* fields bound
      to an envelope with *no* principal (`nil == nil`), and a real actuator
      fired. Every field that participates in binding -- `"principal"`,
      `"capability_id"`, the authority's `"subject"` and `"capability_id"` --
      must now be a present, non-blank string, or the verdict is a refusal.

    * **The caller does not classify its own consequence.** Declaring
      `"consequence" => "observe"` used to skip the authority branch outright.
      The real enforcement point (`AshA2A.CommandBus.run/4` via
      `AshA2A.Info.skill/2`'s `skill.consequence`) takes the classification
      from the resource DSL, never from the request. `envelope/3` now does
      the same when handed a resource or domain module, stamping the
      DSL-derived value into `"capability_consequence"`; `verdict/1` refuses
      (`:consequence_unattested`) when the declared consequence disagrees
      with that attestation, and refuses an *unattested* `"observe"` outright
      rather than letting a self-declaration buy an authority bypass.

    * **The constrained party does not pick the clock.** Expiry used to be
      judged against the envelope's own `"evaluated_at"` -- carried inside
      the very message being judged. It is now judged against the deciding
      host's real clock (`DateTime.utc_now/0`, matching
      `AshA2A.Authority.expired?/1`), *and* additionally against
      `"evaluated_at"` when that instant is itself past expiry, so a caller's
      own stated instant can only ever close the gate further, never open it.
      `"evaluated_at"` must still be present and parseable: an envelope that
      does not say when it was evaluated is unjudgeable and fails closed.

  The two hosts implement these rules independently. They cannot be *made*
  identical without a code-generation step across the BEAM/Node boundary, so
  instead they are *pinned* identical: one shared, version-controlled vector
  file is executed by both, and any drift fails the suite.

  ## This module is NOT the enforcement point

  `AshA2A.CommandBus.run/4` remains the only enforcement boundary. `verdict/1`
  mirrors `CommandBus`'s own `admit/2` + `AshA2A.Authority.admits?/2` rules,
  and `test/ash_a2a_authority_non_implications_test.exs` pins the two
  together against the real bus rather than trusting this docstring: if the
  bus's rules change and this module's do not, that test fails.

  ## Canonical form

  `canonical_json/1` emits recursively key-sorted JSON with no insignificant
  whitespace, so `digest/1` is a stable content address for the decision
  *input* across hosts (the SA2A `O*_input,A = O*_input,B` precondition).
  """

  alias AshA2A.{Authority, Command, Identity}

  @envelope_version "sa2a-authority-decision/1"

  # The classifications the real DSL can emit (`AshA2A.Dsl`'s
  # `{:one_of, [:observe, :change, :external_do, :unknown]}`). `:unknown` is
  # deliberately NOT admissible here, exactly as `CommandBus.admit/2` refuses
  # it with `:consequence_unclassified`.
  @declarable_consequences [:observe, :change, :external_do, :unknown]
  @classified ["observe", "change", "external_do"]
  @consequence_bearing ["change", "external_do"]

  @typedoc "Typed verdict. `:admitted` is permission to *attempt* DO, nothing more."
  @type verdict ::
          {:admitted, %{code: :authority_admitted}}
          | {:refused, %{code: atom(), detail: String.t()}}

  @doc "The envelope format version this module reads and writes."
  @spec envelope_version() :: String.t()
  def envelope_version, do: @envelope_version

  @doc """
  Projects a real `AshA2A.Command` into the canonical, JSON-safe decision
  envelope.

  The second argument is either:

    * **a resource or domain module** -- the attested form, and the one to
      prefer. The consequence is read from the real resource DSL through
      `AshA2A.Info.skill/2`, exactly as `AshA2A.CommandBus.run/4` reads it,
      and is stamped into both `"consequence"` and `"capability_consequence"`.
      A capability that does not resolve yields `nil` for both, which
      `verdict/1` refuses as `:consequence_unclassified` -- fail-closed, not
      an exception.

    * **a consequence atom** (`:observe` / `:change` / `:external_do` /
      `:unknown`) -- the *unattested* form, kept for callers that genuinely
      have no resource in hand. `"capability_consequence"` is `nil`, and
      `verdict/1` will not admit an unattested `"observe"`: a self-declared
      non-consequence is exactly the fail-open this module closes.

  `:evaluated_at` (a `DateTime`) may be supplied so a caller pins the instant
  the decision is made; it defaults to now. It is envelope evidence and is
  never allowed to *extend* an authority's life -- see `verdict/1`.
  """
  @spec envelope(Command.t(), atom() | module(), keyword()) :: map()
  def envelope(command, consequence_or_resource, opts \\ [])

  def envelope(%Command{} = command, consequence, opts)
      when consequence in @declarable_consequences do
    build_envelope(command, Atom.to_string(consequence), nil, opts)
  end

  def envelope(%Command{} = command, resource_or_domain, opts) when is_atom(resource_or_domain) do
    attested = attested_consequence(resource_or_domain, command.capability_id)
    build_envelope(command, attested, attested, opts)
  end

  # Mirrors `AshA2A.CommandBus.inspect_target/2`: the classification is the
  # resource's own, never the request's. An unresolvable capability produces
  # no classification at all rather than a permissive guess.
  defp attested_consequence(resource_or_domain, capability_id) do
    case AshA2A.Info.skill(resource_or_domain, capability_id) do
      {:ok, %{consequence: consequence}} when consequence in @declarable_consequences ->
        Atom.to_string(consequence)

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp build_envelope(%Command{} = command, consequence, attested, opts) do
    evaluated_at = Keyword.get(opts, :evaluated_at, DateTime.utc_now())

    %{
      "envelope_version" => @envelope_version,
      "agent" => Identity.external(command.agent_id),
      "authority" => authority_envelope(command.authority),
      "capability_consequence" => attested,
      "capability_id" => command.capability_id,
      "command_fingerprint" => command.fingerprint,
      "consequence" => consequence,
      "evaluated_at" => DateTime.to_iso8601(evaluated_at),
      "principal" => Identity.external(command.principal_id),
      "task" => command.task_id && Identity.external(command.task_id)
    }
  end

  defp authority_envelope(nil), do: nil

  defp authority_envelope(%Authority{} = authority) do
    %{
      "capability_id" => authority.capability_id,
      "expires_at" => authority.expires_at && DateTime.to_iso8601(authority.expires_at),
      "source" => to_string(authority.source),
      "subject" => Identity.external(authority.subject),
      "token" => Identity.external(authority.token_id)
    }
  end

  @doc """
  Evaluates the envelope against the deciding host's own clock.

  Mirrors `AshA2A.CommandBus`'s admission rules:

    * an envelope missing a present, non-blank `"principal"` or
      `"capability_id"` -> `:envelope_incomplete`. There is no operation to
      judge, so there is nothing to admit.
    * a consequence that is absent, blank, or outside
      `observe | change | external_do` -> `:consequence_unclassified` (the
      DSL's fail-closed `:unknown` lands here, as it does on the bus).
    * a declared consequence that contradicts the DSL-derived
      `"capability_consequence"`, or an `"observe"` with no such attestation
      -> `:consequence_unattested`. The request does not get to classify
      itself out of the authority branch.
    * attested `observe` needs no authority.
    * `change` / `external_do` with no authority -> `:authority_required`.
    * `change` / `external_do` whose authority does not bind the *same*,
      *present* principal and the *same*, *present* capability, or which has
      expired as of the deciding host's real clock (or as of the envelope's
      own `"evaluated_at"`, whichever is later) -> `:authority_mismatch`.

  Note what is deliberately absent from the rule set: identity,
  authentication source, task assignment, plan validity, proof, model
  confidence, and agent-card declaration are all *present in the envelope*
  yet none of them appear in any admitting branch (RFC S29).

      iex> AshA2A.Authority.Decision.verdict(%{
      ...>   "envelope_version" => AshA2A.Authority.Decision.envelope_version(),
      ...>   "consequence" => "external_do",
      ...>   "authority" => %{}
      ...> })
      {:refused, %{code: :envelope_incomplete, detail: "envelope_incomplete"}}
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{"envelope_version" => @envelope_version} = envelope) do
    with :ok <- require_present(envelope, "principal"),
         :ok <- require_present(envelope, "capability_id"),
         {:ok, consequence} <- classify(envelope) do
      if consequence in @consequence_bearing do
        consequence_verdict(envelope)
      else
        admitted()
      end
    else
      {:refused, _detail} = refusal -> refusal
    end
  end

  def verdict(_envelope), do: refused(:decision_envelope_unrecognized)

  defp require_present(envelope, key) do
    if present?(Map.get(envelope, key)), do: :ok, else: refused(:envelope_incomplete)
  end

  # Absence never satisfies anything. A blank string is absence with
  # punctuation.
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The real enforcement point reads the classification off the resource DSL.
  # Here it must at minimum be *consistent* with the DSL-derived attestation
  # the BEAM stamped into the envelope, and an unattested `observe` -- the
  # only classification that skips the authority branch entirely -- is never
  # taken on the request's word.
  defp classify(envelope) do
    declared = Map.get(envelope, "consequence")
    attested = Map.get(envelope, "capability_consequence")

    cond do
      not present?(declared) or declared not in @classified ->
        refused(:consequence_unclassified)

      present?(attested) and attested != declared ->
        refused(:consequence_unattested)

      declared not in @consequence_bearing and attested != declared ->
        refused(:consequence_unattested)

      true ->
        {:ok, declared}
    end
  end

  defp consequence_verdict(envelope) do
    case Map.get(envelope, "authority") do
      nil ->
        refused(:authority_required)

      authority when is_map(authority) ->
        if binds?(authority, envelope), do: admitted(), else: refused(:authority_mismatch)

      _ ->
        refused(:authority_mismatch)
    end
  end

  defp binds?(authority, envelope) do
    same?(Map.get(authority, "subject"), Map.get(envelope, "principal")) and
      same?(Map.get(authority, "capability_id"), Map.get(envelope, "capability_id")) and
      not expired?(Map.get(authority, "expires_at"), Map.get(envelope, "evaluated_at"))
  end

  # `nil == nil` is not a match; it is two absences. Both sides must really
  # be there before sameness means anything.
  defp same?(left, right), do: present?(left) and present?(right) and left == right

  # An envelope that does not parseably say when it was evaluated is
  # unjudgeable, and unjudgeable fails closed -- the same way an unparseable
  # `expires_at` already did.
  defp expired?(expires_at, evaluated_at) do
    case parse_instant(evaluated_at) do
      {:ok, evaluated} -> expired_at?(expires_at, evaluated)
      :error -> true
    end
  end

  defp expired_at?(nil, _evaluated), do: false

  defp expired_at?(expires_at, evaluated) do
    case parse_instant(expires_at) do
      # Unparseable timestamps fail closed: treat as expired.
      :error ->
        true

      {:ok, expires} ->
        # Real host time, as `AshA2A.Authority.expired?/1` uses. The
        # envelope's own instant is consulted only when it is *later*, so
        # the constrained party can close the gate on itself but never hold
        # it open by naming a convenient past.
        DateTime.compare(DateTime.utc_now(), expires) == :gt or
          DateTime.compare(evaluated, expires) == :gt
    end
  end

  defp parse_instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> {:ok, instant}
      _error -> :error
    end
  end

  defp parse_instant(_value), do: :error

  defp admitted, do: {:admitted, %{code: :authority_admitted}}
  defp refused(code), do: {:refused, %{code: code, detail: Atom.to_string(code)}}

  @doc """
  Canonical JSON: recursively key-sorted, no insignificant whitespace.

      iex> AshA2A.Authority.Decision.canonical_json(%{"b" => 1, "a" => [true, nil]})
      ~s({"a":[true,null],"b":1})
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: IO.iodata_to_binary(encode(value))

  defp encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ?:, encode(v)] end)
      |> Enum.intersperse(?,)

    [?{, inner, ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, list |> Enum.map(&encode/1) |> Enum.intersperse(?,), ?]]

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_binary(value), do: JSON.encode!(value)
  defp encode(value) when is_atom(value), do: JSON.encode!(Atom.to_string(value))

  @doc "SHA-256 hex of `canonical_json/1` -- a stable cross-host content address."
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
