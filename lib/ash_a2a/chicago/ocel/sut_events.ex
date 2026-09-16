defmodule AshA2A.Chicago.Ocel.SutEvents do
  @moduledoc """
  Static SUT telemetry vocabulary (RFC-SA2A-002 §17, §138 unknown event type).

  Reads every compiled `:ash_a2a` module's BEAM abstract code
  (`AshA2A.Chicago.AbstractCode.telemetry_events/1`) for literal
  `:telemetry.execute` / `:telemetry.span` event names. `unmapped/1` returns
  the discovered events no admitted mapping covers, which the runner hands to
  the observer as `:watch_events`: real SUT telemetry without an admitted
  interpretation is recorded as a typed `chicago.unmapped` event instead of
  being silently absent from the evidence.

  Call sites whose event name is computed at runtime cannot be resolved
  statically and are only counted (`dynamic_sites`); their events are covered
  exclusively by explicit mappings (e.g. `AshA2A.CommandBus` boundary events
  in `AshA2A.Chicago.Ocel.SutMappings`). Fixture events under
  `[:ash_a2a, :chicago, :fixtures | _]` are excluded.

  Discovery is cached per VM for the loaded application module list; a code
  reload that changes a module's telemetry without changing the module list
  keeps the cached vocabulary until the VM restarts.
  """

  alias AshA2A.Chicago.{AbstractCode, Context}
  alias AshA2A.Chicago.Ocel.Mapping

  @type discovery :: %{
          events: [[atom()]],
          dynamic_sites: non_neg_integer(),
          modules_scanned: non_neg_integer(),
          unreadable: [module()]
        }

  @doc "Discovered literal telemetry events of the `:ash_a2a` application."
  @spec discover() :: discovery()
  def discover do
    _ = Application.load(:ash_a2a)
    modules = :ash_a2a |> Application.spec(:modules) |> List.wrap()
    key = {__MODULE__, :erlang.phash2(modules)}

    case :persistent_term.get(key, nil) do
      nil ->
        discovery = scan(modules)
        :persistent_term.put(key, discovery)
        discovery

      discovery ->
        discovery
    end
  end

  @doc """
  Discovered SUT events not covered by `mappings`, excluding stimulus and
  fixture events.
  """
  @spec unmapped([Mapping.t()]) :: [[atom()]]
  def unmapped(mappings) do
    mapped = MapSet.new(mappings, & &1.event)

    discover().events
    |> Enum.reject(fn event ->
      MapSet.member?(mapped, event) or event in Context.stimulus_events() or
        match?([:ash_a2a, :chicago, :fixtures | _], event)
    end)
  end

  defp scan(modules) do
    Enum.reduce(
      modules,
      %{events: [], dynamic_sites: 0, modules_scanned: 0, unreadable: []},
      fn module, acc ->
        case AbstractCode.telemetry_events(module) do
          {:ok, %{events: events, dynamic_sites: dynamic}} ->
            %{
              acc
              | events: events ++ acc.events,
                dynamic_sites: acc.dynamic_sites + dynamic,
                modules_scanned: acc.modules_scanned + 1
            }

          {:error, _reason} ->
            %{acc | unreadable: [module | acc.unreadable]}
        end
      end
    )
    |> Map.update!(:events, &(&1 |> Enum.uniq() |> Enum.sort()))
  end
end
