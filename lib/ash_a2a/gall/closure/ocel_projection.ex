defmodule AshA2A.Gall.Closure.OcelProjection do
  @moduledoc "Projects GALL finding/candidate/command/receipt identities into a compact OCEL 2 object/event envelope."

  def project(candidate, command, receipt) when is_map(candidate) and is_map(command) and is_map(receipt) do
    event_id = "gall:" <> to_string(field(receipt, :receipt_id) || field(command, :command_id))

    %{
      "ocel:events" => %{
        event_id => %{
          "ocel:type" => "bounded_intervention",
          "ocel:time" => field(receipt, :recorded_at),
          "ocel:typedOmap" => [
            %{"ocel:oid" => "candidate:" <> to_string(field(candidate, :candidate_digest)), "ocel:qualifier" => "candidate"},
            %{"ocel:oid" => "command:" <> to_string(field(command, :command_id)), "ocel:qualifier" => "command"},
            %{"ocel:oid" => "receipt:" <> to_string(field(receipt, :receipt_id)), "ocel:qualifier" => "receipt"}
          ]
        }
      },
      "ocel:objects" => %{
        "candidate:" <> to_string(field(candidate, :candidate_digest)) => %{"ocel:type" => "gall_candidate"},
        "command:" <> to_string(field(command, :command_id)) => %{"ocel:type" => "command"},
        "receipt:" <> to_string(field(receipt, :receipt_id)) => %{"ocel:type" => "receipt"}
      }
    }
  end

  def project(_, _, _), do: {:error, {:refused_gall, :ocel_projection, :invalid_subject}}

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
