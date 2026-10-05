defmodule SwarmNode.ReleaseClosureTest do
  @moduledoc """
  DEP-02: the prod release runs `capability_release_mode: :strict` with the
  closure frozen from the shipped manifest (rel/overlays/capability_release.json).
  Drives the real manifest file, the real `AshA2A.CapabilityRelease` lifecycle,
  and a real dispatch to the supervised `SwarmNode.EchoAgent`.
  """

  use ExUnit.Case, async: false

  alias AshA2A.CapabilityRelease
  alias SwarmNode.ReleaseClosure

  @manifest Path.expand("../../rel/overlays/capability_release.json", __DIR__)
  @standing_artifacts_dir Path.expand("../../rel/overlays/standing", __DIR__)
  @subject_revision "501a4fdbc427dc6ae50c64368126f2156d3b99c9"

  setup do
    mode = Application.get_env(:ash_a2a, :capability_release_mode)
    closure = Application.get_env(:ash_a2a, :capability_release_closure)

    on_exit(fn ->
      restore(:capability_release_mode, mode)
      restore(:capability_release_closure, closure)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ash_a2a, key)
  defp restore(key, value), do: Application.put_env(:ash_a2a, key, value)

  test "the shipped manifest freezes to a closure containing the echo skill" do
    closure = ReleaseClosure.load!(@manifest, nil, standing_artifacts_dir: @standing_artifacts_dir)

    assert CapabilityRelease.released_ids(closure) == ["SwarmNode.Echo.ping"]

    assert %CapabilityRelease.Closure{} =
             ReleaseClosure.load!(@manifest, closure.portable_digest,
               standing_artifacts_dir: @standing_artifacts_dir
             )

    # The release is standing-bound: every member carries the real resolved
    # binding (durable artifact receipt source, exact subject, CONFORMANT).
    assert %CapabilityRelease.Capability{
             subject_revision: @subject_revision,
             standing_binding: %AshA2A.StandingBinding{} = binding
           } = closure.capabilities["SwarmNode.Echo.ping"]

    assert binding.technical_standing == "CONFORMANT"
    assert binding.subject_revision == @subject_revision
    assert String.starts_with?(binding.receipt_source, "artifact:")
  end

  test "k8s/deployment.yaml pins the shipped manifest's portable digest" do
    deployment = File.read!(Path.expand("../../../k8s/deployment.yaml", __DIR__))

    [_, pinned] =
      Regex.run(
        ~r/ASH_A2A_CAPABILITY_RELEASE_DIGEST\n\s+value: "([^"]+)"/,
        deployment
      )

    assert pinned ==
             ReleaseClosure.load!(@manifest, nil,
               standing_artifacts_dir: @standing_artifacts_dir
             ).portable_digest
  end

  test "a pinned digest that does not match refuses to load" do
    assert_raise ArgumentError, ~r/digest mismatch/, fn ->
      ReleaseClosure.load!(@manifest, "sha256:" <> String.duplicate("0", 64),
        standing_artifacts_dir: @standing_artifacts_dir
      )
    end
  end

  test "a manifest with an unreleasable entry refuses to load", %{} do
    path = Path.join(System.tmp_dir!(), "closure_#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      JSON.encode!(%{
        "capabilities" => [
          %{
            "id" => "X.y",
            "version" => "1",
            "digest" => "sha256:" <> String.duplicate("a", 64),
            "subject_revision" => String.duplicate("0", 40)
          }
        ]
      })
    )

    on_exit(fn -> File.rm(path) end)
    assert_raise ArgumentError, ~r/not releasable/, fn -> ReleaseClosure.load!(path) end
  end

  test "strict mode with the shipped closure dispatches the echo skill" do
    Application.put_env(:ash_a2a, :capability_release_mode, :strict)

    Application.put_env(
      :ash_a2a,
      :capability_release_closure,
      ReleaseClosure.load!(@manifest, nil, standing_artifacts_dir: @standing_artifacts_dir)
    )

    assert {:ok, task} = SwarmNode.EchoAgent.call(SwarmNode.EchoAgent, message())
    assert [%AshA2A.Protocol.Artifact{parts: [%AshA2A.Protocol.Part.Data{data: %{node: node_name}}]} | _] = task.artifacts
    assert node_name == to_string(node())
  end

  test "strict mode with no closure refuses the echo skill (fail closed)" do
    Application.put_env(:ash_a2a, :capability_release_mode, :strict)
    Application.delete_env(:ash_a2a, :capability_release_closure)

    result = SwarmNode.EchoAgent.call(SwarmNode.EchoAgent, message())
    refute match?({:ok, %{artifacts: [%AshA2A.Protocol.Artifact{} | _]}}, result)
  end

  defp message, do: AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"from" => "test"})])
end
