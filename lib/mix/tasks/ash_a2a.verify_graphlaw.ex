defmodule Mix.Tasks.AshA2a.VerifyGraphlaw do
  @shortdoc "Verifies the committed GraphLaw wasm law package against its manifest (CI-suitable)"

  @moduledoc """
  Verifies the committed GraphLaw law package (RFC-SA2A-001 S21, S27).

  Two independent checks, both real:

    * **Content address.** Recompute the real SHA-256 (and, when a `b3sum`
      executable is available, the real BLAKE3) of `priv/graphlaw/*.wasm` and
      compare with `MANIFEST.json`. Also recompute the manifest's own
      `content_digest` over its canonical serialization.
    * **Execution.** Actually instantiate and run the artifact, and re-assert
      the same semantic properties the vendor task accepted it on: canonical
      graph identity across prefix-label and triple-order permutation, a
      different hash for a different graph, and `blake3_hex("abc")` matching
      the published BLAKE3 test vector.

  A digest match alone is not acceptance. A file can hash correctly and still
  be a module that no longer runs, so this task refuses to pass on digests
  alone -- unless execution is genuinely impossible on this host, in which
  case it says so by name (`--allow-skip-exec`) rather than quietly passing.

  Needs **no praxis checkout, no Rust toolchain, and no network**; everything
  it reads is committed in this repository. Per RFC S27 what it reports is a
  projection, never authority: a passing verification is evidence of byte
  identity and live execution, and grants nothing.

  ## Usage

      mix ash_a2a.verify_graphlaw
      mix ash_a2a.verify_graphlaw --allow-skip-exec   # digests only; prints a named SKIP

  ## Options

    * `--dir PATH`          -- law-package dir. Default `priv/graphlaw`.
    * `--allow-skip-exec`   -- if no Node host is available, report a named
                               skip instead of failing. Digest checks still run
                               and still fail hard on mismatch.
  """

  use Mix.Task

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.GraphLaw.WasmHost

  @switches [dir: :string, allow_skip_exec: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    dir = opts[:dir] || GraphLaw.dir()
    manifest_path = Path.join(dir, "MANIFEST.json")
    wasm_path = Path.join(dir, GraphLaw.artifact_name())

    manifest = read_manifest!(manifest_path)
    Mix.shell().info("law package : #{dir}")
    Mix.shell().info("schema      : #{manifest["schema"]}")
    Mix.shell().info("graphlaw    : #{manifest["graphlaw_version"]}")

    verify_content_digest!(manifest, manifest_path)
    verify_artifact_digests!(manifest, wasm_path)
    verify_execution!(manifest, wasm_path, dir, opts)

    Mix.shell().info("GraphLaw law package VERIFIED.")
  end

  defp read_manifest!(path) do
    case Manifest.read(path) do
      {:ok, manifest} -> manifest
      {:error, error} -> Mix.raise("[#{error.code}] #{error.message}")
    end
  end

  defp verify_content_digest!(manifest, path) do
    claimed = manifest["content_digest"]
    actual = Manifest.content_digest(manifest)

    cond do
      is_nil(claimed) ->
        Mix.shell().info("content_digest: ABSENT (manifest predates digest stamping)")

      claimed == actual ->
        Mix.shell().info("content_digest: OK #{actual}")

      true ->
        Mix.raise("""
        [manifest_content_digest_mismatch] #{path}
          claimed : #{claimed}
          actual  : #{actual}
        The manifest body was edited without re-stamping its digest.
        """)
    end
  end

  defp verify_artifact_digests!(manifest, wasm_path) do
    case Manifest.verify_digests(manifest, wasm_path) do
      {:ok, result} ->
        Mix.shell().info("bytes       : OK #{result.bytes_actual}")
        Mix.shell().info("sha256      : OK #{result.sha256_actual}")

        case result.blake3_status do
          :match -> Mix.shell().info("blake3      : OK #{result.blake3_actual}")
          :skipped -> Mix.shell().info("blake3      : SKIP (no b3sum executable on PATH)")
          :unclaimed -> Mix.shell().info("blake3      : SKIP (manifest claims no blake3)")
        end

      {:error, result} ->
        Mix.raise("""
        [#{result.code}] #{result.path}
          bytes  claimed=#{inspect(result.bytes_claimed)} actual=#{result.bytes_actual}
          sha256 claimed=#{inspect(result.sha256_claimed)}
                 actual =#{result.sha256_actual}
          blake3 claimed=#{inspect(result.blake3_claimed)}
                 actual =#{inspect(result.blake3_actual)} (#{result.blake3_status})
        The committed artifact no longer matches its manifest.
        """)
    end
  end

  defp verify_execution!(manifest, wasm_path, dir, opts) do
    host = Path.join(dir, "host/graphlaw_host.mjs")
    probe_opts = [wasm_path: wasm_path, host_path: host, fixtures_dir: Path.join(dir, "fixtures")]

    case WasmHost.probe(probe_opts) do
      {:ok, probe} ->
        assert_probe!(manifest, probe)

      {:error, %{code: :node_not_available} = error} ->
        if opts[:allow_skip_exec] do
          Mix.shell().info("execution   : SKIP (#{error.message})")
        else
          Mix.raise(
            "[#{error.code}] #{error.message}\n" <>
              "Pass --allow-skip-exec to accept a digest-only verification, which is " <>
              "strictly weaker: it proves byte identity, not that the module still runs."
          )
        end

      {:error, error} ->
        Mix.raise("[#{error.code}] #{error.message}")
    end
  end

  defp assert_probe!(manifest, probe) do
    recorded = manifest["verification"] || %{}
    fixtures = recorded["fixtures"] || %{}

    drift =
      [
        {"graphlaw_version", manifest["graphlaw_version"], probe.graphlaw_version},
        {"fixtures.base.ttl", fixtures["base.ttl"], probe.graph_hash_base},
        {"fixtures.reordered.ttl", fixtures["reordered.ttl"], probe.graph_hash_reordered},
        {"fixtures.mutated.ttl", fixtures["mutated.ttl"], probe.graph_hash_mutated}
      ]
      |> Enum.reject(fn {_k, claimed, actual} -> is_nil(claimed) or claimed == actual end)

    failures = WasmHost.probe_failures(probe)

    cond do
      failures != [] ->
        Mix.raise("[execution_semantics_failed]\n  - " <> Enum.join(failures, "\n  - "))

      drift != [] ->
        lines =
          Enum.map(drift, fn {k, claimed, actual} ->
            "  #{k}\n    manifest=#{claimed}\n    actual  =#{actual}"
          end)

        Mix.raise(
          "[execution_drift] artifact runs but no longer agrees with its manifest:\n" <>
            Enum.join(lines, "\n")
        )

      true ->
        Mix.shell().info("execution   : OK (real wasm instantiation)")
        Mix.shell().info("  graphlaw_version()        = #{probe.graphlaw_version}")
        Mix.shell().info("  graph_hash(base.ttl)      = #{probe.graph_hash_base}")
        Mix.shell().info("  canonical order invariant : PASS")
        Mix.shell().info("  distinct graph distinct   : PASS")
        Mix.shell().info("  blake3_hex(\"abc\") vector  : PASS")
    end
  end
end
