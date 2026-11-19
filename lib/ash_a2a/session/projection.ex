# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT
# UNSUPPORTED(generator-capability): hand-written; no pack emits a session projection.

defmodule AshA2A.Session.Projection do
  @moduledoc """
  Projects session state through `AshGraphLaw.Host` (FNOX-SJ-SESS-4).

  The session state `{state, data}` of an `AshA2A.Session.Statem` is rendered as
  N-Triples (`to_ntriples/2`) and canonicalised by the GraphLaw engine's
  `canonical` op. The result is an observation (content-addressed id and quad
  count), never authority.

  Byte-identical graph input yields an identical result (the engine
  canonicalises). The vendored graphlaw wasm version is not touched here.
  """

  @type result :: %{id: String.t(), quads: non_neg_integer(), nquads: String.t()}

  @ns "urn:ash_a2a:session"

  @doc "Renders session `state` and `data` (`conn_id`, `transitions`) as N-Triples."
  @spec to_ntriples(atom(), map()) :: String.t()
  def to_ntriples(state, %{conn_id: conn_id, transitions: transitions}) when is_atom(state) do
    subject = "<#{@ns}:" <> URI.encode_www_form(inspect(conn_id)) <> ">"

    """
    #{subject} <#{@ns}#state> "#{state}" .
    #{subject} <#{@ns}#transitions> "#{transitions}"^^<http://www.w3.org/2001/XMLSchema#integer> .
    #{subject} <#{@ns}#kind> "a2a-session" .
    """
  end

  @doc """
  Canonicalises graph text through the host. `dialect` is a GraphLaw dialect
  name such as `"ntriples"` or `"turtle"`.
  """
  @spec project_graph(GenServer.server(), String.t(), String.t()) ::
          {:ok, result()} | {:error, term()}
  def project_graph(host, text, dialect \\ "ntriples") when is_binary(text) do
    request = %{"op" => "canonical", "data" => %{"text" => text, "dialect" => dialect}}

    case AshGraphLaw.Host.request(host, request) do
      {:ok, %{"ok" => true, "id" => id, "nquads" => nquads, "quads" => quads}} ->
        {:ok, %{id: id, quads: quads, nquads: nquads}}

      {:ok, other} ->
        {:error, {:engine_refused, other}}

      {:error, _refusal} = error ->
        error
    end
  end

  @doc """
  Projects a live session (pid or connection id) through `host`. Only a session in
  `:projecting` is projected; any other state is `{:error, {:not_projecting, state}}`.
  """
  @spec project(pid() | term(), GenServer.server()) :: {:ok, result()} | {:error, term()}
  def project(session, host) do
    pid = if is_pid(session), do: session, else: GenServer.whereis(AshA2A.Session.Statem.via(session))

    case pid && :sys.get_state(pid) do
      {:projecting, data} -> project_graph(host, to_ntriples(:projecting, data))
      {state, _data} -> {:error, {:not_projecting, state}}
      nil -> {:error, :no_such_session}
    end
  end
end
