# SPDX-FileCopyrightText: 2026 ash_a2a contributors
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.PEPHardeningTest do
  use ExUnit.Case, async: true

  alias AshA2A.Authority.{GraphPin, PEP, Source}

  defmodule Raiser do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: raise("boom")
  end

  defmodule Thrower do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: throw(:nope)
  end

  defmodule Exiter do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: exit(:gone)
  end

  defmodule Extra do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: {:ok, %{extra: 1}}
  end

  defmodule Denier do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: {:deny, :why}
  end

  defmodule Garbage do
    @behaviour AshA2A.Authority.Source
    def check(_, _, _, _), do: String.duplicate("secret", 100)
  end

  defmodule NotASource do
    def check(_, _, _, _), do: :ok
  end

  defp run(src, scope \\ "a2a:x"), do: PEP.assert_standing("a", scope, %{}, source: src)

  test "raise/throw/exit become typed refusals" do
    assert {:refused, :insufficient_authority, %{reason: :source_raised}} = run(Raiser)
    assert {:refused, :insufficient_authority, %{reason: :source_threw}} = run(Thrower)
    assert {:refused, :insufficient_authority, %{reason: :source_exited}} = run(Exiter)
  end

  test "unloaded module refused" do
    assert {:refused, :insufficient_authority, %{reason: :source_raised}} =
             run(Does.Not.Exist)
  end

  test "malformed :source values refused" do
    for bad <- [nil, "str", {Raiser}, {Extra, :nope}, 42, [Extra]] do
      assert {:refused, :insufficient_authority, %{reason: :invalid_source}} = run(bad)
    end
  end

  test "non-list opts and bad actor refused" do
    assert {:refused, :insufficient_authority, %{reason: :invalid_opts}} =
             PEP.assert_standing("a", "s", %{}, :bad)

    assert {:refused, :insufficient_authority, %{reason: :invalid_actor_id}} =
             PEP.assert_standing(nil, "s", %{}, [])
  end

  test "{:ok, extra} admits; {:deny, r} refuses" do
    assert :ok = run(Extra)
    assert {:refused, _, %{reason: :source_deny, deny_reason: ":why"}} = run(Denier)
  end

  test "scope shapes: string-key map and struct refused, atom-key map ok" do
    assert {:refused, _, %{reason: {:invalid_scope_missing_action, _}}} =
             run(Extra, %{"action" => "a"})

    assert {:refused, _, %{reason: :invalid_scope}} = run(Extra, URI.parse("x"))
    assert :ok = run(Extra, %{action: "a"})
  end

  test "raw return is redacted and bounded" do
    {:refused, _, %{got: got}} = run(Garbage)
    assert is_binary(got) and byte_size(got) < 100
  end

  test "delegate enforces Source behaviour" do
    assert :ok = PEP.delegate("a", "s", %{}, Extra)

    assert {:refused, _, %{reason: :delegate_not_a_source}} =
             PEP.delegate("a", "s", %{}, NotASource)

    assert {:refused, _, %{reason: :invalid_source}} = PEP.delegate("a", "s", %{}, nil)
  end

  test "Source.resolve single implementation" do
    assert {:ok, {Extra, []}} = Source.resolve(Extra)
    assert {:error, :invalid_source} = Source.resolve(nil)
  end

  test "AllowAll refuses in prod" do
    assert {:deny, :allow_all_in_prod} = Source.AllowAll.__check__(:prod, "a", "s", %{}, [])
    assert :ok = Source.AllowAll.__check__(:test, "a", "s", %{}, [])
  end

  describe "GraphPin" do
    @d "sha256:" <> String.duplicate("a", 64)

    test "typed errors for bad inputs" do
      assert {:error, :invalid_digest} = GraphPin.pin("o", nil)
      assert {:error, :invalid_digest} = GraphPin.pin("o", "x")
      assert {:error, :invalid_order_id} = GraphPin.pin(nil, @d)
      assert {:error, :invalid_order_id} = GraphPin.assert_fresh(1, @d)
    end

    defmodule BadStore do
      def put(_, _), do: :weird
      def get(_), do: nil
    end

    test "store.put return validated" do
      assert {:error, {:store_error, {:invalid_return, :weird}}} =
               GraphPin.pin("o", @d, store: BadStore)
    end

    test "concurrent first start tolerated" do
      if pid = Process.whereis(GraphPin.Store.Memory), do: Agent.stop(pid)

      results =
        1..20
        |> Task.async_stream(fn i -> GraphPin.pin("order-#{i}", @d) end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &(&1 == :ok))
      assert :ok = GraphPin.assert_fresh("order-1", @d)
    end
  end
end
