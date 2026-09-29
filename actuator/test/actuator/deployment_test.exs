defmodule Actuator.DeploymentTest do
  @moduledoc """
  Structural courts over the release config and k8s manifests: no Erlang distribution,
  default-deny network, restricted pod, durable PVC. String-level (no YAML dependency);
  `kubectl kustomize` renders the same tree in the lane's verification.
  """
  use ExUnit.Case, async: true

  @k8s Path.expand("../../../k8s/actuator", __DIR__)
  @root Path.expand("../..", __DIR__)

  defp k8s(f), do: File.read!(Path.join(@k8s, f))

  test "release pins RELEASE_DISTRIBUTION=none and ships no distribution flags" do
    assert File.read!(Path.join(@root, "rel/env.sh.eex")) =~ "export RELEASE_DISTRIBUTION=none"
    refute File.read!(Path.join(@root, "rel/vm.args.eex")) =~ ~r/^\s*-s?name/m
    assert File.read!(Path.join(@root, "mix.exs")) =~ "actuator: ["
  end

  test "mix.exs depends on sa2a_crypto and never on ash_a2a" do
    mix = File.read!(Path.join(@root, "mix.exs"))
    assert mix =~ ~s({:sa2a_crypto, path: "../sa2a_crypto"})
    refute mix =~ "ash_a2a"
    refute mix =~ ~r/\{:ash/
  end

  test "namespace is actuator-system with restricted pod security" do
    ns = k8s("namespace.yaml")
    assert ns =~ "name: actuator-system"
    assert ns =~ "pod-security.kubernetes.io/enforce: restricted"
  end

  test "network policy: default deny both ways, ingress only from authority/control-plane, no egress, no dist ports" do
    np = k8s("networkpolicy.yaml")
    assert np =~ "podSelector: {}"
    assert np =~ ~r/policyTypes:\n\s+- Ingress\n\s+- Egress/
    assert np =~ "authority-system" and np =~ "control-plane"
    assert np =~ "port: 8443"
    refute np =~ ~r/^\s*egress:/m
    for port <- ["4369", "9000"], do: refute(np =~ port)
    refute k8s("statefulset.yaml") =~ "4369"
  end

  test "pod is restricted: non-root, read-only rootfs, no caps, no token, no dist, PVC state" do
    ss = k8s("statefulset.yaml")

    for needle <- [
          "runAsNonRoot: true",
          "readOnlyRootFilesystem: true",
          "allowPrivilegeEscalation: false",
          "drop: [\"ALL\"]",
          "automountServiceAccountToken: false",
          "hostNetwork: false",
          "type: RuntimeDefault",
          "name: RELEASE_DISTRIBUTION",
          "value: \"none\"",
          "volumeClaimTemplates:",
          "replicas: 1"
        ] do
      assert ss =~ needle, "missing #{needle}"
    end

    refute ss =~ "hostPath"
    refute ss =~ "privileged: true"
    assert k8s("serviceaccount.yaml") =~ "automountServiceAccountToken: false"
  end

  test "base config fails closed: empty registry" do
    assert k8s("configmap.yaml") =~ ~s("registry": [])
    dir = Actuator.Kit.tmp_dir("cfg")
    path = Path.join(dir, "a.json")
    File.write!(path, ~s({"state_dir":"#{dir}","audience":"a","policy_epoch":1,"registry":[]}))
    assert {:error, :config_unavailable} = Actuator.Config.load(path)
  end
end
