defmodule AshA2A.DslVerifiersV11Test do
  use ExUnit.Case, async: true

  alias AshA2A.Domain.Verifiers.VerifyExecution

  defp msg({:error, %Spark.Error.DslError{message: m}}), do: m

  describe "events_transport" do
    test "nil, atom, global, via, pid accepted" do
      for v <- [nil, :my_events, MyApp.Events, {:global, :x}, {:via, Registry, {R, 1}}, self()] do
        assert :ok = VerifyExecution.validate(events_transport: v)
      end

      assert :ok = VerifyExecution.validate([])
    end

    test "bad values refused with typed error" do
      for v <- [true, false, "events", 42, [:a], %{}] do
        res = VerifyExecution.validate(events_transport: v)
        assert {:error, %Spark.Error.DslError{path: [:execution, :events_transport]}} = res
        assert msg(res) =~ "invalid `events_transport`"
      end
    end
  end

  describe "cancel_in_flight" do
    test "valid values" do
      for v <- [:refuse, :interrupt, :default, nil] do
        assert :ok = VerifyExecution.validate(cancel_in_flight: v)
      end
    end

    test "invalid values refused" do
      for v <- [:kill, "refuse", true, 1] do
        res = VerifyExecution.validate(cancel_in_flight: v)
        assert msg(res) =~ "invalid `cancel_in_flight`"
      end
    end
  end

  describe "validate_input_modes" do
    test "booleans ok, others refused" do
      assert :ok = VerifyExecution.validate(validate_input_modes: true)
      assert :ok = VerifyExecution.validate(validate_input_modes: false)
      assert msg(VerifyExecution.validate(validate_input_modes: :yes)) =~ "expected a boolean"
      assert msg(VerifyExecution.validate(validate_input_modes: "true")) =~ "expected a boolean"
    end
  end

  describe "user_artifacts" do
    test "execution-keyword form" do
      assert :ok = VerifyExecution.validate(user_artifacts: true)
      assert msg(VerifyExecution.validate(user_artifacts: "yes")) =~ "`user_artifacts`"
    end

    test "domain DSL: good value compiles" do
      quoted =
        quote do
          defmodule AshA2A.Y7Fixtures.GoodArtifactsDomain do
            use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false

            agent do
              name "y7"
              url "https://y7.example.com"
            end

            transport do
              user_artifacts(true)
            end
          end
        end

      assert [{_, _} | _] = Code.compile_quoted(quoted)
    end

    test "domain DSL: non-boolean fails to compile with DslError" do
      quoted =
        quote do
          defmodule AshA2A.Y7Fixtures.BadArtifactsDomain do
            use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false

            agent do
              name "y7"
              url "https://y7.example.com"
            end

            transport do
              user_artifacts("yes")
            end
          end
        end

      error = assert_raise Spark.Error.DslError, fn -> Code.compile_quoted(quoted) end
      assert Exception.message(error) =~ "user_artifacts"
    end
  end

  test "validate!/2 raises the typed error" do
    assert_raise Spark.Error.DslError, ~r/cancel_in_flight/, fn ->
      VerifyExecution.validate!(cancel_in_flight: :nope, events_transport: :ok_name)
    end
  end
end
