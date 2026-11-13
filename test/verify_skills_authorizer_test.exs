# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.VerifySkillsAuthorizerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # Regression: the lease_required? verifier read authorizers via
  # `Transformer.get_entities(dsl_state, [:authorizers])` (always []), so a resource that really
  # has Ash.Policy.Authorizer was told it had none.
  defp compile(name, authorizers_opt) do
    code = """
    defmodule #{inspect(Module.concat(__MODULE__, name))} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshA2A]#{authorizers_opt}

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read])
      end

      a2a do
        skill(:list, :read, lease_required?: true)
      end
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(code) end)
  end

  test "a resource with Ash.Policy.Authorizer is not refused for lease_required?" do
    out = compile("WithAuthorizer", ",\n        authorizers: [Ash.Policy.Authorizer]")
    refute out =~ "refused_lease_required_no_authorizer"
  end

  test "a resource without an authorizer is still refused for lease_required?" do
    out = compile("WithoutAuthorizer", "")
    assert out =~ "refused_lease_required_no_authorizer"
  end
end
