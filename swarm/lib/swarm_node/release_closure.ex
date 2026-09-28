defmodule SwarmNode.ReleaseClosure do
  @moduledoc """
  Loads the frozen capability-release closure the prod release runs under
  (`capability_release_mode: :strict`, DEP-02) from a JSON manifest file:

      {"capabilities": [{"id": "SwarmNode.Echo.ping", "version": "0.1.0",
        "digest": "sha256:...", "admission_digest": "sha256:...",
        "release_digest": "sha256:..."}]}

  Each entry is driven through the real `AshA2A.CapabilityRelease` lifecycle
  (candidate -> admit -> release) and frozen. When `expected_digest` is given
  the frozen closure's `portable_digest` (the runtime-independent digest,
  `AshA2A.CapabilityRelease.portable_digest/1`, stable across OTP versions and
  hosts) must equal it exactly, so a tampered or stale
  manifest refuses to boot rather than silently widening what may execute.
  Every failure raises (this runs from `config/runtime.exs`: boot fails closed).
  """

  alias AshA2A.CapabilityRelease

  @spec load!(Path.t(), String.t() | nil) :: CapabilityRelease.Closure.t()
  def load!(path, expected_digest \\ nil) do
    manifest = path |> File.read!() |> JSON.decode!()

    capabilities =
      case manifest do
        %{"capabilities" => list} when is_list(list) and list != [] -> Enum.map(list, &release!/1)
        _ -> raise ArgumentError, "capability release manifest #{path} has no capabilities"
      end

    closure =
      case CapabilityRelease.freeze(capabilities) do
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

  defp release!(%{"id" => id, "version" => version, "digest" => digest} = entry) do
    with candidate <- CapabilityRelease.candidate(id, version, digest),
         {:ok, admitted} <- CapabilityRelease.admit(candidate, entry["admission_digest"]),
         {:ok, released} <- CapabilityRelease.release(admitted, entry["release_digest"]) do
      released
    else
      {:error, reason} ->
        raise ArgumentError, "capability #{id} not releasable: #{inspect(reason)}"
    end
  end

  defp release!(entry),
    do: raise(ArgumentError, "malformed capability manifest entry: #{inspect(entry)}")
end
