defmodule AshA2A.Authority.Decision do
  @moduledoc """
  A host-portable, canonically-serializable authority decision (RFC-SA2A-001
  S28 authority ceiling, S30 typed refusal, S60 decision evidence).

  This module exists for one reason: so the authority verdict for a command
  can be *re-derived on a host that shares no code with the BEAM* and be
  shown to reach the identical typed refusal. It is deliberately a pure
  function of a serializable envelope -- no process state, no clock, no
  registry lookup. Even expiry is decided against the envelope's own
  `"evaluated_at"`, so two hosts with different clocks still agree.

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

  @typedoc "Typed verdict. `:admitted` is permission to *attempt* DO, nothing more."
  @type verdict ::
          {:admitted, %{code: :authority_admitted}}
          | {:refused, %{code: atom(), detail: String.t()}}

  @doc "The envelope format version this module reads and writes."
  @spec envelope_version() :: String.t()
  def envelope_version, do: @envelope_version

  @doc """
  Projects a real `AshA2A.Command` and its skill consequence into the
  canonical, JSON-safe decision envelope.

  `:evaluated_at` (a `DateTime`) may be supplied so a caller pins the instant
  the decision is made; it defaults to now.
  """
  @spec envelope(Command.t(), atom(), keyword()) :: map()
  def envelope(%Command{} = command, consequence, opts \\ []) when is_atom(consequence) do
    evaluated_at = Keyword.get(opts, :evaluated_at, DateTime.utc_now())

    %{
      "envelope_version" => @envelope_version,
      "agent" => Identity.external(command.agent_id),
      "authority" => authority_envelope(command.authority),
      "capability_id" => command.capability_id,
      "command_fingerprint" => command.fingerprint,
      "consequence" => Atom.to_string(consequence),
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
  Evaluates the envelope. Pure; the only inputs are the envelope's own fields.

  Mirrors `AshA2A.CommandBus`'s admission rules exactly:

    * `observe` needs no authority.
    * `change` / `external_do` with no authority -> `:authority_required`.
    * `change` / `external_do` whose authority does not bind the *same*
      principal and the *same* capability, or which has expired as of
      `"evaluated_at"`, -> `:authority_mismatch`.
    * any other consequence -> `:consequence_unclassified`.

  Note what is deliberately absent from the rule set: identity,
  authentication source, task assignment, plan validity, proof, model
  confidence, and agent-card declaration are all *present in the envelope*
  yet none of them appear in any admitting branch (RFC S29).
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{"envelope_version" => @envelope_version} = envelope) do
    case Map.get(envelope, "consequence") do
      "observe" ->
        admitted()

      consequence when consequence in ["change", "external_do"] ->
        consequence_verdict(envelope)

      _ ->
        refused(:consequence_unclassified)
    end
  end

  def verdict(_envelope), do: refused(:decision_envelope_unrecognized)

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
    Map.get(authority, "subject") == Map.get(envelope, "principal") and
      Map.get(authority, "capability_id") == Map.get(envelope, "capability_id") and
      not expired?(Map.get(authority, "expires_at"), Map.get(envelope, "evaluated_at"))
  end

  defp expired?(nil, _evaluated_at), do: false

  defp expired?(expires_at, evaluated_at)
       when is_binary(expires_at) and is_binary(evaluated_at) do
    with {:ok, expires, _} <- DateTime.from_iso8601(expires_at),
         {:ok, now, _} <- DateTime.from_iso8601(evaluated_at) do
      DateTime.compare(now, expires) == :gt
    else
      # Unparseable timestamps fail closed: treat as expired.
      _ -> true
    end
  end

  defp expired?(_expires_at, _evaluated_at), do: true

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
