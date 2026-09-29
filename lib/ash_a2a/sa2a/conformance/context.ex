defmodule AshA2A.SA2A.Conformance.Context do
  @moduledoc """
  Input context for the conformance checks: every collaborator a check probes is
  a key here, defaulting to the real one in this tree, so a test (or an operator
  verifying a different deployment) substitutes a real fixture instead of
  mutating application env.
  """

  @default_boundary_modules [
    AshA2A.ConsequenceKernel.EffectIdentity,
    AshA2A.ConsequenceKernel.RequestIdentity,
    AshA2A.ConsequenceKernel.ExactSubject,
    AshA2A.ConsequenceKernel.IdentityBundle,
    AshA2A.ConsequenceKernel.ReplayEvidence,
    AshA2A.ConsequenceKernel.PreparedRecordCodec,
    AshA2A.ConsequenceKernel.ReceiptChain,
    AshA2A.C2.PreparedEffect,
    AshA2A.C2.AuthorityRequest
  ]

  @spec build(map() | keyword()) :: map()
  def build(opts) when is_list(opts), do: opts |> Map.new() |> build()

  def build(%{} = opts) do
    defaults = %{
      root: File.cwd!(),
      version: "v26.9.28",
      tier: "I1",
      scope: "same-host-os-user",
      github: false,
      gh: "gh",
      security_profile_module: AshA2A.SecurityProfile,
      closure_module: AshA2A.ConsequenceKernel.ClosureCourt,
      command_bus: AshA2A.CommandBus,
      dispatcher: AshA2A.Dispatcher,
      boundary_modules: @default_boundary_modules,
      beam_binaries: %{},
      certificate_verifier: AshA2A.C2.CertificateVerifier,
      crypto_verifier: AshA2A.C2.CryptoVerifier,
      signer_set: AshA2A.C3.SignerSet,
      control_plane_app: :ash_a2a
    }

    lazy = [
      claim_store: fn -> Application.get_env(:ash_a2a, :claim_store) end,
      journal_dir: fn -> Application.get_env(:ash_a2a, :receipt_outbox_dir) end,
      journal_key_provider: &default_key_provider/0,
      app_env: fn -> Application.get_all_env(:ash_a2a) end,
      env: fn -> System.get_env() end
    ]

    base = Map.merge(defaults, opts)

    Enum.reduce(lazy, base, fn {key, fun}, acc ->
      if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, fun.())
    end)
  end

  defp default_key_provider do
    key =
      Application.get_env(:ash_a2a, :receipt_outbox_key) ||
        Application.get_env(:ash_a2a, :receipt_binding_key)

    if is_binary(key),
      do: {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: key]},
      else: nil
  end
end
