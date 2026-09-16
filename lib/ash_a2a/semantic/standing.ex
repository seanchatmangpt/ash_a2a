defmodule AshA2A.Semantic.Standing do
  @moduledoc """
  RFC-SA2A-001 S6/S41 standing lifecycle as a real, enforced transition
  function over `AshA2A.Semantic.Envelope`.

  Standing is not an atom a caller sets. It is a position in an ordered
  chain, and each step is only reachable by presenting the specific evidence
  that step is *about*. `transition/3` is the only way standing ever changes.

  ## The chain (S41)

      candidate
        -> received -> parsed -> identified -> structurally_valid
        -> semantically_valid -> closed -> falsifier_clean -> admitted
        -> plannable -> selected -> constructed -> authorized -> prepared
        -> executed -> receipted -> attested

  `:candidate` is the genesis standing, below `:received`. It exists because
  *even having been received is an observation requiring evidence*: an
  envelope built from raw bytes has been constructed, not yet witnessed by
  a transport. `AshA2A.Semantic.Envelope` can only ever be constructed at
  `:candidate`, so "received is not admitted" is structural here rather
  than a comment: reaching `:admitted` requires eight separate evidenced
  transitions, none of which may be skipped.

  Terminal (absorbing) states: `:refused`, `:blocked`, `:unknown`,
  `:unsupported`, `:failed`. They are reachable from any non-terminal state
  -- refusal is always lawful and always available -- and nothing transitions
  out of them.

  ## No transition may skip a REQUIRED predecessor

  Enforced, not documented: `transition/3` refuses
  `:standing_predecessor_skipped` (`REFUSED_META_RIGOR`) unless the
  envelope's current standing is exactly `predecessor(next)`. Jumping
  `:parsed -> :admitted` is a refusal carrying the required predecessor in
  its detail, not a silent success.

  ## Evidence required per step

  Every step demands evidence *of that step*. The evidence map's shape is
  checked; a step's evidence-shape failure refuses with the class that owns
  that step (see `evidence_class/1`).

  | to                     | required evidence keys                          | refuses as            |
  |------------------------|-------------------------------------------------|-----------------------|
  | `:received`            | `transport`, `received_at`                      | `REFUSED_STRUCTURE`   |
  | `:parsed`              | `media_type`, `triple_count`                    | `REFUSED_STRUCTURE`   |
  | `:identified`          | `graph_digest`, `digest_algorithm`              | `REFUSED_IDENTITY`    |
  | `:structurally_valid`  | `shex_result` with `conformant: true`           | `REFUSED_STRUCTURE`   |
  | `:semantically_valid`  | `shacl_report` with `conforms: true`            | `REFUSED_SHACL`       |
  | `:closed`              | `closure` with `entailed_triple_count`          | `REFUSED_RULE`        |
  | `:falsifier_clean`     | `falsifiers` (non-empty), `violations: []`      | `REFUSED_FALSIFIER`   |
  | `:admitted`            | `admission_receipt_id`                          | `REFUSED_RECEIPT`     |
  | `:plannable`           | `planning_fingerprint`, `goal_count` > 0        | `REFUSED_PLAN`        |
  | `:selected`            | `plan_id`, `step_count` > 0                     | `REFUSED_PLAN`        |
  | `:constructed`         | `command_id`, `capability_id`                   | `REFUSED_CAPABILITY`  |
  | `:authorized`          | `authority_id`, `scope`                         | `REFUSED_AUTHORITY`   |
  | `:prepared`            | `receipt_anchor_id`                             | `REFUSED_RECEIPT`     |
  | `:executed`            | `execution_id`, `consequence`                   | `REFUSED_CONSEQUENCE` |
  | `:receipted`           | `receipt_id`, `status`                          | `REFUSED_RECEIPT`     |
  | `:attested`            | `receipt_id`, `attestation`                     | `REFUSED_PROVENANCE`  |

  `:structurally_valid` demands a real ShEx result (from
  `praxis-graphlaw`'s `validate_all/5`), and `:semantically_valid` demands a
  real SHACL report from the same engine. Nothing in this module validates
  RDF -- it checks that a real validation *result* was presented, and
  refuses when it was not, or when it was present and non-conformant.

  Transitions to `:parsed` additionally honour the envelope's own `bounds`:
  a `"maxTriples"` bound that the presented `triple_count` exceeds refuses
  `:standing_bounds_exceeded` (`REFUSED_BOUNDS`).

  ## S6: standing MUST NOT be inferred

  Eleven forbidden inference sources. None of them may appear as evidence;
  each has a reserved evidence key that `transition/3` rejects outright with
  `:standing_inferred` (`REFUSED_META_RIGOR`):

    1. **An LLM produced output.** (`:llm_output`) A model emitting text is
       not a validation result. LLM output is a candidate, never standing.
    2. **A model's self-reported confidence or correctness.**
       (`:confidence`) A number a generator assigned to itself is not
       evidence about the subject.
    3. **A plan exists.** (`:plan_exists`) A plan is a candidate structure;
       having one says nothing about whether the subject was admitted.
    4. **A proof/derivation exists without an admission check having run.**
       (`:derivation_exists`) A derivation is a candidate until an admission
       function consumes it.
    5. **A hook fired.** (`:hook_fired`) Hooks are intent only, never
       authority -- the same rule `AshA2A.CommandBus` already enforces at
       the consequence boundary.
    6. **A prior envelope's standing.** (`:inherited_standing`) Standing is
       per-envelope. It is never inherited from a sibling, a parent, or a
       session.
    7. **A retry or replay of a previously admitted subject.**
       (`:previous_standing`) A replayed command reuses a *receipt*, not a
       standing; the new envelope re-earns its own.
    8. **A receipt being named rather than present.** (`:named_receipt`) A
       named receipt is not a receipt. `:admitted`/`:receipted` demand an
       identity that a store can actually be asked for.
    9. **Successful transport.** (`:http_status`) HTTP 200, delivery
       acknowledgement, or queue acceptance say the bytes arrived, not that
       the content is admissible.
   10. **Absence of an error.** (`:no_error`) Silence is not evidence.
       This is the S43 fail-closed rule stated as an inference ban.
   11. **Self-declaration by the sender.** (`:asserted_by`) The sender does
       not get to fill in its own standing -- `Envelope.from_json/1` already
       refuses a declared `"standing"` before this module is ever reached.

  The ban is enforced by a **recursive** scan of the whole evidence term --
  maps, lists, tuples and structs, to arbitrary depth -- so you cannot launder
  an inference by bundling it with a real result *or* by burying it one level
  down. It previously scanned only top-level keys via `Map.has_key?/2`, which
  the paragraph above claimed was laundering-proof and was not:
  `%{transport: "https", received_at: "...", bundle: %{llm_output: "..."}}`
  passed. The refusal detail now names the full path to each forbidden key
  (`forbidden_inference_paths`), not just the key.

  Evidence nested deeper than `max_evidence_depth/0` refuses
  `:standing_evidence_too_deep` rather than being scanned partially -- an
  un-scannable term is an un-cleared term (S43 again).

  ## Standing cannot be forged: the evidence ledger

  `AshA2A.Semantic.Envelope` is a public struct, so `%Envelope{envelope_id:
  "x", kind: "sa2a:Request", standing: :admitted}` is three lines any caller
  can write. `transition/3` used to read `:standing` straight off that struct,
  which made every predecessor and evidence check above bypassable by simply
  starting from a forged struct.

  Standing is therefore carried by an **append-only evidence ledger**, checked
  on every single transition before any other rule is applied:

    * `envelope.standing_history` is the ordered chain of evidenced steps.
      Entry 0 must start at `:candidate` and each entry's `from` must equal the
      previous entry's `to` -- a chain with a hole is refused.
    * `envelope.standing` must equal the `to` of the last ledger entry
      (`:candidate` when the ledger is empty). A standing ahead of its own
      evidence is `:standing_ledger_inconsistent`.
    * `envelope.standing_seal` must equal the HMAC-SHA256 chain over that
      history under a per-runtime key. A fabricated history is
      `:standing_ledger_unsealed`.

  `:candidate` with an empty ledger and no seal is the one lawful unsealed
  state -- it is the genesis standing and confers nothing. Every state above it
  requires a verifying seal.

  **What this does and does not defend against, precisely.** The key is 32
  random bytes generated once per runtime and held in `:persistent_term`; the
  seal is never serialized (`Envelope.to_map/1` omits it). That closes
  struct-literal forgery, forgery by hand-built history, forgery across the
  wire, and forgery by replaying a serialized envelope. It does **not** defend
  against code running in this BEAM that reads the key out of
  `:persistent_term` or redefines this module -- an attacker with arbitrary
  in-process code execution has already won by other means, and claiming
  otherwise would be the same kind of overclaim this module exists to refuse.
  No public function in `AshA2A` mints or extends a seal: the sealing functions
  are private to this module and `transition/3` is the only path that reaches
  them, after every check above has passed.
  """

  alias AshA2A.Semantic.{Envelope, Refusal}

  @chain [
    :candidate,
    :received,
    :parsed,
    :identified,
    :structurally_valid,
    :semantically_valid,
    :closed,
    :falsifier_clean,
    :admitted,
    :plannable,
    :selected,
    :constructed,
    :authorized,
    :prepared,
    :executed,
    :receipted,
    :attested
  ]

  @terminal [:refused, :blocked, :unknown, :unsupported, :failed]

  @forbidden_inference_keys [
    :llm_output,
    :confidence,
    :plan_exists,
    :derivation_exists,
    :hook_fired,
    :inherited_standing,
    :previous_standing,
    :named_receipt,
    :http_status,
    :no_error,
    :asserted_by
  ]

  # Both spellings, so an evidence map using string keys cannot slip past the
  # scan. Compared by name rather than by term so that `:llm_output` and
  # `"llm_output"` are the same ban at every depth.
  @forbidden_inference_names Enum.map(@forbidden_inference_keys, &Atom.to_string/1)

  @evidence_class %{
    received: :refused_structure,
    parsed: :refused_structure,
    identified: :refused_identity,
    structurally_valid: :refused_structure,
    semantically_valid: :refused_shacl,
    closed: :refused_rule,
    falsifier_clean: :refused_falsifier,
    admitted: :refused_receipt,
    plannable: :refused_plan,
    selected: :refused_plan,
    constructed: :refused_capability,
    authorized: :refused_authority,
    prepared: :refused_receipt,
    executed: :refused_consequence,
    receipted: :refused_receipt,
    attested: :refused_provenance
  }

  @ledger_key_term {__MODULE__, :ledger_key}
  @ledger_genesis "sa2a:standing:ledger:genesis:v1"
  @max_evidence_depth 64

  @type state :: atom()

  @doc "The ordered non-terminal chain, `:candidate` first."
  @spec states() :: [state()]
  def states, do: @chain

  @doc "The absorbing terminal states."
  @spec terminal_states() :: [state()]
  def terminal_states, do: @terminal

  @doc "True when `state` is absorbing."
  @spec terminal?(state()) :: boolean()
  def terminal?(state), do: state in @terminal

  @doc """
  The 11 evidence keys banned by S6, one per forbidden inference source.

      iex> length(AshA2A.Semantic.Standing.forbidden_inference_keys())
      11
  """
  @spec forbidden_inference_keys() :: [atom()]
  def forbidden_inference_keys, do: @forbidden_inference_keys

  @doc """
  0-based position in the chain, or `nil` for a terminal/unknown state.

      iex> AshA2A.Semantic.Standing.rank(:candidate)
      0
      iex> AshA2A.Semantic.Standing.rank(:refused)
      nil
  """
  @spec rank(state()) :: non_neg_integer() | nil
  def rank(state), do: Enum.find_index(@chain, &(&1 == state))

  @doc """
  The REQUIRED predecessor of a chain state.

      iex> AshA2A.Semantic.Standing.predecessor(:admitted)
      :falsifier_clean
      iex> AshA2A.Semantic.Standing.predecessor(:candidate)
      nil
  """
  @spec predecessor(state()) :: state() | nil
  def predecessor(state) do
    case rank(state) do
      nil -> nil
      0 -> nil
      index -> Enum.at(@chain, index - 1)
    end
  end

  @doc "The refusal class that owns a chain step's evidence check."
  @spec evidence_class(state()) :: Refusal.class()
  def evidence_class(state), do: Map.get(@evidence_class, state, :refused_meta_rigor)

  @doc """
  The single lawful standing transition.

  Returns `{:ok, envelope}` with the new standing and an appended
  `standing_history` entry, or `{:error, %AshA2A.Semantic.Refusal{}}`.

      iex> alias AshA2A.Semantic.{Envelope, Standing}
      iex> {:ok, e} = Envelope.new(%{envelope_id: "urn:uuid:9", kind: "sa2a:Request"})
      iex> {:error, refusal} = Standing.transition(e, :admitted, %{admission_receipt_id: "r1"})
      iex> {refusal.class, refusal.code, refusal.detail.required}
      {:refused_meta_rigor, :standing_predecessor_skipped, :falsifier_clean}
  """
  @spec transition(Envelope.t(), state(), map()) ::
          {:ok, Envelope.t()} | {:error, Refusal.t()}
  def transition(envelope, next, evidence \\ %{})

  def transition(%Envelope{standing: current} = envelope, next, evidence)
      when is_atom(next) and is_map(evidence) do
    with :ok <- verify_ledger(envelope, next) do
      cond do
        terminal?(current) ->
          {:error,
           refuse(:refused_meta_rigor, :standing_terminal, next, %{
             from: current,
             to: next,
             reason: "terminal standing is absorbing"
           })}

        next in @terminal ->
          terminal_transition(envelope, next, evidence)

        next in @chain ->
          chain_transition(envelope, next, evidence)

        true ->
          {:error, refuse(:refused_structure, :standing_state_unknown, next, next)}
      end
    end
  end

  def transition(%Envelope{} = _envelope, next, evidence) do
    {:error,
     refuse(:refused_structure, :standing_evidence_invalid, next, %{
       to: next,
       evidence: evidence
     })}
  end

  defp chain_transition(%Envelope{standing: current} = envelope, next, evidence) do
    required = predecessor(next)

    with :ok <- require_predecessor(current, next, required),
         :ok <- reject_inference(next, evidence),
         :ok <- check_evidence(envelope, next, evidence) do
      {:ok, seal_step(envelope, current, next, evidence)}
    end
  end

  defp require_predecessor(current, _next, current), do: :ok

  defp require_predecessor(current, next, required) do
    {:error,
     refuse(:refused_meta_rigor, :standing_predecessor_skipped, next, %{
       from: current,
       to: next,
       required: required
     })}
  end

  # S6, enforced over the whole evidence term rather than its top-level keys.
  #
  # `Map.has_key?/2` on the top level was defeated by one level of nesting, so
  # this walks maps, lists, tuples and structs to arbitrary depth. Structs are
  # handled explicitly: `is_map/1` is true for a struct but a struct is not
  # `Enumerable`, so reducing over one raises `Protocol.UndefinedError` --
  # `Map.from_struct/1` is applied first, and the struct's own fields are
  # scanned like any other map's.
  defp reject_inference(next, evidence) do
    case scan_evidence(evidence, [], 0, []) do
      {:error, {:evidence_scan, :too_deep}} ->
        {:error,
         refuse(:refused_meta_rigor, :standing_evidence_too_deep, next, %{
           to: next,
           max_depth: @max_evidence_depth,
           reason: "evidence nested past the scan depth cannot be cleared of inference sources"
         })}

      [] ->
        :ok

      paths ->
        ordered = Enum.reverse(paths)

        {:error,
         refuse(:refused_meta_rigor, :standing_inferred, next, %{
           to: next,
           forbidden_inference_sources:
             ordered |> Enum.map(&canonical_inference_key(List.last(&1))) |> Enum.uniq(),
           forbidden_inference_paths: ordered
         })}
    end
  end

  @doc """
  Maximum evidence nesting depth the S6 inference scan will descend.

      iex> AshA2A.Semantic.Standing.max_evidence_depth()
      64
  """
  @spec max_evidence_depth() :: pos_integer()
  def max_evidence_depth, do: @max_evidence_depth

  defp scan_evidence(_term, _path, depth, _acc) when depth > @max_evidence_depth,
    do: {:error, {:evidence_scan, :too_deep}}

  defp scan_evidence(%_{} = struct, path, depth, acc) do
    struct |> Map.from_struct() |> scan_evidence(path, depth, acc)
  end

  defp scan_evidence(map, path, depth, acc) when is_map(map) do
    Enum.reduce_while(map, acc, fn {key, value}, acc ->
      name = key_name(key)
      here = [name | path]

      acc = if name in @forbidden_inference_names, do: [Enum.reverse(here) | acc], else: acc

      case scan_evidence(value, here, depth + 1, acc) do
        {:error, {:evidence_scan, :too_deep}} -> {:halt, {:error, {:evidence_scan, :too_deep}}}
        next -> {:cont, next}
      end
    end)
  end

  defp scan_evidence(list, path, depth, acc) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(acc, fn {value, index}, acc ->
      case scan_evidence(value, [index | path], depth + 1, acc) do
        {:error, {:evidence_scan, :too_deep}} -> {:halt, {:error, {:evidence_scan, :too_deep}}}
        next -> {:cont, next}
      end
    end)
  end

  defp scan_evidence(tuple, path, depth, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> scan_evidence(path, depth, acc)
  end

  defp scan_evidence(_other, _path, _depth, acc), do: acc

  # The scan compares by name so `:llm_output` and `"llm_output"` are one ban,
  # but the refusal reports the canonical atom -- the same value
  # `forbidden_inference_keys/0` publishes -- so callers match on one shape.
  defp canonical_inference_key(name) do
    Enum.find(@forbidden_inference_keys, name, &(Atom.to_string(&1) == name))
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)

  # --- the append-only evidence ledger (anti-forgery) ---------------------

  # Every transition re-verifies the ledger the envelope presents before any
  # other rule runs. An envelope whose `:standing` is not exactly what its own
  # sealed history says it is has no standing at all.
  defp verify_ledger(%Envelope{standing_history: history}, next) when not is_list(history) do
    {:error,
     refuse(:refused_meta_rigor, :standing_ledger_malformed, next, %{
       to: next,
       reason: "standing_history must be a list"
     })}
  end

  defp verify_ledger(
         %Envelope{standing: :candidate, standing_history: [], standing_seal: nil},
         _n
       ),
       do: :ok

  defp verify_ledger(%Envelope{standing_history: [], standing: standing}, next) do
    {:error,
     refuse(:refused_meta_rigor, :standing_ledger_absent, next, %{
       to: next,
       claimed_standing: standing,
       reason:
         "an empty ledger evidences :candidate and nothing else; " <>
           "standing above :candidate requires a sealed evidence chain"
     })}
  end

  defp verify_ledger(%Envelope{} = envelope, next) do
    history = envelope.standing_history

    with :ok <- verify_entry_shapes(history, next),
         :ok <- verify_chain_contiguous(history, next),
         :ok <- verify_standing_matches_ledger(envelope, next) do
      verify_seal(envelope, next)
    end
  end

  defp verify_entry_shapes(history, next) do
    if Enum.all?(history, &entry_shape?/1) do
      :ok
    else
      {:error,
       refuse(:refused_meta_rigor, :standing_ledger_malformed, next, %{
         to: next,
         reason: "every ledger entry must carry from/to/at/evidence_keys/evidence_digest"
       })}
    end
  end

  defp entry_shape?(%{
         from: from,
         to: to,
         at: at,
         evidence_keys: keys,
         evidence_digest: digest
       })
       when is_atom(from) and is_atom(to) and is_binary(at) and is_list(keys) and
              is_binary(digest),
       do: true

  defp entry_shape?(_other), do: false

  defp verify_chain_contiguous(history, next) do
    expected = [:candidate | Enum.map(history, & &1.to)] |> Enum.drop(-1)
    actual = Enum.map(history, & &1.from)

    if expected == actual do
      :ok
    else
      {:error,
       refuse(:refused_meta_rigor, :standing_ledger_discontinuous, next, %{
         to: next,
         expected_from_chain: expected,
         actual_from_chain: actual
       })}
    end
  end

  defp verify_standing_matches_ledger(%Envelope{standing: standing} = envelope, next) do
    evidenced = envelope.standing_history |> List.last() |> Map.fetch!(:to)

    if standing == evidenced do
      :ok
    else
      {:error,
       refuse(:refused_meta_rigor, :standing_ledger_inconsistent, next, %{
         to: next,
         claimed_standing: standing,
         evidenced_standing: evidenced
       })}
    end
  end

  defp verify_seal(%Envelope{standing_seal: seal, standing_history: history}, next) do
    if is_binary(seal) and secure_compare(seal, seal_chain(history)) do
      :ok
    else
      {:error,
       refuse(:refused_meta_rigor, :standing_ledger_unsealed, next, %{
         to: next,
         reason:
           "the presented standing history is not sealed by this runtime's ledger key; " <>
             "standing is evidence this runtime holds, never a field a caller fills in"
       })}
    end
  end

  # The only seal-minting path in `AshA2A`, reached only after every check in
  # `transition/3` has passed. Deliberately private: a public mint would be a
  # forgery primitive, which is exactly what the ledger exists to remove.
  defp seal_step(%Envelope{} = envelope, from, to, evidence) do
    history = envelope.standing_history ++ [Envelope.history_entry(from, to, evidence)]

    %{envelope | standing: to, standing_history: history, standing_seal: seal_chain(history)}
  end

  defp seal_chain(history) do
    key = ledger_key()

    history
    |> Enum.reduce(@ledger_genesis, fn entry, acc ->
      Base.encode16(:crypto.mac(:hmac, :sha256, key, acc <> "\n" <> entry_payload(entry)),
        case: :lower
      )
    end)
    |> then(&("hmac-sha256:" <> &1))
  end

  defp entry_payload(entry) do
    Enum.join(
      [
        Atom.to_string(entry.from),
        Atom.to_string(entry.to),
        entry.at,
        Enum.join(entry.evidence_keys, ","),
        entry.evidence_digest
      ],
      "|"
    )
  end

  @doc """
  Ensures this runtime's standing-ledger key exists.

  Called once from `AshA2A.Application.start/2` so the key is seeded before any
  envelope is sealed. Safe to call repeatedly; it never replaces an existing
  key.
  """
  @spec ensure_ledger_key() :: :ok
  def ensure_ledger_key do
    _ = ledger_key()
    :ok
  end

  defp ledger_key do
    case :persistent_term.get(@ledger_key_term, nil) do
      nil -> seed_ledger_key()
      key -> key
    end
  end

  # Seeded under a named global lock so two concurrent first-callers cannot
  # seal under two different keys.
  defp seed_ledger_key do
    result =
      :global.trans({@ledger_key_term, self()}, fn ->
        case :persistent_term.get(@ledger_key_term, nil) do
          nil ->
            key = :crypto.strong_rand_bytes(32)
            :persistent_term.put(@ledger_key_term, key)
            key

          key ->
            key
        end
      end)

    case result do
      key when is_binary(key) -> key
      :aborted -> :persistent_term.get(@ledger_key_term, nil) || seed_ledger_key()
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  # --- terminal transitions ----------------------------------------------

  defp terminal_transition(%Envelope{standing: current} = envelope, next, evidence) do
    with {:ok, refusal} <- terminal_refusal(next, evidence),
         :ok <- terminal_class_admissible(next, refusal) do
      {:ok,
       seal_step(envelope, current, next, %{
         refusal_class: refusal.class,
         refusal_code: refusal.code,
         refusal_stage: refusal.stage
       })}
    end
  end

  defp terminal_refusal(next, %{refusal: %Refusal{} = refusal}), do: {:ok, wrap(next, refusal)}

  defp terminal_refusal(next, %{"refusal" => %Refusal{} = refusal}),
    do: {:ok, wrap(next, refusal)}

  defp terminal_refusal(next, evidence) do
    {:error,
     refuse(:refused_meta_rigor, :standing_terminal_evidence_invalid, next, %{
       to: next,
       reason: "terminal standing requires evidence %{refusal: %AshA2A.Semantic.Refusal{}}",
       evidence_keys: evidence |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
     })}
  end

  defp wrap(_next, refusal), do: refusal

  defp terminal_class_admissible(:failed, %Refusal{}), do: :ok

  defp terminal_class_admissible(next, %Refusal{class: class} = refusal) do
    if class in admissible_classes(next) do
      :ok
    else
      {:error,
       refuse(:refused_meta_rigor, :standing_terminal_evidence_invalid, next, %{
         to: next,
         refusal_class: class,
         admissible_classes: admissible_classes(next),
         refusal_code: refusal.code
       })}
    end
  end

  defp admissible_classes(:refused), do: Refusal.refused_classes()
  defp admissible_classes(:blocked), do: Refusal.blocked_classes()
  defp admissible_classes(:unknown), do: [:blocked_unknown]
  defp admissible_classes(:unsupported), do: Refusal.unsupported_classes()

  # --- per-step evidence checks ------------------------------------------

  defp check_evidence(_envelope, :received, evidence) do
    require_keys(:received, evidence, [:transport, :received_at])
  end

  defp check_evidence(envelope, :parsed, evidence) do
    with :ok <- require_keys(:parsed, evidence, [:media_type, :triple_count]),
         :ok <- require_non_neg_integer(:parsed, evidence, :triple_count) do
      check_triple_bounds(envelope, evidence)
    end
  end

  defp check_evidence(_envelope, :identified, evidence) do
    require_keys(:identified, evidence, [:graph_digest, :digest_algorithm])
  end

  defp check_evidence(_envelope, :structurally_valid, evidence) do
    with :ok <- require_keys(:structurally_valid, evidence, [:shex_result]) do
      require_flag(:structurally_valid, evidence, :shex_result, :conformant)
    end
  end

  defp check_evidence(_envelope, :semantically_valid, evidence) do
    with :ok <- require_keys(:semantically_valid, evidence, [:shacl_report]) do
      require_flag(:semantically_valid, evidence, :shacl_report, :conforms)
    end
  end

  defp check_evidence(_envelope, :closed, evidence) do
    with :ok <- require_keys(:closed, evidence, [:closure]) do
      case get(evidence, :closure) do
        closure when is_map(closure) ->
          if is_integer(get(closure, :entailed_triple_count)) do
            :ok
          else
            evidence_invalid(:closed, %{
              reason: "closure must carry an integer :entailed_triple_count",
              closure: closure
            })
          end

        other ->
          evidence_invalid(:closed, %{reason: "closure must be a map", closure: other})
      end
    end
  end

  defp check_evidence(_envelope, :falsifier_clean, evidence) do
    with :ok <- require_keys(:falsifier_clean, evidence, [:falsifiers, :violations]) do
      falsifiers = get(evidence, :falsifiers)
      violations = get(evidence, :violations)

      cond do
        not is_list(falsifiers) or falsifiers == [] ->
          evidence_invalid(:falsifier_clean, %{
            reason: "a falsifier-clean claim requires at least one declared falsifier",
            falsifiers: falsifiers
          })

        violations != [] ->
          {:error,
           refuse(:refused_falsifier, :standing_evidence_invalid, :falsifier_clean, %{
             reason: "declared falsifiers fired",
             violations: violations
           })}

        true ->
          :ok
      end
    end
  end

  defp check_evidence(_envelope, :admitted, evidence) do
    require_keys(:admitted, evidence, [:admission_receipt_id])
  end

  defp check_evidence(_envelope, :plannable, evidence) do
    with :ok <- require_keys(:plannable, evidence, [:planning_fingerprint, :goal_count]) do
      require_positive_integer(:plannable, evidence, :goal_count)
    end
  end

  defp check_evidence(_envelope, :selected, evidence) do
    with :ok <- require_keys(:selected, evidence, [:plan_id, :step_count]) do
      require_positive_integer(:selected, evidence, :step_count)
    end
  end

  defp check_evidence(_envelope, :constructed, evidence) do
    require_keys(:constructed, evidence, [:command_id, :capability_id])
  end

  defp check_evidence(_envelope, :authorized, evidence) do
    require_keys(:authorized, evidence, [:authority_id, :scope])
  end

  defp check_evidence(_envelope, :prepared, evidence) do
    require_keys(:prepared, evidence, [:receipt_anchor_id])
  end

  defp check_evidence(_envelope, :executed, evidence) do
    require_keys(:executed, evidence, [:execution_id, :consequence])
  end

  defp check_evidence(_envelope, :receipted, evidence) do
    require_keys(:receipted, evidence, [:receipt_id, :status])
  end

  defp check_evidence(_envelope, :attested, evidence) do
    require_keys(:attested, evidence, [:receipt_id, :attestation])
  end

  defp check_triple_bounds(%Envelope{bounds: bounds}, evidence) do
    max = get(bounds, :maxTriples) || get(bounds, :max_triples)
    count = get(evidence, :triple_count)

    if is_integer(max) and is_integer(count) and count > max do
      {:error,
       refuse(:refused_bounds, :standing_bounds_exceeded, :parsed, %{
         bound: :maxTriples,
         limit: max,
         observed: count
       })}
    else
      :ok
    end
  end

  defp require_keys(step, evidence, keys) do
    missing = Enum.reject(keys, fn key -> present?(evidence, key) end)

    if missing == [] do
      :ok
    else
      {:error,
       refuse(evidence_class(step), :standing_evidence_missing, step, %{
         to: step,
         missing: missing,
         required: keys
       })}
    end
  end

  defp require_non_neg_integer(step, evidence, key) do
    case get(evidence, key) do
      value when is_integer(value) and value >= 0 ->
        :ok

      other ->
        evidence_invalid(step, %{reason: "#{key} must be a non-negative integer", value: other})
    end
  end

  defp require_positive_integer(step, evidence, key) do
    case get(evidence, key) do
      value when is_integer(value) and value > 0 ->
        :ok

      other ->
        evidence_invalid(step, %{reason: "#{key} must be a positive integer", value: other})
    end
  end

  defp require_flag(step, evidence, result_key, flag_key) do
    case get(evidence, result_key) do
      result when is_map(result) ->
        case get(result, flag_key) do
          true ->
            :ok

          other ->
            evidence_invalid(step, %{
              reason: "#{result_key}.#{flag_key} must be true",
              value: other
            })
        end

      other ->
        evidence_invalid(step, %{reason: "#{result_key} must be a map", value: other})
    end
  end

  defp evidence_invalid(step, detail) do
    {:error,
     refuse(evidence_class(step), :standing_evidence_invalid, step, Map.put(detail, :to, step))}
  end

  defp present?(evidence, key) do
    case get(evidence, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_map, _key), do: nil

  defp refuse(class, code, stage, detail), do: Refusal.new(class, code, stage, detail)
end
