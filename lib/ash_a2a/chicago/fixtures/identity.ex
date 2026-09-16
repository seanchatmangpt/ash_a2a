defmodule AshA2A.Chicago.Fixtures.Identity do
  @moduledoc """
  Real environment builders for the Gate 1 exact-identity court
  (`AshA2A.Chicago.Courts.ExactIdentity`).

  Everything here is real: `git init` scratch repositories with real commits,
  real annotated tags and a real mutable branch; real artifact bytes (the
  SUT's own GraphLaw wasm when present, else a minimal valid wasm module);
  real N-Triples manifests and real SHACL / N3 rule files in their own git
  repository. Mutations change the environment around the real subject
  (RFC-SA2A-002 §10) -- nothing replaces the identity boundary under test.

  git runs with the user's global and system config disabled so a local
  signing key, hook path or default branch cannot change the fixture.
  """

  @tag "v26.9.16"
  @branch "qualification"
  @wasm_header <<0, ?a, ?s, ?m, 1, 0, 0, 0>>

  @doc "The final release tag the scratch release repo is cut at."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The mutable qualification branch name."
  @spec branch() :: String.t()
  def branch, do: @branch

  @doc """
  Runs real `git` in `dir`, raising with git's output on failure. Returns
  trimmed stdout.
  """
  @spec git!(Path.t(), [String.t()]) :: String.t()
  def git!(dir, args) do
    base = [
      "-c",
      "user.name=chicago-court",
      "-c",
      "user.email=chicago-court@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "tag.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null"
    ]

    case System.cmd("git", base ++ args,
           cd: dir,
           stderr_to_stdout: true,
           env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
         ) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status} in #{dir}: #{out}"
    end
  end

  @doc """
  Builds a real release under `root/name`:

    * `name/` -- a git repo on branch `qualification` with one commit `c1`,
      annotated tag `v26.9.16` at `c1`, and an ignored `dist/` holding the
      executable artifact `dist/graphlaw.wasm` and the published root
      manifest `dist/root_manifest.nt`
    * `name-rules/` -- a separate git repo holding the validator rule set
      (`shapes.shacl.ttl`, `rules.n3`) at commit `r1`

  Returns the paths, the commits, and `subject_opts` binding every identity
  source for `AshA2A.Chicago.Subject.capture/1`.
  """
  @spec release!(Path.t(), String.t()) :: map()
  def release!(root, name) do
    repo = Path.join(root, name)
    rules = Path.join(root, name <> "-rules")
    File.rm_rf!(repo)
    File.rm_rf!(rules)
    File.mkdir_p!(Path.join(repo, "src"))
    File.mkdir_p!(Path.join(repo, "dist"))
    File.mkdir_p!(rules)

    git!(repo, ["init", "--quiet", "--initial-branch=" <> @branch])
    File.write!(Path.join(repo, ".gitignore"), "dist/\n")

    File.write!(Path.join(repo, "src/agent.ex"), """
    defmodule Scratch.Agent do
      def capability, do: "scratch.item.create"
    end
    """)

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "--quiet", "-m", "c1: release candidate"])
    c1 = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["tag", "-a", @tag, "-m", "final conformance tag"])

    artifact = Path.join(repo, "dist/graphlaw.wasm")
    File.write!(artifact, wasm_bytes())

    manifest = Path.join(repo, "dist/root_manifest.nt")

    File.write!(manifest, """
    <urn:sa2a:root> <urn:sa2a:profile> "SA2A-CORE" .
    <urn:sa2a:root> <urn:sa2a:validator> <urn:sa2a:rules:shapes> .
    <urn:sa2a:root> <urn:sa2a:artifact> <urn:sa2a:artifact:graphlaw> .
    """)

    git!(rules, ["init", "--quiet", "--initial-branch=main"])
    shapes = Path.join(rules, "shapes.shacl.ttl")
    n3 = Path.join(rules, "rules.n3")

    File.write!(shapes, """
    @prefix sh: <http://www.w3.org/ns/shacl#> .
    @prefix ex: <http://example.org/> .
    ex:ItemShape a sh:NodeShape ;
      sh:targetClass ex:Item ;
      sh:property [ sh:path ex:label ; sh:minCount 1 ] .
    """)

    File.write!(n3, """
    @prefix ex: <http://example.org/> .
    { ?item a ex:Item } => { ?item ex:admissible true } .
    """)

    git!(rules, ["add", "-A"])
    git!(rules, ["commit", "--quiet", "-m", "r1: rule set"])
    r1 = git!(rules, ["rev-parse", "HEAD"])

    %{
      repo: repo,
      rules: rules,
      c1: c1,
      r1: r1,
      artifact: artifact,
      manifest: manifest,
      shapes: shapes,
      n3: n3,
      subject_opts: [
        repo: repo,
        tag: @tag,
        artifacts: [artifact],
        root_manifest: manifest,
        validators: [shapes, n3]
      ]
    }
  end

  @doc "Adds a real commit to the checked-out branch (the branch moves)."
  @spec advance_branch!(map()) :: String.t()
  def advance_branch!(%{repo: repo}) do
    File.write!(Path.join(repo, "src/agent.ex"), """
    defmodule Scratch.Agent do
      def capability, do: "scratch.item.delete"
    end
    """)

    git!(repo, ["commit", "--quiet", "-am", "c2: branch moved after qualification"])
    git!(repo, ["rev-parse", "HEAD"])
  end

  @doc """
  Substitutes the executable artifact with different, still-valid wasm bytes
  (a trailing custom section) while the source revision stays unchanged.
  """
  @spec substitute_artifact!(map()) :: :ok
  def substitute_artifact!(%{artifact: artifact}) do
    File.write!(artifact, File.read!(artifact) <> custom_section("chicago", "substituted"))
  end

  @doc "Alters one triple of the published root manifest."
  @spec alter_manifest!(map()) :: :ok
  def alter_manifest!(%{manifest: manifest}) do
    altered =
      manifest
      |> File.read!()
      |> String.replace(~s("SA2A-CORE"), ~s("SA2A-STRICT"))

    File.write!(manifest, altered)
  end

  @doc "Commits a new validator rule-set revision `r2` (a relaxed SHACL shape)."
  @spec revise_rules!(map()) :: String.t()
  def revise_rules!(%{rules: rules, shapes: shapes}) do
    File.write!(shapes, String.replace(File.read!(shapes), "sh:minCount 1", "sh:minCount 0"))
    git!(rules, ["commit", "--quiet", "-am", "r2: relax ItemShape"])
    git!(rules, ["rev-parse", "HEAD"])
  end

  @doc """
  Force-moves the final tag to a new commit `c2` on another branch while the
  checkout stays at `c1`. Returns `c2`.
  """
  @spec move_tag!(map()) :: String.t()
  def move_tag!(%{repo: repo}) do
    git!(repo, ["checkout", "--quiet", "-b", "hotfix"])
    File.write!(Path.join(repo, "src/hotfix.ex"), "defmodule Scratch.Hotfix, do: nil\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "--quiet", "-m", "c2: hotfix"])
    c2 = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "--quiet", @branch])
    git!(repo, ["tag", "-f", "-a", @tag, c2, "-m", "moved final conformance tag"])
    c2
  end

  @doc "Adds a second, newer CalVer tag at the same commit. Returns the tag."
  @spec tag_newer_calver!(map(), String.t()) :: String.t()
  def tag_newer_calver!(%{repo: repo}, tag \\ "v26.9.17") do
    git!(repo, ["tag", "-a", tag, "-m", "newer calver, same commit"])
    tag
  end

  @doc """
  A one-vector SA2A conformance corpus copied from the SUT's real corpus
  (`v001_minimal_admit`), so a court run through both runtimes stays small.
  """
  @spec one_vector_corpus!(Path.t()) :: Path.t()
  def one_vector_corpus!(root) do
    dir = Path.join(root, "sa2a_corpus_one_vector")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    source = Path.join(AshA2A.SA2A.Vector.corpus_dir(), "v001_minimal_admit")
    File.cp_r!(source, Path.join(dir, "v001_minimal_admit"))
    dir
  end

  defp wasm_bytes do
    path = Path.join(to_string(:code.priv_dir(:ash_a2a)), "graphlaw/praxis_graphlaw.wasm")

    case File.read(path) do
      {:ok, <<0, ?a, ?s, ?m, _::binary>> = bytes} -> bytes
      _ -> @wasm_header <> custom_section("chicago", "minimal")
    end
  end

  # A wasm custom section (id 0): valid anywhere after the header, ignored by
  # engines, so the module still instantiates while its bytes differ.
  defp custom_section(name, payload) do
    body = uleb128(byte_size(name)) <> name <> payload
    <<0>> <> uleb128(byte_size(body)) <> body
  end

  defp uleb128(n) when n < 0x80, do: <<n>>

  defp uleb128(n) do
    import Bitwise
    <<(n &&& 0x7F) ||| 0x80>> <> uleb128(n >>> 7)
  end

  defmodule PaddedHostRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmexSession`: every call really
    reaches the real `:wasmex` instance and returns the real string the real
    wasm produced. Its only difference is a caller-controlled label: the host
    id carries one trailing space (the known one-space bypass of the SA2A
    degenerate-run refusal, RFC-SA2A-002 §126). Not a mock -- it records no
    interaction and returns nothing canned.
    """

    @behaviour AshA2A.GraphLaw.Runtime

    alias AshA2A.GraphLaw.WasmexSession

    @impl true
    def host_id, do: WasmexSession.host_id() <> " "

    @impl true
    def engine_id, do: WasmexSession.engine_id()

    @impl true
    def available?(opts \\ []), do: WasmexSession.available?(opts)

    @impl true
    def open(opts \\ []), do: WasmexSession.open(opts)

    @impl true
    def call(session, fun, args), do: WasmexSession.call(session, fun, args)

    @impl true
    def close(session), do: WasmexSession.close(session)
  end

  defmodule RelabelledHostRuntime do
    @moduledoc """
    A real runtime that IS `AshA2A.GraphLaw.WasmexSession` under entirely
    different caller-controlled labels (`"WASI/StandaloneHost"`, `"wasm3"`).
    Every call really executes in the real in-BEAM Wasmtime instance. Only
    identity observed from the executing resources (RFC-SA2A-002 §126) can
    tell that it is not a heterogeneous host.
    """

    @behaviour AshA2A.GraphLaw.Runtime

    alias AshA2A.GraphLaw.WasmexSession

    @impl true
    def host_id, do: "WASI/StandaloneHost"

    @impl true
    def engine_id, do: "wasm3"

    @impl true
    def available?(opts \\ []), do: WasmexSession.available?(opts)

    @impl true
    def open(opts \\ []), do: WasmexSession.open(opts)

    @impl true
    def call(session, fun, args), do: WasmexSession.call(session, fun, args)

    @impl true
    def close(session), do: WasmexSession.close(session)
  end
end
