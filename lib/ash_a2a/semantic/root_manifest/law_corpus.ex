defmodule AshA2A.Semantic.RootManifest.LawCorpus do
  @moduledoc """
  Manufactures a content-addressed Root Manifest whose pins are a given set of
  machinery documents (RFC-SA2A-001 S20/S21), for a host that judges
  candidates under law it holds in memory.

  `build/3` writes each document's exact bytes under `root/law/<kind>/` and
  builds the manifest over those real files with
  `AshA2A.Semantic.RootManifest.build/2`, using the conformance corpus spec
  (`AshA2A.Semantic.RootManifest.ConformanceCorpus.spec/1`) for every
  non-pin section -- engine pin, canonicalization, algorithms, manufacturers,
  Authority Broker, BRCE contract, receipt law, version policy.

  ## What this is, and what it is not

  It is a host-side build tool, the in-memory sibling of
  `mix ash_a2a.sa2a.pin_root_manifest`: the host decides which documents are
  its admitted law and passes the resulting manifest to a consumer (for
  example `AshA2A.Semantic.AdmissionPipeline`'s `:root_manifest` option).
  A candidate never reaches it -- a candidate's law documents are judged
  AGAINST a manifest, they do not produce one.

  Standing conferred through such a manifest is still decided at use time by
  `AshA2A.Semantic.MetaAdmission.document_standing/4`, which re-verifies the
  manifest against the files written here (`RootManifest.verify_use/2`): a
  file edited after `build/3` has no standing.
  """

  alias AshA2A.Semantic.{MetaAdmission, RootManifest}
  alias AshA2A.Semantic.RootManifest.ConformanceCorpus

  @type document :: {String.t(), String.t()} | {String.t(), String.t(), String.t()}

  @doc """
  Pins `documents` (`{kind, bytes}` or `{kind, bytes, id}`) under `root` and
  builds the manifest. Raises `ArgumentError` for a kind that is not a
  `MetaAdmission.artifact_kinds/0` kind. `opts` are forwarded to
  `ConformanceCorpus.spec/1` (`:wasm_path`, `:engine_path`,
  `:expected_version`).
  """
  @spec build(Path.t(), [document()], keyword()) :: {:ok, RootManifest.t()} | {:error, map()}
  def build(root, documents, opts \\ []) when is_list(documents) do
    pins =
      documents
      |> Enum.map(&entry(root, &1))
      |> Enum.uniq_by(&{&1[:kind], &1[:path]})

    {roots, rest} = Enum.split_with(pins, &(&1[:kind] == "ontology_root"))
    {profiles, validators} = Enum.split_with(rest, &(&1[:kind] == "semantic_profile"))

    spec =
      opts
      |> ConformanceCorpus.spec()
      |> Keyword.merge(ontology_roots: roots, semantic_profiles: profiles, validators: validators)

    RootManifest.build(root, spec)
  end

  defp entry(root, {kind, bytes}), do: entry(root, {kind, bytes, nil})

  defp entry(root, {kind, bytes, id}) when is_binary(kind) and is_binary(bytes) do
    unless kind in MetaAdmission.artifact_kinds() do
      raise ArgumentError, "#{inspect(kind)} is not a meta-admission artifact kind"
    end

    "sha256:" <> hex = RootManifest.digest_bytes(bytes)
    short = String.slice(hex, 0, 16)
    relative = Path.join(["law", kind, short <> ".doc"])
    absolute = Path.join(root, relative)

    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, bytes)

    [id: id || "urn:ash-a2a:law:#{kind}:#{short}", kind: kind, path: relative]
  end
end
