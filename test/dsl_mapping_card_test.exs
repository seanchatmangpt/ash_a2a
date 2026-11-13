# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.DslMappingCardFixtures.MappedResource do
  @moduledoc false
  use Ash.Resource,
    domain: AshA2A.DslMappingCardFixtures.MappedDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])

    action :shout, :string do
      argument(:query, :string, allow_nil?: false)
      run(fn input, _context -> {:ok, String.upcase(input.arguments.query)} end)
    end
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  a2a do
    skill(:shout, :shout,
      consequence: :observe,
      argument_mapping: %{"q" => :query},
      get?: true,
      lease_required?: true
    )

    skill(:plain_read, :read, get?: false, lease_required?: false)
  end
end

defmodule AshA2A.DslMappingCardFixtures.MappedDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslMappingCardFixtures.MappedResource)
  end
end

defmodule AshA2A.DslMappingCardFixtures.Agent do
  @moduledoc false
  use AshA2A.Agent,
    resource_or_domain: AshA2A.DslMappingCardFixtures.MappedResource,
    name: "lane11_agent",
    public_skills: [:plain_read]
end

defmodule AshA2A.DslMappingCardFixtures.CardDomain do
  @moduledoc false
  use Ash.Domain, extensions: [AshA2A, AshA2A.Domain], validate_config_inclusion?: false

  resources do
    resource(AshA2A.DslMappingCardFixtures.MappedResource)
  end

  agent do
    name "lane11-card"
    description "Lane 11 card description"
    version "9.8.7"
    provider "Lane Eleven Org"
    documentation_url "https://docs.example.com/lane11"
    icon_url "https://icons.example.com/lane11.png"
  end

  security do
    security_scheme :token, :bearer
    security_scheme :key, :api_key
    security_scheme :open, :none
    requirements ["token"]
  end

  transport do
    base_url "https://lane11.example.com"
    streaming false
    push_notifications true
  end
end

defmodule AshA2A.DslMappingCardTest do
  use ExUnit.Case, async: true

  import Spark.Test

  alias AshA2A.DslMappingCardFixtures.CardDomain
  alias AshA2A.DslMappingCardFixtures.MappedResource

  defp compile(quoted), do: Code.compile_quoted(quoted)

  # Spark converts verifier errors to stderr warnings; Spark.Test collects the
  # real %Spark.Error.DslError{} values the verifiers returned.
  defp first_error(quoted) do
    errors =
      dsl_errors do
        compile(quoted)
      end
      |> Enum.flat_map(fn {_module, errors} -> errors end)

    assert errors != [], "expected a verifier error but none was collected"
    hd(errors)
  end

  defp warning_messages(quoted) do
    dsl_warnings do
      compile(quoted)
    end
    |> Enum.flat_map(fn {_module, warnings} -> Enum.map(warnings, &elem(&1, 0)) end)
    |> Enum.join("\n")
  end

  # Resource fixture builder: `extra` is spliced into the resource body.
  defp resource_quoted(name, actions, extra) do
    mod = Module.concat(AshA2A.DslLane11Gen, name)

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
          unquote(actions)
        end

        unquote(extra)
      end
    end
  end

  defp domain_quoted(name, body) do
    mod = Module.concat(AshA2A.DslLane11Gen, name)

    quote do
      defmodule unquote(mod) do
        use Ash.Domain, extensions: [AshA2A.Domain], validate_config_inclusion?: false
        unquote(body)
      end
    end
  end

  describe "compiler projection (argument_mapping / get? / lease_required?)" do
    test "override fields are carried into the compiled skill and explicit false is kept" do
      {:ok, shout} = AshA2A.Info.skill(MappedResource, :shout)
      assert shout.argument_mapping == %{"q" => :query}
      assert shout.get? == true
      assert shout.lease_required? == true

      {:ok, plain} = AshA2A.Info.skill(MappedResource, :plain_read)
      assert plain.argument_mapping == %{}
      assert plain.get? == false
      assert plain.lease_required? == false
    end

    test "argument_mapping drives real end-to-end dispatch through the Executor" do
      {:ok, skill} = AshA2A.Info.skill(MappedResource, :shout)

      message =
        AshA2A.Protocol.Message.new_user([AshA2A.Protocol.Part.Data.new(%{"q" => "hello"})])

      assert {:ok, [%AshA2A.Protocol.Part.Data{data: data}]} =
               AshA2A.Executor.execute(skill, message, auth_identity: %{sub: "alice"})

      assert inspect(data) =~ "HELLO"
    end
  end

  describe "duplicate overrides" do
    test "two overrides of the same {resource, action} are refused at compile time" do
      quoted =
        resource_quoted(
          "DupOverride",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:first, :read)
              skill(:second, :read)
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "REFUSED_DUPLICATE_ACTION_OVERRIDE"
    end
  end

  describe "authority gate topology" do
    test "gate :open reports every default public create/update/destroy offender" do
      quoted =
        resource_quoted(
          "OpenGate",
          quote(do: defaults([:read, :destroy, create: [:label], update: [:label]])),
          quote do
            authority do
              gate :open
            end
          end
        )

      error = first_error(quoted)
      assert error.path == [:authority, :gate]
      assert error.message =~ ":create"
      assert error.message =~ ":update"
      assert error.message =~ ":destroy"
      assert error.message =~ "3 exposed action(s)"
    end

    test "gate :open with only reads (and an expose? false mutation) compiles" do
      quoted =
        resource_quoted(
          "OpenGateReadOnly",
          quote(do: defaults([:read, create: [:label]])),
          quote do
            authority do
              gate :open
            end

            a2a do
              skill(:hidden_create, :create, expose?: false)
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "declared but not enforced"
    end
  end

  describe "authority / hooks are never silently inert" do
    test "non-default lease_duration_ms and hooks emit declared-but-not-enforced warnings" do
      quoted =
        resource_quoted(
          "InertSections",
          quote(do: defaults([:read])),
          quote do
            authority do
              lease_duration_ms 5_000
            end

            hooks do
              pre_dispatch [:audit_hook]
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "lease_duration_ms 5000 is declared but not enforced"
      refute stderr =~ "hooks pre_dispatch"
    end

    test "defaults compile without any inert-section warning" do
      quoted = resource_quoted("CleanSections", quote(do: defaults([:read])), nil)
      stderr = warning_messages(quoted)
      refute stderr =~ "not enforced"
    end

    test "authority and hooks values persist and read back through AshA2A.Info" do
      mod = Module.concat(AshA2A.DslLane11Gen, "PersistedSections")

      compile(
        resource_quoted(
          "PersistedSections",
          quote(do: defaults([:read])),
          quote do
            authority do
              lease_duration_ms 7_000
            end

            hooks do
              post_dispatch [:after_hook]
            end
          end
        )
      )

      assert AshA2A.Info.lease_duration_ms(mod) == 7_000
      assert AshA2A.Info.hooks(mod) == %{pre_dispatch: [], post_dispatch: [:after_hook]}
      assert AshA2A.Info.authority_gate(mod) == :two_port
    end
  end

  describe "skill verification" do
    test "on_cancel naming a missing module is refused" do
      quoted =
        resource_quoted(
          "BadOnCancel",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: Elixir.AshA2A.DslLane11Gen.NoSuchHook)
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_on_cancel_target"
    end

    test "on_cancel MFA with a missing function arity is refused" do
      quoted =
        resource_quoted(
          "BadOnCancelMfa",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: {Kernel, :definitely_not_a_function, [1]})
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "does not export definitely_not_a_function/4"
    end

    test "an existing on_cancel MFA compiles" do
      quoted =
        resource_quoted(
          "GoodOnCancelMfa",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill(:r, :read, on_cancel: {Kernel, :apply, []})
            end
          end
        )

      assert [] ==
               dsl_errors(do: compile(quoted))
               |> Enum.flat_map(fn {_m, errors} -> errors end)
    end

    test "hddl fact args outside the operator parameters are refused" do
      quoted =
        resource_quoted(
          "BadHddlArgs",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill :r, :read do
                hddl_operator(
                  parameters: [:a],
                  preconditions: [{:holds, [:a, :zzz]}]
                )
              end
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_hddl_fact_args"
    end

    test "more than one hddl_operator per skill is refused" do
      quoted =
        resource_quoted(
          "TwoHddl",
          quote(do: defaults([:read])),
          quote do
            a2a do
              skill :r, :read do
                hddl_operator(parameters: [:a])
                hddl_operator(parameters: [:b])
              end
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "refused_hddl_multiple_operators"
    end

    test "default-projected action with a :term argument warns (no override needed)" do
      quoted =
        resource_quoted(
          "DefaultTerm",
          quote do
            defaults([:read])

            action :snap, :term do
              argument(:state, :term, allow_nil?: false)
              run(fn _i, _c -> {:ok, nil} end)
            end
          end,
          nil
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "default-projected action"
      assert stderr =~ "not JSON-Schema-serializable"
    end

    test "a domain-level skill naming a resource outside the domain is refused" do
      mod = Module.concat(AshA2A.DslLane11Gen, "ForeignResourceDomain")

      quoted =
        quote do
          defmodule unquote(mod) do
            use Ash.Domain, extensions: [AshA2A], validate_config_inclusion?: false

            resources do
              resource(AshA2A.DslMappingCardFixtures.MappedResource)
            end

            a2a do
              skill(:foreign, AshA2A.DslLane11Gen.NotInThisDomain, :read)
            end
          end
        end

      error = assert_raise Spark.Error.DslError, fn -> compile(quoted) end
      assert error.message =~ "not a compiled Ash resource"
    end
  end

  describe "Domain.Info over a real declared domain (PersistConfig)" do
    alias AshA2A.Domain.Info

    test "agent getters" do
      assert Info.agent_name(CardDomain) == "lane11-card"
      assert Info.agent_description(CardDomain) == "Lane 11 card description"
      assert Info.agent_version(CardDomain) == "9.8.7"
      assert Info.agent_provider(CardDomain) == "Lane Eleven Org"
      assert Info.agent_documentation_url(CardDomain) == "https://docs.example.com/lane11"
      assert Info.agent_icon_url(CardDomain) == "https://icons.example.com/lane11.png"
      assert Info.agent(CardDomain).name == "lane11-card"
    end

    test "security getters" do
      assert Enum.map(Info.security_schemes(CardDomain), &{&1.name, &1.kind}) ==
               [token: :bearer, key: :api_key, open: :none]

      assert {:ok, %{kind: :bearer}} = Info.security_scheme(CardDomain, :token)
      assert {:error, :scheme_not_found} = Info.security_scheme(CardDomain, :missing)
      assert Info.security_requirements(CardDomain) == ["token"]
    end

    test "transport getters and card_identity" do
      refute Info.streaming?(CardDomain)
      assert Info.push_notifications?(CardDomain)
      assert Info.base_url(CardDomain) == "https://lane11.example.com"

      assert %{
               name: "lane11-card",
               url: "https://lane11.example.com",
               version: "9.8.7",
               endpoint: "https://lane11.example.com/a2a",
               mount: "/a2a"
             } = Info.card_identity(CardDomain)
    end
  end

  describe "agent card takes identity/security/transport from the domain config" do
    test "name, version, provider, docs, icon, schemes, requirements and capability flags" do
      card = AshA2A.Info.agent_card(CardDomain)

      assert card.name == "lane11-card"
      assert card.description == "Lane 11 card description"
      assert card.version == "9.8.7"
      assert card.url == "https://lane11.example.com"
      assert card.provider == %{organization: "Lane Eleven Org"}
      assert card.documentation_url == "https://docs.example.com/lane11"
      assert card.icon_url == "https://icons.example.com/lane11.png"
      assert card.capabilities.streaming == false
      assert card.capabilities.push_notifications == true

      assert %{"token" => %AshA2A.Protocol.SecurityScheme.HTTPAuth{scheme: "bearer"}} =
               Map.take(card.security_schemes, ["token"])

      assert %AshA2A.Protocol.SecurityScheme.APIKey{} = card.security_schemes["key"]
      refute Map.has_key?(card.security_schemes, "open")
      assert card.security == [%{"token" => []}]
    end

    test "explicit opts win over domain config; absent config falls back to defaults" do
      card = AshA2A.Info.agent_card(CardDomain, name: "override", version: "0.0.1")
      assert card.name == "override"
      assert card.version == "0.0.1"

      fallback = AshA2A.Info.agent_card(MappedResource)
      assert fallback.name == "ash_a2a_agent"
      assert fallback.version == "0.1.0"
      assert fallback.url == "http://localhost:4000"
      assert fallback.security_schemes == %{}
    end
  end

  describe "VerifyConfig" do
    test "missing agent.name is refused" do
      quoted =
        domain_quoted(
          "NoName",
          quote do
            agent do
              description "x"
            end

            transport do
              base_url "https://x.example.com"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "agent.name"
    end

    test "invalid security scheme kind is refused" do
      quoted =
        domain_quoted(
          "BadKind",
          quote do
            agent do
              name "n"
            end

            security do
              security_scheme :t, :kerberos
            end

            transport do
              base_url "https://x.example.com"
            end
          end
        )

      assert_raise Spark.Error.DslError, fn -> compile(quoted) end
    end

    test "missing url (no base_url, no agent.url) is a warning, not an error" do
      quoted =
        domain_quoted(
          "NoUrl",
          quote do
            agent do
              name "n"
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ "transport.base_url is not set"
    end

    test "duplicate scheme names are refused" do
      quoted =
        domain_quoted(
          "DupScheme",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            security do
              security_scheme :t, :bearer
              security_scheme :t, :api_key
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "duplicate"
    end

    test "requirements naming an undeclared scheme are refused" do
      quoted =
        domain_quoted(
          "UndeclaredReq",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            security do
              security_scheme :t, :bearer
              requirements ["ghost"]
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "references no declared security_scheme"
    end

    test "a malformed base_url is refused" do
      quoted =
        domain_quoted(
          "BadUrl",
          quote do
            agent do
              name "n"
            end

            transport do
              base_url "not a url"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "not a valid absolute http(s) URL"
    end

    test "default_mount without a leading slash is refused" do
      quoted =
        domain_quoted(
          "BadDefaultMount",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              default_mount "a2a"
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "must start with"
    end
  end

  describe "VerifyMounts" do
    test "a mounted module that is not an AshA2A.Agent is refused" do
      quoted =
        domain_quoted(
          "NotAnAgent",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: Enum, path: "/e", binding: :jsonrpc
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "not an AshA2A.Agent"
    end

    test "a mount path without a leading slash is refused" do
      quoted =
        domain_quoted(
          "NoSlash",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "echo", binding: :jsonrpc
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "must start with"
    end

    test "overlapping mount path prefixes are refused" do
      quoted =
        domain_quoted(
          "Overlap",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/a", binding: :jsonrpc
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/a/b", binding: :rest
            end
          end
        )

      error = first_error(quoted)
      assert error.message =~ "is a prefix of"
    end

    test "a :grpc mount draws a warning and valid distinct mounts compile" do
      quoted =
        domain_quoted(
          "GrpcWarn",
          quote do
            agent do
              name "n"
              url "https://x.example.com"
            end

            transport do
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/ok", binding: :jsonrpc
              mount agent: AshA2A.DslMappingCardFixtures.Agent, path: "/grpc", binding: :grpc
            end
          end
        )

      stderr = warning_messages(quoted)
      assert stderr =~ ":grpc binding"
    end
  end
end
