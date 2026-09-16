defmodule AshA2A.Semantic.GraphLaw do
  @moduledoc """
  Port to the real `praxis-graphlaw` semantic engine.

  `ash_a2a` deliberately owns no SHACL/ShEx/Datalog/N3/SPARQL implementation
  and no RDF canonicalization. Those already exist, in Rust, in
  `praxis-graphlaw` (native N3, Datalog, SPARQL 1.1, SHACL, ShEx, RDFC-1.0
  canonicalization via `oxrdf` `rdfc-10`). Elixir's job at this boundary is
  envelope, standing, refusal typing, authority, receipts and admission
  orchestration -- not validation. This module is the seam between the two.

  The engine is reached as a real WebAssembly module
  (`praxis_graphlaw_wasm_bg.wasm`, wasm-bindgen bundler target) instantiated
  by a small real host shim, `priv/graphlaw/graphlaw_host_peer.mjs`. See
  `AshA2A.Semantic.GraphLaw.Wasm` for the transport and the exact
  wasm-bindgen ABI it speaks.

  ## Why this is a behaviour

  Cross-peer portability (the SA2A claim) is about two *runtimes* agreeing
  while running the *same* wasm. A behaviour lets two peers in one test be
  wired to two separately-configured, independently-instantiated engine
  runners over the same wasm bytes, which is precisely the shape the claim
  needs. It is not an invitation to substitute a mock: every implementation
  shipped here executes the real engine.

  ## Fail-closed

  Every call returns a typed result. When the engine cannot be reached at
  all the answer is `{:error, %{code: :graphlaw_unavailable}}` -- never a
  silent pass. A caller that cannot run admission must refuse standing, not
  assume it.
  """

  @typedoc "A typed refusal from the port itself (not a semantic verdict)."
  @type refusal :: %{required(:code) => atom(), required(:detail) => String.t()}

  @typedoc """
  The real decoded `validate_all` report. Keys are the engine's own:
  `"graph_hash"`, `"dialects"` (each with `"dialect"`/`"status"`/`"detail"`),
  `"hooks"`, `"replay"`.
  """
  @type report :: map()

  @callback version() :: {:ok, String.t()} | {:error, refusal()}
  @callback graph_hash(String.t()) :: {:ok, String.t()} | {:error, refusal()}
  @callback validate(String.t(), String.t()) :: {:ok, report()} | {:error, refusal()}

  @doc """
  Returns the configured engine implementation.

  Defaults to `AshA2A.Semantic.GraphLaw.Wasm`, the real wasm runner.
  """
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(opts, :graph_law) ||
      Application.get_env(:ash_a2a, :graph_law, AshA2A.Semantic.GraphLaw.Wasm)
  end

  @spec version(keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def version(opts \\ []), do: impl(opts).version()

  @spec graph_hash(String.t(), keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def graph_hash(ttl, opts \\ []) when is_binary(ttl), do: impl(opts).graph_hash(ttl)

  @spec validate(String.t(), String.t(), keyword()) :: {:ok, report()} | {:error, refusal()}
  def validate(ttl, shapes, opts \\ []) when is_binary(ttl) and is_binary(shapes),
    do: impl(opts).validate(ttl, shapes)

  @doc """
  Reduces a real engine report to a single admission verdict.

  A dialect the engine reports as `"REFUSED"` refuses the whole graph.
  `"UNSUPPORTED"` and `"PROFILE_NOT_ADMITTED"` are *not* refusals and are
  *not* admissions either -- they mean that dialect was not exercised (no
  shapes supplied, no profile supplied). They are carried through to the
  caller rather than silently collapsed, because `UNSUPPORTED != REFUSED`.

  Returns `{:admitted, graph_hash}` or `{:refused, code, detail}`.
  """
  @spec verdict(report()) :: {:admitted, String.t()} | {:refused, atom(), String.t()}
  def verdict(%{} = report) do
    dialects = Map.get(report, "dialects", [])

    refused =
      Enum.filter(dialects, fn dialect -> Map.get(dialect, "status") == "REFUSED" end)

    replay_status = report |> Map.get("replay", %{}) |> Map.get("status")

    cond do
      refused != [] ->
        detail =
          Enum.map_join(refused, "; ", fn dialect ->
            "#{Map.get(dialect, "dialect")}: #{Map.get(dialect, "detail")}"
          end)

        {:refused, :semantic_shape_violation, detail}

      replay_status == "REFUSED" ->
        {:refused, :semantic_replay_divergence,
         "replay hashes diverged: #{inspect(Map.get(report, "replay"))}"}

      not is_binary(Map.get(report, "graph_hash")) ->
        {:refused, :semantic_graph_unhashable, "engine returned no graph_hash"}

      true ->
        {:admitted, Map.fetch!(report, "graph_hash")}
    end
  end

  @doc """
  Lists the dialects the engine reported as not exercised.

  Kept separate from `verdict/1` on purpose: a caller must be able to see
  that (for example) SHEX was `UNSUPPORTED` rather than passing, so an
  admission receipt can record what was actually checked instead of implying
  the whole ladder ran.
  """
  @spec unexercised(report()) :: [%{dialect: String.t(), status: String.t()}]
  def unexercised(%{} = report) do
    report
    |> Map.get("dialects", [])
    |> Enum.filter(&(Map.get(&1, "status") in ["UNSUPPORTED", "PROFILE_NOT_ADMITTED"]))
    |> Enum.map(&%{dialect: Map.get(&1, "dialect"), status: Map.get(&1, "status")})
  end
end
