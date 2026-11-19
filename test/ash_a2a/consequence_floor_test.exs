# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.ConsequenceFloorTest do
  @moduledoc """
  SEC-04 court: `consequence: :observe` on a mutating (`:create`/`:update`/
  `:destroy`) action must be a compile-time `Spark.Error.DslError`, because
  `:observe` bypasses `AshA2A.Authority.Grant`, `AshA2A.CommandBus`
  admission, receipts and the BRCE anchor. Real `defmodule` compilation
  through the real `AshA2A.Transformers.BuildCapabilityIndex`; no doubles.
  """
  use ExUnit.Case

  test "resource-level :observe on a default :create action is refused at compile time" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.ConsequenceFloor.ObserveCreate do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
            attribute(:label, :string, public?: true)
          end

          actions do
            defaults([:read, create: [:label]])
          end

          a2a do
            skill(:sneaky_create, :create, consequence: :observe)
          end
        end
      end

    assert error.message =~ "observe_on_mutating_action"
    assert error.path == [:a2a, :sneaky_create, :consequence]
  end

  for type <- [:update, :destroy] do
    test "resource-level :observe on an explicit #{type} action is refused" do
      type = unquote(type)
      mod = Module.concat(AshA2A.Test.ConsequenceFloor, "Explicit#{type}")

      error =
        assert_raise Spark.Error.DslError, fn ->
          Code.compile_quoted(
            quote do
              defmodule unquote(mod) do
                use Ash.Resource,
                  domain: nil,
                  validate_domain_inclusion?: false,
                  data_layer: Ash.DataLayer.Ets,
                  extensions: [AshA2A]

                attributes do
                  uuid_primary_key(:id)
                  attribute(:label, :string, public?: true)
                end

                actions do
                  defaults([:read])
                  unquote(type)(:mutate)
                end

                a2a do
                  skill(:mutate_skill, :mutate, consequence: :observe)
                end
              end
            end
          )
        end

      assert error.message =~ "#{inspect(type)} action `mutate`"
    end
  end

  test "domain-level :observe on a real resource's :destroy action is refused" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule Elixir.AshA2A.Test.ConsequenceFloor.ObserveDestroyDomain do
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(AshA2A.Test.Fixture.Item)
          end

          a2a do
            skill(:quiet_destroy, AshA2A.Test.Fixture.Item, :destroy, consequence: :observe)
          end
        end
      end

    assert error.message =~ "observe_on_mutating_action"
  end

  test "raising a mutating action and :observe on :read/generic actions still compile" do
    defmodule Elixir.AshA2A.Test.ConsequenceFloor.Allowed do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]

      attributes do
        uuid_primary_key(:id)
        attribute(:label, :string, public?: true)
      end

      actions do
        defaults([:read, create: [:label]])

        action :ping, :string do
          run(fn _input, _context -> {:ok, "pong"} end)
        end
      end

      a2a do
        skill(:loud_create, :create, consequence: :external_do)
        skill(:look, :read, consequence: :observe)
        skill(:ping, :ping, consequence: :observe)
      end
    end

    overrides =
      Spark.Dsl.Extension.get_persisted(
        AshA2A.Test.ConsequenceFloor.Allowed,
        :ash_a2a_skill_overrides
      )

    assert Enum.map(overrides, &{&1.name, &1.consequence}) == [
             loud_create: :external_do,
             look: :observe,
             ping: :observe
           ]
  end

  test "the refusal code is S42-classified" do
    assert AshA2A.Transformers.BuildCapabilityIndex.__sa2a_refusal_codes__() ==
             %{observe_on_mutating_action: :refused_consequence}
  end
end
