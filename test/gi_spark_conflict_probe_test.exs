# Probe (fixed forward by lane F1 from another lane's in-progress file, then
# re-pinned by lane G-I): a Spark section that declares a same-named schema
# option AND entity (`mount`) makes Spark generate `mount/1` from both the
# Options module and the entity builder module, so EVERY use inside the
# section fails with "call is ambiguous". This file pins that reality, plus
# the second reality lane G-I's court depends on: a Spark entity with
# positional args cannot also accept the keyword spelling -- the keyword list
# is consumed by the trailing positional arg (pinned by
# test/gi_probe2_test.exs). So the de-conflicted section is option-renamed +
# keyword-only entity, exactly the shape AshA2A.Domain ships.
defmodule Gi.Probe do
  defmodule Mount do
    defstruct [:agent, :path, :__spark_metadata__]
  end

  defmodule Ext do
    use Spark.Dsl.Extension,
      sections: [
        # CONFLICTING section: schema option `mount` + entity `mount` -> the
        # generated `mount/1` import is ambiguous.
        %Spark.Dsl.Section{
          name: :transport,
          schema: [mount: [type: :string, default: "/a2a"]],
          entities: [
            %Spark.Dsl.Entity{
              name: :mount,
              args: [],
              target: Gi.Probe.Mount,
              schema: [
                agent: [type: :atom, required: true],
                path: [type: :string, required: true]
              ]
            }
          ]
        },
        # DE-CONFLICTED control section: the option is renamed so the entity
        # import is unambiguous, and the entity is keyword-only (`args: []`).
        %Spark.Dsl.Section{
          name: :transport_ok,
          schema: [default_mount: [type: :string, default: "/a2a"]],
          entities: [
            %Spark.Dsl.Entity{
              name: :mount,
              args: [],
              target: Gi.Probe.Mount,
              schema: [
                agent: [type: :atom, required: true],
                path: [type: :string, required: true]
              ]
            }
          ]
        }
      ]
  end

  use Spark.Dsl, default_extensions: [extensions: [Gi.Probe.Ext]]
end

defmodule GiSparkConflictProbeTest do
  use ExUnit.Case, async: false

  test "a same-named section option + entity is an ambiguous call and fails to compile" do
    source = """
    defmodule Gi.Probe.Conflicting do
      use Gi.Probe

      transport do
        mount "/x"
      end
    end
    """

    assert_raise CompileError, ~r/cannot compile module/, fn ->
      Code.compile_string(source)
    end
  end

  test "the de-conflicted section parses the keyword-only mount entity" do
    source = """
    defmodule Gi.Probe.Control do
      use Gi.Probe

      transport_ok do
        mount agent: Foo, path: "/y"
      end
    end
    """

    Code.compile_string(source)
    mounts = Spark.Dsl.Extension.get_entities(Gi.Probe.Control, [:transport_ok])

    assert [%Gi.Probe.Mount{agent: Foo, path: "/y"}] = mounts
  end
end
