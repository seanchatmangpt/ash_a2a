defmodule AshA2A.V1ArchitectureTest do
  @moduledoc """
  Post-v1.0 architecture courts over the CURRENT tree (lane X10).

  Static source reads + real module introspection. Zero mocks.

  Courts:
    (a) Perimeter purity — every module under lib/ash_a2a/protocol/** outside
        the perimeter (protocol/plug*) is scanned (comments and doc heredocs
        stripped) for direct I/O side effects (ETS, HTTP client, HTTP server,
        Plug.Conn). The codec layer must have no I/O.

        FINDING PIN (2026-10-04, lane X10): the vendored `a2a` hex-package port
        (see lib/ash_a2a/protocol/NOTICE) keeps five I/O-bearing adapters under
        protocol/** outside the plug* perimeter:
          - protocol/client.ex                      (Req HTTP)
          - protocol/card_cache.ex                  (Req HTTP + disk cache)
          - protocol/push_notification_sender/http.ex (Req HTTP)
          - protocol/registry.ex                    (ETS registry)
          - protocol/task_store/ets.ex              (ETS task store)
        These are pinned here as the ONLY protocol modules allowed to perform
        I/O. The court fails if ANY other protocol module gains I/O, if any
        module's side-effect surface changes (ets/http/plug_conn families are
        enumerated per module and pinned exactly), or if a pinned module
        vacates the tree. Promotion path: move these out of protocol/** (or
        behind plug*) and shrink this pin to the empty map.
    (b) Single-source constants — AshA2A.Protocol.Version.protocol_version()
        is the single source ("1.0"); no "0.3.0" literals and no "2.0" literals
        in protocol-version position anywhere in protocol/** or
        capability_index/** (JSON-RPC wire "jsonrpc" => "2.0" is exempt: it is
        the JSON-RPC version, not the A2A protocol version).
    (c) Fail-closed surfaces — ToA2AError's Any fallback returns -32603 with an
        opaque ref and no detail; VerifySkills is registered in the
        lib/ash_a2a.ex verifier list; the installer contains no add_dep({:a2a.
    (d) Router surface inventory — the four transports implement @behaviour
        Plug with call/2 and init/1 on the compiled beams.
    (e) External-dependency perimeter — mix.exs has no {:a2a, dep; mix.lock
        has no "a2a" entry.
  """

  use ExUnit.Case, async: true

  @protocol_glob "lib/ash_a2a/protocol/**/*.ex"
  @cap_index_glob "lib/ash_a2a/capability_index/**/*.ex"
  @cap_index_root "lib/ash_a2a/capability_index.ex"

  # Perimeter = the A2A plug surface itself (protocol/plug*). Exempt from the
  # codec-purity scan: it is where I/O is allowed to live by contract.
  @perimeter_prefix "lib/ash_a2a/protocol/plug"

  # FINDING PIN — see moduledoc (a). I/O-bearing protocol modules outside the
  # perimeter, each with the side-effect families enumerated per module.
  @pinned_io_modules %{
    "lib/ash_a2a/protocol/client.ex" =>
      {:http_client, ["Req.post", "Req.get", "Req.delete"]},
    "lib/ash_a2a/protocol/card_cache.ex" =>
      {:http_client, ["Req.get"]},
    "lib/ash_a2a/protocol/push_notification_sender/http.ex" =>
      {:http_client, ["Req.post"]},
    "lib/ash_a2a/protocol/registry.ex" =>
      {:ets, [":ets.new", ":ets.insert", ":ets.lookup", ":ets.tab2list", ":ets.delete"]},
    "lib/ash_a2a/protocol/task_store/ets.ex" =>
      {:ets, [":ets.new", ":ets.insert", ":ets.lookup", ":ets.tab2list", ":ets.delete", ":ets.match_object"]}
  }

  # Direct side-effect families scanned for in codec-purity court (a).
  @ets_rx ~r/:ets\.\w+/
  @http_client_rx ~r/\b(?:Req\.(?:get|post|put|delete|patch|request)|:httpc\.\w+|:hackney\.\w+|Finch\.\w+|Tesla\.(?:get|post|request))\(/
  @http_server_rx ~r/\b(?:Bandit|:cowboy)\.(?:start|start_link)\(/
  @plug_conn_rx ~r/\bPlug\.Conn\.(?!t\()\w+\(/

  @triple_quote "\"\"\""

  @transports [
    AshA2A.Transport.Plug,
    AshA2A.A2ATransport.Plug,
    AshA2A.Transport.HTTPJSON,
    AshA2A.Protocol.Plug
  ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp repo_sources(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
    |> Map.new(fn path -> {path, File.read!(path)} end)
  end

  # Strips line comments and doc heredocs (""" blocks) so that @doc examples
  # (e.g. the Bandit start_link example in extension.ex) are not counted as
  # runtime I/O. Comment-only mentions (e.g. `# mirrors Req.get/2`) are also
  # excluded.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_heredoc?} ->
      trimmed = String.trim(line)

      cond do
        in_heredoc? ->
          if String.ends_with?(trimmed, @triple_quote),
            do: {acc, false},
            else: {acc, true}

        String.ends_with?(trimmed, @triple_quote) ->
          # opener line of a doc heredoc (e.g. `@doc """`) — skip content
          {acc, true}

        String.starts_with?(trimmed, "#") ->
          {acc, false}

        true ->
          {[line | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp io_families(source) do
    code = code_lines(source) |> Enum.join("\n")

    [
      {:ets, Regex.scan(@ets_rx, code) |> List.flatten()},
      {:http_client,
       Regex.scan(@http_client_rx, code)
       |> List.flatten()
       |> Enum.map(&String.trim_trailing(&1, "("))},
      {:http_server, Regex.scan(@http_server_rx, code) |> List.flatten()},
      {:plug_conn, Regex.scan(@plug_conn_rx, code) |> List.flatten()}
    ]
    |> Map.new(fn {family, hits} -> {family, Enum.uniq(hits)} end)
    |> Map.filter(fn {_family, hits} -> hits != [] end)
  end

  defp perimeter?(path), do: String.starts_with?(path, @perimeter_prefix)

  defp protocol_census do
    protocol_sources = repo_sources([@protocol_glob])

    {classified, extras} =
      Enum.split_with(protocol_sources, fn {path, _src} ->
        perimeter?(path) or Map.has_key?(@pinned_io_modules, path)
      end)

    classified_map = Map.new(classified)
    extras_map = Map.new(extras)

    {perimeter, rest} =
      Map.split(classified_map, Map.keys(classified_map) |> Enum.filter(&perimeter?/1))

    {pinned, _} = Map.split(rest, Map.keys(@pinned_io_modules))

    # every non-perimeter, non-pinned module must have zero I/O of any family;
    # clean ones are the pure codec set, dirty ones are findings.
    {impure_list, pure_list} =
      extras_map
      |> Enum.map(fn {path, src} -> {path, io_families(src)} end)
      |> Enum.split_with(fn {_path, families} -> families != %{} end)

    {%{pure: Map.new(pure_list), perimeter: perimeter, pinned: pinned}, Map.new(impure_list)}
  end

  defp compiled_behaviours(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         path when path not in [:non_existing, false, nil] <- :code.which(module),
         beam_path <- path |> to_string() |> String.to_charlist(),
         {:ok, {^module, chunks}} <- :beam_lib.chunks(beam_path, [:attributes]),
         attrs when is_list(attrs) <- Keyword.get(chunks, :attributes) do
      Keyword.get(attrs, :behaviour, [])
    else
      other ->
        raise "beam for #{inspect(module)} is not readable — cannot run court (d) (got #{inspect(other)})"
    end
  end

  # ---------------------------------------------------------------------------
  # Court (a) — perimeter purity
  # ---------------------------------------------------------------------------

  describe "court (a): perimeter purity of lib/ash_a2a/protocol/**" do
    test "perimeter (plug*) is present" do
      {census, _} = protocol_census()
      assert map_size(census.perimeter) > 0, "expected protocol/plug* perimeter modules"

      for path <- Map.keys(census.perimeter) do
        assert String.starts_with?(path, @perimeter_prefix),
               "perimeter misclassification: #{path}"
      end
    end

    test "pinned I/O modules exist and match their pin exactly" do
      {census, _} = protocol_census()

      assert MapSet.new(Map.keys(census.pinned)) ==
               MapSet.new(Map.keys(@pinned_io_modules)),
             "the pinned I/O module set drifted; update the FINDING PIN with a court change"

      for {path, {kind, expected_calls}} <- @pinned_io_modules do
        source = census.pinned[path]
        families = io_families(source)

        expected = %{kind => MapSet.new(expected_calls)}

        actual =
          families
          |> Map.filter(fn {_f, hits} -> hits != [] end)
          |> Map.new(fn {f, hits} -> {f, MapSet.new(hits)} end)

        assert actual == expected,
               "side-effect surface of pinned module #{path} drifted:\nexpected #{inspect(expected)}\ngot #{inspect(actual)}"
      end
    end

    test "every other non-perimeter protocol module is I/O-free" do
      {_, impure_extras} = protocol_census()

      assert impure_extras == %{},
             "codec layer gained I/O outside the perimeter and the FINDING PIN:\n" <>
               Enum.map_join(impure_extras, "\n", fn {path, families} ->
                 "  #{path}: #{inspect(families)}"
               end)
    end

    test "census covers the full protocol tree" do
      {census, impure_extras} = protocol_census()
      total = map_size(census.pure) + map_size(census.perimeter) + map_size(census.pinned)

      assert total == map_size(repo_sources([@protocol_glob]))
      assert total >= 40, "protocol tree unexpectedly small — glob broken?"
      assert impure_extras == %{}, "unexpected impure extras (see court (a) findings)"
    end
  end

  # ---------------------------------------------------------------------------
  # Court (b) — single-source constants
  # ---------------------------------------------------------------------------

  describe "court (b): single-source protocol version constants" do
    test "AshA2A.Protocol.Version.protocol_version() == \"1.0\"" do
      assert AshA2A.Protocol.Version.protocol_version() == "1.0"
    end

    test "no \"0.3.0\" literals in protocol/** or capability_index/**" do
      sources = repo_sources([@protocol_glob, @cap_index_glob, @cap_index_root])

      for {path, source} <- sources do
        hits =
          code_lines(source)
          |> Enum.filter(&String.contains?(&1, ~s("0.3.0")))

        assert hits == [],
               "#{path} hardcodes the legacy \"0.3.0\" protocol version:\n#{Enum.join(hits, "\n")}"
      end
    end

    test "no \"2.0\" literals in protocol-version position in protocol/** or capability_index/**" do
      sources = repo_sources([@protocol_glob, @cap_index_glob, @cap_index_root])

      # JSON-RPC wire version (`"jsonrpc" => "2.0"` or `jsonrpc: "2.0"`) is the
      # JSON-RPC version, not the A2A protocol version — allowed only in
      # jsonrpc-keyed position.
      allowed_rx = ~r/(?:"jsonrpc"|jsonrpc:)\s*(?:=>\s*)?"2\.0"/

      forbidden_rx =
        ~r/protocol_version:\s*"2\.0"|"protocolVersion"\s*=>\s*"2\.0"|"protocolVersion"\s*:\s*"2\.0"|"A2A-Version"\s*=>?\s*"2\.0"/

      for {path, source} <- sources do
        for line <- code_lines(source) do
          if String.contains?(line, ~s("2.0")) do
            assert line =~ allowed_rx,
                   "#{path}: bare \"2.0\" literal outside JSON-RPC wire position: #{String.trim(line)}"
          end

          refute line =~ forbidden_rx,
                 "#{path} hardcodes \"2.0\" in protocol-version position: #{String.trim(line)}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Court (c) — fail-closed surfaces
  # ---------------------------------------------------------------------------

  describe "court (c): fail-closed surfaces" do
    @tag :tmp_dir
    test "ToA2AError Any fallback returns -32603 with an opaque ref and no detail", %{tmp_dir: _} do
      error =
        AshA2A.ToA2AError.to_a2a_error({:opaque, %RuntimeError{message: "SECRET-SERVER-DETAIL"}},
          "req-arch-1"
        )

      assert %{"error" => err, "jsonrpc" => "2.0", "id" => "req-arch-1"} = error
      assert err["code"] == -32_603
      assert err["message"] == "Internal error"

      refute err["message"] =~ "SECRET-SERVER-DETAIL"
      refute inspect(error) =~ "SECRET-SERVER-DETAIL"

      assert %{"ref" => ref} = err["data"]
      assert is_binary(ref)
      assert ref =~ ~r/^[0-9a-f]{16}$/

      refute Map.has_key?(err["data"], "detail"),
             "fail-closed violated: Any fallback leaked detail without expose_error_detail"
    end

    test "VerifySkills is registered in lib/ash_a2a.ex verifier list" do
      source = File.read!("lib/ash_a2a.ex")

      assert String.contains?(source, "AshA2A.Verifiers.VerifySkills"),
             "VerifySkills missing from the verifier list in lib/ash_a2a.ex"

      assert {:module, AshA2A.Verifiers.VerifySkills} = Code.ensure_loaded(AshA2A.Verifiers.VerifySkills)

      assert source =~ ~r/verifiers:\s*\[[^\]]*AshA2A\.Verifiers\.VerifySkills/,
             "VerifySkills is not inside the `verifiers:` list"
    end

    test "installer contains no add_dep({:a2a call" do
      source = File.read!("lib/mix/tasks/ash_a2a.install.ex")
      assert byte_size(source) > 0

      refute source =~ ~r/add_dep\(\s*igniter,\s*\{:a2a\b/,
             "installer re-introduces the external {:a2a dependency"

      refute source =~ ~r/add_dep\(\s*\{:a2a\b/,
             "installer re-introduces the external {:a2a dependency"

      # sanity: the installer is real igniter content, not an empty stub
      assert String.contains?(source, "use Igniter.Mix.Task"),
             "installer does not look like an Igniter task"
    end
  end

  # ---------------------------------------------------------------------------
  # Court (d) — router surface inventory
  # ---------------------------------------------------------------------------

  describe "court (d): router surface inventory" do
    test "all four transports implement @behaviour Plug with call/2 and init/1" do
      for transport <- @transports do
        assert Plug in compiled_behaviours(transport),
               "#{inspect(transport)} beam does not declare @behaviour Plug (got #{inspect(compiled_behaviours(transport))})"

        assert function_exported?(transport, :init, 1),
               "#{inspect(transport)} does not export init/1"

        assert function_exported?(transport, :call, 2),
               "#{inspect(transport)} does not export call/2"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Court (e) — external-dependency perimeter
  # ---------------------------------------------------------------------------

  describe "court (e): external-dependency perimeter" do
    test "mix.exs declares no {:a2a dependency" do
      source = File.read!("mix.exs")
      refute source =~ ~r/\{:a2a\s*,/, "mix.exs declares the external {:a2a dependency"
    end

    test "mix.lock has no \"a2a\" entry" do
      lock = File.read!("mix.lock")

      refute lock =~ ~r/^\s*"a2a"\s*:/m,
             "mix.lock still locks the a2a package"
    end
  end
end
