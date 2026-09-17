defmodule AshA2A.Semantic.RootManifest do
  @moduledoc """
  RFC-SA2A-001 S21: the deliberately small, content-addressed semantic trust
  root.

  Everything else in the semantic stack derives its standing from this one
  document. It pins, with real digests computed from real files on disk:
  admitted ontology roots, semantic profile versions, the canonicalization
  algorithm, manufacturer identities, admitted validator/compiler identities,
  the Authority Broker identity, the BRCE contract, the receipt law, the
  cryptographic algorithms, and the version policy.

  ## Content-addressed, and portable on purpose

  `content_digest/1` is derived from the manifest's own contents via
  `canonical_form/1`, a deterministic encoder that sorts every map key so the
  address never depends on in-memory map ordering, JSON key order, or
  encoder implementation.

  The address deliberately EXCLUDES every machine-local value: `:root` (the
  absolute directory the relative pin paths resolve against), the engine
  pin's `"path_hint"`, and the transient verification results
  (`:engine_verified?`, `:engine_verified_digest`, `:verified_at`). This is
  not an oversight -- the qualification this manifest serves is about two
  DIFFERENT runtimes
  agreeing, and two runtimes never agree on absolute paths. Pin paths are
  stored relative to `:root` so the same corpus checked out at two different
  locations yields the identical manifest digest.

  `addressed_fields/0` is the explicit, auditable list of what the address
  covers; `unaddressed_fields/0` is the explicit list of what it must not.
  Their union is asserted against the real struct keys by a real test, so a
  field added later cannot silently fall outside the content address.

  ## The self-check must not depend on the artifact it pins

  The manifest's own content address uses SHA-256 via OTP's `:crypto`, NOT
  the BLAKE3 inside the `praxis-graphlaw` wasm module this manifest pins.
  Verifying the engine artifact with a hash function computed BY that same
  engine artifact would be circular: a substituted engine could report
  whatever digest made itself look admitted. Digesting it with an
  independent, in-BEAM implementation breaks the circularity.

  `canonicalization` pins the RFC S12 graph identity actually executed --
  `AshA2A.Semantic.CanonicalGraph.identity/0` (RDFC-1.0 over RDF.ex, SHA-256
  over sorted N-Quads) -- and `load/2` refuses a pin that names anything else.
  `hash_algorithms` records BLAKE3 as the ENGINE's graph digest
  (`engine_graph_digest`), which is not RDFC-1.0. Both are claims about the
  pinned machinery's semantics, separate from how this document checks
  itself.

  ## Loading fails closed on any drift

  `load/2` verifies EVERY pinned digest against the real bytes on disk and
  refuses the whole manifest on the first mismatch. There is no partial
  load, no "warn and continue", and no branch that returns a manifest whose
  pins were not checked. A missing artifact, a changed artifact, or a
  manifest whose own recomputed content address differs from its recorded
  `digest` each return a typed refusal.

  `opts[:require_engine]` (default `true`) additionally verifies the pinned
  engine: the wasm artifact's real SHA-256 must equal the pin, and the
  engine's own self-reported `graphlaw_version()` -- obtained by really
  executing it -- must equal `expected_version`. Passing `require_engine:
  false` does NOT buy unverified validation: it yields a manifest marked
  `engine_verified?: false`, and `AshA2A.Semantic.MetaAdmission` refuses
  every engine-backed operation against such a manifest.

  ## Mutation is a high-consequence transition

  `mutate/5` requires a real `AshA2A.Authority` admitted for the single fixed
  capability `mutation_capability_id/0`, checked against an
  INDEPENDENTLY-SUPPLIED `expected_principal`. The independence is the whole
  point and this codebase has already been bitten by its absence: an earlier
  `AshA2A.KillSwitch.reset/4` compared `authority.subject` against itself, a
  tautology any caller able to name the (public) capability string passed.
  `mutate/5` copies that module's corrected shape -- the caller supplies the
  real, separately-known identity of whoever is attempting the change, and
  it is compared for real.

  ### "No ordinary agent MAY mutate it", made structurally true

  Three real, executable structural properties, not comments:

  1. **Custody source gate.** `authority.source` must be `:root_custodian`.
     The ordinary A2A path mints authority through
     `AshA2A.Authority.from_verified_identity/2`, which stamps
     `source: :transport_verified` -- so an ordinary authenticated agent
     cannot produce a mutation-admissible authority even when it names the
     correct capability and the correct subject. That refusal
     (`:REFUSED_ROOT_CUSTODY`) is exercised by a real falsifier test.

  2. **One fixed, non-parameterised capability.** There is no per-agent or
     per-class mutation capability to mint; `mutation_capability_id/0` is a
     single constant.

  3. **Mutation moves the content address.** `mutate/5` returns a NEW
     manifest with a NEWLY computed digest, and re-verifies every pin
     against disk before returning. Any consumer holding the old address
     fails closed the moment it checks.

  ### What this does NOT claim

  This module governs mutation of a LOADED manifest inside the BEAM. It does
  not, and cannot, prevent someone with filesystem write access from editing
  `root_manifest.json` directly -- that is the operating system's ACL
  boundary, not Elixir's. What it does guarantee is that such an out-of-band
  edit is DETECTABLE: it changes the recorded contents, so the recomputed
  content address no longer matches, and `load/2` refuses with
  `:REFUSED_MANIFEST_DIGEST_MISMATCH` unless the editor also recomputed the
  address -- and any consumer pinned to the previous address refuses
  regardless.
  """

  alias AshA2A.{Authority, Identity}
  alias AshA2A.Semantic.RootManifest.EngineProbe

  @manifest_version "sa2a/1"
  @mutation_capability_id "root_manifest:mutate"
  @custody_source :root_custodian
  @default_relative_path "sa2a/root_manifest.json"

  @addressed_fields [
    :manifest_version,
    :canonicalization,
    :hash_algorithms,
    :engine,
    :ontology_roots,
    :semantic_profiles,
    :validators,
    :manufacturers,
    :authority_broker,
    :brce_contract,
    :receipt_law,
    :version_policy
  ]

  # Deliberately outside the content address: machine-local or transient.
  @unaddressed_fields [
    :digest,
    :root,
    :engine_verified?,
    :engine_verified_digest,
    :verified_at
  ]

  @engine_unaddressed_keys ["path_hint"]

  defstruct manifest_version: @manifest_version,
            canonicalization: %{},
            hash_algorithms: %{},
            engine: %{},
            ontology_roots: [],
            semantic_profiles: [],
            validators: [],
            manufacturers: [],
            authority_broker: %{},
            brce_contract: %{},
            receipt_law: %{},
            version_policy: %{},
            digest: nil,
            root: nil,
            engine_verified?: false,
            engine_verified_digest: nil,
            verified_at: nil

  @type pin :: %{required(String.t()) => String.t()}
  @type t :: %__MODULE__{}
  @type refusal :: %{required(:code) => atom(), required(:detail) => term()}

  @doc "The explicit list of struct fields covered by the content address."
  @spec addressed_fields() :: [atom()]
  def addressed_fields, do: @addressed_fields

  @doc "The explicit list of struct fields deliberately NOT content-addressed."
  @spec unaddressed_fields() :: [atom()]
  def unaddressed_fields, do: @unaddressed_fields

  @doc """
  The single fixed `AshA2A.Authority` capability id `mutate/5` checks
  against. Not parameterised by agent, class, or field -- see the moduledoc's
  structural-property 2.
  """
  @spec mutation_capability_id() :: String.t()
  def mutation_capability_id, do: @mutation_capability_id

  @doc """
  The `AshA2A.Authority` `source` that `mutate/5` admits. Deliberately NOT
  `:transport_verified` (what every ordinary authenticated A2A caller gets)
  and NOT the generic `:authority_broker` default.
  """
  @spec custody_source() :: atom()
  def custody_source, do: @custody_source

  @doc "Default on-disk location of the manifest inside this app's `priv/`."
  @spec default_path() :: String.t()
  def default_path do
    Path.join(to_string(:code.priv_dir(:ash_a2a)), @default_relative_path)
  end

  # ---------------------------------------------------------------------------
  # Digesting
  # ---------------------------------------------------------------------------

  @doc """
  Real SHA-256 of a real file's real bytes, in this repo's existing
  `"sha256:" <> 64 hex` convention (the same shape
  `AshA2A.SemanticSubject` already enforces, so a manifest pin is directly
  usable as a semantic subject digest).
  """
  @spec artifact_digest(Path.t()) :: {:ok, String.t()} | {:error, refusal()}
  def artifact_digest(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, digest_bytes(bytes)}

      {:error, reason} ->
        refuse(:REFUSED_MANIFEST_ARTIFACT_MISSING, %{path: path, reason: reason})
    end
  end

  @doc "Real SHA-256 of arbitrary bytes in the `sha256:<hex>` convention."
  @spec digest_bytes(iodata()) :: String.t()
  def digest_bytes(bytes) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  @doc """
  Deterministic canonical encoding of the manifest's addressed contents.

  Every map is emitted with its keys sorted, so the encoding -- and therefore
  `content_digest/1` -- is independent of map ordering on any runtime. Exposed
  publicly so a second, non-Elixir runtime can reproduce the identical bytes
  and therefore the identical content address.
  """
  @spec canonical_form(t()) :: iodata()
  def canonical_form(%__MODULE__{} = manifest) do
    manifest
    |> content_map()
    |> canon()
  end

  @doc """
  The manifest's content address: real SHA-256 over `canonical_form/1`.
  Derived from contents only -- never stored-and-trusted.
  """
  @spec content_digest(t()) :: String.t()
  def content_digest(%__MODULE__{} = manifest) do
    manifest |> canonical_form() |> digest_bytes()
  end

  defp content_map(%__MODULE__{} = manifest) do
    @addressed_fields
    |> Enum.map(fn
      :engine -> {"engine", Map.drop(manifest.engine, @engine_unaddressed_keys)}
      field -> {Atom.to_string(field), Map.fetch!(manifest, field)}
    end)
    |> Map.new()
  end

  defp canon(value) when is_map(value) do
    inner =
      value
      |> Enum.map(fn {k, v} -> {canon_key(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ":", canon(v)] end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp canon(value) when is_list(value) do
    ["[", value |> Enum.map(&canon/1) |> Enum.intersperse(","), "]"]
  end

  defp canon(value) when is_binary(value), do: JSON.encode!(value)
  defp canon(value) when is_integer(value), do: Integer.to_string(value)
  defp canon(value) when is_boolean(value), do: to_string(value)
  defp canon(nil), do: "null"
  defp canon(value) when is_atom(value), do: JSON.encode!(Atom.to_string(value))

  defp canon_key(k) when is_binary(k), do: k
  defp canon_key(k) when is_atom(k), do: Atom.to_string(k)

  # ---------------------------------------------------------------------------
  # Pinning / building
  # ---------------------------------------------------------------------------

  @doc """
  Builds one pin by really reading and digesting the file at
  `Path.join(root, relative_path)`.
  """
  @spec pin(Path.t(), String.t(), String.t(), String.t()) :: {:ok, pin()} | {:error, refusal()}
  def pin(root, id, kind, relative_path) do
    with {:ok, digest} <- artifact_digest(Path.join(root, relative_path)) do
      {:ok, %{"id" => id, "kind" => kind, "path" => relative_path, "digest" => digest}}
    end
  end

  @doc """
  Builds a manifest struct from `spec`, computing every artifact digest from
  the real files under `root` and deriving the content address from the
  result. This is the reproducible construction path: running it again over
  an unchanged corpus yields a byte-identical `digest`.
  """
  @spec build(Path.t(), keyword()) :: {:ok, t()} | {:error, refusal()}
  def build(root, spec) do
    with {:ok, ontology_roots} <- pin_all(root, Keyword.get(spec, :ontology_roots, [])),
         {:ok, profiles} <- pin_all(root, Keyword.get(spec, :semantic_profiles, [])),
         {:ok, validators} <- pin_all(root, Keyword.get(spec, :validators, [])),
         {:ok, engine} <- build_engine(Keyword.get(spec, :engine, [])) do
      manifest = %__MODULE__{
        manifest_version: Keyword.get(spec, :manifest_version, @manifest_version),
        canonicalization: stringify(Keyword.fetch!(spec, :canonicalization)),
        hash_algorithms: stringify(Keyword.fetch!(spec, :hash_algorithms)),
        engine: engine,
        ontology_roots: ontology_roots,
        semantic_profiles: profiles,
        validators: validators,
        manufacturers: Enum.map(Keyword.get(spec, :manufacturers, []), &stringify/1),
        authority_broker: stringify(Keyword.fetch!(spec, :authority_broker)),
        brce_contract: stringify(Keyword.fetch!(spec, :brce_contract)),
        receipt_law: stringify(Keyword.fetch!(spec, :receipt_law)),
        version_policy: stringify(Keyword.fetch!(spec, :version_policy)),
        root: root
      }

      {:ok, %{manifest | digest: content_digest(manifest)}}
    end
  end

  defp pin_all(root, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      id = Keyword.fetch!(entry, :id)
      kind = to_string(Keyword.fetch!(entry, :kind))
      path = Keyword.fetch!(entry, :path)

      case pin(root, id, kind, path) do
        {:ok, pin} -> {:cont, {:ok, acc ++ [pin]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp build_engine(spec) do
    path = Keyword.get(spec, :path) || EngineProbe.wasm_path([])

    with {:ok, digest} <- artifact_digest(path) do
      {:ok,
       %{
         "id" => Keyword.get(spec, :id, "praxis-graphlaw-wasm"),
         "artifact_digest" => digest,
         "expected_version" => Keyword.fetch!(spec, :expected_version),
         "abi" => Keyword.get(spec, :abi, "wasm-bindgen"),
         "path_hint" => path
       }}
    end
  end

  defp stringify(map) when is_map(map) or is_list(map) do
    map |> Enum.map(fn {k, v} -> {canon_key(k), stringify_value(v)} end) |> Map.new()
  end

  defp stringify_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: Atom.to_string(v)

  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Serializes the manifest to its on-disk JSON form. `:root` and the engine
  pin's `"path_hint"` are written for human orientation but are NOT part of
  the content address, so moving the checkout does not change the digest.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = manifest) do
    payload =
      @addressed_fields
      |> Enum.map(fn field -> {Atom.to_string(field), Map.fetch!(manifest, field)} end)
      |> Map.new()
      |> Map.put("digest", manifest.digest)

    JSON.encode!(payload)
  end

  @doc "Writes the manifest to `path`, creating parent directories."
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = manifest, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, to_json(manifest))
  end

  @doc """
  The REAL SHA-256 of the engine artifact resolved right now via
  `EngineProbe.wasm_path/1` -- the same resolution order (`opts[:wasm_path]`
  -> app env -> `GRAPHLAW_WASM` -> default) `do_verify_engine/2` used at
  load time.

  This is deliberately independent of `engine_verified_digest`: it re-reads
  the file off disk at the moment of the call rather than trusting anything
  recorded on the manifest struct. Callers that must bind a load-time
  verification to a specific later use (`AshA2A.Semantic.MetaAdmission`'s
  use-time engine check) call this at that later moment and compare the
  result against `manifest.engine_verified_digest` themselves -- comparing
  two independently-obtained values, never trusting one alone.
  """
  @spec current_engine_digest(keyword()) :: {:ok, String.t()} | {:error, refusal()}
  def current_engine_digest(opts \\ []) do
    path = EngineProbe.wasm_path(opts)

    case artifact_digest(path) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Loading -- fails closed
  # ---------------------------------------------------------------------------

  @doc """
  Loads and FULLY verifies the manifest at `path`.

  Verification, in order, refusing on the first failure:

  1. the file exists and decodes as a JSON object with the expected fields;
  2. the recomputed content address equals the recorded `digest`
     (`:REFUSED_MANIFEST_DIGEST_MISMATCH`);
  2a. the `canonicalization` pin names exactly the executing RFC S12
     identity, `AshA2A.Semantic.CanonicalGraph.identity/0`
     (`:REFUSED_MANIFEST_CANONICALIZATION_DRIFT`);
  3. every pinned artifact exists at `Path.join(root, path)`
     (`:REFUSED_MANIFEST_ARTIFACT_MISSING`);
  4. every pinned artifact's real SHA-256 equals its pin
     (`:REFUSED_MANIFEST_DRIFT`);
  5. unless `require_engine: false`, the pinned engine artifact's real
     SHA-256 equals its pin AND the engine's really-executed
     `graphlaw_version()` equals `expected_version`
     (`:REFUSED_MANIFEST_ENGINE_DRIFT`).

  Options: `:root` (default `Path.dirname(path)`), `:require_engine`
  (default `true`), plus any `AshA2A.Semantic.RootManifest.EngineProbe`
  path overrides, which are forwarded.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, refusal()}
  def load(path \\ nil, opts \\ []) do
    path = path || default_path()
    root = Keyword.get(opts, :root, Path.dirname(path))

    result =
      with {:ok, raw} <- read_file(path),
           {:ok, decoded} <- decode_json(raw, path),
           {:ok, manifest} <- from_map(decoded, root),
           :ok <- verify_self_address(manifest, decoded),
           :ok <- verify_canonicalization(manifest),
           :ok <- verify_pins(manifest),
           {:ok, manifest} <- verify_engine(manifest, opts) do
        {:ok, %{manifest | verified_at: DateTime.utc_now()}}
      end

    result = emit_verify(:load, path, root, result)

    # RFC-SA2A-002 §12 attempt evidence, emitted where the load decision is
    # made -- a sibling event to `emit_verify/4`'s
    # `root_manifest.verify{operation: :load}` above: exact_identity.ex
    # observes that one, canonical_graph_identity.ex/generated_projection.ex
    # observe this one. Both are real projections of this same `result`.
    :telemetry.execute([:ash_a2a, :semantic, :root_manifest, :load], %{}, %{
      outcome: if(match?({:ok, _}, result), do: :loaded, else: :refused),
      code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil)),
      digest: with({:ok, %__MODULE__{digest: digest}} <- result, do: digest, else: (_ -> nil))
    })

    result
  end

  @doc """
  Re-runs every pin check of `load/2` against an already-built manifest,
  without re-reading the manifest file. Used by `mutate/5` and available to
  a caller that wants to re-verify a long-held manifest against disk.
  """
  @spec verify(t(), keyword()) :: {:ok, t()} | {:error, refusal()}
  def verify(%__MODULE__{} = manifest, opts \\ []) do
    result =
      with :ok <- verify_canonicalization(manifest),
           :ok <- verify_pins(manifest),
           {:ok, manifest} <- verify_engine(manifest, opts) do
        {:ok, %{manifest | verified_at: DateTime.utc_now()}}
      end

    emit_verify(:verify, nil, manifest.root, result)
  end

  @doc """
  Telemetry event `load/2` and `verify/2` emit for every verification
  decision, where the decision is made (RFC-SA2A-002 §12 attempt evidence).

  Metadata: `:operation` (`:load | :verify`), `:outcome`
  (`:verified | :refused`), `:code` (the refusal code, else `nil`),
  `:path`, `:root`, `:manifest_digest` (verified manifests only),
  `:engine_verified`, and for a refusal naming one pin, `:pin_id`,
  `:pin_kind` and `:pin_path`.
  """
  @spec verify_event() :: [atom()]
  def verify_event, do: [:ash_a2a, :semantic, :root_manifest, :verify]

  defp emit_verify(operation, path, root, result) do
    {outcome, code, digest, engine_verified, detail} =
      case result do
        {:ok, %__MODULE__{} = manifest} ->
          {:verified, nil, manifest.digest, manifest.engine_verified?, %{}}

        {:error, %{code: code} = refusal} ->
          # Only a refusal about one pin (it carries the pin's `:kind`) names
          # a pin; e.g. `:REFUSED_MANIFEST_NOT_FOUND` carries the manifest path.
          detail = Map.get(refusal, :detail)
          pin = if is_map(detail) and Map.has_key?(detail, :kind), do: detail, else: %{}
          {:refused, code, nil, nil, pin}
      end

    :telemetry.execute([:ash_a2a, :semantic, :root_manifest, :verify], %{}, %{
      operation: operation,
      outcome: outcome,
      code: code,
      path: path,
      root: root,
      manifest_digest: digest,
      engine_verified: engine_verified,
      pin_id: Map.get(detail, :id),
      pin_kind: Map.get(detail, :kind),
      pin_path: Map.get(detail, :path)
    })

    result
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> refuse(:REFUSED_MANIFEST_NOT_FOUND, %{path: path, reason: reason})
    end
  end

  defp decode_json(raw, path) do
    case JSON.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> refuse(:REFUSED_MANIFEST_MALFORMED, %{path: path, reason: :not_a_json_object})
    end
  end

  defp from_map(decoded, root) do
    missing = Enum.reject(@addressed_fields, &Map.has_key?(decoded, Atom.to_string(&1)))

    cond do
      missing != [] ->
        refuse(:REFUSED_MANIFEST_MALFORMED, %{missing_fields: missing})

      not is_binary(Map.get(decoded, "digest")) ->
        refuse(:REFUSED_MANIFEST_MALFORMED, %{missing_fields: [:digest]})

      true ->
        manifest =
          Enum.reduce(@addressed_fields, %__MODULE__{}, fn field, acc ->
            Map.put(acc, field, Map.fetch!(decoded, Atom.to_string(field)))
          end)

        {:ok, %{manifest | digest: Map.fetch!(decoded, "digest"), root: root}}
    end
  end

  defp verify_self_address(%__MODULE__{} = manifest, _decoded) do
    recomputed = content_digest(manifest)

    if recomputed == manifest.digest do
      :ok
    else
      refuse(:REFUSED_MANIFEST_DIGEST_MISMATCH, %{
        recorded: manifest.digest,
        recomputed: recomputed
      })
    end
  end

  # RFC-SA2A-002 §50: the canonicalization algorithm and digest function are
  # pinned by this manifest. A pin naming anything other than the identity
  # actually executed (`CanonicalGraph.identity/0`) is drift, refused even when
  # the content address was recomputed consistently.
  defp verify_canonicalization(%__MODULE__{canonicalization: pin}) do
    case AshA2A.Semantic.CanonicalGraph.verify_pin(pin) do
      :ok -> :ok
      {:error, drift} -> refuse(:REFUSED_MANIFEST_CANONICALIZATION_DRIFT, drift)
    end
  end

  defp verify_pins(%__MODULE__{} = manifest) do
    manifest
    |> all_pins()
    |> Enum.reduce_while(:ok, fn pin, :ok ->
      absolute = resolve(manifest, Map.fetch!(pin, "path"))

      case artifact_digest(absolute) do
        {:ok, actual} ->
          if actual == Map.fetch!(pin, "digest") do
            {:cont, :ok}
          else
            {:halt,
             refuse(:REFUSED_MANIFEST_DRIFT, %{
               id: Map.get(pin, "id"),
               kind: Map.get(pin, "kind"),
               path: Map.get(pin, "path"),
               pinned: Map.fetch!(pin, "digest"),
               actual: actual
             })}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp verify_engine(%__MODULE__{} = manifest, opts) do
    if Keyword.get(opts, :require_engine, true) do
      do_verify_engine(manifest, opts)
    else
      {:ok, %{manifest | engine_verified?: false, engine_verified_digest: nil}}
    end
  end

  defp do_verify_engine(%__MODULE__{engine: engine} = manifest, opts) do
    path = EngineProbe.wasm_path(opts)
    pinned = Map.get(engine, "artifact_digest")
    expected_version = Map.get(engine, "expected_version")

    with {:ok, actual} <- engine_artifact_digest(path),
         :ok <- match_engine_digest(pinned, actual, path),
         {:ok, version} <- engine_version(opts),
         :ok <- match_engine_version(expected_version, version) do
      {:ok, %{manifest | engine_verified?: true, engine_verified_digest: actual}}
    end
  end

  defp engine_artifact_digest(path) do
    case artifact_digest(path) do
      {:ok, actual} ->
        {:ok, actual}

      {:error, _} ->
        refuse(:REFUSED_MANIFEST_ENGINE_DRIFT, %{reason: :engine_artifact_missing, path: path})
    end
  end

  defp match_engine_digest(pinned, actual, path) do
    if pinned == actual do
      :ok
    else
      refuse(:REFUSED_MANIFEST_ENGINE_DRIFT, %{
        reason: :artifact_digest_mismatch,
        path: path,
        pinned: pinned,
        actual: actual
      })
    end
  end

  defp engine_version(opts) do
    case EngineProbe.version(opts) do
      {:ok, version} ->
        {:ok, version}

      {:error, failure} ->
        refuse(:REFUSED_MANIFEST_ENGINE_DRIFT, %{reason: :engine_unreachable, detail: failure})
    end
  end

  defp match_engine_version(expected, actual) do
    if expected == actual do
      :ok
    else
      refuse(:REFUSED_MANIFEST_ENGINE_DRIFT, %{
        reason: :version_mismatch,
        expected: expected,
        actual: actual
      })
    end
  end

  # ---------------------------------------------------------------------------
  # Lookup
  # ---------------------------------------------------------------------------

  @doc "Every pin in the manifest, across ontology roots, profiles, and validators."
  @spec all_pins(t()) :: [pin()]
  def all_pins(%__MODULE__{} = manifest) do
    manifest.ontology_roots ++ manifest.semantic_profiles ++ manifest.validators
  end

  @doc """
  Finds the pin for `relative_path`, optionally requiring a specific `kind`.
  Returns `:error` when nothing is pinned at that path -- the raw signal
  `AshA2A.Semantic.MetaAdmission` turns into a `REFUSED_META_RIGOR` refusal.
  """
  @spec find_pin(t(), String.t(), String.t() | nil) :: {:ok, pin()} | :error
  def find_pin(%__MODULE__{} = manifest, relative_path, kind \\ nil) do
    manifest
    |> all_pins()
    |> Enum.find(fn pin ->
      Map.get(pin, "path") == relative_path and (is_nil(kind) or Map.get(pin, "kind") == kind)
    end)
    |> case do
      nil -> :error
      pin -> {:ok, pin}
    end
  end

  @doc "Resolves a manifest-relative path against this manifest's `:root`."
  @spec resolve(t(), String.t()) :: String.t()
  def resolve(%__MODULE__{root: root}, relative_path), do: Path.join(root, relative_path)

  # ---------------------------------------------------------------------------
  # Mutation -- high-consequence, real-authority gated
  # ---------------------------------------------------------------------------

  @doc """
  Applies `changes` to the manifest and returns a NEW manifest with a newly
  derived content address.

  REQUIRES all of:

  * a real `AshA2A.Authority.t()` naming `mutation_capability_id/0`, unexpired;
  * `expected_principal`, a real `AshA2A.Identity.t()` supplied
    INDEPENDENTLY of `authority` (never read off the authority struct --
    see the moduledoc), matched against `authority.subject`;
  * `authority.source == custody_source/0`, which the ordinary
    transport-verified agent path structurally cannot produce.

  Any failure returns a typed refusal and leaves the input manifest
  completely untouched -- there is no partial mutation. On success every pin
  (including any newly supplied one) is re-verified against the real files
  on disk before the new manifest is returned, so `mutate/5` can never mint
  a manifest that `load/2` would refuse.
  """
  @spec mutate(t(), map(), Authority.t() | nil, Identity.t() | nil, keyword()) ::
          {:ok, t()} | {:error, refusal()}
  def mutate(manifest, changes, authority, expected_principal, opts \\ []) do
    result = do_mutate(manifest, changes, authority, expected_principal, opts)

    # `[:ash_a2a, :semantic, :root_manifest, :mutate]`: the custody decision
    # over a proposed trust-root change (RFC-SA2A-002 §53/§81). Observational.
    :telemetry.execute(
      [:ash_a2a, :semantic, :root_manifest, :mutate],
      %{count: 1},
      %{
        manifest_digest: match?(%__MODULE__{}, manifest) && manifest.digest,
        authority_source: match?(%Authority{}, authority) && authority.source,
        outcome: if(match?({:ok, _}, result), do: :mutated, else: :refused),
        code: with({:error, %{code: code}} <- result, do: code, else: (_ -> nil)),
        next_digest: with({:ok, %__MODULE__{digest: d}} <- result, do: d, else: (_ -> nil))
      }
    )

    result
  end

  defp do_mutate(
         %__MODULE__{} = manifest,
         changes,
         %Authority{} = authority,
         %Identity{kind: :principal} = expected_principal,
         opts
       )
       when is_map(changes) do
    admitted? =
      Authority.admits?(authority, %{
        principal_id: expected_principal,
        capability_id: @mutation_capability_id
      })

    cond do
      not admitted? ->
        refuse(:authority_mismatch, %{capability_id: @mutation_capability_id})

      authority.source != @custody_source ->
        refuse(:REFUSED_ROOT_CUSTODY, %{
          required_source: @custody_source,
          actual_source: authority.source
        })

      true ->
        apply_changes(manifest, changes, opts)
    end
  end

  defp do_mutate(%__MODULE__{}, _changes, _authority, _expected_principal, _opts),
    do: refuse(:authority_mismatch, %{reason: :malformed_authority_or_principal})

  defp apply_changes(manifest, changes, opts) do
    normalized =
      Enum.map(changes, fn {k, v} -> {if(is_binary(k), do: safe_atom(k), else: k), v} end)

    unknown = normalized |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in @addressed_fields))

    if unknown == [] do
      mutated = Enum.reduce(normalized, manifest, fn {k, v}, acc -> Map.put(acc, k, v) end)

      mutated = %{
        mutated
        | digest: content_digest(mutated),
          engine_verified?: false,
          engine_verified_digest: nil
      }

      verify(mutated, opts)
    else
      refuse(:REFUSED_MANIFEST_MALFORMED, %{unmutable_or_unknown_fields: unknown})
    end
  end

  # Never `String.to_atom/1` on caller input: an unknown key must become a
  # refusal, not a new atom in the VM's permanent atom table.
  defp safe_atom(key) do
    Enum.find(@addressed_fields, :"$unknown", &(Atom.to_string(&1) == key))
  end

  defp refuse(code, detail), do: {:error, %{code: code, detail: detail}}
end
