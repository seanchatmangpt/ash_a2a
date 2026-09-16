defmodule AshA2A.GraphLaw.Vendor do
  @moduledoc """
  The GraphLaw law-package vendor pipeline (RFC-SA2A-001 S21, S46, S79).

  Turns a praxis checkout into a content-addressed law package under
  `priv/graphlaw/`. The pipeline is deliberately a plain module rather than
  logic embedded in a Mix task, so each hop is independently callable and
  independently testable with real inputs.

  ## Hops

    1. `locate_praxis/1` -- resolve the praxis checkout (flag, then env, then
       a conventional default). Never a single hardcoded absolute path.
    2. `build/2` -- run the real `wasm-pack` over `praxis-graphlaw-wasm`.
    3. `AshA2A.GraphLaw.WasmHost.probe/1` -- **execute** the freshly built
       artifact. An artifact that has not been run is never vendored.
    4. `install/3` -- copy the accepted artifact into `priv/graphlaw/` and
       write `MANIFEST.json`.

  Every hop returns `{:ok, _}` or a typed `{:error, %{code: atom()}}`. The
  interesting failure modes are real and measured, not hypothetical: at the
  time this pipeline was written, `praxis-graphlaw` at praxis HEAD did not
  compile for `wasm32-unknown-unknown` at all (oxigraph's `Store::open` is
  absent in a wasm build), which surfaces here as `:wasm_pack_failed` with the
  real compiler output attached.

  ## Absent praxis is a first-class state, not a crash

  A consumer of `ash_a2a` has the committed artifact and manifest and no
  praxis checkout whatsoever. `locate_praxis/1` returns
  `{:error, %{code: :praxis_not_found}}` for them, and nothing else in this
  repository depends on the rebuild path -- `AshA2A.GraphLaw.WasmHost` and
  `mix ash_a2a.verify_graphlaw` operate purely on what is committed.
  """

  alias AshA2A.GraphLaw
  alias AshA2A.GraphLaw.Manifest
  alias AshA2A.GraphLaw.WasmHost

  @wasm_crate "crates/praxis-graphlaw-wasm"
  @graphlaw_crate "crates/praxis-graphlaw"
  @default_praxis "~/praxis"
  @default_target "bundler"

  @doc """
  Resolves the praxis checkout directory.

  Order: `opts[:praxis]`, then `$PRAXIS_ROOT`, then `~/praxis`. The result is
  accepted only if it actually contains `crates/praxis-graphlaw-wasm/Cargo.toml`,
  so a stale env var fails loudly instead of producing a confusing cargo error.
  """
  @spec locate_praxis(keyword()) :: {:ok, String.t()} | {:error, map()}
  def locate_praxis(opts \\ []) do
    candidate =
      opts[:praxis] || System.get_env("PRAXIS_ROOT") || @default_praxis

    root = Path.expand(candidate)
    marker = Path.join([root, @wasm_crate, "Cargo.toml"])

    if File.exists?(marker) do
      {:ok, root}
    else
      {:error,
       %{
         code: :praxis_not_found,
         message:
           "no praxis checkout at #{root} (expected #{marker}). " <>
             "Pass --praxis <dir> or set PRAXIS_ROOT. This is not fatal for " <>
             "consumers: the committed priv/graphlaw artifact and manifest " <>
             "remain usable without a praxis checkout."
       }}
    end
  end

  @doc """
  Runs the real `wasm-pack build --release` over `praxis-graphlaw-wasm`.

  Options: `:target` (default `"bundler"`), `:out_dir` (default a fresh
  directory under `System.tmp_dir!/0`), `:wasm_pack` (executable path),
  `:target_dir` (value for `CARGO_TARGET_DIR`).

  Returns `{:ok, %{wasm_path: path, out_dir: dir, target: target, log: output}}`.
  Typed errors: `:wasm_pack_not_found`, `:wasm_pack_failed` (the real combined
  stdout/stderr is carried in `:log`), `:wasm_output_missing`.
  """
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def build(praxis_root, opts \\ []) do
    target = Keyword.get(opts, :target, @default_target)
    exe = Keyword.get(opts, :wasm_pack) || System.get_env("WASM_PACK") || "wasm-pack"

    out_dir =
      Keyword.get(opts, :out_dir) ||
        Path.join(System.tmp_dir!(), "ash_a2a_graphlaw_pkg_#{System.unique_integer([:positive])}")

    crate_dir = Path.join(praxis_root, @wasm_crate)

    case System.find_executable(exe) do
      nil ->
        {:error,
         %{
           code: :wasm_pack_not_found,
           message: "no `#{exe}` executable on PATH. Install wasm-pack or set WASM_PACK."
         }}

      wasm_pack ->
        env =
          case Keyword.get(opts, :target_dir) do
            nil -> []
            dir -> [{"CARGO_TARGET_DIR", Path.expand(dir)}]
          end

        args = [
          "build",
          "--release",
          "--target",
          target,
          "--out-dir",
          Path.expand(out_dir),
          "--out-name",
          "praxis_graphlaw_wasm"
        ]

        {log, code} =
          System.cmd(wasm_pack, args,
            cd: crate_dir,
            env: env,
            stderr_to_stdout: true
          )

        built = Path.join(Path.expand(out_dir), "praxis_graphlaw_wasm_bg.wasm")

        cond do
          code != 0 ->
            {:error,
             %{
               code: :wasm_pack_failed,
               message: "wasm-pack exited #{code} for target #{target}",
               log: log
             }}

          not File.exists?(built) ->
            {:error,
             %{
               code: :wasm_output_missing,
               message: "wasm-pack exited 0 but produced no #{built}",
               log: log
             }}

          true ->
            {:ok, %{wasm_path: built, out_dir: Path.expand(out_dir), target: target, log: log}}
        end
    end
  end

  @doc """
  Copies `wasm_path` into `priv/graphlaw/` and writes `MANIFEST.json`.

  `probe` is the real `AshA2A.GraphLaw.WasmHost.probe/1` result for *this*
  artifact; `provenance` is the map from `provenance/2`. Returns
  `{:ok, %{artifact: path, manifest: path, manifest_body: map}}`.
  """
  @spec install(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def install(wasm_path, probe, provenance, opts \\ []) do
    dest_dir = Keyword.get(opts, :dest_dir, GraphLaw.dir())
    dest = Path.join(dest_dir, GraphLaw.artifact_name())
    manifest_path = Path.join(dest_dir, "MANIFEST.json")

    with {:ok, bytes} <- read_artifact(wasm_path) do
      File.mkdir_p!(dest_dir)
      File.write!(dest, bytes)
      copied = copy_support_files(dest_dir)

      manifest = manifest(bytes, probe, provenance, opts)
      Manifest.write!(manifest, manifest_path)

      {:ok,
       %{
         artifact: dest,
         manifest: manifest_path,
         manifest_body: manifest,
         support_files: copied
       }}
    end
  end

  # A vendored law package must be self-contained: `mix ash_a2a.verify_graphlaw
  # --dir <that dir>` has to be able to execute the artifact using only what is
  # inside it. When the destination *is* the canonical `priv/graphlaw`, the
  # files are already in place and this is a no-op.
  defp copy_support_files(dest_dir) do
    source = GraphLaw.dir()

    if Path.expand(dest_dir) == Path.expand(source) do
      []
    else
      for relative <- ["host/graphlaw_host.mjs" | Enum.map(fixtures(), &"fixtures/#{&1}")],
          File.exists?(Path.join(source, relative)) do
        target = Path.join(dest_dir, relative)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(Path.join(source, relative), target)
        relative
      end
    end
  end

  @doc "Names of the committed conformance fixtures, in probe order."
  @spec fixtures() :: [String.t()]
  def fixtures, do: ["base.ttl", "reordered.ttl", "mutated.ttl"]

  @doc """
  Builds the manifest document for an artifact's bytes, its executed probe,
  and a provenance map.

  Pure: it computes digests and shapes the document; it performs no I/O other
  than the real `b3sum` invocation behind `AshA2A.GraphLaw.Manifest.blake3_hex/2`.
  """
  @spec manifest(binary(), map(), map(), keyword()) :: map()
  def manifest(bytes, probe, provenance, opts \\ []) do
    blake3 =
      case Keyword.get(opts, :blake3) do
        nil -> nil
        hex -> hex
      end

    %{
      "schema" => Manifest.schema(),
      "artifact" => %{
        "name" => GraphLaw.artifact_name(),
        "bytes" => byte_size(bytes),
        "sha256" => Manifest.sha256_hex(bytes),
        "blake3" => blake3
      },
      "graphlaw_version" => probe.graphlaw_version,
      "provenance" => provenance,
      "host_abi" => host_abi(probe),
      "verification" => verification(probe, opts)
    }
  end

  @doc """
  Collects the real provenance of a build: praxis git SHA and dirtiness, the
  two crate versions, the real `wasm-pack --version` and `rustc --version`
  strings, the wasm-pack target, and an ISO-8601 UTC build timestamp.

  Every field is measured by actually running the tool or reading the real
  file; unavailable fields are `nil`, never guessed.
  """
  @spec provenance(String.t() | nil, keyword()) :: map()
  def provenance(praxis_root, opts \\ []) do
    %{
      "praxis_root_at_build" => praxis_root,
      "praxis_git_sha" => git(praxis_root, ["rev-parse", "HEAD"]),
      "praxis_git_describe" => git(praxis_root, ["describe", "--always", "--dirty", "--tags"]),
      "praxis_git_dirty" => git_dirty(praxis_root),
      "wasm_crate" => "praxis-graphlaw-wasm",
      "wasm_crate_version" => crate_version(praxis_root, @wasm_crate),
      "graphlaw_crate" => "praxis-graphlaw",
      "graphlaw_crate_version" => crate_version(praxis_root, @graphlaw_crate),
      "wasm_pack_version" => tool_version(Keyword.get(opts, :wasm_pack, "wasm-pack")),
      "wasm_pack_target" => Keyword.get(opts, :target, @default_target),
      "rustc_version" => tool_version(Keyword.get(opts, :rustc, "rustc")),
      "rust_target" => "wasm32-unknown-unknown",
      "built_at" => Keyword.get(opts, :built_at) || DateTime.utc_now() |> DateTime.to_iso8601(),
      "vendored_by" => "mix ash_a2a.vendor_graphlaw"
    }
  end

  @doc """
  Reads the crate version out of a `Cargo.toml` without a TOML parser: the
  first `version = "..."` line at the top level of the file. Returns `nil`
  when the file is absent or has no such line.
  """
  @spec crate_version(String.t() | nil, String.t()) :: String.t() | nil
  def crate_version(nil, _relative), do: nil

  def crate_version(praxis_root, relative) do
    path = Path.join([praxis_root, relative, "Cargo.toml"])

    with {:ok, body} <- File.read(path),
         [_, version] <- Regex.run(~r/^version\s*=\s*"([^"]+)"/m, body) do
      version
    else
      _ -> nil
    end
  end

  defp host_abi(probe) do
    %{
      "note" =>
        "The module is instantiated directly; wasm-pack's JS glue is not used. " <>
          "See docs/explanation/graphlaw-wasm-integration.md.",
      "imports" => probe.imports,
      "exports" => probe.exports,
      "string_abi" => %{
        "malloc" => "__wbindgen_export2(len, align) -> ptr",
        "realloc" => "__wbindgen_export3(ptr, old_len, new_len, align) -> ptr",
        "free" => "__wbindgen_export4(ptr, len, align) -> ()",
        "ret_area" => "__wbindgen_add_to_stack_pointer(-16) -> retptr, +16 to restore",
        "call" => "fn(retptr, ptr0, len0, ...) then read two LE i32 at retptr+0/+4 => (ptr, len)"
      }
    }
  end

  defp verification(probe, opts) do
    %{
      "verified_at" =>
        Keyword.get(opts, :verified_at) || DateTime.utc_now() |> DateTime.to_iso8601(),
      "method" =>
        "real WebAssembly instantiation and execution via priv/graphlaw/host/graphlaw_host.mjs",
      "graphlaw_version" => probe.graphlaw_version,
      "blake3_hex_abc" => probe.blake3_abc,
      "blake3_hex_abc_matches_published_vector" => probe.blake3_abc_matches_published_vector,
      "fixtures" => %{
        "base.ttl" => probe.graph_hash_base,
        "reordered.ttl" => probe.graph_hash_reordered,
        "mutated.ttl" => probe.graph_hash_mutated
      },
      "canonical_order_invariant" => probe.canonical_order_invariant,
      "distinct_graph_distinct_hash" => probe.distinct_graph_distinct_hash
    }
  end

  defp read_artifact(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error,
         %{
           code: :artifact_not_found,
           message: "cannot read built artifact #{path}: #{:file.format_error(reason)}"
         }}
    end
  end

  defp git(nil, _args), do: nil

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp git_dirty(nil), do: nil

  defp git_dirty(root) do
    case System.cmd("git", ["-C", root, "status", "--porcelain"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> nil
    end
  end

  defp tool_version(exe) do
    case System.find_executable(exe) do
      nil ->
        nil

      path ->
        case System.cmd(path, ["--version"], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end
    end
  end

  @doc false
  def probe_module, do: WasmHost
end
