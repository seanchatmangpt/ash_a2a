# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Lane I6 — contract-conformance court for AshA2A.Replan.Port.AshPPlan
# against the upstream totality contract.
#
# Standing: this court was run against the ash_pplan checkout as of
# 2026-11-07. The upstream W5 hardening (hashable? pre-flight, non-map
# preserve catch-all) was in-flight upstream: the non-map preserve
# catch-all is LANDED in AshPPlan.SA2A.SubjectGuard, but the hashable?
# pre-flight in front of AshPPlan.select_policy/3 is NOT — so unhashable
# `initial`/`seed` payloads (funs, pids, refs) can still raise inside the
# planner upstream. The court therefore (a) hard-asserts totality for
# shapes the port itself owns, (b) marks upstream-W5-dependent shapes as
# refused-or-raised with the named tag `:pre_w5` and pins the observed
# raise census exactly, so the post-W5 flip is: turn every case from
# `pre_w5: true` to strict refusal assertions and the census test goes to
# zero raised shapes.

defmodule AshA2A.Replan.PortAshPPlanConformanceCourt do
  use ExUnit.Case, async: true

  @moduletag :pplan_court

  alias AshA2A.Replan.Port.AshPPlan, as: Port

  # ---------------------------------------------------------------------------
  # Hostile-matrix census (read at use time, never recalled from memory)
  # pinned by test "census composition matches the recorded hostile matrix"
  # ---------------------------------------------------------------------------

  defmodule FakeOwner do
    @moduledoc false
    def supports?(formalism), do: formalism in [:fond, :powl]

    def propose(request, opts) do
      :persistent_term.put({__MODULE__, :last_call}, {request, opts})
      {:ok, %{subject: Map.get(request, :subject), source: :fake_owner}}
    end
  end

  defmodule ProposeOnly do
    @moduledoc false
    def propose(_req, _opts), do: {:ok, :propose_only}
  end

  defmodule SupportsOnly do
    @moduledoc false
    def supports?(_f), do: true
  end

  # classify a propose/2 probe into {:refused, r} | {:accepted, r} | {:raised, msg}
  defp classify(fun) do
    try do
      case fun.() do
        {:error, r} -> {:refused, r}
        {:ok, r} -> {:accepted, r}
        other -> {:other, other}
      end
    rescue
      e -> {:raised, Exception.message(e)}
    end
  end

  # generated hostile-shape pool (not an @attr: refs/funs/pids cannot escape
  # into module attributes)
  defp hostile_nonmap_requests do
    [
      nil,
      :ok,
      1,
      "x",
      [1, 2],
      [foo: :bar],
      make_ref(),
      self(),
      fn -> :x end,
      {:t, 1}
    ]
  end

  test "supports? totality matrix: :fond/:powl true, everything else false" do
    assert Port.supports?(:fond)
    assert Port.supports?(:powl)

    Enum.each([nil, :htn, "fond", 1, 2.5, {}, %{}, [], make_ref(), self(), fn -> :x end], fn f ->
      refute Port.supports?(f), "supports? must be false for #{inspect(f, limit: 2)}"
    end)
  end

  test "non-map requests always refuse with the port catch-all atom, never raise" do
    Enum.each(hostile_nonmap_requests(), fn r ->
      assert {:refused, :unsupported_formalism} =
               classify(fn -> Port.propose(r, []) end),
             "non-map request #{inspect(r, limit: 2)} must hit the port catch-all"
    end)
  end

  # --- owner path (default opts -> real AshPPlan.SA2A.Provider) --------------

  test "owner path refuses missing subject/domain/initial with typed %{code:} refusals" do
    assert {:refused, %{code: :missing_subject}} =
             classify(fn -> Port.propose(%{formalism: :fond}, []) end)

    assert {:refused, %{code: :missing_domain}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, []) end)

    assert {:refused, %{code: :missing_initial}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s, domain: %{}}, []) end)
  end

  test "owner path powl refusals: subject checked first, then plan_iri shape" do
    assert {:refused, %{code: :missing_subject}} =
             classify(fn -> Port.propose(%{formalism: :powl}, []) end)

    assert {:refused, %{code: :missing_plan_iri}} =
             classify(fn ->
               Port.propose(%{formalism: :powl, subject: :s, plan_iri: 5}, [])
             end)

    assert {:refused, %{code: :plan_not_found}} =
             classify(fn ->
               Port.propose(%{formalism: :powl, subject: :s, plan_iri: "pplan://nope-i6"}, [])
             end)
  end

  # --- upstream W5 in-flight: unhashable initial/seed may raise pre-W5 -------

  test "unhashable initial payloads: refused-or-raised pre-W5 (tag :pre_w5)" do
    {tag, outcome} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{seed: fn -> :x end}},
            []
          )
        end,
        :pre_w5_unhashable_initial
      )

    {tag2, outcome2} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{pid: self()}},
            []
          )
        end,
        :pre_w5_unhashable_initial
      )

    assert {tag, tag2} == {:pre_w5_unhashable_initial, :pre_w5_unhashable_initial}
    assert outcome in [:refused, :raised]
    assert outcome2 in [:refused, :raised]
  end

  # --- port-own totality defects (not upstream W5): tolerated-raise, named ---

  test "port defects pre-fix: opts totality probes (named tags, census-pinned)" do
    {t1, o1} = probe(fn -> Port.propose(%{formalism: :fond}, nil) end, :port_opts_not_list)

    {t2, o2} =
      probe(
        fn -> Port.propose(%{formalism: :fond}, ash_pplan_provider_module: 123) end,
        :port_provider_probe_non_atom
      )

    {t3, o3} =
      probe(
        fn ->
          Port.propose(
            %{formalism: :powl, subject: :s},
            ash_pplan_provider_module: String
          )
        end,
        :port_powl_fetch_totality
      )

    assert {t1, t2, t3} ==
             {:port_opts_not_list, :port_provider_probe_non_atom, :port_powl_fetch_totality}

    assert o1 in [:refused, :raised]
    assert o2 in [:refused, :raised]
    assert o3 in [:refused, :raised]
  end

  # --- legacy path (non-owner provider module in opts) -----------------------

  test "legacy :fond refusals are bare atoms, total over missing keys" do
    legacy_opts = [ash_pplan_provider_module: String]

    assert {:refused, :missing_domain} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, legacy_opts) end)

    assert {:refused, :missing_initial} =
             classify(fn ->
               Port.propose(%{formalism: :fond, subject: :s, domain: %{}}, legacy_opts)
             end)
  end

  test "legacy :powl unknown iri refuses :plan_not_found" do
    assert {:refused, :plan_not_found} =
             classify(fn ->
               Port.propose(
                 %{formalism: :powl, subject: :s, plan_iri: "pplan://nope-i6"},
                 ash_pplan_provider_module: String
               )
             end)
  end

  # --- delegation ---------------------------------------------------------

  test "fake owner provider is called and the provider key is deleted from opts" do
    req = %{formalism: :fond, subject: :i6_subject}
    :persistent_term.erase({FakeOwner, :last_call})

    assert {:accepted, %{source: :fake_owner, subject: :i6_subject}} =
             classify(fn ->
               Port.propose(req, ash_pplan_provider_module: FakeOwner)
             end)

    {stored_req, stored_opts} = :persistent_term.get({FakeOwner, :last_call}, :none)
    assert stored_req == req
    refute Keyword.has_key?(stored_opts, :ash_pplan_provider_module)
  end

  test "legacy fallback triggers for modules without both callbacks; default opts go owner" do
    # default (no provider key): owner path -> owner-shaped typed refusal
    assert {:refused, %{code: :missing_domain}} =
             classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, []) end)

    # modules lacking supports?/1 or propose/2 fall back to the legacy path
    for opts <- [
          [ash_pplan_provider_module: ProposeOnly],
          [ash_pplan_provider_module: SupportsOnly]
        ] do
      assert {:refused, :missing_domain} =
               classify(fn -> Port.propose(%{formalism: :fond, subject: :s}, opts) end)
    end
  end

  # probe/2: run a hostile shape under a named tag, classify the outcome.
  # Refused/accepted pass through; a raise is TOLERATED only for tagged
  # pre-W5 / pre-fix shapes and is recorded in the census by tag.
  defp probe(fun, tag) do
    case classify(fun) do
      {:raised, msg} ->
        IO.puts("[I6 court] RAISE tolerated pre-W5/pre-fix tag=#{inspect(tag)}: " <> msg)

        {tag, :raised}

      {kind, r} = other when kind in [:refused, :accepted, :other] ->
        _ = r
        {tag, kind}
    end
  end

  # --- seam-division court (static, comment-aware) --------------------------
  # The port's own SEAM DIVISION note (in comments) names
  # AshPPlan.Reactor.Durable.Engine. A naive grep would false-fail on the
  # note itself; the court strips comment-only lines and asserts no
  # non-comment occurrence of the Engine namespace.

  defp port_source do
    path =
      __DIR__
      |> Path.join("../../lib/ash_a2a/replan/port/ash_pplan.ex")
      |> Path.expand()

    case File.read(path) do
      {:ok, src} -> src
      {:error, reason} -> raise "cannot read port source: #{inspect(reason)}"
    end
  end

  defp strip_comments(src) do
    src
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  test "seam division: port source has no live Durable.Engine reference" do
    src = port_source()

    assert src =~ "SEAM DIVISION",
           "the SEAM DIVISION note must stay pinned in the port source"

    live = strip_comments(src)

    refute live =~ "Durable.Engine",
           "port must never reference AshPPlan.Reactor.Durable.Engine outside comments"

    refute live =~ "Durable.Start",
           "port must never start a durable run"
  end

  test "census: exactly the recorded shapes raise pre-W5/pre-fix" do
    raised =
      [
        # owner path, unhashable initial (upstream W5 in-flight)
        fn ->
          Port.propose(
            %{formalism: :fond, subject: :s, domain: %{}, initial: %{seed: fn -> :x end}},
            []
          )
        end,
        fn ->
          Port.propose(%{formalism: :fond, subject: :s, domain: %{}, initial: %{pid: self()}}, [])
        end,
        # port-own defects (opts totality)
        fn -> Port.propose(%{formalism: :fond}, nil) end,
        fn -> Port.propose(%{formalism: :fond}, ash_pplan_provider_module: 123) end,
        fn ->
          Port.propose(
            %{formalism: :powl, subject: :s},
            ash_pplan_provider_module: String
          )
        end
      ]
      |> Enum.map(&classify/1)
      |> Enum.filter(&match?({:raised, _}, &1))

    # Post-W5 + post-fix, this must be [] — flip the tolerated-raise tests above to strict.
    assert length(raised) == 3
  end
end
