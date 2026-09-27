defmodule AshA2A.ArchitectureEnvelopeTest do
  use ExUnit.Case, async: true

  alias AshA2A.ArchitectureEnvelope

  defp subject do
    %{
      abb_digest: "sha256:abb",
      contract_digest: "sha256:contract",
      candidate_digest: "sha256:candidate",
      exact_subject_digest: "sha256:subject"
    }
  end

  defp qualification(overrides \\ %{}) do
    Map.merge(
      %{
        standing: :qualified,
        candidate_digest: "sha256:candidate",
        contract_digest: "sha256:contract",
        exact_subject_digest: "sha256:subject",
        qualification_digest: "sha256:qualification"
      },
      overrides
    )
  end

  test "provider and transport substitution preserve semantic identity" do
    assert {:ok, first} =
             ArchitectureEnvelope.build(subject(),
               operation: :select,
               authority: :select,
               provider: :provider_a,
               transport: :http,
               qualification: qualification()
             )

    assert {:ok, second} =
             ArchitectureEnvelope.build(subject(),
               operation: :select,
               authority: :select,
               provider: :provider_b,
               transport: :nats,
               qualification: qualification()
             )

    assert first.semantic_identity == second.semantic_identity
    assert first.execution_authority == :none
    assert first.authority_ceiling == :select
  end

  test "participants can propose candidates without manufacturing qualification" do
    assert {:ok, envelope} =
             ArchitectureEnvelope.build(subject(), operation: :propose, authority: :observe)

    assert envelope.qualification_standing == :candidate
    assert is_nil(envelope.qualification_digest)
  end

  test "stale or forged qualification fails closed" do
    assert {:error, {:refused, :stale_contract}} =
             ArchitectureEnvelope.build(subject(),
               qualification: qualification(%{contract_digest: "sha256:old"})
             )

    assert {:error, {:refused, :forged_qualification}} =
             ArchitectureEnvelope.build(subject(),
               qualification: qualification(%{standing: :candidate})
             )
  end

  test "CONSTRUCT and DO cannot be laundered through interchange" do
    assert {:error, {:refused, :authority_laundering}} =
             ArchitectureEnvelope.build(subject(), authority: :construct)

    assert {:error, {:refused, :authority_laundering}} =
             ArchitectureEnvelope.build(subject(), authority: :do)
  end
end
