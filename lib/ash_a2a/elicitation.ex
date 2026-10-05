# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Elicitation do
  @moduledoc """
  The formal elicitation contract: a typed, schema-constrained input request
  over the A2A `INPUT_REQUIRED` park/resume lifecycle.

  The repo already had the *mechanics* -- a task parks `:input_required`
  (`AshA2A.Protocol.Agent.Runtime.handle_reply/2`,
  `AshA2A.Transport.Runtime.apply_reply/2`) and a follow-up `message/send`
  carrying the same `task_id` resumes it (`AshA2A.Transport.Runtime.continue/6`,
  `AshA2A.Protocol.Agent.Runtime.continue_task/5`) -- but nothing made the
  requested input *formal*: no schema rode with the request, so nothing could
  refuse a wrong-shape response before dispatch resumed. This module formalizes
  the request per the specs:

    * MCP `elicitation/create` form mode
      (`~/ggen-marketplace/vendors/mcp-spec/docs/specification/draft/client/elicitation.mdx`):
      a `message` plus a `requestedSchema` -- a flat object of primitive
      properties (string/number/integer/boolean/enum, optional
      array-of-primitive) -- and the three-action response model. Complex
      nested structures are intentionally unsupported there, so this module's
      validator covers exactly that restricted subset and fails closed on
      anything outside it.
    * MCP multi-round-trip requests
      (`~/ggen-marketplace/vendors/mcp-spec/docs/specification/draft/basic/patterns/mrtr.mdx`):
      the request rides in a result the client must fulfill and name on the
      retried request -- here, the elicitation rides as an
      `AshA2A.Protocol.Part.Data` part on the `{:input_required, _}` reply, and
      correlation is by `task_id` plus an elicitation id in the follow-up's
      metadata.
    * A2A roadmap "Elicitation & Multi-Turn Workflows"
      (`~/ggen-marketplace/vendors/a2a/docs/roadmap.md`, #2149/#2143):
      structured human-in-the-loop interaction over the A2A task timeline --
      `INPUT_REQUIRED` is the A2A carrier state.

  ## The contract

    1. `request/3` mints an elicitation for a real Ash action or projected
       skill. The requested shape rides as an `AshA2A.Protocol.Part.Data` part
       (`to_parts/1`, `reply/1`) whose data map carries `requestedSchema` --
       the real Draft 2020-12 projection from `AshA2A.Schema.for_action/3` /
       `AshA2A.Schema.for_skill/2` -- and whose part metadata carries the
       elicitation id and task id the follow-up must name (`resume/2` step 1).
    2. `resume/2` validates a follow-up message against the pending
       elicitation BEFORE dispatch resumes: the follow-up's
       `AshA2A.Protocol.Part.Data` parts are merged and validated against the
       requested schema. Fail-closed: any violation is a typed JSON-RPC
       `-32602` `Invalid params` error (`AshA2A.Protocol.JSONRPC.Error`), and
       the caller replies `{:input_required, _}` with the error part so the
       task stays parked -- a malformed response must not consume the park.
    3. Expiry is configured per elicitation (`:expires_in`, milliseconds;
       default `nil` = never expires). When an expired elicitation is resumed,
       `resume/2` returns `{:error, {:elicitation_expired, id}}`, which the
       standard error classifier (`AshA2A.Transport.Runtime.apply_reply/2` /
       `AshA2A.Protocol.Agent.Runtime.handle_reply/2`) maps through the
       lifecycle to terminal `:failed`.

  ## Usage

  An agent composes the contract in `handle_message/2` -- recover the pending
  elicitation from the task's own history, resume or mint:

      def handle_message(message, context) do
        case AshA2A.Elicitation.from_history(context.history) do
          {:ok, pending} ->
            case AshA2A.Elicitation.resume(pending, message) do
              {:ok, data} ->
                msg = %{message | parts: [AshA2A.Protocol.Part.Data.new(data)]}
                AshA2A.Agent.__dispatch__(@ash_a2a_resource_or_domain, msg, context, @ash_a2a_dispatch_opts)

              {:error, %AshA2A.Protocol.JSONRPC.Error{} = err} ->
                # fail-closed: park with the typed error, never dispatch
                {:input_required,
                 [
                   AshA2A.Protocol.Part.Data.new(%{
                     "error" => AshA2A.Protocol.JSONRPC.Error.to_map(err),
                     "elicitationId" => pending.id
                   })
                 ]}

              {:error, {:elicitation_expired, _} = expired} ->
                {:error, expired}
            end

          :error ->
            case AshA2A.Elicitation.request(@ash_a2a_resource_or_domain, :the_action,
                   task_id: context.task_id
                 ) do
              {:ok, elicitation} -> AshA2A.Elicitation.reply(elicitation)
              {:error, _} = err -> {:error, err}
            end
        end
      end

  Zero state: the elicitation lives in the task's own history (the runtime
  appends the `{:input_required, _}` agent message there), so there is no
  second source of task truth for this module to drift from.
  """

  alias AshA2A.Protocol.JSONRPC.Error
  alias AshA2A.Protocol.{Message, Part}

  @enforce_keys [:id, :message, :requested_schema]
  defstruct [:id, :task_id, :mode, :message, :requested_schema, :created_at, :expires_at]

  @typedoc """
  One pending schema-constrained input request.

  `:expires_at` is `nil` (never expires) unless `request/3` got `:expires_in`.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t() | nil,
          mode: :form,
          message: String.t(),
          requested_schema: %{optional(String.t()) => term()},
          created_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc """
  Mints a schema-constrained elicitation for a real Ash action or projected skill.

  `resource_or_domain` is the `AshA2A`-extended resource or domain whose
  capability index names the action; `action_or_skill` is the skill id/name or
  the Ash action name. The requested schema is the real Draft 2020-12
  projection of the action's public arguments/accepted attributes
  (`AshA2A.Schema.for_skill/2` when a skill resolves, `AshA2A.Schema.for_action/3`
  otherwise), so the requested shape is never hand-written per call site.

  Options:

    * `:task_id` -- the parked task this elicitation belongs to (correlation
      data; also stamped on `to_parts/1`'s part metadata).
    * `:message` -- the human-readable message explaining the request
      (default "Additional input required").
    * `:expires_in` -- milliseconds until the elicitation expires. `nil`
      (default) = never expires.

  Returns `{:ok, elicitation}` or `{:error, {:unserializable_type, type}}`
  (an argument type `AshA2A.Schema` cannot represent -- fail-closed, never a
  silently loose schema).
  """
  @spec request(module(), atom() | String.t(), keyword()) ::
          {:ok, t()} | {:error, {:unserializable_type, term()}}
  def request(resource_or_domain, action_or_skill, opts \\ []) do
    with {:ok, schema} <- resolve_schema(resource_or_domain, action_or_skill) do
      now = DateTime.utc_now()

      expires_at =
        case Keyword.get(opts, :expires_in) do
          nil -> nil
          ms when is_integer(ms) and ms > 0 -> DateTime.add(now, ms, :millisecond)
        end

      {:ok,
       %__MODULE__{
         id: AshA2A.Protocol.ID.generate("eli"),
         task_id: Keyword.get(opts, :task_id),
         mode: :form,
         message: Keyword.get(opts, :message, "Additional input required"),
         requested_schema: schema,
         created_at: now,
         expires_at: expires_at
       }}
    end
  end

  # Skill first (so `argument_mapping` wire names project), then the raw Ash
  # action. Both schemas are the real `AshA2A.Schema` projection -- never a
  # hand-written shape.
  defp resolve_schema(resource_or_domain, name) do
    case AshA2A.Info.skill(resource_or_domain, name) do
      {:ok, skill} ->
        AshA2A.Schema.for_skill(skill, skill.resource)

      {:error, :skill_not_found} ->
        AshA2A.Schema.for_action(resource_or_domain, name)
    end
  end

  @doc """
  The elicitation as the parts that ride the `{:input_required, _}` reply.

  One `AshA2A.Protocol.Part.Data` part whose data map carries the wire shape:

      %{"elicitation" => %{
           "id" => "eli-...",
           "taskId" => "tsk-...",
           "mode" => "form",
           "message" => "Please provide ...",
           "requestedSchema" => %{"type" => "object", "properties" => %{}, "required" => []},
           "expiresAt" => "2026-...Z" | nil
         }}

  Part metadata carries the same ids (`:elicitation_id`, `:task_id`) so
  in-process consumers can correlate without re-walking the data map.
  """
  @spec to_parts(t()) :: [Part.Data.t()]
  def to_parts(%__MODULE__{} = elicitation) do
    [
      Part.Data.new(
        %{"elicitation" => wire_map(elicitation)},
        %{elicitation_id: elicitation.id, task_id: elicitation.task_id}
      )
    ]
  end

  @doc """
  The complete handler reply that parks the task awaiting the elicited input.

  `{:input_required, [part]}` -- the exact tuple `AshA2A.Transport.Runtime.apply_reply/2`
  and `AshA2A.Protocol.Agent.Runtime.handle_reply/2` map to the parked
  `:input_required` state, with the elicitation part as the status message.
  """
  @spec reply(t()) :: {:input_required, [Part.Data.t()]}
  def reply(%__MODULE__{} = elicitation), do: {:input_required, to_parts(elicitation)}

  defp wire_map(%__MODULE__{} = elicitation) do
    %{
      "id" => elicitation.id,
      "taskId" => elicitation.task_id,
      "mode" => "form",
      "message" => elicitation.message,
      "requestedSchema" => elicitation.requested_schema,
      "expiresAt" => serialize_time(elicitation.expires_at)
    }
  end

  defp serialize_time(nil), do: nil
  defp serialize_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc """
  Recovers the most recent pending elicitation from a task's history.

  Scans newest-first for an agent message whose `AshA2A.Protocol.Part.Data`
  part carries the `"elicitation"` data key (the shape `to_parts/1` mints) and
  rebuilds the struct from its wire map. `:error` when no turn ever parked an
  elicitation.
  """
  @spec from_history([Message.t()]) :: {:ok, t()} | :error
  def from_history(history) when is_list(history) do
    found =
      history
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :agent, parts: parts} ->
          Enum.find_value(parts, fn
            %Part.Data{data: %{"elicitation" => el}} -> rebuild(el)
            _ -> nil
          end)

        _user_message ->
          nil
      end)

    case found do
      %__MODULE__{} = elicitation -> {:ok, elicitation}
      _ -> :error
    end
  end

  def from_history(_), do: :error

  defp rebuild(wire) when is_map(wire) do
    %__MODULE__{
      id: wire["id"],
      task_id: wire["taskId"],
      mode: :form,
      message: wire["message"],
      requested_schema: wire["requestedSchema"],
      created_at: nil,
      expires_at: parse_time(wire["expiresAt"])
    }
  end

  defp rebuild(_), do: nil

  defp parse_time(nil), do: nil

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @doc """
  Whether `elicitation` has passed its `:expires_at` (comparing against `now`,
  default `DateTime.utc_now/0`). An elicitation minted without `:expires_in`
  never expires -- expiry is off by default.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :lt

  def expired?(%__MODULE__{} = elicitation), do: expired?(elicitation, DateTime.utc_now())

  @doc """
  Validates a follow-up message against a pending elicitation, BEFORE dispatch resumes.

  Correlation first, then expiry, then schema:

    1. the follow-up's metadata must name the pending elicitation
       (`elicitationId` on the wire, `:elicitation_id` in-process -- the same
       `AshA2A.MetadataKey` atom-or-string convention as `:skill`); an
       uncorrelated follow-up is refused even if its data would validate;
    2. the pending elicitation must not be expired -- expiry is
       `{:error, {:elicitation_expired, id}}`, which the standard error
       classifier maps to terminal `:failed` ("task transitions per the
       lifecycle");
    3. the follow-up's `AshA2A.Protocol.Part.Data` parts are merged and
       validated against the requested schema. Fail-closed: any violation is a
       typed `-32602` `AshA2A.Protocol.JSONRPC.Error` -- the caller replies
       `{:input_required, _}` with the error part and the task stays parked.

  Returns `{:ok, validated_data}` or `{:error, term()}`.
  """
  @spec resume(t(), Message.t()) ::
          {:ok, map()}
          | {:error, Error.t()}
          | {:error, {:elicitation_expired, String.t()}}
  def resume(%__MODULE__{} = pending, %Message{} = message) do
    cond do
      not matching?(pending, message) ->
        {:error,
         Error.invalid_params(%{
           "reason" => "elicitationId",
           "detail" => "follow-up does not name the pending elicitation #{pending.id}"
         })}

      expired?(pending) ->
        {:error, {:elicitation_expired, pending.id}}

      true ->
        validate_message(pending.requested_schema, message)
    end
  end

  # The follow-up must NAME the elicitation it answers. Task scoping rides in
  # the transport: `AshA2A.Transport.Runtime.continue/6` only ever resumes the
  # named task id, so the elicitation id is the second, in-task correlation
  # factor.
  defp matching?(pending, message) do
    metadata = message.metadata || %{}

    # Wire form is camelCase `elicitationId`; in-process callers may use the
    # atom `:elicitation_id` (or its snake_case string form). All three are
    # accepted; a missing or mismatching name is the same refusal.
    name =
      metadata["elicitationId"] ||
        AshA2A.MetadataKey.get(metadata, :elicitation_id)

    name == pending.id
  end

  defp validate_message(schema, message) do
    data = merge_data_parts(message)

    case validate(schema, data) do
      :ok -> {:ok, data}
      {:error, violations} -> {:error, Error.invalid_params(%{"violations" => violations})}
    end
  end

  defp merge_data_parts(%Message{parts: parts}) do
    Enum.reduce(parts, %{}, fn
      %Part.Data{data: data}, acc when is_map(data) -> Map.merge(acc, data)
      _part, acc -> acc
    end)
  end

  @doc """
  Validates `data` against the restricted JSON-Schema subset a requested
  schema is allowed to use -- flat object, primitive properties (the MCP
  form-mode subset `AshA2A.Schema` itself projects) -- fail-closed.

  Rules:

    * `data` must be a map;
    * unknown keys are violations (flat-subset schemas are closed-world);
    * every `"required"` name must be present;
    * each present property is checked against its projected constraints
      (`type`, `enum`, `minLength`/`maxLength`, `minimum`/`maximum`,
      `minItems`/`maxItems`, `oneOf`-`const`, `anyOf`);
    * `format` is advisory (as in MCP form mode: the client validates before
      sending; the server re-checks shape, not format).

  Returns `:ok` or `{:error, violations}` where each violation is
  `%{"property" => name, "error" => reason}` (`"property"` may be `nil` for
  whole-document violations).
  """
  @spec validate(%{optional(String.t()) => term()}, term()) ::
          :ok | {:error, [%{String.t() => String.t() | nil}]}
  def validate(schema, data)

  def validate(%{"type" => "object"} = schema, data) when is_map(data) do
    properties = schema["properties"] || %{}

    violations =
      unknown_key_violations(data, properties) ++
        required_violations(schema["required"] || [], data) ++
        property_violations(properties, data)

    case violations do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  def validate(%{"type" => "object"}, _data) do
    {:error, [%{"property" => nil, "error" => "expected an object"}]}
  end

  # A schema that is not a projected object schema (nothing `AshA2A.Schema`
  # emits looks like this) fails closed rather than validating against a shape
  # nobody declared.
  def validate(_schema, _data) do
    {:error, [%{"property" => nil, "error" => "unsupported schema shape"}]}
  end

  # -- object-level checks -----------------------------------------------------

  defp unknown_key_violations(data, properties) do
    for key <- Map.keys(data), not Map.has_key?(properties, key) do
      %{"property" => key, "error" => "unknown property"}
    end
  end

  defp required_violations(required, data) do
    for name <- required, not Map.has_key?(data, name) do
      %{"property" => name, "error" => "missing required property"}
    end
  end

  defp property_violations(properties, data) do
    Enum.flat_map(properties, fn {name, sub} ->
      case Map.fetch(data, name) do
        {:ok, value} -> check_property(name, value, sub)
        :error -> []
      end
    end)
  end

  # `anyOf`/`oneOf` branches own the whole check for that property (the
  # projected union/enum-with-titles shapes carry no sibling "type").
  defp check_property(name, value, %{"anyOf" => branches}), do: any_of(name, value, branches)

  defp check_property(name, value, %{"oneOf" => branches}), do: one_of(name, value, branches)

  defp check_property(name, value, sub) do
    case type_check(value, sub) do
      :ok -> constraint_violations(name, value, sub)
      {:error, reason} -> [%{"property" => name, "error" => reason}]
    end
  end

  defp any_of(name, value, branches) do
    if Enum.any?(branches, &match_branch?(value, &1)) do
      []
    else
      [%{"property" => name, "error" => "matched none of the anyOf branches"}]
    end
  end

  defp one_of(name, value, branches) do
    case Enum.count(branches, &match_branch?(value, &1)) do
      1 ->
        []

      0 ->
        [%{"property" => name, "error" => "matched none of the oneOf branches"}]

      _multiple ->
        [%{"property" => name, "error" => "matched more than one oneOf branch"}]
    end
  end

  defp match_branch?(value, %{"const" => const}), do: value == const
  defp match_branch?(value, %{"type" => _} = branch), do: type_check(value, branch) == :ok
  defp match_branch?(_value, _branch), do: false

  # -- type shape --------------------------------------------------------------

  defp type_check(value, %{"type" => "string"}),
    do: shape(is_binary(value), "string", value)

  defp type_check(value, %{"type" => "integer"}),
    do: shape(is_integer(value), "integer", value)

  defp type_check(value, %{"type" => "number"}),
    do: shape(is_integer(value) or is_float(value), "number", value)

  defp type_check(value, %{"type" => "boolean"}),
    do: shape(is_boolean(value), "boolean", value)

  defp type_check(value, %{"type" => "array"}),
    do: shape(is_list(value), "array", value)

  # No "type" key: check enum membership only (fail-closed: no declared type,
  # no invented type check).
  defp type_check(value, sub), do: enum_check(value, sub)

  defp shape(true, _expected, _value), do: :ok
  defp shape(false, expected, value), do: {:error, "expected #{expected}, got #{type_name(value)}"}

  # -- value constraints -------------------------------------------------------

  # Array items: each element checked against the projected items schema; the
  # count constraints checked once for the whole array.
  defp constraint_violations(name, value, %{"type" => "array"} = sub) when is_list(value) do
    items = sub["items"] || %{}

    case count_check(value, sub) do
      :ok ->
        Enum.flat_map(Enum.with_index(value), fn {item, i} ->
          case type_check(item, items) do
            :ok -> []
            {:error, reason} -> [%{"property" => name, "error" => "item #{i}: #{reason}"}]
          end
        end)

      {:error, violations} ->
        Enum.map(violations, &Map.put(&1, "property", name))
    end
  end

  defp constraint_violations(name, value, sub) do
    # Scalar sub-checks that cannot name their property (enum membership) get
    # the property name filled in here.
    scalar_constraints(name, value, sub)
    |> Enum.map(fn
      %{"property" => nil} = violation -> %{violation | "property" => name}
      violation -> violation
    end)
  end

  defp scalar_constraints(name, value, sub) do
    enum_check_result(value, sub) ++
      length_constraints(name, value, sub) ++
      bound_constraints(name, value, sub)
  end

  defp enum_check(value, sub) do
    case enum_check_result(value, sub) do
      [] -> :ok
      [violation | _] -> {:error, violation["error"]}
    end
  end

  defp enum_check_result(value, %{"enum" => enum}) do
    if value in enum,
      do: [],
      else: [%{"property" => nil, "error" => "value not in enum"}]
  end

  defp enum_check_result(_value, _sub), do: []

  defp length_constraints(name, value, %{"type" => "string"} = sub) when is_binary(value) do
    min = sub["minLength"]
    max = sub["maxLength"]

    cond do
      is_integer(min) and String.length(value) < min ->
        [%{"property" => name, "error" => "shorter than minLength #{min}"}]

      is_integer(max) and String.length(value) > max ->
        [%{"property" => name, "error" => "longer than maxLength #{max}"}]

      true ->
        []
    end
  end

  defp length_constraints(_name, _value, _sub), do: []

  defp bound_constraints(name, value, sub) do
    min = sub["minimum"]
    max = sub["maximum"]

    cond do
      not is_number(value) ->
        []

      is_number(min) and value < min ->
        [%{"property" => name, "error" => "below minimum #{min}"}]

      is_number(max) and value > max ->
        [%{"property" => name, "error" => "above maximum #{max}"}]

      true ->
        []
    end
  end

  defp count_check(value, sub) do
    min = sub["minItems"]
    max = sub["maxItems"]

    cond do
      is_integer(min) and length(value) < min ->
        {:error, [%{"property" => nil, "error" => "fewer than minItems #{min}"}]}

      is_integer(max) and length(value) > max ->
        {:error, [%{"property" => nil, "error" => "more than maxItems #{max}"}]}

      true ->
        :ok
    end
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_map(value), do: "object"
  defp type_name(nil), do: "null"
  defp type_name(_), do: "other"
end
