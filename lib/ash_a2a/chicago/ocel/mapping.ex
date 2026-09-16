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
      `nil` ids are absent and skipped; malformed references are rejected
      and reported (`resolve_objects/3`), never fabricated
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

  @reserved_object_types ["chicago_run", "court", "falsifier"]
  @max_identity_bytes 4096

  @type rejection ::
          {:malformed_shape
           | :malformed_type
           | :reserved_type
           | :malformed_qualifier
           | :malformed_id, String.t() | nil}

  @doc """
  Object types only the observer itself may create. A mapping that yields one
  would forge falsifier/court/run attribution, so it is rejected.
  """
  @spec reserved_object_types() :: [String.t()]
  def reserved_object_types, do: @reserved_object_types

  @doc "Resolves object refs, dropping absent and malformed ones. Never raises."
  @spec objects(t(), map(), map()) :: {[object_ref()], String.t() | nil}
  def objects(%__MODULE__{} = mapping, measurements, metadata) do
    {refs, _rejected, error} = resolve_objects(mapping, measurements, metadata)
    {refs, error}
  end

  @doc """
  Resolves object refs into `{accepted, rejected, error}` (RFC-SA2A-002 §138
  corrupted relationship identity). Never raises.

    * a `nil` id is *absent* (the SUT did not carry that identity): skipped,
      not rejected;
    * a malformed shape, a type that is not a non-empty colon-free string or
      atom, a reserved type (`reserved_object_types/0`), a malformed
      qualifier, or an id that is empty, not valid UTF-8, oversized, or not a
      string/integer/atom/identity struct is *rejected* with a reason.

  Types are colon-free, so the observer's object id `type <> ":" <> id` is
  injective: two distinct references can never collapse into one object.
  """
  @spec resolve_objects(t(), map(), map()) ::
          {[object_ref()], [rejection()], String.t() | nil}
  def resolve_objects(%__MODULE__{objects: nil}, _m, _meta), do: {[], [], nil}

  def resolve_objects(%__MODULE__{objects: fun}, measurements, metadata) do
    {accepted, rejected} =
      measurements
      |> fun.(metadata)
      |> List.wrap()
      |> Enum.reduce({[], []}, fn ref, {accepted, rejected} ->
        case validate_ref(ref) do
          {:ok, ref} -> {[ref | accepted], rejected}
          :absent -> {accepted, rejected}
          {:rejected, reason, type} -> {accepted, [{reason, type} | rejected]}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(rejected), nil}
  rescue
    exception -> {[], [], Exception.message(exception)}
  end

  @doc "Validates one `{type, id, qualifier}` reference. See `resolve_objects/3`."
  @spec validate_ref(term()) ::
          {:ok, object_ref()} | :absent | {:rejected, atom(), String.t() | nil}
  def validate_ref({type, id, qualifier}) do
    with {:ok, type} <- object_type(type),
         :ok <- unreserved(type),
         {:ok, qualifier} <- qualifier(qualifier, type) do
      case scalar_id(id) do
        :absent -> :absent
        :malformed -> {:rejected, :malformed_id, type}
        sid -> {:ok, {type, sid, qualifier}}
      end
    end
  end

  def validate_ref(_other), do: {:rejected, :malformed_shape, nil}

  defp object_type(type) when is_atom(type) and type not in [nil, true, false],
    do: type |> Atom.to_string() |> object_type()

  defp object_type(type) when is_binary(type) do
    if identity_text?(type) and not String.contains?(type, ":"),
      do: {:ok, type},
      else: {:rejected, :malformed_type, nil}
  end

  defp object_type(_type), do: {:rejected, :malformed_type, nil}

  defp unreserved(type) when type in @reserved_object_types,
    do: {:rejected, :reserved_type, type}

  defp unreserved(_type), do: :ok

  defp qualifier(q, type) when is_atom(q) and q not in [nil, true, false],
    do: q |> Atom.to_string() |> qualifier(type)

  defp qualifier(q, type) when is_binary(q) do
    if identity_text?(q), do: {:ok, q}, else: {:rejected, :malformed_qualifier, type}
  end

  defp qualifier(_q, type), do: {:rejected, :malformed_qualifier, type}

  defp identity_text?(text) do
    text != "" and byte_size(text) <= @max_identity_bytes and String.valid?(text) and
      not String.match?(text, ~r/[\x00-\x1F\x7F]/u)
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

  defp scalar_id(nil), do: :absent
  defp scalar_id(id) when is_boolean(id), do: :malformed

  defp scalar_id(id) when is_binary(id),
    do: if(identity_text?(id), do: id, else: :malformed)

  defp scalar_id(id) when is_integer(id), do: Integer.to_string(id)
  defp scalar_id(id) when is_atom(id), do: Atom.to_string(id)
  defp scalar_id(%{__struct__: _, value: value}), do: scalar_id(value)
  defp scalar_id(_), do: :malformed
end
