defmodule AshA2A.Authority.SecurityPreflight do
  @moduledoc """
  Boot-time security readiness gate (SEC-07).

  Several insecure settings are legal for local development but must never
  reach production silently:

    * `:authority_policy` = `:transport_verified_grants_capability` -- every
      transport-authenticated caller holds every capability (a documented
      privilege escalation, RFC-SA2A-001 S29).
    * no `:authority_broker`, or `AshA2A.Authority.Broker.InMemory` -- grants
      are either unprovable or lost on restart.
    * `:receipt_store` = `AshA2A.ReceiptStore.Memory` (the library default) --
      receipts and replay state do not survive a restart.
    * an EKV-backed receipt store or broker whose `:data_dir` is under
      `System.tmp_dir!/0` or a system-wide volatile root (`/tmp`,
      `/private/tmp`, `/dev/shm`) -- "durable" state on a volatile path.

  ## Strict mode

  `strict?/0` is `config :ash_a2a, :strict_security, bool` when set, and
  otherwise `AshA2A.SecurityProfile.strict?/0` (RFC-SA2A-007: the build's
  profile, `:strict` by default, so a `:prod` build is strict).
  In strict mode `check!/0` raises `AshA2A.Authority.SecurityPreflight.Error`
  listing every violation, and `AshA2A.Authority.Grant` refuses the legacy
  policy at request time with `:legacy_authority_policy_refused` even if
  `check!/0` was never called (defence in depth).

  The legacy policy may still be run in strict mode only with the explicit
  acknowledgement
  `config :ash_a2a, :allow_legacy_authority_policy, :i_accept_privilege_escalation`.

  `check/0` never raises and returns `:ok | {:error, [violation]}`, so hosts
  can surface the same findings in a health endpoint.
  """

  @legacy_ack :i_accept_privilege_escalation

  # `System.tmp_dir!/0` honours $TMPDIR (on macOS a per-user
  # /var/folders/.../T), so it alone misses the system-wide volatile roots:
  # a `:data_dir` of "/tmp/ekv" must be refused too.
  @volatile_roots ["/tmp", "/private/tmp", "/dev/shm"]

  defmodule Error do
    @moduledoc "Raised by `AshA2A.Authority.SecurityPreflight.check!/0` in strict mode."
    defexception [:violations, :message]

    @impl true
    def exception(violations) do
      detail = Enum.map_join(violations, "\n", &"  * #{&1.code}: #{&1.detail}")

      %__MODULE__{
        violations: violations,
        message: "ash_a2a security preflight refused to boot:\n" <> detail
      }
    end
  end

  @type violation :: %{code: atom(), detail: String.t()}

  @doc "Whether strict security enforcement is active (see moduledoc)."
  @spec strict?() :: boolean()
  def strict? do
    case Application.get_env(:ash_a2a, :strict_security) do
      value when is_boolean(value) -> value
      _ -> AshA2A.SecurityProfile.strict?()
    end
  end

  @doc """
  Whether the legacy `:transport_verified_grants_capability` policy is
  admissible right now: always outside strict mode; in strict mode only with
  the explicit `:allow_legacy_authority_policy` acknowledgement.
  """
  @spec legacy_policy_allowed?() :: boolean()
  def legacy_policy_allowed? do
    not strict?() or
      Application.get_env(:ash_a2a, :allow_legacy_authority_policy) == @legacy_ack
  end

  @doc """
  Runs `check/0` and raises `Error` on any violation when `strict?/0` (or
  `force: true`). Returns `:ok` otherwise. Intended to be called from
  `AshA2A.Application.start/2` before any child starts.
  """
  @spec check!(keyword()) :: :ok
  def check!(opts \\ []) do
    if Keyword.get(opts, :force, false) or strict?() do
      case check() do
        :ok -> :ok
        {:error, violations} -> raise Error, violations
      end
    else
      :ok
    end
  end

  @doc "Evaluates every readiness rule against the current application env."
  @spec check() :: :ok | {:error, [violation()]}
  def check do
    violations =
      [
        legacy_policy_violation(),
        broker_violation(),
        receipt_store_violation(),
        tmp_dir_violation(
          :receipt_store_ekv_data_dir_in_tmp,
          receipt_store_ekv?(),
          Application.get_env(:ash_a2a, :receipt_store_ekv_opts, []),
          "ash_a2a_receipt_store_ekv"
        ),
        tmp_dir_violation(
          :authority_broker_ekv_data_dir_in_tmp,
          broker_ekv?(),
          broker_ekv_opts(),
          "ash_a2a_authority_broker_ekv"
        )
      ]
      |> Enum.reject(&is_nil/1)

    if violations == [], do: :ok, else: {:error, violations}
  end

  @doc false
  # S42 refusal totality.
  def __sa2a_refusal_codes__ do
    %{
      legacy_authority_policy_refused: :refused_authority,
      legacy_authority_policy_unacknowledged: :refused_authority,
      authority_broker_missing: :refused_authority,
      authority_broker_non_durable: :refused_authority,
      receipt_store_non_durable: :refused_receipt,
      receipt_store_ekv_data_dir_in_tmp: :refused_receipt,
      authority_broker_ekv_data_dir_in_tmp: :refused_authority
    }
  end

  defp legacy_policy_violation do
    if Application.get_env(:ash_a2a, :authority_policy) == :transport_verified_grants_capability and
         Application.get_env(:ash_a2a, :allow_legacy_authority_policy) != @legacy_ack do
      %{
        code: :legacy_authority_policy_unacknowledged,
        detail:
          ":authority_policy is :transport_verified_grants_capability (every authenticated " <>
            "caller holds every capability). Use :broker, or set `config :ash_a2a, " <>
            ":allow_legacy_authority_policy, #{inspect(@legacy_ack)}`."
      }
    end
  end

  defp broker_violation do
    case broker_module() do
      nil ->
        %{
          code: :authority_broker_missing,
          detail:
            "no :authority_broker configured; no capability grant can be proven. " <>
              "Configure AshA2A.Authority.Broker.Ekv or a durable custom broker."
        }

      AshA2A.Authority.Broker.InMemory ->
        %{
          code: :authority_broker_non_durable,
          detail:
            ":authority_broker is AshA2A.Authority.Broker.InMemory; grants and " <>
              "revocations are lost on restart."
        }

      _ ->
        nil
    end
  end

  defp receipt_store_violation do
    if Application.get_env(:ash_a2a, :receipt_store, AshA2A.ReceiptStore.Memory) ==
         AshA2A.ReceiptStore.Memory do
      %{
        code: :receipt_store_non_durable,
        detail:
          ":receipt_store is AshA2A.ReceiptStore.Memory (the default); receipts and replay " <>
            "state are lost on restart. Configure AshA2A.ReceiptStore.Ekv or a durable store."
      }
    end
  end

  # Mirrors AshA2A.Application's own defaults: an EKV instance with no
  # `:data_dir` lands under System.tmp_dir!/0.
  defp tmp_dir_violation(_code, false, _opts, _default_leaf), do: nil

  defp tmp_dir_violation(code, true, opts, default_leaf) do
    data_dir =
      Keyword.get(opts || [], :data_dir) || Path.join(System.tmp_dir!(), default_leaf)

    if under_tmp?(data_dir) do
      %{
        code: code,
        detail:
          "EKV :data_dir #{inspect(data_dir)} is under a volatile tmp directory " <>
            "(#{inspect([System.tmp_dir!() | @volatile_roots])}); set a persistent :data_dir."
      }
    end
  end

  defp under_tmp?(path) do
    expanded = path |> Path.expand() |> resolve()

    [System.tmp_dir!() | @volatile_roots]
    |> Enum.map(&(&1 |> Path.expand() |> resolve()))
    |> Enum.any?(fn root ->
      expanded == root or String.starts_with?(expanded, String.trim_trailing(root, "/") <> "/")
    end)
  end

  # macOS tmp dirs live under /var -> /private/var; compare real paths.
  defp resolve(path) do
    path
    |> Path.split()
    |> Enum.reduce("", fn segment, acc ->
      candidate = if acc == "", do: segment, else: Path.join(acc, segment)

      case File.read_link(candidate) do
        {:ok, target} -> Path.expand(target, Path.dirname(candidate))
        _ -> candidate
      end
    end)
  end

  defp receipt_store_ekv? do
    Application.get_env(:ash_a2a, :receipt_store) == AshA2A.ReceiptStore.Ekv
  end

  defp broker_ekv?, do: broker_module() == AshA2A.Authority.Broker.Ekv

  defp broker_ekv_opts do
    case Application.get_env(:ash_a2a, :authority_broker) do
      {_module, opts} when is_list(opts) -> opts
      _ -> []
    end
  end

  defp broker_module do
    case Application.get_env(:ash_a2a, :authority_broker) do
      {module, _opts} when is_atom(module) -> module
      module when is_atom(module) -> module
      _ -> nil
    end
  end
end
