defmodule AshA2A.Transport.GRPC.Downgrade do
  @moduledoc """
  pb-level v1.1 -> v1.0 downgrade for the gRPC binding.

  `strip(struct, version)` clears the v1.1-only fields (Task `generation` /
  `timeline`, Artifact `start_generation` / `end_generation` / `role`, event
  and timeline-entry `generation`) to their pb zero values when the negotiated
  version is explicitly below 1.1 (`AshA2A.Protocol.Downgrade.applies?/1`).
  A `StreamResponse` carrying only a `message_update` is `:drop`ped. Any other
  version (including `nil`, no header) returns the struct unchanged.
  """

  alias AshA2A.Protocol.Downgrade
  alias Lf.A2a.V1

  @spec strip(term(), String.t() | nil) :: term() | :drop
  def strip(struct, version) do
    if Downgrade.applies?(version), do: do_strip(struct), else: struct
  end

  defp do_strip(%V1.StreamResponse{payload: {:message_update, _}}), do: :drop

  defp do_strip(%V1.StreamResponse{payload: {kind, inner}} = resp),
    do: %{resp | payload: {kind, do_strip(inner)}}

  defp do_strip(%V1.SendMessageResponse{payload: {kind, inner}} = resp),
    do: %{resp | payload: {kind, do_strip(inner)}}

  defp do_strip(%V1.ListTasksResponse{tasks: tasks} = resp),
    do: %{resp | tasks: Enum.map(tasks, &do_strip/1)}

  defp do_strip(%V1.Task{} = task) do
    %{
      task
      | generation: 0,
        timeline: [],
        artifacts: Enum.map(task.artifacts, &do_strip/1)
    }
  end

  defp do_strip(%V1.Artifact{} = artifact),
    do: %{artifact | start_generation: 0, end_generation: 0, role: :ROLE_UNSPECIFIED}

  defp do_strip(%V1.TaskStatusUpdateEvent{} = event), do: %{event | generation: 0}

  defp do_strip(%V1.TaskArtifactUpdateEvent{} = event),
    do: %{event | generation: 0, artifact: do_strip(event.artifact)}

  defp do_strip(%V1.TimelineEntry{} = entry), do: %{entry | generation: 0}

  defp do_strip(other), do: other
end
