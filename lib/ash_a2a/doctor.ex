# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Doctor do
  @moduledoc """
  Diagnoses how an application is wired for A2A, without starting anything.

  `diagnose/1` inspects the domains and resources you hand it and returns a
  list of findings. Each finding is a map:

      %{severity: :error | :warn | :info, code: atom(), message: String.t(), fix: String.t()}

  It checks:

    * domains carrying the `AshA2A.Domain` extension and their agent, transport
      and security configuration (read through `AshA2A.Domain.Info`);
    * resources and domains with a2a skills (read through `AshA2A.Info`);
    * consequence-bearing skills whose authority gate is `:open`, or that can
      never be admitted because no authority broker is configured;
    * domains that mount agents but declare no security scheme, or an
      application that disables `:require_authenticated_caller`;
    * optional dependencies that are present or absent;
    * a few `:ash_a2a` application-config keys that are unset;
    * an agent card whose advertised endpoint is not served by any mount.

  The core is pure apart from reading application env and `Code.ensure_loaded?/1`;
  both can be injected for tests through the `:env` and `:loaded?` options.
  This is a read-only diagnosis: it does not prove a deployment is secure.

  ## Options

    * `:domains` -- domain modules to inspect (default: none)
    * `:resources` -- extra resource modules to inspect (default: the resources
      of every given domain)
    * `:env` -- `fun.(key) -> value | nil` replacing
      `Application.get_env(:ash_a2a, key)`
    * `:loaded?` -- `fun.(module) -> boolean` replacing `Code.ensure_loaded?/1`
  """

  @type severity :: :error | :warn | :info
  @type finding :: %{
          severity: severity(),
          code: atom(),
          message: String.t(),
          fix: String.t()
        }

  @optional_deps [
    {:oban, Oban, "durable delivery through AshA2A.Delivery.Oban"},
    {:ash_oban, AshOban, "AshOban triggers"},
    {:ash_state_machine, AshStateMachine, "AshA2A.TaskLifecycle"},
    {:postgrex, Postgrex, "a Postgres data layer"},
    {:flame, FLAME, "AshA2A.Execution.FLAME"},
    {:durable_server, DurableServer, "AshA2A.Durability.DurableServer"},
    {:req_llm, ReqLLM, "semantic compilation and planning"}
  ]

  # Keys with no safe default that a deployment normally sets.
  @config_keys [
    {:receipt_binding_key, :warn,
     "receipt binding is refused (:receipt_binding_key_unavailable) until it is set",
     "Set `config :ash_a2a, receipt_binding_key: <32+ random bytes>`, identical on every node."},
    {:standing_ledger_key, :info,
     "the standing ledger key is generated per node at boot, so standing chains do not cross nodes or restarts",
     "Set `config :ash_a2a, standing_ledger_key: <exactly 32 bytes>` on every node."}
  ]

  @doc "Runs every check and returns findings, errors first."
  @spec diagnose(keyword()) :: [finding()]
  def diagnose(opts \\ []) do
    ctx = %{
      env: Keyword.get(opts, :env, &Application.get_env(:ash_a2a, &1)),
      loaded?: Keyword.get(opts, :loaded?, &Code.ensure_loaded?/1)
    }

    domains = Keyword.get(opts, :domains, [])

    resources =
      (Enum.flat_map(domains, &domain_resources/1) ++ Keyword.get(opts, :resources, []))
      |> Enum.uniq()

    a2a_domains = Enum.filter(domains, &a2a_domain?/1)
    subjects = Enum.uniq(Enum.filter(resources ++ domains, &AshA2A.Info.capability_index?/1))

    (domain_findings(a2a_domains, ctx) ++
       skill_findings(subjects, ctx) ++
       auth_findings(a2a_domains, ctx) ++
       dep_findings(ctx) ++
       config_findings(ctx) ++
       card_findings(a2a_domains))
    |> Enum.sort_by(&severity_rank(&1.severity))
  end

  @doc "Whether any finding is an error (or a warning when `strict?`)."
  @spec failing?([finding()], boolean()) :: boolean()
  def failing?(findings, strict? \\ false) do
    Enum.any?(findings, fn %{severity: s} -> s == :error or (strict? and s == :warn) end)
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warn), do: 1
  defp severity_rank(:info), do: 2

  defp finding(severity, code, message, fix),
    do: %{severity: severity, code: code, message: message, fix: fix}

  defp domain_resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  # `card_identity/1` is nil until the extension's transformer has run.
  defp a2a_domain?(domain), do: not is_nil(AshA2A.Domain.Info.card_identity(domain))

  defp domain_findings([], _ctx) do
    [
      finding(
        :info,
        :no_a2a_domains,
        "No domain with the AshA2A.Domain extension was found.",
        "Add `extensions: [AshA2A.Domain]` to a domain, or pass --domain."
      )
    ]
  end

  defp domain_findings(domains, _ctx) do
    Enum.flat_map(domains, fn domain ->
      name = inspect(domain)
      mounts = AshA2A.Domain.Info.mounts(domain)

      [
        finding(
          :info,
          :domain_summary,
          "#{name}: agent #{inspect(AshA2A.Domain.Info.agent_name(domain))}, " <>
            "default mount #{AshA2A.Domain.Info.default_mount(domain)}, " <>
            "#{length(mounts)} mount(s), streaming #{AshA2A.Domain.Info.streaming?(domain)}, " <>
            "push #{AshA2A.Domain.Info.push_notifications?(domain)}, " <>
            "#{length(AshA2A.Domain.Info.security_schemes(domain))} security scheme(s).",
          "None."
        )
      ] ++
        if(is_nil(AshA2A.Domain.Info.agent_name(domain)),
          do: [
            finding(
              :warn,
              :agent_name_missing,
              "#{name} declares no agent name; the card has no identity.",
              "Add `agent do name \"...\" end` to #{name}."
            )
          ],
          else: []
        ) ++
        if(
          is_nil(AshA2A.Domain.Info.base_url(domain)) and
            is_nil(AshA2A.Domain.Info.agent_url(domain)),
          do: [
            finding(
              :warn,
              :card_url_missing,
              "#{name} declares neither transport base_url nor agent url; the card cannot advertise an absolute endpoint.",
              "Set `transport do base_url \"https://...\" end` on #{name}."
            )
          ],
          else: []
        )
    end)
  end

  defp skill_findings([], _ctx) do
    [
      finding(
        :warn,
        :no_a2a_skills,
        "No resource or domain exposes a2a skills.",
        "Add `extensions: [AshA2A]` and an `a2a do ... end` block to a resource."
      )
    ]
  end

  defp skill_findings(subjects, ctx) do
    broker? = not is_nil(ctx.env.(:authority_broker))

    Enum.flat_map(subjects, fn subject ->
      skills = AshA2A.Info.capability_index(subject) || []
      gate = AshA2A.Info.authority_gate(subject)

      consequential =
        Enum.filter(skills, fn skill -> consequence(subject, skill) in [:change, :external] end)

      summary =
        finding(
          :info,
          :skill_summary,
          "#{inspect(subject)}: #{length(skills)} skill(s), #{length(consequential)} consequence-bearing, authority gate #{inspect(gate)}.",
          "None."
        )

      gated =
        cond do
          consequential == [] ->
            []

          gate == :open ->
            [
              finding(
                :warn,
                :consequential_skill_no_gate,
                "#{inspect(subject)} has consequence-bearing skills (#{ids(consequential)}) with authority gate :open.",
                "Remove `gate :open` (default :two_port) in the `authority` section of #{inspect(subject)}."
              )
            ]

          not broker? ->
            [
              finding(
                :warn,
                :authority_broker_unset,
                "#{inspect(subject)} has consequence-bearing skills (#{ids(consequential)}) but :authority_broker is unset; every such dispatch is refused :authority_required.",
                "Set `config :ash_a2a, authority_broker: AshA2A.Authority.Broker.InMemory` (dev) or `Broker.Ekv` (durable)."
              )
            ]

          true ->
            []
        end

      [summary | gated]
    end)
  end

  defp consequence(subject, skill) do
    case skill.consequence do
      class when class in [:observe, :change, :external] ->
        class

      _ ->
        resource = skill.resource || subject

        type =
          try do
            case Ash.Resource.Info.action(resource, skill.action) do
              %{type: type} -> type
              _ -> nil
            end
          rescue
            _ -> nil
          end

        case AshA2A.ConsequenceClass.classify(type) do
          {:ok, class} -> class
        end
    end
  end

  defp ids(skills), do: skills |> Enum.map(&inspect(&1.id || &1.name)) |> Enum.join(", ")

  defp auth_findings(domains, ctx) do
    caller_open =
      if ctx.env.(:require_authenticated_caller) == false,
        do: [
          finding(
            :error,
            :authenticated_caller_disabled,
            "Application config :require_authenticated_caller is false; unauthenticated callers are admitted.",
            "Remove the setting or set `config :ash_a2a, require_authenticated_caller: true`."
          )
        ],
        else: []

    mounts_open =
      for domain <- domains,
          AshA2A.Domain.Info.mounts(domain) != [],
          AshA2A.Domain.Info.security_schemes(domain) == [] do
        finding(
          :warn,
          :mount_missing_auth,
          "#{inspect(domain)} mounts agents but declares no security scheme, so the card advertises no authentication.",
          "Declare a scheme in the `security` section of #{inspect(domain)} and put an auth plug in front of the mount."
        )
      end

    caller_open ++ mounts_open
  end

  defp dep_findings(ctx) do
    Enum.map(@optional_deps, fn {app, mod, used_for} ->
      if ctx.loaded?.(mod) do
        finding(:info, :optional_dep_present, "Optional dependency #{app} is present.", "None.")
      else
        finding(
          :info,
          :optional_dep_absent,
          "Optional dependency #{app} is absent; #{used_for} is unavailable.",
          "Add `{:#{app}, ...}` to your deps if you need #{used_for}."
        )
      end
    end)
  end

  defp config_findings(ctx) do
    for {key, severity, effect, fix} <- @config_keys, is_nil(ctx.env.(key)) do
      finding(severity, :"config_#{key}_unset", ":#{key} is unset: #{effect}.", fix)
    end
  end

  defp card_findings(domains) do
    for domain <- domains,
        agent_mounts =
          Enum.filter(AshA2A.Domain.Info.mounts(domain), &AshA2A.Domain.Mount.agent_mount?/1),
        agent_mounts != [],
        identity = AshA2A.Domain.Info.card_identity(domain),
        not is_nil(identity.endpoint),
        identity.mount not in Enum.map(agent_mounts, & &1.path) do
      finding(
        :warn,
        :card_mount_mismatch,
        "#{inspect(domain)}: the card endpoint #{identity.endpoint} uses default mount #{identity.mount}, but no declared mount serves that path (mounts: #{Enum.map_join(agent_mounts, ", ", & &1.path)}).",
        "Add a mount at #{identity.mount}, or set `default_mount` to one of the declared mount paths."
      )
    end
  end
end
