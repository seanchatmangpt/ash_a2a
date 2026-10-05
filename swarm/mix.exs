defmodule SwarmNode.MixProject do
  use Mix.Project

  @moduledoc """
  Minimal, real host application for `ash_a2a`'s real distributed-Erlang
  agent swarm test.

  This is NOT ash_a2a's own release story (ash_a2a stays a pure library --
  see `../mix.exs`'s own moduledoc-equivalent comment on that boundary).
  It is a small, separate application whose only job is: depend on
  `ash_a2a` via a real `path:` dependency, define one real `Ash.Resource` +
  `AshA2A.Agent` (the exact same `use AshA2A.Agent, resource_or_domain:`
  pattern every other real consumer in this repo's own test/support
  fixtures uses), join a real Kubernetes-discovered BEAM cluster via
  `libcluster`, and expose one real probe (`SwarmNode.Probe.run/0`) that a
  `mix release`'s `bin/swarm_node rpc` command can invoke from inside a
  running pod to prove real cross-pod `AshA2A.Protocol.Agent` dispatch.
  """

  def project do
    [
      app: :swarm_node,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      # `:ssl` is required in the release: the node's distribution runs over
      # `-proto_dist inet_tls` (rel/vm.args.eex, DEP-07/SEC-10), which needs
      # the ssl application's code in the release boot path.
      extra_applications: [:logger, :runtime_tools, :ssl, :public_key, :crypto],
      mod: {SwarmNode.Application, []}
    ]
  end

  defp deps do
    [
      # Real path dependency on the ash_a2a checkout this app lives beside
      # -- exercises the exact real capability index / dispatcher /
      # CommandBus / AshA2A.Protocol.Agent machinery this whole repo's test suite
      # already covers, never a reimplementation or a mock host.
      {:ash_a2a, path: ".."},
      {:libcluster, "~> 3.5"},
      # HTTP surface for kubelet probes (/healthz, /readyz, /drain) and the
      # opt-in A2A JSON-RPC mount (SwarmNode.A2ARouter). Same versions the
      # root ash_a2a lock already pins.
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end

  defp releases do
    [
      swarm_node: [
        include_executables_for: [:unix],
        # rel/overlays/ssl_dist.conf lands at the release root (/app in the
        # image) and is what rel/vm.args.eex's -ssl_dist_optfile points at.
        overlays: ["rel/overlays"],
        applications: [swarm_node: :permanent]
      ]
    ]
  end
end
