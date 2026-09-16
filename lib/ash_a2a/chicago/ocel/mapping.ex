defmodule AshA2A.Chicago.Ocel.Mapping do
  @moduledoc """
  One admitted mapping from a real SUT `:telemetry` event to an OCEL 2.0
  event type plus its event-to-object relations (RFC-SA2A-002 §17).

  The observer does not prescribe the SUT's internal process structure; it
  interprets whatever real events the SUT emits through these mappings, which
  are fixed and digested (`digest/1`) before the run whose evidence they
  interpret.

    * `:event` -- the telemetry event name, e.g. `[:ash_a2a, :receipt, :committed]`
    * `:activity` -- the OCEL event type, e.g. `"brce.receipt.committed"`
    * `:objects` -- `(measurements, metadata) -> [{type, id, qualifier}]`;
      `nil` ids are skipped (never fabricated)
    * `:attributes` -- `(measurements, metadata) -> %{String.t() => scalar}`
    * `:source` -- the module that contributed the mapping (versioned by its
      BEAM md5 in the digest)
  """

  @enforce_keys [:event, :activity, :source]
  defstruct [:event, :activity, :source, objects: nil, attributes: nil]

  @type object_ref :: {String.t(), String.t() | nil, String.t()}
  @type scalar :: String.t() | integer() | float() | boolean()

  @type t :: %__MODULE__{
          event: [atom()],
          activity: String.t(),
          source: module(),
          objects: (map(), map() -> [object_ref()]) | nil,
          attributes: (map(), map() -> %{String.t() => scalar()}) | nil
        }

  @doc "Builds a mapping, validating the event name and activity."
  @spec new!(keyword()) :: t()
  def new!(fields) do
    mapping = struct!(__MODULE__, fields)

    unless is_list(mapping.event) and mapping.event != [] and Enum.all?(mapping.event, &is_atom/1),
      do: raise(ArgumentError, "OCEL mapping event must be a non-empty list of atoms")

    unless is_binary(mapping.activity) and mapping.activity != "",
      do: raise(ArgumentError, "OCEL mapping activity must be a non-empty string")

    mapping
  end

  @doc "Resolves object refs, dropping any with a nil/empty id. Never raises."
  @spec objects(t(), map(), map()) :: {[object_ref()], String.t() | nil}
  def objects(%__MODULE__{objects: nil}, _m, _meta), do: {[], nil}

  def objects(%__MODULE__{objects: fun}, measurements, metadata) do
    refs =
      fun.(measurements, metadata)
      |> Enum.flat_map(fn
        {type, id, qualifier} when is_binary(type) and is_binary(qualifier) ->
          case scalar_id(id) do
            nil -> []
            sid -> [{type, sid, qualifier}]
          end

        _ ->
          []
      end)

    {refs, nil}
  rescue
    exception -> {[], Exception.message(exception)}
  end

  @doc "Resolves attributes to JSON scalars. Never raises."
  @spec attributes(t(), map(), map()) :: {%{String.t() => scalar()}, String.t() | nil}
  def attributes(%__MODULE__{attributes: nil}, _m, _meta), do: {%{}, nil}

  def attributes(%__MODULE__{attributes: fun}, measurements, metadata) do
    attrs =
      fun.(measurements, metadata)
      |> Enum.flat_map(fn {k, v} ->
        case scalar(v) do
          nil -> []
          s -> [{to_string(k), s}]
        end
      end)
      |> Map.new()

    {attrs, nil}
  rescue
    exception -> {%{}, Exception.message(exception)}
  end

  @doc """
  Digest of a mapping set: sorted `(source, source BEAM md5, event, activity)`.
  Changing any contributing module changes the digest (§119 requalification).
  """
  @spec digest([t()]) :: String.t()
  def digest(mappings) do
    mappings
    |> Enum.map(fn m ->
      md5 =
        if Code.ensure_loaded?(m.source),
          do: Base.encode16(m.source.module_info(:md5), case: :lower),
          else: "unloaded"

      [inspect(m.source), md5, Enum.map_join(m.event, ".", &Atom.to_string/1), m.activity]
    end)
    |> Enum.sort()
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Coerces a telemetry value into an OCEL-safe scalar, or nil."
  @spec scalar(term()) :: scalar() | nil
  def scalar(nil), do: nil
  def scalar(v) when is_boolean(v), do: v
  def scalar(v) when is_integer(v) or is_float(v), do: v
  def scalar(v) when is_atom(v), do: Atom.to_string(v)

  def scalar(v) when is_binary(v),
    do: if(String.valid?(v), do: v, else: "base16:" <> Base.encode16(v, case: :lower))

  def scalar(%DateTime{} = v), do: DateTime.to_iso8601(v)
  def scalar(v) when is_pid(v) or is_reference(v) or is_function(v), do: nil
  def scalar(v), do: inspect(v, limit: 50, printable_limit: 512)

  defp scalar_id(nil), do: nil
  defp scalar_id(""), do: nil
  defp scalar_id(id) when is_binary(id), do: if(String.valid?(id), do: id, else: nil)
  defp scalar_id(id) when is_integer(id), do: Integer.to_string(id)
  defp scalar_id(id) when is_atom(id), do: Atom.to_string(id)
  defp scalar_id(%{__struct__: _} = s), do: s |> Map.get(:value) |> scalar_id()
  defp scalar_id(_), do: nil
end
