# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.PEPTest do
  use ExUnit.Case, async: true

  alias AshA2A.Authority.PEP

  describe "default DenyAll" do
    test "refuses everything with typed refusal" do
      assert {:refused, :insufficient_authority,
              %{reason: :source_deny, actor_id: "actor-1", action: "a2a:task.send"}} =
               PEP.assert_standing("actor-1", "a2a:task.send", %{})
    end
  end

  describe "AllowAll (tests only)" do
    test "admits" do
      assert :ok =
               PEP.assert_standing("actor-1", "a2a:task.send", %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end
  end

  describe "custom Source" do
    defmodule ScopeAllow do
      @behaviour AshA2A.Authority.Source

      @impl true
      def check("admin", "a2a:kill", _ctx, _opts), do: :ok
      def check(_a, _act, _ctx, _opts), do: :deny
    end

    test "honors the custom source decision" do
      assert :ok = PEP.assert_standing("admin", "a2a:kill", %{}, source: ScopeAllow)
      assert {:refused, :insufficient_authority, _} =
               PEP.assert_standing("pleb", "a2a:kill", %{}, source: ScopeAllow)
    end

    test "{module, opts} form is honored" do
      defmodule OptsEcho do
        @behaviour AshA2A.Authority.Source

        @impl true
        def check(_a, _act, _ctx, opts), do: if(opts[:mode] == :open, do: :ok, else: :deny)
      end

      assert :ok = PEP.assert_standing("x", "s", %{}, source: {OptsEcho, mode: :open})
      assert {:refused, :insufficient_authority, _} =
               PEP.assert_standing("x", "s", %{}, source: {OptsEcho, mode: :closed})
    end

    test "unexpected source return is typed refusal, never raise" do
      defmodule Broken do
        @behaviour AshA2A.Authority.Source

        @impl true
        def check(_a, _act, _ctx, _opts), do: :garbage
      end

      assert {:refused, :insufficient_authority, %{reason: :invalid_source_return}} =
               PEP.assert_standing("x", "s", %{}, source: Broken)
    end
  end

  describe "scope normalization (fail-closed, never raise)" do
    test "binary scope ok" do
      assert :ok =
               PEP.assert_standing("a", "x:y", %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "map with binary :action ok" do
      assert :ok =
               PEP.assert_standing("a", %{action: "x:y", resource: "r"}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end

    test "nil scope -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
               PEP.assert_standing("a", nil, %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "atom/integer/list scope -> typed refusal" do
      for bad <- [:atom_scope, 42, ["list"]] do
        assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
                 PEP.assert_standing("a", bad, %{}, source: AshA2A.Authority.Source.AllowAll)
      end
    end

    test "empty binary scope -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: :invalid_scope}} =
               PEP.assert_standing("a", "", %{}, source: AshA2A.Authority.Source.AllowAll)
    end

    test "map missing :action -> typed refusal" do
      assert {:refused, :insufficient_authority,
              %{reason: {:invalid_scope_missing_action, _}}} =
               PEP.assert_standing("a", %{resource: "r"}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end

    test "map with non-binary :action -> typed refusal" do
      assert {:refused, :insufficient_authority, %{reason: {:invalid_scope_action, :atom}}} =
               PEP.assert_standing("a", %{action: :atom}, %{},
                 source: AshA2A.Authority.Source.AllowAll
               )
    end
  end

  describe "pin_graph_digest/2 passthrough" do
    test "pins the Hilt.WorkOrder identity digest" do
      wo =
        AshA2A.Hilt.WorkOrder.new!(
          work_order_id: "wo-1",
          task_id: "t-1",
          exact_subject_digest: "sha256:" <> String.duplicate("a", 64),
          candidate_digest: "sha256:" <> String.duplicate("b", 64),
          capability_id: "cap-1",
          observation_bounds_digest: "sha256:" <> String.duplicate("c", 64),
          action_bounds_digest: "sha256:" <> String.duplicate("d", 64),
          authority_ceiling: :observe,
          consequence_class: :observe,
          process_evidence_digest: "sha256:" <> String.duplicate("e", 64),
          falsifier_digest: "sha256:" <> String.duplicate("f", 64)
        )

      assert {:ok, digest} = PEP.pin_graph_digest(wo)
      assert digest == AshA2A.Hilt.WorkOrder.identity_digest(wo)
    end
  end

  describe "delegate/4" do
    test "typed refusal carries the same vocabulary" do
      assert {:refused, :insufficient_authority, _} =
               PEP.delegate("a", "s", %{}, AshA2A.Authority.Source.DenyAll)
    end
  end
end
