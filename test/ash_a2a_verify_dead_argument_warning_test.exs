defmodule AshA2A.VerifyDeadArgumentWarningTest do
  use ExUnit.Case, async: true

  import Spark.Test

  @moduledoc """
  ERRC Reduce finding (wlnyxcjht adversarial-review workflow): `AshA2A.Dsl`'s
  nested `argument` entity (`a2a do skill ... do argument ... end end`) is
  parsed and persisted onto each `AshA2A.Skill` override, but real
  capability compilation (`AshA2A.CapabilityIndex.Compiler.derive_arguments/2`)
  always derives arguments from the referenced Ash action's own
  `arguments`/`accept` instead -- the override's own `arguments` are never
  consulted. Declaring one compiled silently and did nothing.

  `AshA2A.Verify.verify/1` now surfaces this as a real Spark `{:warn, ...}`
  compile-time warning instead of a silent no-op. These tests compile real,
  freshly-defined DSL modules through `Spark.Test`'s collector (no mocked
  parser, no hand-built verifier return value) and assert on the real
  collected warning/absence of one.
  """

  test "a skill with a nested argument block produces a real compile-time warning" do
    {message, _location} =
      assert_dsl_warning {_, _} do
        defmodule Elixir.AshA2A.Test.VerifyWarn.EchoWithArgumentDomain do
          @moduledoc false
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(Elixir.AshA2A.Test.VerifyWarn.EchoWithArgument)
          end
        end

        defmodule Elixir.AshA2A.Test.VerifyWarn.EchoWithArgument do
          @moduledoc false
          use Ash.Resource,
            domain: Elixir.AshA2A.Test.VerifyWarn.EchoWithArgumentDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill :echo, :read do
              argument(:query, :string)
            end
          end
        end
      end

    assert message =~ "argument"
    assert message =~ ":echo"
  end

  test "a skill with no nested argument block compiles with no warning" do
    :ok =
      refute_dsl_warnings do
        defmodule Elixir.AshA2A.Test.VerifyWarn.EchoNoArgumentDomain do
          @moduledoc false
          use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

          resources do
            resource(Elixir.AshA2A.Test.VerifyWarn.EchoNoArgument)
          end
        end

        defmodule Elixir.AshA2A.Test.VerifyWarn.EchoNoArgument do
          @moduledoc false
          use Ash.Resource,
            domain: Elixir.AshA2A.Test.VerifyWarn.EchoNoArgumentDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          a2a do
            skill(:echo, :read)
          end
        end
      end
  end
end
