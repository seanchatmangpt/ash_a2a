defmodule AshA2A.Lane17DomainVerifierLocationTest do
  # UNVERIFIED: written without an Elixir toolchain; not compiled or run.
  use ExUnit.Case, async: true

  import Spark.Test

  defp errors(body, name) do
    mod = Module.concat(AshA2A.Lane17Gen, name)

    quoted =
      quote do
        defmodule unquote(mod) do
          use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false
          unquote(body)
        end
      end

    dsl_errors do
      Code.compile_quoted(quoted)
    end
    |> Enum.flat_map(fn {_module, errors} -> errors end)
  end

  defp assert_located(errs, path_prefix) do
    assert [%Spark.Error.DslError{} = e | _] = errs
    assert List.starts_with?(e.path, path_prefix)
    refute is_nil(e.location), "refusal at #{inspect(e.path)} carries no location"
  end

  test "VerifyConfig refusals carry path and location" do
    body =
      quote do
        agent do
          description "x"
        end

        transport do
          base_url "https://x.example.com"
        end
      end

    assert_located(errors(body, "NoName"), [:agent, :name])
  end

  test "VerifyMounts refusals carry path and location" do
    body =
      quote do
        agent do
          name "n"
          url "https://x.example.com"
        end

        transport do
          mount agent: Enum, path: "/e", binding: :jsonrpc
        end
      end

    assert_located(errors(body, "NotAnAgent"), [:transport, :mount])
  end
  # VerifyExtensions duplicate-uri: Spark's entity `identifier: :uri` may reject
  # duplicates before the verifier runs, so it is not asserted here (UNVERIFIED).
end
