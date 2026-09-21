defmodule AshA2A.Gall.Message do
  @moduledoc """
  The validation entrypoint for GALL Semantic Work Fabric messages
  (PRD §43.5), namespace `https://semantic-a2a.dev/gall#`.

  Registered types:

    * `"gall:CodingCheckpoint"` -- `AshA2A.Gall.Checkpoint`
    * `"gall:WorkLease"` -- `AshA2A.Gall.WorkLease` (PRD §41 canonical shape)
    * `"gall:EvidenceReceipt"` -- `AshA2A.Gall.EvidenceReceipt`

  ## Transport is not authority (the central §43.5 requirement)

  > Receiving, parsing, validating, or transporting a message NEVER grants
  > the receiver authority to perform the consequence the message
  > describes.

  A `gall:WorkLease` in the inbox describes a lease; it is not the lease's
  authority. A `gall:EvidenceReceipt` transports a report; it does not
  mint the standing it reports. This is the same boundary
  `AshA2A.Authority.Grant` already draws for dispatch (authentication does
  not imply authority, RFC-SA2A-001 S29), applied to representation:
  `validate/2` returns `{:ok, typed_message}` for well-formed work and
  evidence messages and structurally refuses authority-bearing payloads:

    * a message whose `type` is not in the registered set
      → `{:refused, "REFUSED_UNREGISTERED_ACTUATION"}`
    * a message carrying an `execute`/`actuate`/`authorize` directive
      field (any casing/separators, at any depth -- the scan is recursive
      so a directive cannot be laundered inside a nested object)
      → `{:refused, "REFUSED_AUTHORITY"}`
    * a capability name outside the closed vocabulary
      (`AshA2A.Gall.Capability`)
      → `{:refused, "REFUSED_CAPABILITY"}`
    * capability escalation: a lease whose `requires` set is not a subset
      of the parent grant presented via `validate/2`'s `:parent` option
      (PRD §30: `Capabilities(child) ⊆ Capabilities(parent)`), including a
      child that requires a capability the parent explicitly forbids
      → `{:refused, "REFUSED_CAPABILITY"}`

  Malformed shapes (missing/mistyped fields, unknown standing, undecodable
  JSON) refuse `{:refused, "REFUSED_STRUCTURE"}`. Refusal is a lawful
  outcome, never an exception.

  ## The subset rule is evidence-gated

  `validate/1` alone never judges the child-subset rule: without a parent
  grant there is nothing to compare against, and inventing a default
  permissive parent would be the loophole the rule exists to close. The
  escalation check runs only when the caller presents the parent grant --
  a `%AshA2A.Gall.WorkLease{}`, a `requires`/`forbids` map, or a plain
  list of capability labels/atoms. Only `requires` sets are grants;
  `forbids` on the child cannot escalate, so only the child's `requires`
  are compared.
  """

  alias AshA2A.Gall.{Capability, Checkpoint, EvidenceReceipt, Fields, WorkLease}

  @namespace "https://semantic-a2a.dev/gall#"

  @types [Checkpoint.type(), WorkLease.type(), EvidenceReceipt.type()]

  # Any key normalizing to one of these names is an execution-authority
  # directive. Presence alone refuses -- the value is irrelevant, because
  # the sender asserting the field at all is the overreach.
  @directive_names ["execute", "actuate", "authorize"]

  @max_directive_depth 16

  @doc "The GALL message namespace IRI."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc "The registered message type literals."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "True when `type` is in the registered set."
  @spec registered_type?(term()) :: boolean()
  def registered_type?(type) when is_binary(type), do: type in @types
  def registered_type?(_other), do: false

  @doc """
  Validates a work/evidence message from a JSON binary or a decoded map.

  Returns `{:ok, typed_message}` -- a `%AshA2A.Gall.Checkpoint{}`,
  `%AshA2A.Gall.WorkLease{}` or `%AshA2A.Gall.EvidenceReceipt{}` -- or
  `{:refused, reason_string}` with one of `REFUSED_UNREGISTERED_ACTUATION`,
  `REFUSED_AUTHORITY`, `REFUSED_CAPABILITY`, `REFUSED_STRUCTURE`.
  """
  @spec validate(String.t() | map()) :: {:ok, struct()} | {:refused, String.t()}
  def validate(payload), do: validate(payload, [])

  @doc """
  Like `validate/1`, with the parent grant presented for the PRD §30
  child-subset check on a `gall:WorkLease`.

      iex> child = %{
      ...>   "type" => "gall:WorkLease",
      ...>   "checkpoint" => "urn:gall:checkpoint:xaas:001",
      ...>   "epoch" => "urn:xaas:epoch:001",
      ...>   "lease" => "urn:xaas:lease:001",
      ...>   "graphDigest" => "sha256:abc",
      ...>   "capabilities" => %{"requires" => ["Read"]}
      ...> }
      iex> {:ok, lease} = AshA2A.Gall.Message.validate(child)
      iex> {:refused, "REFUSED_CAPABILITY"} = AshA2A.Gall.Message.validate(child, parent: ["Write"])
      {:refused, "REFUSED_CAPABILITY"}
      iex> {:ok, %AshA2A.Gall.WorkLease{capabilities: %{requires: [:read]}}} =
      ...>   AshA2A.Gall.Message.validate(child, parent: ["Read", "Write"])
  """
  @spec validate(String.t() | map(), keyword()) :: {:ok, struct()} | {:refused, String.t()}
  def validate(payload, opts)

  def validate(payload, opts) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> validate(decoded, opts)
      _other -> {:refused, "REFUSED_STRUCTURE"}
    end
  end

  def validate(payload, opts) when is_map(payload) do
    with :ok <- refuse_authority_directives(payload, 0),
         {:ok, message} <- build_registered(payload) do
      enforce_child_subset({:ok, message}, opts)
    end
  end

  def validate(_payload, _opts), do: {:refused, "REFUSED_STRUCTURE"}

  # An unregistered type is not "some other message", it is an attempt to
  # actuate outside every registered, authority-bounded shape.
  defp build_registered(payload) do
    type = Fields.fetch(payload, :type, "type")

    cond do
      type == Checkpoint.type() -> Checkpoint.new(payload)
      type == WorkLease.type() -> WorkLease.new(payload)
      type == EvidenceReceipt.type() -> EvidenceReceipt.new(payload)
      true -> {:refused, "REFUSED_UNREGISTERED_ACTUATION"}
    end
  end

  # Authority directive scan: recursive so the directive cannot hide one
  # level down, name-normalized so `EXECUTE`/`execute_now`-style casing
  # does not slip past, depth-bounded so an un-scannable term refuses
  # rather than being scanned partially.
  defp refuse_authority_directives(_term, depth) when depth > @max_directive_depth,
    do: {:refused, "REFUSED_STRUCTURE"}

  # Structs are not Enumerable; their fields are scanned like any other
  # map's (the same fix `AshA2A.Semantic.Standing`'s evidence scan needed).
  defp refuse_authority_directives(%_{} = struct, depth),
    do: refuse_authority_directives(Map.from_struct(struct), depth)

  defp refuse_authority_directives(map, depth) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      if normalized_name(key) in @directive_names do
        {:halt, {:refused, "REFUSED_AUTHORITY"}}
      else
        case refuse_authority_directives(value, depth + 1) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end
      end
    end)
  end

  defp refuse_authority_directives(list, depth) when is_list(list) do
    Enum.reduce_while(list, :ok, fn value, :ok ->
      case refuse_authority_directives(value, depth + 1) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp refuse_authority_directives(_scalar, _depth), do: :ok

  defp normalized_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> normalized_name()

  defp normalized_name(name) when is_binary(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]/u, "")

  defp normalized_name(_other), do: nil

  # PRD §30: Capabilities(child) ⊆ Capabilities(parent). Runs only when a
  # parent grant was actually presented, and only over the child's
  # `requires` -- a child `forbids` set denies capabilities, it can never
  # grant them, so it cannot escalate. Refusals never reach here: the
  # `with` in `validate/2` already short-circuited them.
  defp enforce_child_subset({:ok, %WorkLease{} = lease}, opts) do
    case Keyword.get(opts, :parent) do
      nil ->
        {:ok, lease}

      parent ->
        with {:ok, grant} <- grant_sets(parent) do
          child_requires = MapSet.new(lease.capabilities.requires)

          if MapSet.subset?(child_requires, MapSet.new(grant.requires)) and
               MapSet.disjoint?(child_requires, MapSet.new(grant.forbids)) do
            {:ok, lease}
          else
            {:refused, "REFUSED_CAPABILITY"}
          end
        end
    end
  end

  defp enforce_child_subset({:ok, message}, _opts), do: {:ok, message}

  defp grant_sets(%WorkLease{} = parent),
    do: {:ok, %{requires: parent.capabilities.requires, forbids: parent.capabilities.forbids}}

  defp grant_sets(list) when is_list(list) do
    case Capability.decode_all(list) do
      {:ok, requires} -> {:ok, %{requires: requires, forbids: []}}
      :error -> {:refused, "REFUSED_CAPABILITY"}
    end
  end

  defp grant_sets(map) when is_map(map) do
    requires = Fields.fetch(map, :requires, "requires") || []
    forbids = Fields.fetch(map, :forbids, "forbids") || []

    with {:ok, requires} <- decode_grant_set(requires),
         {:ok, forbids} <- decode_grant_set(forbids) do
      {:ok, %{requires: requires, forbids: forbids}}
    end
  end

  defp grant_sets(_other), do: {:refused, "REFUSED_STRUCTURE"}

  defp decode_grant_set(list) when is_list(list) do
    case Capability.decode_all(list) do
      {:ok, atoms} -> {:ok, atoms}
      :error -> {:refused, "REFUSED_CAPABILITY"}
    end
  end

  defp decode_grant_set(_other), do: {:refused, "REFUSED_CAPABILITY"}
end
