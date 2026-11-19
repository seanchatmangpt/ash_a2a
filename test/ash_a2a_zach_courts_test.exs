defmodule AshA2A.ZachCourtsTest do
  @moduledoc """
  Adversarial courts (generate-and-kill / mutation lens) for the
  Zach-style surface, reconciled with the landed v1.0 APIs:

    1. NON-VACUITY court -- a `skill` declaration naming a nonexistent action,
       or an `argument_mapping` targeting a nonexistent argument, must FAIL
       COMPILATION with a real `Spark.Error.DslError`. Implemented with real
       Spark compilation of real fixture resources inside the test
       (`Spark.Test.assert_dsl_error/2` / `refute_dsl_errors/1`) -- no mocks.
       `AshA2A.Verifiers.VerifySkills` is registered in lib/ash_a2a.ex, so all
       three refusals are live.

    2. ToA2AError totality court -- for every Ash error struct module found by
       globbing `deps/ash/lib/ash/error/**/*.ex` at test time,
       `AshA2A.ToA2AError.to_a2a_error/2` must return the FULL JSON-RPC 2.0
       error envelope `%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" =>
       integer in -32768..-32000, "message" => binary}}` -- total over the
       enumeration, no FunctionClauseError, no crash of any kind. A raise IS
       the kill. Codes follow the landed v1.0 error registry
       (`AshA2A.Protocol.JSONRPC.Error`): `Ash.Error.Query.NotFound` maps
       -32002 (RECORD_NOT_FOUND ErrorInfo), `Ash.Error.Forbidden`(-class and
       `.Policy`) maps -32001 (POLICY_FORBIDDEN), the `Ash.Error.Invalid`
       class and its caller-input members map -32602 (INVALID_PARAMS), and the
       `Any` fallback maps -32603 with an opaque ref only.

    3. Executor court -- a REAL action on a REAL ETS resource dispatched
       through `AshA2A.Executor.execute/3` (skill, message, opts) with a real
       `Ash.Policy.Authorizer`: a policy denial surfaces as the -32001
       envelope (POLICY_FORBIDDEN ErrorInfo); the happy path returns
       `{:ok, [Part.Data.t()]}`. No mocks (Chicago).

  Positive controls accompany every refusal so the refusals themselves are
  not vacuous: a valid skill (including a valid `argument_mapping`) compiles
  clean, a known error maps at both the error and class level, and an
  authorized dispatch returns `{:ok, _}`.
  """

  use ExUnit.Case, async: true

  @moduletag :zach_courts

  import Spark.Test, only: [assert_dsl_error: 2, refute_dsl_errors: 1]

  @error_info_type "type.googleapis.com/google.rpc.ErrorInfo"
  @a2a_domain "a2a-protocol.org"
  @jsonrpc_code_range -32_768..-32_000

  # ---------------------------------------------------------------------------
  # Court 1: NON-VACUITY -- invalid skill declarations must fail compilation
  # ---------------------------------------------------------------------------

  describe "non-vacuity court: skill compilation" do
    # POSITIVE CONTROL -- the valid skill carries a VALID `argument_mapping`
    # and compiles clean through the registered `AshA2A.Verifiers.VerifySkills`.
    test "positive control: a valid skill with a valid argument_mapping compiles clean" do
      refute_dsl_errors do
        defmodule Elixir.AshA2A.Test.ZachCourts.Positive do
          @moduledoc false

          use Ash.Resource,
            domain: Elixir.AshA2A.Test.ZachCourts.PositiveDomain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshA2A]

          attributes do
            uuid_primary_key(:id)
            attribute(:query, :string, public?: true)
          end

          actions do
            read :echo do
              argument(:query, :string, allow_nil?: true)
            end
          end

          a2a do
            skill :echo, :echo do
              argument_mapping(%{"q" => :query})
            end
          end
        end

        defmodule Elixir.AshA2A.Test.ZachCourts.PositiveDomain do
          @moduledoc false

          use Ash.Domain, extensions: [AshA2A]

          resources do
            resource(Elixir.AshA2A.Test.ZachCourts.Positive)
          end
        end
      end

      # The override survived compilation with its argument_mapping intact on
      # the real DSL entity (argument_mapping is projection metadata; the
      # derived capability index derives arguments from Ash instead) --
      # proving the positive control exercised the real field, not an inert DSL.
      assert {:ok, %AshA2A.Skill{name: :echo, action: :echo}} =
               AshA2A.Info.skill(AshA2A.Test.ZachCourts.Positive, :echo)

      [entity] = Spark.Dsl.Extension.get_entities(AshA2A.Test.ZachCourts.Positive, [:a2a])
      assert %AshA2A.Skill{argument_mapping: %{"q" => :query}} = entity
    end

    # KILL -- refused by `AshA2A.Verify` (via `AshA2A.CapabilityIndex.Validator`)
    # and by the `refused_action_not_found` check in the registered
    # `AshA2A.Verifiers.VerifySkills`.
    test "kill: a skill naming a nonexistent action fails compilation with a real DslError" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.Test.ZachCourts.BogusAction do
            @moduledoc false

            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshA2A]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            a2a do
              skill(:bogus, :not_a_real_action)
            end
          end
        end

      assert error.message =~ "REFUSED_ACTION_NOT_FOUND"
      assert error.message =~ "not_a_real_action"
    end

    # KILL -- refused by the registered `AshA2A.Verifiers.VerifySkills`
    # (lib/ash_a2a/verifiers/verify_skills.ex) with `refused_argument_mapping_target`.
    test "kill: an argument_mapping targeting a nonexistent argument fails compilation" do
      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.AshA2A.Test.ZachCourts.BogusArgumentMapping do
            @moduledoc false

            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshA2A]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            a2a do
              skill(:echo, :read) do
                argument_mapping(%{"wire" => :no_such_argument})
              end
            end
          end
        end

      assert error.message =~ "refused_argument_mapping_target"
      assert error.message =~ "no_such_argument"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 2: ToA2AError totality
  # ---------------------------------------------------------------------------

  describe "ToA2AError totality court" do
    # POSITIVE CONTROL -- a known caller-input error maps at both the bare
    # error level and the wrapped Splode error-class level, producing the full
    # JSON-RPC envelope with the registry's INVALID_PARAMS ErrorInfo.
    test "positive control: a known invalid-input error maps at both error and class level" do
      # `fields:` is not a NoSuchInput field in this Ash version; `.exception/1`
      # requires `input:` (+ `inputs:` for did_you_mean) or it crashes itself.
      error = Ash.Error.Invalid.NoSuchInput.exception(input: "query", inputs: ["query"])

      assert %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{
                 "code" => -32_602,
                 "message" => message,
                 "data" => [
                   %{
                     "@type" => @error_info_type,
                     "domain" => @a2a_domain,
                     "reason" => "INVALID_PARAMS"
                   }
                 ]
               }
             } = AshA2A.ToA2AError.to_a2a_error(error, 7)

      assert is_binary(message) and message != ""

      # Class-level dispatch: the same error wrapped in its Splode error class
      # maps through the same totality guarantee.
      class = Ash.Error.to_error_class([error])

      assert %{"jsonrpc" => "2.0", "id" => 7, "error" => %{"code" => -32_602}} =
               AshA2A.ToA2AError.to_a2a_error(class, 7)
    end

    # KILL -- to_a2a_error/2 must be total over every Ash.Error struct module
    # found by globbing: always the full JSON-RPC envelope, integer code in
    # the JSON-RPC error range, binary message, no crash of any kind.
    test "kill: to_a2a_error/2 is total over every Ash.Error struct module found by globbing" do
      modules = ash_error_modules()

      # Court non-vacuity: the glob must actually find real Ash error modules,
      # otherwise this enumeration proves nothing.
      assert length(modules) >= 20,
             "expected the deps/ash error glob to find real error modules, got: #{inspect(modules)}"

      for mod <- modules do
        envelope = AshA2A.ToA2AError.to_a2a_error(struct(mod), "tot")

        assert %{
                 "jsonrpc" => "2.0",
                 "id" => "tot",
                 "error" => %{"code" => code, "message" => message}
               } = envelope,
               "#{inspect(mod)}: not a JSON-RPC error envelope: #{inspect(envelope)}"

        assert is_integer(code) and code in @jsonrpc_code_range,
               "#{inspect(mod)}: code #{inspect(code)} not in range #{inspect(@jsonrpc_code_range)}"

        assert is_binary(message) and message != "",
               "#{inspect(mod)}: message not a non-empty binary: #{inspect(message)}"
      end

      # Spot-pins on the registry assignments the landed implementations make
      # (lane V3 remap): NotFound -> -32001 stamped TASK_NOT_FOUND by the
      # registry, the Any fallback -> -32603 with an opaque ref and no leaked
      # detail.
      assert %{"error" => %{"code" => -32_001, "data" => [%{"reason" => "TASK_NOT_FOUND"}]}} =
               AshA2A.ToA2AError.to_a2a_error(%Ash.Error.Query.NotFound{}, 1)

      assert %{"error" => %{"code" => -32_603, "data" => %{"ref" => ref}}} =
               AshA2A.ToA2AError.to_a2a_error(%RuntimeError{message: "pg secret"}, 1)

      refute ref =~ "pg secret"
    end
  end

  # ---------------------------------------------------------------------------
  # Court 3: Executor over a real ETS resource with a real policy authorizer
  # ---------------------------------------------------------------------------

  describe "Executor court: real dispatch with real policy authorizer" do
    # POSITIVE CONTROL -- the happy path through the real policy authorizer
    # (which authorizes here) on a real ETS resource, exercising the
    # `:auth_identity` and `:argument_mapping` opts.
    test "happy path: an authorized dispatch returns {:ok, parts} with the mapped argument applied" do
      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorHappy do
        @moduledoc false

        use Ash.Resource,
          domain: Elixir.AshA2A.Test.ZachCourts.ExecutorHappyDomain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshA2A]

        attributes do
          uuid_primary_key(:id)
          attribute(:query, :string, public?: true)
        end

        actions do
          read :echo do
            argument(:query, :string, allow_nil?: true)
          end
        end

        policies do
          policy always() do
            authorize_if(always())
          end
        end

        a2a do
          skill(:echo, :echo, consequence: :observe)
        end
      end

      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorHappyDomain do
        @moduledoc false

        use Ash.Domain, extensions: [AshA2A]

        resources do
          resource(Elixir.AshA2A.Test.ZachCourts.ExecutorHappy)
        end
      end

      # The index skill (not a hand-built struct): the executor refuses a
      # caller-supplied skill that is not structurally identical to its
      # capability-index entry (:capability_mismatch).
      assert {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.ZachCourts.ExecutorHappy, :echo)

      message =
        AshA2A.Protocol.Message.new_user([
          AshA2A.Protocol.Part.Data.new(%{"q" => "hello"})
        ])

      assert {:ok, [%AshA2A.Protocol.Part.Data{data: %{results: []}}]} =
               AshA2A.Executor.execute(skill, message,
                 auth_identity: %{sub: "alice"},
                 argument_mapping: %{"q" => :query},
                 json_rpc_id: 42
               )
    end

    # KILL -- a real, unconditionally-deny-all `Ash.Policy.Authorizer` policy
    # must surface as the v1.0 registry's -32001 envelope (message "Forbidden",
    # POLICY_FORBIDDEN ErrorInfo) -- never a crash, never a bare
    # Ash.Forbidden leak.
    test "kill: a policy denial surfaces as the -32001 envelope with a POLICY_FORBIDDEN ErrorInfo" do
      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorDenied do
        @moduledoc false

        use Ash.Resource,
          domain: Elixir.AshA2A.Test.ZachCourts.ExecutorDeniedDomain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshA2A]

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          defaults([:read])
        end

        policies do
          policy always() do
            forbid_if(always())
          end
        end

        a2a do
          skill(:list, :read, consequence: :observe)
        end
      end

      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorDeniedDomain do
        @moduledoc false

        use Ash.Domain, extensions: [AshA2A]

        resources do
          resource(Elixir.AshA2A.Test.ZachCourts.ExecutorDenied)
        end
      end

      assert {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.ZachCourts.ExecutorDenied, :list)

      message = AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{})])

      assert {:error,
              %{
                "jsonrpc" => "2.0",
                "id" => nil,
                "error" => %{
                  "code" => -32_001,
                  "message" => "Forbidden",
                  "data" => [
                    %{
                      "@type" => @error_info_type,
                      "domain" => @a2a_domain,
                      "reason" => "POLICY_FORBIDDEN"
                    }
                  ]
                }
              }} =
               AshA2A.Executor.execute(skill, message, auth_identity: %{sub: "mallory"})
    end

    # KILL -- the Executor is a second ingress across the sole-DO fence: a
    # consequence-bearing (`:change`) dispatch with NO durable pending anchor
    # must be refused before ANY Ash call. This is the court that backs the
    # `:fenced_second_ingress` typed exceptions in
    # lib/ash_a2a/consequence_kernel/closure/exceptions.ex for the four
    # `AshA2A.Executor.run_*` -> `Ash.*` edges.
    test "kill: an unanchored consequence-bearing dispatch is refused before any Ash call" do
      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorUnanchored do
        @moduledoc false

        use Ash.Resource,
          domain: Elixir.AshA2A.Test.ZachCourts.ExecutorUnanchoredDomain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshA2A]

        attributes do
          uuid_primary_key(:id)
          attribute(:query, :string, public?: true)
        end

        actions do
          defaults([:read])

          create :stamp do
            accept([:query])
          end
        end

        policies do
          policy always() do
            authorize_if(always())
          end
        end

        a2a do
          skill(:stamp, :stamp, consequence: :change)
        end
      end

      defmodule Elixir.AshA2A.Test.ZachCourts.ExecutorUnanchoredDomain do
        @moduledoc false

        use Ash.Domain, extensions: [AshA2A]

        resources do
          resource(Elixir.AshA2A.Test.ZachCourts.ExecutorUnanchored)
        end
      end

      assert {:ok, skill} = AshA2A.Info.skill(AshA2A.Test.ZachCourts.ExecutorUnanchored, :stamp)

      message =
        AshA2A.Protocol.Message.new_user([
          AshA2A.Protocol.Part.Data.new(%{"query" => "fence-kill"})
        ])

      # No BrceAnchor.put/ReceiptOutbox.append anywhere in this process: the
      # anchor is nil, the skill is consequence-bearing, so the fence must
      # refuse pre-Ash. The failure surfaces as the fail-closed -32603
      # envelope (gate refusal maps are not caller-actionable Ash errors).
      assert {:error,
              %{
                "jsonrpc" => "2.0",
                "error" => %{"code" => -32_603}
              }} = AshA2A.Executor.execute(skill, message, auth_identity: %{sub: "alice"})

      # The kill: no record reached the real ETS data layer -- any path that
      # bypassed the fence would have created one.
      assert [] =
               AshA2A.Test.ZachCourts.ExecutorUnanchored
               |> Ash.Query.new()
               |> Ash.read!(authorize?: false)
    end
  end

  # Every file under deps/ash/lib/ash/error that defines a real struct module
  # (error structs and Splode error classes both qualify). Modules whose path
  # does not resolve to a loaded struct are dropped, so the enumeration stays
  # honest about what it feeds to_a2a_error/2.
  defp ash_error_modules do
    "deps/ash/lib/ash/error/**/*.ex"
    |> Path.wildcard()
    |> Enum.map(&error_path_to_module/1)
    |> Enum.filter(fn mod ->
      match?({:module, ^mod}, Code.ensure_loaded(mod)) and function_exported?(mod, :__struct__, 0)
    end)
    |> Enum.sort()
  end

  defp error_path_to_module(path) do
    path
    |> String.trim_trailing(".ex")
    |> String.trim_leading("deps/ash/lib/")
    |> Path.split()
    |> Enum.map(fn segment ->
      segment
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join("")
    end)
    |> Module.concat()
  end
end
