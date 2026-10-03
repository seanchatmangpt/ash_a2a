defmodule AshA2A.Receipt.RProjection do
  @moduledoc """
  Projects an S31 command receipt (`AshA2A.Receipt`) onto the fleet R schema
  v2 (`~/.claude/dfcm/receipt.schema.json`): the five-field receipt
  `R = {identity, authority, consequence, replay, standing}` plus the v2
  additions (`work_order_id`, `origin_authority`, `provider`,
  `provider_execution_id`, `replay_binding`, `provider_ext.ash_a2a`).

  ## The two load-bearing claims

  **1. Evidence-only.** The projection adds no authority and upgrades no
  standing. Every field is read off the receipt or the caller's anchors;
  standing is derived from `terminal_status x store standing` and is monotone
  in the evidence: a `:pending` receipt projects `UNKNOWN`, an `:observed`
  `:executed`/`:reconciled` receipt refuses to project at all rather than
  claiming durability it does not have, and only a receipt whose standing the
  real `AshA2A.CommandBus` upgraded against a store that really declares
  itself durable (`AshA2A.ReceiptStore.Ekv.durable?/0`) can project `ALIVE`.
  The projector also holds no authority of its own: `authority.ceiling` is the
  fixed map of the receipt's own `consequence`, `authority.grant` is the
  receipt's bound grant token (or the honest `"NONE"`), and no caller option
  can override the ceiling, the standing value, or any digest.

  **2. Caller-supplied git anchor.** An `AshA2A.Receipt` carries no git
  identity whatsoever -- receipts are machine identities, not commits -- so
  `repo`, `subject_sha`, and `base_sha` are *required* caller opts. They are
  pattern-validated only (40-hex lowercase for the two SHAs): the projector
  runs **no git subprocess** and cannot verify the anchor resolves; the
  caller per C0 asserts it is the verified clean-tree HEAD. `consequence.
  commits` is therefore always `[]` -- a receipt can never claim a commit it
  did not make.

  ## Precedence (ordered, fail-closed)

  Receipt shape -> `AshA2A.Receipt.Binding.verify/1` -> anchors ->
  work-order id -> consequence -> standing projectability. Every step refuses
  with a typed code (see `refusal_codes/0`) and never falls through to a
  degraded projection.

  ## Standing table

  | terminal_status            | R standing value                    | broken_term |
  |----------------------------|-------------------------------------|-------------|
  | `:refused`                 | `REFUSED(<pre-DO code>)`            | see `@broken_term_map` |
  | `:failed` (`:dispatch_crashed`) | `BUILD_BROKEN`                 | `R_missing_consequence` |
  | `:failed` (other code)     | `BLOCKED(:<code>)`                  | `R_missing_consequence` |
  | `:compensated`             | `PARTIAL_ALIVE`                     | -- |
  | `:unknown_outcome` / `nil` | `UNKNOWN`                           | -- |
  | `:executed` / `:reconciled` (and `standing == :durable`) | `ALIVE` | -- |
  """

  alias AshA2A.Identity
  alias AshA2A.Identity.Canonical
  alias AshA2A.Receipt

  @sha40 ~r/\A[0-9a-f]{40}\z/

  # No caller override anywhere: the ceiling is a pure function of the
  # receipt's own recorded consequence class.
  @ceiling_map %{
    read: "OBSERVE",
    observe: "OBSERVE",
    change: "CONSTRUCT",
    external_do: "DO",
    external: "DO"
  }

  @typed_refusal_codes [
    :r_projection_receipt_required,
    :r_projection_binding_unverified,
    :r_projection_anchor_missing,
    :r_projection_anchor_malformed,
    :r_projection_work_order_unavailable,
    :r_projection_consequence_unknown,
    :r_projection_standing_not_durable
  ]

  # REFUSED(<code>) -> broken_term. Authority-shaped refusals break the
  # authority term; anchor/store/in-flight refusals break the replay term;
  # the kill switch is unlawful manufacture; every other pre-DO refusal
  # admits nothing (the admission gate failed vacuously for that command).
  @broken_term_map %{
    authority_required: "R_missing_authority",
    authority_mismatch: "R_missing_authority",
    consequence_unclassified: "R_missing_consequence",
    receipt_anchor_unavailable: "R_missing_replay",
    actuation_store_unavailable: "R_missing_replay",
    actuation_in_flight: "R_missing_replay",
    kill_switch_tripped: "mu_unlawful"
  }

  @doc "The fixed consequence -> R authority-ceiling map. No caller override."
  @spec ceilings() :: %{atom() => String.t()}
  def ceilings, do: @ceiling_map

  @doc "The typed refusal codes `project/2` can return."
  @spec refusal_codes() :: [atom()]
  def refusal_codes, do: @typed_refusal_codes

  @type refusal :: {:error, %{code: atom(), detail: term()}}

  @doc """
  Projects `receipt` onto the fleet R schema v2.

  Required opts: `:repo`, `:subject_sha` (40-hex), `:base_sha` (40-hex).
  Optional: `:work_order_id` (fallback when the receipt carries no
  `metadata.work_order_digest`), `:transport` (recorded in `provider`).
  """
  @spec project(Receipt.t() | term(), keyword()) :: {:ok, map()} | refusal()
  def project(receipt, opts \\ [])

  def project(%Receipt{} = receipt, opts) do
    with {:ok, _report} <- verified_binding(receipt),
         {:ok, anchors} <- anchors(opts),
         {:ok, work_order_id} <- work_order_id(receipt, opts),
         {:ok, ceiling} <- ceiling(receipt),
         :ok <- standing_projectable(receipt),
         {:ok, sealed} <-
           seal(r_map(receipt, anchors, work_order_id, ceiling, opts), receipt) do
      {:ok, sealed}
    end
  end

  def project(_other, _opts) do
    {:error,
     %{
       code: :r_projection_receipt_required,
       detail: "project/2 projects an %AshA2A.Receipt{}; got something else"
     }}
  end

  # --- preconditions -----------------------------------------------------------

  defp verified_binding(receipt) do
    case Receipt.Binding.verify(receipt) do
      {:ok, report} -> {:ok, report}
      {:error, %{code: code, detail: detail}} ->
        {:error,
         %{code: :r_projection_binding_unverified, detail: %{refused: code, why: detail}}}
    end
  end

  defp anchors(opts) do
    repo = Keyword.get(opts, :repo)
    subject_sha = Keyword.get(opts, :subject_sha)
    base_sha = Keyword.get(opts, :base_sha)

    with :ok <- present(:repo, repo),
         :ok <- present(:subject_sha, subject_sha),
         :ok <- present(:base_sha, base_sha),
         :ok <- valid_repo(repo),
         :ok <- valid_sha(:subject_sha, subject_sha),
         :ok <- valid_sha(:base_sha, base_sha) do
      {:ok, %{repo: repo, subject_sha: subject_sha, base_sha: base_sha}}
    end
  end

  defp present(_field, value) when is_binary(value) and value != "", do: :ok
  defp present(field, nil), do: {:error, %{code: :r_projection_anchor_missing, detail: %{field: field}}}

  defp present(field, value),
    do: {:error, %{code: :r_projection_anchor_missing, detail: %{field: field, observed: value}}}

  defp valid_repo(repo) when is_binary(repo) and repo != "", do: :ok

  defp valid_repo(observed),
    do: {:error, %{code: :r_projection_anchor_malformed, detail: %{field: :repo, observed: observed}}}

  defp valid_sha(field, sha) when is_binary(sha) do
    if Regex.match?(@sha40, sha),
      do: :ok,
      else:
        {:error,
         %{code: :r_projection_anchor_malformed, detail: %{field: field, observed: sha}}}
  end

  # metadata.work_order_digest wins over the opts fallback (R5: it is bound
  # into the receipt's own metadata at the consequence boundary; an opts
  # value is the caller's say-so about a receipt that cannot name its order).
  defp work_order_id(receipt, opts) do
    case metadata_work_order_digest(receipt) || Keyword.get(opts, :work_order_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        {:error,
         %{
           code: :r_projection_work_order_unavailable,
           detail:
             "receipt carries no metadata.work_order_digest and no :work_order_id opt was supplied"
         }}
    end
  end

  defp metadata_work_order_digest(%Receipt{metadata: %{} = metadata}) do
    Map.get(metadata, :work_order_digest) || Map.get(metadata, "work_order_digest")
  end

  defp metadata_work_order_digest(_receipt), do: nil

  defp ceiling(%Receipt{consequence: consequence} = receipt) do
    case Map.fetch(@ceiling_map, consequence) do
      {:ok, ceiling} -> {:ok, ceiling}
      :error ->
        {:error,
         %{
           code: :r_projection_consequence_unknown,
           detail: %{observed: consequence, receipt_id: external(receipt.receipt_id)}
         }}
    end
  end

  # The ALIVE law: an executed/reconciled outcome is only ALIVE when the
  # receipt's own store standing says the evidence is durable. An `:observed`
  # receipt refuses to project rather than deriving standing it does not
  # have -- the dishonesty guard.
  defp standing_projectable(%Receipt{terminal_status: ts, standing: standing})
       when ts in [:executed, :reconciled] and standing != :durable do
    {:error,
     %{
       code: :r_projection_standing_not_durable,
       detail:
         "terminal #{inspect(ts)} at standing #{inspect(standing)}: ALIVE/exit-0 requires " <>
           "receipt.standing == :durable (CommandBus over a store whose durable?/0 is true)"
     }}
  end

  defp standing_projectable(_receipt), do: :ok

  # --- projection ----------------------------------------------------------------

  defp r_map(receipt, anchors, work_order_id, ceiling, opts) do
    %{
      "work_order_id" => work_order_id,
      "identity" => identity(receipt, anchors, work_order_id),
      "authority" => authority(receipt, ceiling),
      "origin_authority" => origin_authority(receipt, ceiling),
      "provider" => provider(ceiling, opts),
      "provider_execution_id" => Identity.external(receipt.execution_id),
      "consequence" => consequence(receipt, ceiling),
      "replay" => replay(receipt, anchors),
      "standing" => standing(receipt, anchors),
      "replay_binding" => replay_binding(receipt)
    }
  end

  defp identity(receipt, anchors, work_order_id) do
    %{
      "subject" => work_order_id,
      "repo" => anchors.repo,
      "subject_sha" => anchors.subject_sha,
      "base_sha" => anchors.base_sha
    }
    |> maybe_put("graph_hash", graph_hash(receipt))
    |> maybe_put("subject_digest", subject_digest(receipt))
  end

  defp graph_hash(%Receipt{semantic_subject: %AshA2A.SemanticSubject{graph_digest: digest}})
       when is_binary(digest),
       do: digest

  defp graph_hash(_receipt), do: nil

  defp subject_digest(%Receipt{input_digest: "sha256:" <> hex}) when is_binary(hex),
    do: %{"algorithm" => "sha256", "value" => hex}

  defp subject_digest(_receipt), do: nil

  defp authority(receipt, ceiling) do
    %{"ceiling" => ceiling, "grant" => grant(receipt), "actor" => actor(receipt)}
  end

  defp origin_authority(receipt, ceiling) do
    %{"ceiling" => ceiling, "grant" => grant(receipt), "actor" => actor(receipt)}
  end

  defp grant(%Receipt{authority_grant: %{token_id: token_id}}) when is_binary(token_id),
    do: token_id

  defp grant(_receipt), do: "NONE"

  defp actor(%Receipt{actor: %Identity{} = actor}), do: Identity.external(actor)
  defp actor(%Receipt{actor: actor}) when is_binary(actor) and actor != "", do: actor
  defp actor(_receipt), do: "unknown"

  defp provider(ceiling, opts) do
    %{
      "name" => "ash_a2a",
      "authority_ceiling" => ceiling,
      "receipt_protocol" => "RFC-SA2A-001 S31"
    }
    |> maybe_put("transport", Keyword.get(opts, :transport))
  end

  defp consequence(receipt, ceiling) do
    remote_effects = if ceiling == "DO", do: [receipt.capability_id], else: []

    %{
      "commits" => [],
      "files_changed" => files_changed(receipt),
      "remote_effects" => remote_effects
    }
  end

  defp files_changed(%Receipt{intended_effect: %{target: target}}) when is_binary(target),
    do: [target]

  defp files_changed(%Receipt{intended_effect: %{target: target}})
       when is_list(target) and target != [] and is_list(hd(target)),
       do: target

  defp files_changed(%Receipt{intended_effect: %{target: target}})
       when is_list(target) and target != [] and is_binary(hd(target)),
       do: target

  defp files_changed(_receipt), do: []

  defp replay(receipt, anchors) do
    executed? = executed_and_durable?(receipt)

    %{
      "commands" => [
        %{
          "cmd" => receipt.capability_id,
          "cwd" => anchors.repo,
          # The exit gate: 0 exactly when the outcome is executed/reconciled
          # AND the receipt's store standing is durable; every other terminal
          # shape replays as a failure.
          "exit" => if(executed?, do: 0, else: 1)
        }
      ]
    }
    |> maybe_put("durable_location", durable_location(receipt, executed?))
  end

  defp executed_and_durable?(%Receipt{terminal_status: ts, standing: standing}),
    do: ts in [:executed, :reconciled] and standing == :durable

  defp durable_location(_receipt, false), do: nil
  defp durable_location(receipt, true), do: "ash_a2a:receipt:" <> external(receipt.receipt_id)

  defp standing(receipt, anchors) do
    {value, broken_term} = standing_value(receipt)

    %{
      "value" => value,
      "derived_from" =>
        "#{receipt.capability_id} exit=#{replay_exit(receipt)} @ #{anchors.subject_sha}"
    }
    |> maybe_put("broken_term", broken_term)
  end

  defp replay_exit(receipt), do: if(executed_and_durable?(receipt), do: 0, else: 1)

  defp standing_value(%Receipt{terminal_status: :refused} = receipt) do
    code = refusal_code(receipt)
    {"REFUSED(#{code || "unknown"})", Map.get(@broken_term_map, code, "admission_vacuous")}
  end

  defp standing_value(%Receipt{terminal_status: :failed} = receipt) do
    case refusal_code(receipt) do
      :dispatch_crashed -> {"BUILD_BROKEN", "R_missing_consequence"}
      code -> {"BLOCKED(:#{code || "unknown"})", "R_missing_consequence"}
    end
  end

  defp standing_value(%Receipt{terminal_status: :compensated}),
    do: {"PARTIAL_ALIVE", nil}

  defp standing_value(%Receipt{terminal_status: ts})
       when ts in [:unknown_outcome, nil],
       do: {"UNKNOWN", nil}

  # Only reachable when the precondition passed, i.e. standing == :durable.
  defp standing_value(%Receipt{terminal_status: ts}) when ts in [:executed, :reconciled],
    do: {"ALIVE", nil}

  defp refusal_code(%Receipt{reply: {:error, %{code: code}}}), do: code
  defp refusal_code(_receipt), do: nil

  defp replay_binding(%Receipt{binding: %{links: links}} = receipt) do
    %{
      "event_ids" =>
        [
          external(receipt.actuation_id),
          external(receipt.command_id)
        ]
        |> Enum.reject(&is_nil/1),
      "chain_head_hash" => List.last(links).digest
    }
  end

  defp external(%Identity{} = identity), do: Identity.external(identity)
  defp external(value) when is_binary(value), do: value
  defp external(_other), do: nil

  # --- self-digest ---------------------------------------------------------------

  # Seals the projection: self_digest is the JCS digest of the *full* map
  # minus the self_digest key itself, so any field mutation -- including in
  # the extension object -- is detectable by recompute. No wall-clock field
  # enters the map anywhere, so the same receipt always seals byte-identical.
  defp seal(r_map, %Receipt{} = receipt) do
    ext =
      %{
        "projection_id" => "ash_a2a:r_projection:v1:" <> external(receipt.receipt_id),
        "input_digest" => receipt.input_digest
      }
      |> maybe_put("plan_digest", receipt.plan_digest)
      |> maybe_put("projection_digest", receipt.projection_digest)

    without_self = Map.put(r_map, "provider_ext.ash_a2a", ext)

    case Canonical.digest(without_self) do
      {:ok, self_digest} ->
        {:ok,
         Map.put(without_self, "provider_ext.ash_a2a", Map.put(ext, "self_digest", self_digest))}

      {:error, reason} ->
        {:error,
         %{code: :r_projection_binding_unverified, detail: {:self_digest_unavailable, reason}}}
    end
  end

  @doc false
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
