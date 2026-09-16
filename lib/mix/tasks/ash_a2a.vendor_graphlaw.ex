defmodule Mix.Tasks.AshA2a.VendorGraphlaw do
  @shortdoc "Rebuilds, executes, and vendors the GraphLaw wasm law package into priv/graphlaw"

  @moduledoc """
  Vendors the GraphLaw semantic law package (RFC-SA2A-001 S21, S46, S79).

  GraphLaw is the user's own prior Rust work (`praxis-graphlaw`) -- this task
  packages it, it does not reimplement it. The Elixir side owns no validation
  logic whatsoever.

  ## What it does

      1. locate the praxis checkout      (--praxis, else $PRAXIS_ROOT, else ~/praxis)
      2. wasm-pack build --release       (real build, real toolchain)
      3. EXECUTE the freshly built wasm  (never vendor an unexecuted artifact)
      4. copy into priv/graphlaw/ + write MANIFEST.json with real digests

  Step 3 is not a smoke test. It asserts real semantic properties over the
  committed conformance fixtures: two Turtle documents that differ only in
  prefix label and triple order must produce the SAME `graph_hash`, one with a
  changed triple must produce a DIFFERENT one, and `blake3_hex("abc")` must
  equal the published BLAKE3 test vector. An artifact that fails any of these
  is rejected and nothing is written.

  ## Usage

      mix ash_a2a.vendor_graphlaw
      mix ash_a2a.vendor_graphlaw --praxis /path/to/praxis --target web
      mix ash_a2a.vendor_graphlaw --dry-run

  ## Options

    * `--praxis PATH`     -- praxis checkout. Default `$PRAXIS_ROOT`, else `~/praxis`.
    * `--target TARGET`   -- wasm-pack target (`bundler`, `web`, `nodejs`, ...).
                             Default `bundler`. The `.wasm` is instantiated
                             directly, so the target only affects the JS glue
                             this repository does not use; see
                             `docs/explanation/graphlaw-wasm-integration.md`.
    * `--out-dir PATH`    -- wasm-pack output directory. Default a temp dir.
    * `--target-dir PATH` -- value for `CARGO_TARGET_DIR`, to keep build
                             artifacts out of the praxis checkout.
    * `--dest PATH`       -- destination law-package dir. Default `priv/graphlaw`.
    * `--dry-run`         -- build and execute, but write nothing.

  ## Absent praxis

  This task requires a praxis checkout and a Rust toolchain; a consumer of
  `ash_a2a` has neither. That is expected and handled: the task exits with a
  typed `:praxis_not_found` error and changes nothing, while the committed
  artifact, manifest, fixtures, and `mix ash_a2a.verify_graphlaw` all keep
  working with no praxis present at all.
  """

  use Mix.Task

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.GraphLaw.Vendor
  alias AshA2A.GraphLaw.WasmHost

  @switches [
    praxis: :string,
    target: :string,
    out_dir: :string,
    target_dir: :string,
    dest: :string,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    dest_dir = opts[:dest] || GraphLaw.dir()

    case vendor(opts, dest_dir) do
      {:ok, report} -> report_success(report, opts, dest_dir)
      {:error, error} -> report_failure(error)
    end
  end

  defp vendor(opts, dest_dir) do
    with {:ok, praxis} <- locate(opts),
         {:ok, build} <- build(praxis, opts),
         {:ok, probe} <- execute(build.wasm_path),
         :ok <- accept(probe) do
      finish(praxis, build, probe, opts, dest_dir)
    end
  end

  defp locate(opts) do
    case Vendor.locate_praxis(praxis: opts[:praxis]) do
      {:ok, praxis} ->
        Mix.shell().info("praxis checkout: #{praxis}")
        {:ok, praxis}

      error ->
        error
    end
  end

  defp build(praxis, opts) do
    target = opts[:target] || "bundler"
    Mix.shell().info("wasm-pack build --release --target #{target} (this is slow)")

    Vendor.build(praxis,
      target: target,
      out_dir: opts[:out_dir],
      target_dir: opts[:target_dir]
    )
  end

  defp execute(wasm_path) do
    Mix.shell().info("executing freshly built artifact: #{wasm_path}")
    WasmHost.probe(wasm_path: wasm_path)
  end

  defp accept(probe) do
    case WasmHost.probe_failures(probe) do
      [] ->
        Mix.shell().info("  graphlaw_version()       = #{probe.graphlaw_version}")
        Mix.shell().info("  graph_hash(base.ttl)     = #{probe.graph_hash_base}")
        Mix.shell().info("  canonical order invariant: PASS")
        Mix.shell().info("  distinct graph distinct  : PASS")
        Mix.shell().info("  blake3_hex(\"abc\") vector : PASS")
        :ok

      failures ->
        {:error,
         %{
           code: :artifact_rejected,
           message:
             "freshly built artifact failed acceptance and was NOT vendored:\n  - " <>
               Enum.join(failures, "\n  - ")
         }}
    end
  end

  defp finish(praxis, build, probe, opts, dest_dir) do
    provenance = Vendor.provenance(praxis, target: build.target)

    blake3 =
      case Manifest.blake3_hex(build.wasm_path) do
        {:ok, hex} ->
          hex

        {:skipped, reason} ->
          Mix.shell().info("  blake3: skipped (#{reason})")
          nil
      end

    if opts[:dry_run] do
      {:ok, %{dry_run: true, probe: probe, provenance: provenance, blake3: blake3}}
    else
      case Vendor.install(build.wasm_path, probe, provenance, dest_dir: dest_dir, blake3: blake3) do
        {:ok, installed} -> {:ok, Map.put(installed, :dry_run, false)}
        error -> error
      end
    end
  end

  defp report_success(%{dry_run: true}, _opts, _dest) do
    Mix.shell().info("--dry-run: artifact built and executed successfully; nothing written.")
  end

  defp report_success(report, _opts, dest_dir) do
    artifact = report.manifest_body["artifact"]

    Mix.shell().info("""
    vendored GraphLaw law package -> #{dest_dir}
      artifact : #{report.artifact}
      bytes    : #{artifact["bytes"]}
      sha256   : #{artifact["sha256"]}
      blake3   : #{artifact["blake3"] || "(skipped: no b3sum)"}
      manifest : #{report.manifest}
    Verify at any time (no praxis checkout needed): mix ash_a2a.verify_graphlaw
    """)
  end

  defp report_failure(%{code: code} = error) do
    detail =
      case Map.get(error, :log) do
        nil -> ""
        log -> "\n\n--- real tool output (tail) ---\n" <> tail(log, 4000)
      end

    Mix.raise("[#{code}] #{error.message}#{detail}")
  end

  defp tail(text, n) do
    len = String.length(text)
    if len <= n, do: text, else: String.slice(text, (len - n)..(len - 1))
  end
end
