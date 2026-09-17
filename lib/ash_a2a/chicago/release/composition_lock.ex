defmodule AshA2A.Chicago.Release.CompositionLock do
  @moduledoc """
  RFC-SA2A-003 v26.9.17 §85 `composition-lock.json` -- bounded, for real, to
  ash_a2a's own load-bearing dependency closure.

  ## Scope -- explicitly NOT the full RFC-SA2A-003 11-repo composition lock

  §85's composition lock, at full RFC-SA2A-003 scope, pins every one of the
  11 repositories' own release artifacts against each other. That is out of
  scope here (autofde-lab, the primary integration court, is a separate,
  concurrently-active repository this task must not touch). `build!/1`
  instead pins the two real, load-bearing dependency surfaces this session's
  actual work touches inside ash_a2a itself:

    * `tracked_dependencies` -- the real pinned `{version, checksum}` for a
      fixed set of load-bearing Hex packages (see `tracked/0` --
      `ash`/`a2a`/`ekv`/`wasmex`/`rdf`, the packages this repo's own real
      Chicago court + release machinery, receipt store, and GraphLaw runtime
      actually depend on), read for real out of `mix.lock` via
      `Code.eval_file/1` (mix.lock is itself valid Elixir term syntax -- the
      same technique Mix's own lock reader uses; nothing here re-derives or
      guesses a version).
    * `native_pins` -- the real pinned `ferroplan` / `ferroplan-hddl` git
      revisions this repo's `native/hddl_cli/Cargo.toml` declares, read for
      real out of that file's `rev = "..."` dependency lines.

  `mix_lock_sha256` additionally content-addresses the *entire* real
  `mix.lock` file (not just the tracked subset), so a change anywhere in the
  full dependency closure is still detectable even though only the tracked
  subset is itemized above.
  """

  @schema "ash_a2a.chicago.release.composition_lock/1"

  @tracked ~w(ash a2a ekv wasmex rdf)

  @scope_disclosure """
  This composition lock is BOUNDED TO ash_a2a's own load-bearing dependency \
  closure (a fixed set of Hex packages this session's real work depends on, \
  pinned from this repo's own mix.lock) plus this repo's own \
  native/hddl_cli ferroplan git-rev pin. It does NOT claim the full \
  RFC-SA2A-003 §85 11-repo cross-repository composition lock, which \
  requires autofde-lab as primary integration court -- that is explicitly \
  out of scope for this document.\
  """

  @enforce_keys [:tracked_dependencies, :native_pins, :mix_lock_sha256]
  defstruct [
    :tracked_dependencies,
    :native_pins,
    :mix_lock_sha256,
    scope_disclosure: @scope_disclosure
  ]

  @type pin :: %{String.t() => String.t() | nil}

  @type t :: %__MODULE__{
          tracked_dependencies: %{String.t() => pin()},
          native_pins: %{String.t() => String.t() | nil},
          mix_lock_sha256: String.t() | nil,
          scope_disclosure: String.t()
        }

  @doc "Document schema identity."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The fixed set of load-bearing Hex package names this lock tracks."
  @spec tracked() :: [String.t()]
  def tracked, do: @tracked

  @doc "The scope-disclosure text every built document carries verbatim."
  @spec scope_disclosure() :: String.t()
  def scope_disclosure, do: @scope_disclosure

  @doc """
  Builds the real §85 composition-lock document.

  Options:

    * `:repo` -- ash_a2a's own repo path (default `File.cwd!/0`); `mix.lock`
      is read from `Path.join(repo, "mix.lock")`.
    * `:native_manifest` -- path to the Cargo manifest carrying the
      ferroplan git-rev pins (default
      `Path.join(repo, "native/hddl_cli/Cargo.toml")`).
    * `:tracked` -- Hex package names to pin (default `tracked/0`).
  """
  @spec build!(keyword()) :: t()
  def build!(opts \\ []) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    lock_path = Path.join(repo, "mix.lock")

    manifest_path =
      Keyword.get(opts, :native_manifest, Path.join(repo, "native/hddl_cli/Cargo.toml"))

    tracked = Keyword.get(opts, :tracked, @tracked)

    %__MODULE__{
      tracked_dependencies: tracked_dependencies(lock_path, tracked),
      native_pins: native_pins(manifest_path),
      mix_lock_sha256: file_sha256(lock_path),
      scope_disclosure: @scope_disclosure
    }
  end

  @doc """
  Real `{version, checksum}` pins for `packages`, read out of the real
  `mix.lock` at `lock_path`. `mix.lock` is valid Elixir term syntax (a map
  literal), so it is read with `Code.eval_file/1` -- the same approach Mix's
  own lock reader uses -- never hand-parsed or guessed. A package absent
  from the lock (or an unreadable lock file) yields `nil` version/checksum
  for that package, recorded rather than invented.
  """
  @spec tracked_dependencies(Path.t(), [String.t()]) :: %{String.t() => pin()}
  def tracked_dependencies(lock_path, packages \\ @tracked) do
    lock = read_mix_lock(lock_path)

    Map.new(packages, fn package ->
      entry = Map.get(lock, String.to_atom(package))
      {package, pin_from_entry(entry)}
    end)
  end

  @doc """
  Real ferroplan / ferroplan-hddl git-rev pins, read out of the real
  `Cargo.toml` at `manifest_path` via a `rev = "..."` regex match per
  dependency line -- never invented, `nil` for a dependency line the
  manifest does not declare or a manifest that cannot be read.
  """
  @spec native_pins(Path.t()) :: %{String.t() => String.t() | nil}
  def native_pins(manifest_path) do
    case File.read(manifest_path) do
      {:ok, contents} ->
        %{
          "ferroplan" => dependency_rev(contents, "ferroplan"),
          "ferroplan-hddl" => dependency_rev(contents, "ferroplan-hddl")
        }

      {:error, _} ->
        %{"ferroplan" => nil, "ferroplan-hddl" => nil}
    end
  end

  @doc "JSON-map form of the document (§85 `composition-lock.json` shape)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = lock) do
    %{
      "schema" => @schema,
      "tracked_dependencies" => lock.tracked_dependencies,
      "native_pins" => lock.native_pins,
      "mix_lock_sha256" => lock.mix_lock_sha256,
      "scope_disclosure" => lock.scope_disclosure
    }
  end

  # --- mix.lock --------------------------------------------------------------

  defp read_mix_lock(lock_path) do
    case File.regular?(lock_path) do
      true ->
        {term, _bindings} = Code.eval_file(lock_path)
        if is_map(term), do: term, else: %{}

      false ->
        %{}
    end
  rescue
    _ -> %{}
  end

  # mix.lock entry shape: {:hex, name, version, outer_checksum, managers,
  # deps, repo, inner_checksum} (or a shorter git/path tuple for non-hex
  # sources) -- version is always position 3, the trailing checksum is the
  # last element, read positionally rather than guessed.
  defp pin_from_entry(nil), do: %{"version" => nil, "checksum" => nil}

  defp pin_from_entry(entry) when is_tuple(entry) do
    values = Tuple.to_list(entry)

    %{
      "version" => Enum.at(values, 2),
      "checksum" => List.last(values)
    }
  end

  defp pin_from_entry(_), do: %{"version" => nil, "checksum" => nil}

  # --- Cargo.toml --------------------------------------------------------------

  defp dependency_rev(contents, name) do
    pattern =
      Regex.compile!(
        "^" <> Regex.escape(name) <> "\\s*=\\s*\\{[^}]*rev\\s*=\\s*\"([0-9a-fA-F]+)\"",
        "m"
      )

    case Regex.run(pattern, contents) do
      [_, rev] -> rev
      _ -> nil
    end
  end

  # --- digests ------------------------------------------------------------

  defp file_sha256(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      {:error, _} -> nil
    end
  end
end
