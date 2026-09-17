defmodule AshA2A.Chicago.Release.ExactSubject do
  @moduledoc """
  RFC-SA2A-003 v26.9.17 §84 `exact-subject.json` -- release composition
  identity, bounded to ash_a2a's own subject.

  ## Scope -- explicitly NOT the full RFC-SA2A-003 11-repo DO-level release

  RFC-SA2A-003 ("Semantic A2A Operational Closure Release Standard") composes
  an 11-repository release with `autofde-lab` as its primary integration
  court, real external consequence, chaos testing, and cross-runtime WASM
  portability proof. `build!/1` does NOT produce that. It produces the
  narrower, honest thing this repository can actually attest for real: an
  exact-subject document over ash_a2a's own Chicago court machinery, plus the
  real existence/identity of the 11 repos the v26.9.17 HDDL topology names
  (via `AshA2A.Chicago.Courts.SA2AV269_17Topology`, reused rather than
  reimplemented) -- existence, never capability depth, exactly as that
  court's own moduledoc discloses. `scope_disclosure/0` states this in the
  document itself so a consumer of `exact-subject.json` never mistakes
  topology-existence for cross-repository DO-level composition.

  ## Fields (§84)

    * `release` / `release_contract` / `architecture_contract` /
      `conformance_contract` -- the release under qualification and the
      three RFCs it is claimed against.
    * `claimed_profile` -- the conformance profile under claim (default
      `"SA2A-STRICT"`, overridable via `:claimed_profile`).
    * `repositories` -- real, per-repo identity from
      `SA2AV269_17Topology.repos/0` + `check_repo/1` (real `git rev-parse` /
      `git status` subprocesses, not re-derived here).
    * `root_manifest_sha256` -- sha256 over the concatenated real source
      (moduledoc included -- moduledocs are `@moduledoc` attributes inside
      the source text, so hashing full file content covers both) of every
      `lib/ash_a2a/chicago/*.ex` file, sorted by path for determinism. This
      is a self-contained digest scoped to the Chicago court subsystem
      itself, deliberately independent of `AshA2A.Semantic.RootManifest`
      (whose own digest addresses the *runtime's* root manifest pin, a
      different and already-nilable-in-test concern -- see
      `AshA2A.Chicago.Subject.root_manifest_digest/1`).
    * `court_revision` -- this repo's own real git HEAD, obtained by
      reusing `AshA2A.Chicago.Subject.capture/1` (`.source_revision`) rather
      than re-deriving a `git rev-parse` subprocess.
    * `falsifier_corpus_sha256` -- reuses the existing
      `AshA2A.Chicago.StandingReceipt.corpus_digest/1` helper over every
      falsifier declared by every court `AshA2A.Chicago.courts/0` discovers
      (concatenated, sorted by id inside `corpus_digest/1` itself) -- real,
      not a placeholder string, and zero new hashing logic duplicated.
    * `scope_disclosure` -- the explicit narrower-than-RFC text above, as
      data.
  """

  alias AshA2A.Chicago
  alias AshA2A.Chicago.Courts.SA2AV269_17Topology, as: Topology
  alias AshA2A.Chicago.{Json, StandingReceipt, Subject}

  @schema "ash_a2a.chicago.release.exact_subject/1"
  @release "26.9.17"
  @release_contract "RFC-SA2A-003-v26.9.17"
  @architecture_contract "RFC-SA2A-001-v26.9.16"
  @conformance_contract "RFC-SA2A-002-v26.9.16"
  @default_claimed_profile "SA2A-STRICT"

  @scope_disclosure """
  This exact-subject composition is BOUNDED TO ash_a2a's own subject and the \
  11-repo topology-EXISTENCE identity captured by SA2A-TOPO (real git HEAD / \
  dirty-state per repo). It does NOT claim the full RFC-SA2A-003 11-repo \
  cross-repository DO-level composition, which requires autofde-lab as \
  primary integration court -- that is explicitly out of scope for this \
  document.\
  """

  @enforce_keys [
    :release,
    :release_contract,
    :architecture_contract,
    :conformance_contract,
    :claimed_profile,
    :repositories,
    :court_revision
  ]
  defstruct [
    :release,
    :release_contract,
    :architecture_contract,
    :conformance_contract,
    :claimed_profile,
    :repositories,
    :root_manifest_sha256,
    :court_revision,
    :falsifier_corpus_sha256,
    :scope_disclosure
  ]

  @type repository_identity :: %{
          String.t() => String.t() | boolean() | nil
        }

  @type t :: %__MODULE__{
          release: String.t(),
          release_contract: String.t(),
          architecture_contract: String.t(),
          conformance_contract: String.t(),
          claimed_profile: String.t(),
          repositories: [repository_identity()],
          root_manifest_sha256: String.t() | nil,
          court_revision: String.t() | nil,
          falsifier_corpus_sha256: String.t(),
          scope_disclosure: String.t()
        }

  @doc "Document schema identity."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The scope-disclosure text every built document carries verbatim."
  @spec scope_disclosure() :: String.t()
  def scope_disclosure, do: @scope_disclosure

  @doc """
  Builds the real §84 exact-subject document.

  Options:

    * `:repo` -- ash_a2a's own repo path (default `File.cwd!/0`), used for
      `court_revision` and `root_manifest_sha256`.
    * `:claimed_profile` -- default `"SA2A-STRICT"` (see
      `@default_claimed_profile`).
    * `:topology_root` -- root directory the 11 sibling repos live under
      (default `SA2AV269_17Topology.root/0`).
    * `:courts` -- courts to draw the falsifier corpus from (default every
      discoverable court, `AshA2A.Chicago.courts/0`).
  """
  @spec build!(keyword()) :: t()
  def build!(opts \\ []) do
    repo = opts |> Keyword.get(:repo, File.cwd!()) |> Path.expand()
    topology_root = Keyword.get(opts, :topology_root, Topology.root())
    courts = Keyword.get_lazy(opts, :courts, fn -> Chicago.courts() end)

    %__MODULE__{
      release: @release,
      release_contract: @release_contract,
      architecture_contract: @architecture_contract,
      conformance_contract: @conformance_contract,
      claimed_profile: Keyword.get(opts, :claimed_profile, @default_claimed_profile),
      repositories: repository_identities(topology_root),
      root_manifest_sha256: root_manifest_sha256(repo),
      court_revision: court_revision(repo),
      falsifier_corpus_sha256: falsifier_corpus_sha256(courts),
      scope_disclosure: @scope_disclosure
    }
  end

  @doc """
  Real per-repo identity for every repo `SA2AV269_17Topology.repos/0` names,
  reusing that court's own `check_repo/1` (real `git rev-parse --verify` +
  `git status` subprocesses) rather than re-deriving git calls.
  """
  @spec repository_identities(Path.t()) :: [repository_identity()]
  def repository_identities(topology_root \\ Topology.root()) do
    Enum.map(Topology.repos(), fn {repo_object, dir, capability, critical?} ->
      status = Topology.check_repo(Path.join(topology_root, dir))

      %{
        "repo" => repo_object,
        "capability" => capability,
        "critical" => critical?,
        "real" => status.real?,
        "head" => status.head,
        "dirty" => status.dirty?
      }
    end)
  end

  @doc """
  sha256 over the concatenated real source of every `lib/ash_a2a/chicago/*.ex`
  file under `repo`, sorted by path. `nil` when the directory does not exist
  (recorded, never invented -- the same discipline as `Subject.file_sha256/1`).
  """
  @spec root_manifest_sha256(Path.t()) :: String.t() | nil
  def root_manifest_sha256(repo \\ File.cwd!()) do
    files =
      repo
      |> Path.join("lib/ash_a2a/chicago/*.ex")
      |> Path.wildcard()
      |> Enum.sort()

    case files do
      [] ->
        nil

      files ->
        files
        |> Enum.map(&File.read!/1)
        |> Enum.join()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    end
  end

  @doc """
  ash_a2a's own real git HEAD, via `AshA2A.Chicago.Subject.capture/1`'s
  already-real `source_revision` (reused, not re-derived).
  """
  @spec court_revision(Path.t()) :: String.t() | nil
  def court_revision(repo \\ File.cwd!()) do
    Subject.capture(repo: repo).source_revision
  end

  @doc """
  sha256 over every falsifier declared by `courts` (default every
  discoverable court), via the existing
  `AshA2A.Chicago.StandingReceipt.corpus_digest/1` helper.
  """
  @spec falsifier_corpus_sha256([module()]) :: String.t()
  def falsifier_corpus_sha256(courts \\ Chicago.courts()) do
    courts
    |> Enum.flat_map(& &1.falsifiers())
    |> StandingReceipt.corpus_digest()
  end

  @doc "JSON-map form of the document (§84 `exact-subject.json` shape)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = subject) do
    %{
      "schema" => @schema,
      "release" => subject.release,
      "release_contract" => subject.release_contract,
      "architecture_contract" => subject.architecture_contract,
      "conformance_contract" => subject.conformance_contract,
      "claimed_profile" => subject.claimed_profile,
      "repositories" => subject.repositories,
      "root_manifest_sha256" => subject.root_manifest_sha256,
      "court_revision" => subject.court_revision,
      "falsifier_corpus_sha256" => subject.falsifier_corpus_sha256,
      "scope_disclosure" => subject.scope_disclosure
    }
  end

  @doc "Deterministic canonical JSON encoding of the document."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = subject), do: subject |> to_map() |> Json.canonical()

  @doc "sha256 over the canonical JSON form -- content address of the document."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = subject) do
    subject
    |> to_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
