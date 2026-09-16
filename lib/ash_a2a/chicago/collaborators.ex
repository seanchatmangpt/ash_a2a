defmodule AshA2A.Chicago.Collaborators do
  @moduledoc """
  RFC-SA2A-002 §9, §10, §34 (gate 3): identifies the load-bearing collaborators
  of the **running configuration** and proves, by execution, that each is the
  real one.

  `inventory/1` reports the component used for each of the nine roles §34
  names, and derives every "real" judgement from an executed probe or from the
  compiled artifact -- never from a module name or a declaration:

  | role                   | component (default configuration)          | how it is proven real |
  |------------------------|--------------------------------------------|-----------------------|
  | `:semantic_engine`     | `AshA2A.GraphLaw.Wasm` over `wasm_path`    | sha256 of the configured wasm equals the vendored manifest's; the real host executes it; its `graphlaw_version` equals the manifest's; its `graph_hash` of a fresh nonce graph equals the manifest-bound vendored artifact's, executed by an independent host (`AshA2A.GraphLaw.WasmHost`). The `AshA2A.Semantic.GraphLaw` port impl must agree on the same nonce. |
  | `:admission_pipeline`  | `AshA2A.Semantic.AdmissionPipeline`        | its compiled import table calls `AshA2A.GraphLaw.Wasm.batch/2` |
  | `:authority_broker`    | configured `:authority_broker` + `:authority_policy` | a fresh nonce principal with no grant is asked for a fresh nonce capability through the real `AshA2A.Authority.Grant.authorize/3`: a real boundary refuses |
  | `:consequence_boundary`| `AshA2A.CommandBus`                        | its import table calls the actuator and `:telemetry.execute/3` |
  | `:receipt_store`       | `AshA2A.CommandBus.default_store/0`        | implements `AshA2A.ReceiptStore`; durability PROVEN by `DurabilityProbe` (write -> real restart -> read -> replay) |
  | `:actuator`            | `AshA2A.Dispatcher`                        | exports `dispatch/5` and is the call `CommandBus` compiles |
  | `:independent_verifier`| `AshA2A.Chicago.Query`                     | the runner's import table loads and evaluates through it |
  | `:replay_engine`       | the receipt store's command replay         | re-claiming a committed command after the real restart answers `:replay` |
  | `:process_observer`    | `AshA2A.Chicago.Observer`                  | loaded; the run's observer process is live when given |

  Every probe uses fresh nonces, so no probe can be satisfied by a canned
  answer. `mock_scan/1` is the §10 zero-mock AST scan
  (`AshA2A.Chicago.Collaborators.MockScan`).

  ## Violations and verdict

  `verdict` is `:admitted` only when no violation stands. Violation codes
  (classified via `__sa2a_refusal_codes__/0`):

    * `:collaborator_unidentified` -- a role's component is absent/unwired
    * `:authority_not_real_boundary` -- the nonce principal obtained authority
      (legacy `:transport_verified_grants_capability`, or a broker that grants
      without a grant)
    * `:receipt_store_durability_unproven` -- the store declares
      `durable?/0 -> true` but the probe could not read its write back after a
      real restart (any claim: `AshA2A.CommandBus` stamps `standing: :durable`
      from that declaration)
    * `:receipt_store_not_durable` -- a `:do`/`:strict` claim with a store
      that is not declared-and-proven durable
    * `:semantic_engine_substituted` / `:semantic_engine_unavailable`
    * `:semantic_port_substituted`
    * `:mock_collaborator_detected` / `:source_unparseable` (with file:line)

  ## Telemetry (emitted here, the deciding boundary)

    * `[:ash_a2a, :chicago, :collaborators, :inventoried]` -- once per inventory
    * `[:ash_a2a, :chicago, :collaborators, :violation]` -- once per violation
    * `[:ash_a2a, :chicago, :collaborators, :mock_scan]` -- once per scan
    * `[:ash_a2a, :chicago, :collaborators, :durability_probe]` -- per probe stage

  The probes also drive real SUT boundaries that emit their own telemetry:
  `[:ash_a2a, :authority, :grant, :decision]` and
  `[:ash_a2a, :graph_law, :wasm, :batch]`.
  """

  alias AshA2A.Authority.Grant
  alias AshA2A.Chicago.Collaborators.{DurabilityProbe, MockScan}
  alias AshA2A.Chicago.Profile
  alias AshA2A.GraphLaw.Manifest

  @roles [
    :semantic_engine,
    :admission_pipeline,
    :authority_broker,
    :consequence_boundary,
    :receipt_store,
    :actuator,
    :independent_verifier,
    :replay_engine,
    :process_observer
  ]

  @inventoried [:ash_a2a, :chicago, :collaborators, :inventoried]
  @violation [:ash_a2a, :chicago, :collaborators, :violation]
  @mock_scan [:ash_a2a, :chicago, :collaborators, :mock_scan]

  @durable_claims [:do, :strict]

  @refusal_codes %{
    collaborator_unidentified: :blocked_resource,
    authority_not_real_boundary: :refused_authority,
    receipt_store_durability_unproven: :refused_receipt,
    receipt_store_not_durable: :refused_receipt,
    semantic_engine_substituted: :refused_identity,
    semantic_engine_unavailable: :blocked_resource,
    semantic_port_substituted: :refused_identity,
    mock_collaborator_detected: :refused_meta_rigor,
    source_unparseable: :refused_meta_rigor
  }

  defmodule Inventory do
    @moduledoc "One gate-3 inventory of the running configuration."
    @enforce_keys [:claim, :scope, :roles, :violations, :verdict, :nonce]
    defstruct [:claim, :scope, :roles, :mock_scan, :violations, :verdict, :nonce]

    @type t :: %__MODULE__{
            claim: AshA2A.Chicago.Profile.t(),
            scope: :full | :partial,
            roles: %{atom() => map()},
            mock_scan: map() | nil,
            violations: [map()],
            verdict: :admitted | :refused,
            nonce: String.t()
          }
  end

  @type violation :: %{
          required(:code) => atom(),
          required(:role) => atom(),
          optional(:module) => module() | nil,
          optional(:file) => String.t(),
          optional(:line) => non_neg_integer(),
          optional(:detail) => String.t()
        }

  @doc "The nine §34 roles, in RFC order."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Telemetry events this module emits."
  @spec events() :: [[atom()]]
  def events, do: [@inventoried, @violation, @mock_scan, DurabilityProbe.event()]

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @doc """
  Inventories the running configuration.

  Options:

    * `:claim` -- the profile being claimed (default `:core`); `:do`/`:strict`
      additionally require a declared-and-proven durable receipt store
    * `:roles` -- restrict to these roles (default all nine; `scope: :partial`
      otherwise)
    * `:scan` -- run the zero-mock AST scan (default `true`)
    * `:root`, `:scan_dirs` -- scan root (default `File.cwd!()`) and dirs
      (default `["lib", "test"]`)
    * `:receipt_store` -- store module (default `AshA2A.CommandBus.default_store/0`)
    * `:probe_dir` -- parent directory for the durability probe instance
    * `:observer` -- the run's `AshA2A.Chicago.Observer` pid
  """
  @spec inventory(keyword()) :: Inventory.t()
  def inventory(opts \\ []) do
    claim = Keyword.get(opts, :claim, :core)

    unless Profile.profile?(claim),
      do: raise(ArgumentError, "unknown claim #{inspect(claim)}")

    roles = Enum.filter(@roles, &(&1 in Keyword.get(opts, :roles, @roles)))
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    store = Keyword.get_lazy(opts, :receipt_store, &AshA2A.CommandBus.default_store/0)

    durability =
      if Enum.any?([:receipt_store, :replay_engine], &(&1 in roles)),
        do: DurabilityProbe.run(store, opts)

    env = %{opts: opts, nonce: nonce, store: store, durability: durability, claim: claim}
    role_maps = Map.new(roles, &{&1, role(&1, env)})

    scan = if Keyword.get(opts, :scan, true), do: run_scan(opts)

    violations =
      Enum.flat_map(roles, &role_violations(&1, Map.fetch!(role_maps, &1), claim)) ++
        scan_violations(scan)

    Enum.each(violations, &emit_violation/1)

    inventory = %Inventory{
      claim: claim,
      scope: if(roles == @roles, do: :full, else: :partial),
      roles: role_maps,
      mock_scan: scan,
      violations: violations,
      verdict: if(violations == [], do: :admitted, else: :refused),
      nonce: nonce
    }

    emit_inventoried(inventory)
    inventory
  end

  @doc """
  The §10 zero-mock AST scan on its own, emitting the `:mock_scan` and one
  `:violation` event per finding. Options as `MockScan.scan/1` (`:root`,
  `:dirs`). Returns `{scan_result, violations}`.
  """
  @spec mock_scan(keyword()) :: {MockScan.result(), [violation()]}
  def mock_scan(opts \\ []) do
    scan = MockScan.scan(opts)
    emit_scan(scan)
    violations = scan_violations(scan)
    Enum.each(violations, &emit_violation/1)
    {scan, violations}
  end

  @doc "True when `inventory` carries a violation with `code`."
  @spec violation?(Inventory.t(), atom()) :: boolean()
  def violation?(%Inventory{violations: violations}, code),
    do: Enum.any?(violations, &(&1.code == code))

  @doc "JSON-safe form of an inventory (for evidence and receipts)."
  @spec to_map(Inventory.t()) :: map()
  def to_map(%Inventory{} = inventory),
    do: inventory |> Map.from_struct() |> AshA2A.Chicago.Json.safe()

  # --- roles ------------------------------------------------------------------

  defp role(:semantic_engine, env), do: semantic_engine(env)

  defp role(:admission_pipeline, _env) do
    module = AshA2A.Semantic.AdmissionPipeline
    engine_calls = calls_into(module, AshA2A.GraphLaw.Wasm)

    %{
      module: module,
      engine: AshA2A.GraphLaw.Wasm,
      engine_calls: engine_calls,
      required_stages:
        if(exported?(module, :required_stages, 0), do: module.required_stages(), else: nil),
      identified?: exported?(module, :admit, 2) and "batch/2" in engine_calls
    }
  end

  defp role(:authority_broker, env) do
    {broker, _broker_opts} =
      case Application.get_env(:ash_a2a, :authority_broker) do
        {module, broker_opts} when is_atom(module) and is_list(broker_opts) ->
          {module, broker_opts}

        module when is_atom(module) ->
          {module, []}

        _other ->
          {nil, []}
      end

    probe_principal = "ash_a2a.chicago.collaborators.ungranted." <> env.nonce
    probe_capability = "ash_a2a.chicago.collaborators.probe_capability." <> env.nonce
    authority = Grant.authorize(probe_principal, probe_capability)

    %{
      module: broker,
      policy: Grant.policy(),
      probe_principal: probe_principal,
      probe_capability: probe_capability,
      ungranted_principal_obtained_authority?: authority != nil,
      fail_closed_proven?: authority == nil,
      identified?: broker != nil and exported?(broker, :granted?, 3)
    }
  end

  defp role(:consequence_boundary, _env) do
    module = AshA2A.CommandBus

    %{
      module: module,
      actuator_calls: calls_into(module, AshA2A.Dispatcher),
      boundary_telemetry?: "execute/3" in calls_into(module, :telemetry),
      identified?:
        exported?(module, :run, 4) and "dispatch/5" in calls_into(module, AshA2A.Dispatcher)
    }
  end

  defp role(:receipt_store, %{store: store, durability: durability}) do
    %{
      module: store,
      behaviour?: AshA2A.ReceiptStore in behaviours(store),
      declared_durable?: declared_durable?(store),
      proven_durable?: durability.proven?,
      durability: durability,
      identified?:
        AshA2A.ReceiptStore in behaviours(store) and exported?(store, :claim, 2) and
          exported?(store, :commit, 2) and exported?(store, :fetch, 2)
    }
  end

  defp role(:actuator, _env) do
    module = AshA2A.Dispatcher

    %{
      module: module,
      invoked_by: AshA2A.CommandBus,
      identified?:
        exported?(module, :dispatch, 5) and
          "dispatch/5" in calls_into(AshA2A.CommandBus, module)
    }
  end

  defp role(:independent_verifier, _env) do
    module = AshA2A.Chicago.Query
    runner_calls = calls_into(AshA2A.Chicago.Runner, module)
    validator = AshA2A.Chicago.Ocel.Validator

    %{
      module: module,
      runner_calls: runner_calls,
      ocel_validator: validator,
      ocel_validator_available?: exported?(validator, :validate_file, 1),
      identified?: "load/2" in runner_calls and "eval/3" in runner_calls
    }
  end

  defp role(:replay_engine, %{store: store, durability: durability}) do
    %{
      module: store,
      kind: :command_replay,
      replay_after_restart?: durability.replay == :replay,
      identified?: exported?(store, :claim, 2)
    }
  end

  defp role(:process_observer, env) do
    module = AshA2A.Chicago.Observer
    observer = Keyword.get(env.opts, :observer)
    live? = if is_pid(observer), do: Process.alive?(observer)

    %{
      module: module,
      live?: live?,
      identified?: exported?(module, :start_link, 1) and live? != false
    }
  end

  defp semantic_engine(env) do
    host = AshA2A.GraphLaw.Wasm
    wasm_path = host.wasm_path([])

    {manifest_sha, manifest_version} =
      case Manifest.read() do
        {:ok, manifest} ->
          {get_in(manifest, ["artifact", "sha256"]), manifest["graphlaw_version"]}

        {:error, _} ->
          {nil, nil}
      end

    wasm_sha = file_sha256(wasm_path)
    ttl = nonce_graph(env.nonce)
    reference = reference_graph_hash(ttl, manifest_sha)

    {version, host_hash, host_error} =
      case host.batch([{:graphlaw_version, []}, {:graph_hash, [ttl]}]) do
        {:ok, [version, hash]} -> {version, hash, nil}
        {:ok, other} -> {nil, nil, "unexpected host results #{inspect(other, limit: 5)}"}
        {:error, error} -> {nil, nil, inspect(error, limit: 10, printable_limit: 512)}
      end

    digest_bound? = wasm_sha != nil and wasm_sha == manifest_sha

    agrees? =
      match?({:ok, _}, reference) and host_hash != nil and {:ok, host_hash} == reference

    port = semantic_port(ttl, reference, manifest_sha)

    %{
      module: host,
      wasm_path: wasm_path,
      wasm_sha256: wasm_sha,
      manifest_sha256: manifest_sha,
      manifest_version: manifest_version,
      digest_bound?: digest_bound?,
      version: version,
      version_matches_manifest?: version != nil and version == manifest_version,
      nonce_graph_hash: host_hash,
      reference: reference_summary(reference),
      agrees_with_reference?: agrees?,
      host_error: host_error,
      real?:
        digest_bound? and version != nil and version == manifest_version and agrees? and
          host_error == nil,
      port: port,
      identified?: exported?(host, :batch, 2)
    }
  end

  defp semantic_port(ttl, reference, manifest_sha) do
    impl = AshA2A.Semantic.GraphLaw.impl()

    hash =
      bounded(fn ->
        case impl.graph_hash(ttl) do
          {:ok, hash} when is_binary(hash) -> hash
          other -> {:error, inspect(other, limit: 10)}
        end
      end)

    {wasm_path, wasm_sha} =
      if exported?(impl, :wasm_path, 0) do
        path = impl.wasm_path()
        {path, file_sha256(path)}
      else
        {nil, nil}
      end

    agrees? = is_binary(hash) and {:ok, hash} == reference

    %{
      module: impl,
      wasm_path: wasm_path,
      wasm_sha256: wasm_sha,
      digest_bound?: wasm_sha != nil and wasm_sha == manifest_sha,
      nonce_graph_hash: if(is_binary(hash), do: hash),
      error: if(is_binary(hash), do: nil, else: inspect(hash, limit: 10)),
      agrees_with_reference?: agrees?,
      real?: agrees? and (wasm_path == nil or wasm_sha == manifest_sha)
    }
  end

  # The manifest-bound vendored artifact, executed by a host independent of
  # the configured one (different module, different JS host script).
  defp reference_graph_hash(ttl, manifest_sha) do
    vendored = AshA2A.GraphLaw.wasm_path()

    cond do
      manifest_sha == nil ->
        {:error, "no vendored GraphLaw manifest digest"}

      file_sha256(vendored) != manifest_sha ->
        {:error, "vendored artifact #{vendored} does not match its manifest digest"}

      true ->
        case AshA2A.GraphLaw.WasmHost.run([%{fn: "graph_hash", args: [ttl]}], wasm_path: vendored) do
          {:ok, %{results: [hash]}} when is_binary(hash) -> {:ok, hash}
          other -> {:error, "reference host: #{inspect(other, limit: 10)}"}
        end
    end
  end

  defp reference_summary({:ok, hash}), do: %{available?: true, nonce_graph_hash: hash}
  defp reference_summary({:error, detail}), do: %{available?: false, detail: detail}

  defp nonce_graph(nonce) do
    "<urn:ash_a2a:chicago:collaborators:#{nonce}> " <>
      "<urn:ash_a2a:chicago:collaborators:probe> \"#{nonce}\" ."
  end

  # --- violations -------------------------------------------------------------

  defp role_violations(role, %{identified?: false} = map, claim) do
    [violation(:collaborator_unidentified, role, map, "#{role} is not identified")] ++
      specific_violations(role, map, claim)
  end

  defp role_violations(role, map, claim), do: specific_violations(role, map, claim)

  defp specific_violations(:authority_broker, %{fail_closed_proven?: false} = map, _claim) do
    [
      violation(
        :authority_not_real_boundary,
        :authority_broker,
        map,
        "ungranted nonce principal obtained authority under policy #{inspect(map.policy)} " <>
          "with broker #{inspect(map.module)}"
      )
    ]
  end

  defp specific_violations(:receipt_store, map, claim) do
    unproven =
      if map.declared_durable? and not map.proven_durable? do
        [
          violation(
            :receipt_store_durability_unproven,
            :receipt_store,
            map,
            "declares durable?/0 -> true but the durability probe did not prove it: " <>
              to_string(map.durability.detail)
          )
        ]
      else
        []
      end

    not_durable =
      if claim in @durable_claims and not map.declared_durable? do
        [
          violation(
            :receipt_store_not_durable,
            :receipt_store,
            map,
            "#{inspect(claim)} claim requires a durable receipt store; " <>
              "#{inspect(map.module)} is not declared durable (probe proven?: #{map.proven_durable?})"
          )
        ]
      else
        []
      end

    unproven ++ not_durable
  end

  defp specific_violations(:semantic_engine, map, _claim) do
    engine =
      cond do
        map.real? ->
          []

        not map.reference.available? or not File.exists?(map.wasm_path) ->
          [
            violation(
              :semantic_engine_unavailable,
              :semantic_engine,
              map,
              "cannot execute #{map.wasm_path}: #{map.host_error || map.reference[:detail]}"
            )
          ]

        true ->
          [
            violation(
              :semantic_engine_substituted,
              :semantic_engine,
              map,
              "configured wasm #{map.wasm_path} (sha256 #{map.wasm_sha256}) is not the " <>
                "manifest-bound GraphLaw artifact (sha256 #{map.manifest_sha256}); " <>
                "executed: #{map.version != nil}; agrees with reference: #{map.agrees_with_reference?}"
            )
          ]
      end

    port =
      if map.reference.available? and not map.port.real? do
        [
          violation(
            :semantic_port_substituted,
            :semantic_engine,
            %{module: map.port.module},
            "AshA2A.Semantic.GraphLaw impl #{inspect(map.port.module)} did not reproduce the " <>
              "real engine's graph_hash of a fresh nonce graph"
          )
        ]
      else
        []
      end

    engine ++ port
  end

  defp specific_violations(_role, _map, _claim), do: []

  defp scan_violations(nil), do: []

  defp scan_violations(scan) do
    Enum.map(scan.violations, fn v ->
      %{
        code: :mock_collaborator_detected,
        role: :zero_mock_scan,
        module: nil,
        file: v.file,
        line: v.line,
        detail: v.call
      }
    end) ++
      Enum.map(scan.unparseable, fn u ->
        %{
          code: :source_unparseable,
          role: :zero_mock_scan,
          module: nil,
          file: u.file,
          line: u.line,
          detail: u.detail
        }
      end)
  end

  defp violation(code, role, map, detail),
    do: %{code: code, role: role, module: Map.get(map, :module), detail: detail}

  # --- scan -------------------------------------------------------------------

  defp run_scan(opts) do
    scan =
      MockScan.scan(
        root: Keyword.get_lazy(opts, :root, &File.cwd!/0),
        dirs: Keyword.get(opts, :scan_dirs, ["lib", "test"])
      )

    emit_scan(scan)
    scan
  end

  defp emit_scan(scan) do
    :telemetry.execute(
      @mock_scan,
      %{files: scan.files, violations: length(scan.violations) + length(scan.unparseable)},
      %{
        root: scan.root,
        dirs: Enum.join(scan.dirs, ","),
        missing_dirs: Enum.join(scan.missing_dirs, ","),
        outcome: scan.outcome
      }
    )
  end

  # --- telemetry --------------------------------------------------------------

  defp emit_violation(violation) do
    :telemetry.execute(@violation, %{system_time: System.system_time()}, violation)
  end

  defp emit_inventoried(%Inventory{} = inv) do
    roles = inv.roles
    get = fn role, key -> roles |> Map.get(role, %{}) |> Map.get(key) end
    semantic = Map.get(roles, :semantic_engine, %{})

    metadata = %{
      claim: inv.claim,
      verdict: inv.verdict,
      scope: inv.scope,
      nonce: inv.nonce,
      roles: roles |> Map.keys() |> Enum.map_join(",", &Atom.to_string/1),
      roles_identified: Enum.count(roles, fn {_role, map} -> map.identified? end),
      violations: length(inv.violations),
      violation_codes: inv.violations |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.join(","),
      mock_scan: if(inv.mock_scan, do: inv.mock_scan.outcome, else: :skipped),
      mock_scan_dirs: inv.mock_scan && Enum.join(inv.mock_scan.dirs, ","),
      authority_policy: get.(:authority_broker, :policy),
      authority_broker: get.(:authority_broker, :module),
      authority_fail_closed: get.(:authority_broker, :fail_closed_proven?),
      receipt_store: get.(:receipt_store, :module),
      receipt_store_declared_durable: get.(:receipt_store, :declared_durable?),
      receipt_store_proven_durable: get.(:receipt_store, :proven_durable?),
      replay_after_restart: get.(:replay_engine, :replay_after_restart?),
      semantic_engine: semantic[:module],
      semantic_engine_wasm_sha256: semantic[:wasm_sha256],
      semantic_engine_digest_bound: semantic[:digest_bound?],
      semantic_engine_real: semantic[:real?],
      semantic_port: semantic[:port] && semantic.port.module,
      semantic_port_real: semantic[:port] && semantic.port.real?,
      process_observer_live: get.(:process_observer, :live?),
      collaborators: Enum.map(roles, fn {role, map} -> {role, Map.get(map, :module)} end)
    }

    :telemetry.execute(
      @inventoried,
      %{roles: map_size(roles), violations: length(inv.violations)},
      metadata
    )
  end

  # --- helpers ----------------------------------------------------------------

  defp exported?(module, fun, arity) when is_atom(module) and module != nil,
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  defp exported?(_module, _fun, _arity), do: false

  defp behaviours(module) do
    if Code.ensure_loaded?(module) do
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    else
      []
    end
  end

  defp declared_durable?(store) do
    exported?(store, :durable?, 0) and store.durable?() == true
  rescue
    _ -> false
  end

  # Remote calls `module`'s compiled BEAM makes into `target`, as "fun/arity".
  # Read from the import table of the loaded object code: evidence of real
  # wiring, independent of any module name a config or doc asserts.
  defp calls_into(module, target) do
    with true <- Code.ensure_loaded?(module),
         path when is_list(path) <- :code.which(module),
         {:ok, {_, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
      |> Enum.filter(fn {mod, _fun, _arity} -> mod == target end)
      |> Enum.map(fn {_mod, fun, arity} -> "#{fun}/#{arity}" end)
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp file_sha256(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end

  defp file_sha256(_), do: nil

  defp bounded(fun) do
    task = Task.async(fn -> safe(fun) end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _ -> {:error, "timed out after 60000ms"}
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
