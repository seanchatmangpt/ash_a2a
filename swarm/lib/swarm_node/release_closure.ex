defmodule SwarmNode.ReleaseClosure do
  @moduledoc """
  Loads the frozen capability-release closure the prod release runs under
  (`capability_release_mode: :strict`, DEP-02) from a JSON manifest file:

      {"capabilities": [{"id": "SwarmNode.Echo.ping", "version": "0.1.0",
        "digest": "sha256:...", "admission_digest": "sha256:...",
        "subject_revision": "<40-hex>"}]}

  Each entry is driven through the real `AshA2A.CapabilityRelease` lifecycle
  (candidate -> admit -> release). Release is NOT digest-shaped caller input:
  it resolves an `AshA2A.StandingBinding` through `AshA2A.StandingRef` against
  durable court evidence at the exact 40-hex `subject_revision` each entry
  declares. Durable evidence is located through the CI-artifact source
  (`:artifacts_dir` in `AshA2A.StandingRef.resolve/1`): a directory of
  `sa2a-conformance-<sha>/` receipt directories holding
  `chicago/standing_receipt.json` (plus the optional `sa2a-conformance.json`
  the court's cross-runtime runner wrote beside it). The shipped overlay
  `rel/overlays/standing/` carries that directory layout, vendored
  byte-identically from the ash_a2a checkout's real
  `receipts/courts/sa2a/<sha>/` artifacts; `config/runtime.exs` passes it as
  `ASH_A2A_STANDING_ARTIFACTS_DIR` / `:standing_artifacts_dir`.

  Resolution anchors `:ref` at the entry's own `subject_revision` -- the
  candidate set is the receipt's exact subject, never a moving history head --
  and every admission check (schema, receipt-digest recompute, subject
  identity, CONFORMANT consistency, wasm identity against the co-located
  conformance receipt) runs unchanged. Note the standing dependency:
  `AshA2A.StandingRef.resolve/1` still requires the anchor `:ref` to be a
  resolvable git commit in `:repo` (git binary + object store), so an
  environment without git refuses to boot rather than fabricating standing.
  A fully git-independent artifact-only resolution mode is a typed
  `lib/ash_a2a/standing_ref.ex` follow-up.

  When `expected_digest` pin is given the frozen closure's `portable_digest`
  (the runtime-independent digest, `AshA2A.CapabilityRelease.portable_digest/1`,
  stable across OTP versions and hosts) must equal it exactly, so a tampered
  or stale manifest refuses to boot rather than silently widening what may
  execute. Every failure raises (this runs from `config/runtime.exs`: boot
  fails closed).
  """

  alias AshA2A.CapabilityRelease

  @spec load!(Path.t(), String.t() | nil, keyword()) :: CapabilityRelease.Closure.t()
  def load!(path, expected_digest \\ nil, opts \\ []) when is_list(opts) do
    manifest = path |> File.read!() |> JSON.decode!()

    capabilities =
      case manifest do
        %{"capabilities" => list} when is_list(list) and list != [] ->
          Enum.map(list, &release!(&1, standing_opts(opts)))

        _ ->
          raise ArgumentError, "capability release manifest #{path} has no capabilities"
      end

    closure =
      case CapabilityRelease.freeze(capabilities, standing_opts(opts)) do
        {:ok, closure} -> closure
        {:error, reason} -> raise ArgumentError, "cannot freeze #{path}: #{inspect(reason)}"
      end

    if expected_digest not in [nil, ""] and closure.portable_digest != expected_digest do
      raise ArgumentError,
            "capability release closure digest mismatch for #{path}: " <>
              "expected #{expected_digest}, got portable digest #{closure.portable_digest}"
    end

    closure
  end

  # `:standing_artifacts_dir` is the swarm-facing name; it forwards to
  # `AshA2A.StandingRef`'s `:artifacts_dir` CI-artifact source.
  defp standing_opts(opts) do
    case Keyword.fetch(opts, :standing_artifacts_dir) do
      {:ok, dir} -> [artifacts_dir: dir]
      :error -> []
    end
  end

  defp release!(%{"id" => id, "version" => version, "digest" => digest} = entry, standing_opts) do
    subject = manifest_subject_revision!(id, entry)

    with candidate <-
           CapabilityRelease.candidate(id, version, digest, subject_revision: subject),
         {:ok, admitted} <- CapabilityRelease.admit(candidate, entry["admission_digest"]),
         # Anchor StandingRef's walk at the receipt's own exact subject so the
         # vendored artifact receipt is a candidate regardless of HEAD's history.
         {:ok, released} <-
           CapabilityRelease.release(admitted, Keyword.put(standing_opts, :ref, subject)) do
      released
    else
      {:error, reason} ->
        raise ArgumentError, "capability #{id} not releasable: #{inspect(reason)}"
    end
  end

  defp release!(entry, _standing_opts),
    do: raise(ArgumentError, "malformed capability manifest entry: #{inspect(entry)}")

  defp manifest_subject_revision!(id, %{"subject_revision" => sha}) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      sha
    else
      raise ArgumentError,
            "capability #{id} manifest entry subject_revision must be 40 lowercase hex, got: #{inspect(sha)}"
    end
  end

  defp manifest_subject_revision!(id, _entry) do
    raise ArgumentError,
          "capability #{id} manifest entry is missing required subject_revision " <>
            "(40-hex exact subject of the admitted standing receipt)"
  end
end
