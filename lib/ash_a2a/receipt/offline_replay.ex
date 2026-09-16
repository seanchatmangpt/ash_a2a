defmodule AshA2A.Receipt.OfflineReplay do
  @moduledoc """
  Fresh offline replay engine (RFC-SA2A-001 S32; RFC-SA2A-002 §41 Gate 10,
  §92 B8).

  Verifies a durable `AshA2A.Receipt.EvidenceChain` from its files alone and
  reconstructs, per command, the eight replay stages:

      admission  selection  construction  authority_decision
      prepared_receipt  intended_effect  final_receipt  observed_post_state

  > "Replaying evidence is not authority to re-actuate."

  Replay never actuates: this module has no path to `AshA2A.CommandBus`,
  `AshA2A.Dispatcher`, `AshA2A.BrceAnchor` or `Ash`; per-command semantic
  bases come from `AshA2A.Receipt.Replay.basis/1`, whose authority record is
  deliberately not an `AshA2A.Authority`.

  ## Three entry points

    * `verify_chain/2` -- pure verification. No telemetry, no consequence.
    * `replay/2` -- in-VM acceptance boundary: runs `verify_chain/2` in a
      newly spawned BEAM process that inherits nothing but the chain
      directory, samples that process's memory, and emits
      `[:ash_a2a, :replay, :verified]` (`mode: :in_vm`).
    * `verify_fresh/2` -- fresh-process acceptance boundary: runs `main/1` in
      a genuinely fresh `elixir` OS process (no application started, code-path
      environment scrubbed, no producer memory), accepts its verdict only
      when it provably came from that OS process with `:ash_a2a` unstarted and
      no DO boundary module loaded, and emits `[:ash_a2a, :replay, :verified]`
      (`mode: :fresh_os_process`).

  ## Checks (a failing check refuses the chain)

  Integrity, over bytes (reconstruction runs only when all pass):

    * `replay_manifest_invalid` -- `chain.json` absent, undecodable or malformed
    * `replay_receipt_missing` -- a link's file is absent
    * `replay_digest_mismatch` -- a file's SHA-256 or size differs from its link
    * `replay_link_broken` -- `seq`, `prev` or link `digest` does not chain
    * `replay_root_divergence` -- the recomputed link root differs from the
      manifest's, or from an external anchor (`:link_root`)
    * `replay_payload_undecodable` -- a link does not decode to what it claims
    * `replay_identity_divergence` -- a link's command id differs from its payload's

  Reconstruction, over decoded receipts (`reconstruct/1`):

    * `replay_receipt_missing` -- no final receipt, no post-state observation,
      no prepared anchor for a consequence that crossed DO, or a deduplicated
      receipt whose prior receipt is absent
    * `replay_receipt_order_violation` -- stages out of order (prepared ->
      final -> post_state; prepared logical clock before final), or a
      deduplicated receipt before its prior
    * `replay_identity_divergence` -- the finalized receipt does not preserve
      the prepared anchor's identity (receipt, command, execution, actuation,
      idempotency, input digest, fingerprint, intended effect, ...)
    * `replay_authority_divergence` -- prepared and final grants differ, or a
      consequence-bearing grant does not name the receipt's actor/capability
    * `replay_duplicate_actuation` -- a command, receipt or declared actuation
      identity crosses the consequence boundary more than once in the chain
    * `replay_basis_refused` -- `AshA2A.Receipt.Replay.basis/1` refuses a receipt
    * `replay_post_state_unbound` -- the post-state observation is not bound
      to the final receipt, or contradicts an executed outcome
    * `replay_root_divergence` -- the reconstructed basis root differs from
      the manifest's, or from an external anchor (`:basis_root`)
  """

  alias AshA2A.{Identity, Receipt}
  alias AshA2A.Receipt.{EvidenceChain, Replay}

  @schema "ash_a2a.offline_replay/1"
  @marker "SA2A-OFFLINE-REPLAY-VERDICT "
  @event [:ash_a2a, :replay, :verified]
  @do_boundary [AshA2A.CommandBus, AshA2A.Dispatcher, AshA2A.BrceAnchor]
  @stages ~w(admission selection construction authority_decision prepared_receipt intended_effect final_receipt observed_post_state)
  @scrubbed_env ~w(ERL_LIBS ERL_AFLAGS ERL_ZFLAGS ELIXIR_ERL_OPTIONS MIX_ENV MIX_BUILD_PATH MIX_EXS)
  @max_output 16_000_000
  @max_link_bytes 16_000_000
  @file_pattern ~r/^links\/[A-Za-z0-9_.-]+$/
  @identity_fields [
    :receipt_id,
    :command_id,
    :execution_id,
    :task_id,
    :agent_id,
    :principal_id,
    :capability_id,
    :fingerprint,
    :consequence,
    :actuation_id,
    :idempotency_key,
    :actor,
    :input_digest,
    :intended_effect,
    :plan_digest,
    :projection_digest,
    :semantic_subject
  ]

  @refusal_codes %{
    replay_manifest_invalid: :refused_structure,
    replay_receipt_missing: :refused_receipt,
    replay_digest_mismatch: :refused_provenance,
    replay_link_broken: :refused_provenance,
    replay_payload_undecodable: :refused_structure,
    replay_receipt_order_violation: :refused_receipt,
    replay_identity_divergence: :refused_identity,
    replay_authority_divergence: :refused_authority,
    replay_duplicate_actuation: :refused_consequence,
    replay_basis_refused: :refused_receipt,
    replay_post_state_unbound: :refused_provenance,
    replay_root_divergence: :refused_provenance,
    replay_process_not_fresh: :refused_meta_rigor,
    replay_consequence_boundary_loaded: :refused_consequence,
    replay_fresh_process_unavailable: :blocked_resource,
    replay_crashed: :blocked_unknown
  }

  @doc false
  def __sa2a_refusal_codes__, do: @refusal_codes

  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The replay decision event: `[:ash_a2a, :replay, :verified]`."
  @spec event() :: [atom()]
  def event, do: @event

  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc "Modules whose loading would mean the replay process reached a DO boundary."
  @spec do_boundary() :: [module()]
  def do_boundary, do: @do_boundary

  # --- pure verification --------------------------------------------------------

  @doc """
  Verifies the chain in `dir` from its files alone and returns the JSON-safe
  verdict. Options: `:link_root`, `:basis_root` -- an external anchor (e.g.
  the producer's seal) both roots must also match. Pure.
  """
  @spec verify_chain(Path.t(), keyword()) :: map()
  def verify_chain(dir, opts \\ []) when is_binary(dir) do
    dir = Path.expand(dir)
    anchor = anchor(opts)

    case load_manifest(dir) do
      {:ok, manifest} ->
        {integrity, recomputed_link_root} = integrity_checks(dir, manifest, anchor)

        if Enum.all?(integrity, & &1["ok"]) do
          case decode_links(dir, manifest) do
            {:ok, links} ->
              rec = reconstruct(links)

              checks =
                integrity ++
                  reconstruction_checks(rec) ++ basis_root_checks(manifest, rec, anchor)

              finish(dir, manifest, checks, rec, anchor, recomputed_link_root)

            {:error, decode_checks} ->
              finish(dir, manifest, integrity ++ decode_checks, nil, anchor, recomputed_link_root)
          end
        else
          finish(dir, manifest, integrity, nil, anchor, recomputed_link_root)
        end

      {:error, detail} ->
        finish(dir, nil, [failed("manifest", :replay_manifest_invalid, detail)], nil, anchor, nil)
    end
  end

  @doc """
  Reads and decodes the links named by `manifest` from `dir` and reconstructs
  them (no integrity checks). Used by `AshA2A.Receipt.EvidenceChain.write/2`
  to seal the basis root from the bytes actually written.
  """
  @spec reconstruct_dir(Path.t(), map()) :: %{
          records: [map()],
          failures: [map()],
          basis_root: String.t()
        }
  def reconstruct_dir(dir, manifest) do
    case decode_links(dir, manifest) do
      {:ok, links} ->
        reconstruct(links)

      {:error, checks} ->
        %{records: [], failures: checks, basis_root: EvidenceChain.sha256("[]"), stages: 0}
    end
  end

  defp anchor(opts) do
    %{
      link_root: non_empty(Keyword.get(opts, :link_root)),
      basis_root: non_empty(Keyword.get(opts, :basis_root))
    }
  end

  defp non_empty(value) when is_binary(value) and value not in ["", "-"], do: value
  defp non_empty(_), do: nil

  defp load_manifest(dir) do
    path = Path.join(dir, EvidenceChain.manifest_file())

    with {:ok, bytes} <- read(path, "chain.json"),
         {:ok, doc} <- decode_json(bytes, "chain.json"),
         :ok <- manifest_shape(doc) do
      {:ok, doc}
    end
  end

  defp read(path, name) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, "#{name} unreadable: #{inspect(posix)}"}
    end
  end

  defp decode_json(bytes, name) do
    case JSON.decode(bytes) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, "#{name} undecodable: #{inspect(reason)}"}
    end
  end

  defp manifest_shape(doc) do
    cond do
      not is_map(doc) ->
        {:error, "chain.json is not an object"}

      doc["schema"] != EvidenceChain.schema() ->
        {:error, "chain.json schema #{inspect(doc["schema"])}"}

      doc["genesis"] != EvidenceChain.genesis() ->
        {:error, "chain.json genesis #{inspect(doc["genesis"])}"}

      not (is_binary(doc["link_root"]) and is_binary(doc["basis_root"]) and
               is_binary(doc["chain_id"])) ->
        {:error, "chain.json lacks chain_id/link_root/basis_root"}

      not is_list(doc["links"]) ->
        {:error, "chain.json links is not a list"}

      bad = Enum.find(doc["links"], &(not link_shape?(&1))) ->
        {:error, "chain.json malformed link #{inspect(bad, limit: 10)}"}

      true ->
        :ok
    end
  end

  defp link_shape?(%{} = link) do
    is_integer(link["seq"]) and link["kind"] in EvidenceChain.kinds() and
      is_binary(link["command_id"]) and is_binary(link["file"]) and
      Regex.match?(@file_pattern, link["file"]) and not String.contains?(link["file"], "..") and
      is_binary(link["sha256"]) and is_integer(link["bytes"]) and is_binary(link["prev"]) and
      is_binary(link["digest"])
  end

  defp link_shape?(_), do: false

  # --- integrity ------------------------------------------------------------------

  defp integrity_checks(dir, manifest, anchor) do
    links = manifest["links"]

    {missing, mismatched} =
      Enum.reduce(links, {[], []}, fn link, {missing, mismatched} ->
        path = Path.join(dir, link["file"])

        case File.stat(path) do
          {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_link_bytes ->
            bytes = File.read!(path)

            if EvidenceChain.sha256(bytes) == link["sha256"] and byte_size(bytes) == link["bytes"],
              do: {missing, mismatched},
              else: {missing, [describe(link) | mismatched]}

          {:ok, _too_large_or_not_regular} ->
            {missing, [describe(link) | mismatched]}

          {:error, _} ->
            {[describe(link) | missing], mismatched}
        end
      end)

    {broken, recomputed_root} =
      links
      |> Enum.with_index(1)
      |> Enum.reduce({[], EvidenceChain.genesis()}, fn {link, index}, {broken, prev} ->
        expected = EvidenceChain.link_digest(Map.put(link, "seq", index), prev)

        broken =
          if link["seq"] == index and link["prev"] == prev and link["digest"] == expected,
            do: broken,
            else: [describe(link) <> " at position #{index}" | broken]

        {broken, expected}
      end)

    length_ok? = manifest["length"] == length(links)

    checks = [
      check(
        "links_present",
        missing == [],
        :replay_receipt_missing,
        "absent link files: " <> Enum.join(Enum.reverse(missing), "; ")
      ),
      check(
        "link_digests",
        mismatched == [],
        :replay_digest_mismatch,
        "content digest/size mismatch: " <> Enum.join(Enum.reverse(mismatched), "; ")
      ),
      check(
        "link_chaining",
        broken == [] and length_ok?,
        :replay_link_broken,
        "links that do not chain: " <>
          Enum.join(Enum.reverse(broken), "; ") <>
          "; manifest length #{inspect(manifest["length"])} vs #{length(links)} links"
      ),
      check(
        "link_root",
        recomputed_root == manifest["link_root"],
        :replay_root_divergence,
        "recomputed link root #{recomputed_root}, manifest #{manifest["link_root"]}"
      )
    ]

    anchor_check =
      case anchor.link_root do
        nil ->
          []

        root ->
          [
            check(
              "anchor_link_root",
              root == recomputed_root,
              :replay_root_divergence,
              "anchored link root #{root}, recomputed #{recomputed_root}"
            )
          ]
      end

    {checks ++ anchor_check, recomputed_root}
  end

  defp describe(link), do: "##{link["seq"]} #{link["kind"]} #{link["file"]}"

  # --- decoding ---------------------------------------------------------------------

  defp decode_links(dir, manifest) do
    {links, errors} =
      Enum.reduce(manifest["links"], {[], []}, fn link, {links, errors} ->
        case decode_link(dir, link) do
          {:ok, decoded} -> {[decoded | links], errors}
          {:error, code, detail} -> {links, [{code, describe(link) <> ": " <> detail} | errors]}
        end
      end)

    case Enum.reverse(errors) do
      [] ->
        {:ok, Enum.reverse(links)}

      errors ->
        {:error,
         errors
         |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
         |> Enum.map(fn {code, details} ->
           failed("link_payloads", code, Enum.join(details, "; "))
         end)}
    end
  end

  defp decode_link(dir, %{"kind" => "post_state"} = link) do
    with {:ok, bytes} <- File.read(Path.join(dir, link["file"])),
         {:ok, %{"command_id" => command_id} = observation} when is_binary(command_id) <-
           JSON.decode(bytes) do
      bind(link, command_id, observation)
    else
      _ ->
        {:error, :replay_payload_undecodable, "not a post-state observation object"}
    end
  end

  defp decode_link(dir, %{"kind" => kind} = link) do
    with {:ok, bytes} <- File.read(Path.join(dir, link["file"])),
         {:ok, %Receipt{} = receipt} <- EvidenceChain.decode_receipt(bytes) do
      cond do
        kind == "prepared" and receipt.status != :pending ->
          {:error, :replay_payload_undecodable,
           "prepared link holds a #{inspect(receipt.status)} receipt, not a pending anchor"}

        true ->
          bind(link, id_value(receipt.command_id), receipt)
      end
    else
      _ -> {:error, :replay_payload_undecodable, "not a journal-format receipt"}
    end
  end

  defp bind(link, command_id, payload) do
    if command_id == link["command_id"] do
      {:ok, %{seq: link["seq"], kind: link["kind"], command_id: command_id, payload: payload}}
    else
      {:error, :replay_identity_divergence,
       "link names command #{link["command_id"]}, payload is #{inspect(command_id)}"}
    end
  end

  # --- reconstruction -----------------------------------------------------------

  @doc """
  Reconstructs the replay stages for every command in a decoded link list
  (`[%{seq, kind, command_id, payload}]`, chain order). Returns the records,
  the reconstruction failures and the `basis_root` over the records. Pure.
  """
  @spec reconstruct([map()]) :: %{
          records: [map()],
          failures: [map()],
          basis_root: String.t(),
          stages: non_neg_integer()
        }
  def reconstruct(links) when is_list(links) do
    finals = Enum.filter(links, &(&1.kind == "final"))

    groups =
      links
      |> Enum.group_by(& &1.command_id)
      |> Enum.sort_by(fn {_command_id, ls} -> ls |> Enum.map(& &1.seq) |> Enum.min() end)

    {records, failures} =
      Enum.map_reduce(groups, [], fn {command_id, ls}, acc ->
        {record, fs} = command_record(command_id, ls, finals)
        {record, acc ++ fs}
      end)

    failures = failures ++ duplicate_receipts(links) ++ duplicate_declared_actuations(groups)
    records = EvidenceChain.json_safe(records)

    %{
      records: records,
      failures: failures,
      basis_root: records |> EvidenceChain.canonical_json() |> EvidenceChain.sha256(),
      stages: Enum.reduce(records, 0, fn r, acc -> acc + Enum.count(@stages, &(r[&1] != nil)) end)
    }
  end

  defp command_record(command_id, links, finals) do
    by_kind = Enum.group_by(links, & &1.kind)
    prepared_link = first(by_kind["prepared"])
    final_link = first(by_kind["final"])
    post_link = first(by_kind["post_state"])
    prepared = prepared_link && prepared_link.payload
    final = final_link && final_link.payload
    post = post_link && post_link.payload
    dedup? = match?(%Receipt{metadata: %{outcome: :deduplicated}}, final)
    dedup_from = dedup? && Map.get(final.metadata, :deduplicated_from_receipt_id)

    final_basis =
      case final && Replay.basis(final) do
        {:ok, basis} -> basis
        _ -> nil
      end

    failures =
      [
        duplicate_kinds(command_id, by_kind),
        missing(command_id, prepared, final, post, dedup?),
        order(command_id, prepared_link, final_link, post_link),
        identity(command_id, prepared, final, dedup?),
        authority(command_id, prepared, final),
        basis(command_id, prepared, final),
        post_state(command_id, final, post, dedup?),
        dedup_reference(command_id, final_link, dedup_from, finals)
      ]
      |> List.flatten()

    record = %{
      "command_id" => command_id,
      "admission" =>
        final &&
          %{
            "consequence" => final.consequence,
            "input_digest" => final.input_digest,
            "fingerprint" => final.fingerprint,
            "anchored_before_do" => prepared != nil,
            "terminal_status" => final.terminal_status
          },
      "selection" => final_basis && final_basis.plan_selection,
      "construction" => final_basis && final_basis.construction,
      "authority_decision" => final_basis && final_basis.authorization,
      "prepared_receipt" =>
        cond do
          prepared ->
            %{
              "receipt_id" => id_value(prepared.receipt_id),
              "status" => prepared.status,
              "logical_clock" => prepared.logical_clock,
              "recorded_at" => prepared.recorded_at
            }

          dedup? ->
            %{
              "marker" => "not_prepared",
              "reason" => "deduplicated",
              "deduplicated_from" => dedup_from
            }

          true ->
            nil
        end,
      "intended_effect" => final_basis && final_basis.intended_effect,
      "final_receipt" =>
        final &&
          %{
            "receipt_id" => id_value(final.receipt_id),
            "status" => final.status,
            "terminal_status" => final.terminal_status,
            "standing" => final.standing,
            "replayed" => final.replayed?,
            "deduplicated_from" => dedup_from || nil,
            "logical_clock" => final.logical_clock,
            "reply_shape" => final_basis && final_basis.observed_outcome.reply_shape,
            "basis_digest" => final_basis && final_basis.basis_digest,
            "actuated_by_replay" => final_basis && final_basis.actuated?
          },
      "observed_post_state" => post
    }

    {record, failures}
  end

  defp first([x | _]), do: x
  defp first(_), do: nil

  defp fail(code, command_id, detail),
    do: %{"reason" => Atom.to_string(code), "command_id" => command_id, "detail" => detail}

  defp duplicate_kinds(command_id, by_kind) do
    for {kind, [_, _ | _] = xs} <- by_kind do
      fail(
        :replay_duplicate_actuation,
        command_id,
        "command carries #{length(xs)} #{kind} links (replayed identity)"
      )
    end
  end

  defp missing(command_id, prepared, final, post, dedup?) do
    [
      final == nil && fail(:replay_receipt_missing, command_id, "no final receipt"),
      match?(%Receipt{status: :pending}, final) &&
        fail(
          :replay_receipt_missing,
          command_id,
          "final link holds a pending receipt: the observed outcome is not recorded"
        ),
      post == nil && fail(:replay_receipt_missing, command_id, "no post-state observation"),
      (prepared == nil and not dedup? and consequence_crossed_do?(final)) &&
        fail(
          :replay_receipt_missing,
          command_id,
          "no prepared anchor for a #{final.consequence} consequence that reached #{inspect(final.terminal_status)}"
        )
    ]
    |> Enum.filter(&is_map/1)
  end

  defp consequence_crossed_do?(%Receipt{consequence: c, terminal_status: t})
       when c in [:change, :external_do],
       do: t != :refused

  defp consequence_crossed_do?(_), do: false

  defp order(command_id, prepared_link, final_link, post_link) do
    seqs = Enum.reject([prepared_link, final_link, post_link], &is_nil/1) |> Enum.map(& &1.seq)

    clock_ok? =
      case {prepared_link, final_link} do
        {%{payload: %Receipt{logical_clock: p}}, %{payload: %Receipt{logical_clock: f}}}
        when is_integer(p) ->
          is_integer(f) and p < f

        _ ->
          true
      end

    cond do
      seqs != Enum.sort(seqs) ->
        [
          fail(
            :replay_receipt_order_violation,
            command_id,
            "stages out of chain order (prepared -> final -> post_state): seqs #{inspect(seqs)}"
          )
        ]

      not clock_ok? ->
        [
          fail(
            :replay_receipt_order_violation,
            command_id,
            "prepared logical clock #{prepared_link.payload.logical_clock} is not before final #{final_link.payload.logical_clock}"
          )
        ]

      true ->
        []
    end
  end

  defp identity(_command_id, nil, _final, _dedup?), do: []
  defp identity(_command_id, _prepared, nil, _dedup?), do: []

  defp identity(command_id, _prepared, _final, true),
    do: [
      fail(
        :replay_identity_divergence,
        command_id,
        "a deduplicated receipt cannot have a prepared anchor"
      )
    ]

  defp identity(command_id, %Receipt{} = prepared, %Receipt{} = final, false) do
    case Enum.reject(@identity_fields, &(Map.fetch!(prepared, &1) == Map.fetch!(final, &1))) do
      [] ->
        []

      fields ->
        [
          fail(
            :replay_identity_divergence,
            command_id,
            "final receipt does not preserve the prepared anchor's " <> Enum.join(fields, ", ")
          )
        ]
    end
  end

  defp authority(command_id, prepared, final) do
    divergence =
      case {prepared, final} do
        {%Receipt{authority_grant: a}, %Receipt{authority_grant: b}} when a != b ->
          [
            fail(
              :replay_authority_divergence,
              command_id,
              "prepared and final authority grants differ in " <>
                Enum.join(differing_keys(a, b), ", ")
            )
          ]

        _ ->
          []
      end

    divergence ++ grant_binding(command_id, prepared) ++ grant_binding(command_id, final)
  end

  defp differing_keys(a, b) when is_map(a) and is_map(b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(a, &1) == Map.get(b, &1)))
    |> Enum.map(&to_string/1)
  end

  defp differing_keys(_a, _b), do: ["grant"]

  defp grant_binding(command_id, %Receipt{consequence: c, terminal_status: t} = receipt)
       when c in [:change, :external_do] and t != :refused do
    grant = receipt.authority_grant
    actor = receipt.actor && Identity.external(receipt.actor)

    cond do
      not is_map(grant) ->
        [
          fail(
            :replay_authority_divergence,
            command_id,
            "#{receipt.status} #{c} receipt carries no authority grant"
          )
        ]

      Map.get(grant, :subject) != actor or Map.get(grant, :capability_id) != receipt.capability_id ->
        [
          fail(
            :replay_authority_divergence,
            command_id,
            "#{receipt.status} receipt grant names #{inspect(Map.get(grant, :subject))} / #{inspect(Map.get(grant, :capability_id))}, receipt actor #{inspect(actor)} / #{inspect(receipt.capability_id)}"
          )
        ]

      true ->
        []
    end
  end

  defp grant_binding(_command_id, _receipt), do: []

  defp basis(command_id, prepared, final) do
    for %Receipt{} = receipt <- [prepared, final],
        {:error, %{code: code, detail: detail}} <- [Replay.basis(receipt)] do
      fail(:replay_basis_refused, command_id, "#{receipt.status} receipt: #{code}: #{detail}")
    end
  end

  defp post_state(_command_id, nil, _post, _dedup?), do: []
  defp post_state(_command_id, _final, nil, _dedup?), do: []

  defp post_state(command_id, %Receipt{} = final, %{} = post, dedup?) do
    bound? =
      post["receipt_id"] == id_value(final.receipt_id) and
        post["actuation_id"] == id_value(final.actuation_id)

    rows = post["rows"]

    cond do
      not bound? ->
        [
          fail(
            :replay_post_state_unbound,
            command_id,
            "observation names receipt #{inspect(post["receipt_id"])} / actuation #{inspect(post["actuation_id"])}"
          )
        ]

      not (is_integer(rows) and rows >= 0) ->
        [fail(:replay_post_state_unbound, command_id, "observation rows #{inspect(rows)}")]

      final.terminal_status == :executed and not dedup? and rows < 1 ->
        [
          fail(
            :replay_post_state_unbound,
            command_id,
            "executed receipt contradicted by an independent observation of #{rows} rows"
          )
        ]

      true ->
        []
    end
  end

  defp dedup_reference(_command_id, _final_link, false, _finals), do: []

  defp dedup_reference(command_id, final_link, from, finals) do
    prior =
      Enum.find(finals, fn link ->
        link.seq != final_link.seq and Identity.external(link.payload.receipt_id) == from
      end)

    cond do
      prior == nil ->
        [
          fail(
            :replay_receipt_missing,
            command_id,
            "deduplicated from receipt #{inspect(from)}, which the chain does not carry"
          )
        ]

      prior.seq > final_link.seq ->
        [
          fail(
            :replay_receipt_order_violation,
            command_id,
            "deduplicated receipt precedes its prior receipt #{from}"
          )
        ]

      prior.payload.actuation_id != final_link.payload.actuation_id ->
        [
          fail(
            :replay_identity_divergence,
            command_id,
            "deduplicated receipt names a different actuation than its prior #{from}"
          )
        ]

      true ->
        []
    end
  end

  defp duplicate_receipts(links) do
    for kind <- ["prepared", "final"],
        {receipt_id, [_, _ | _] = xs} <-
          links
          |> Enum.filter(&(&1.kind == kind))
          |> Enum.group_by(&id_value(&1.payload.receipt_id)),
        MapSet.size(MapSet.new(xs, & &1.command_id)) > 1 do
      fail(
        :replay_duplicate_actuation,
        Enum.map_join(xs, ",", & &1.command_id),
        "#{kind} receipt #{receipt_id} appears under #{length(xs)} commands"
      )
    end
  end

  # A declared idempotent effect (an external token, so the idempotency key is
  # not the effect digest) crossed the consequence boundary -- prepared anchor
  # plus executed, non-deduplicated final -- under more than one command.
  defp duplicate_declared_actuations(groups) do
    groups
    |> Enum.flat_map(fn {command_id, ls} ->
      by_kind = Enum.group_by(ls, & &1.kind)
      prepared = first(by_kind["prepared"])
      final = first(by_kind["final"])

      with %{payload: %Receipt{}} <- prepared,
           %{payload: %Receipt{terminal_status: :executed} = receipt} <- final,
           false <- match?(%{metadata: %{outcome: :deduplicated}}, receipt),
           true <- declared?(receipt) do
        [{id_value(receipt.actuation_id), command_id}]
      else
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {actuation_id, [_, _ | _] = commands} ->
        [
          fail(
            :replay_duplicate_actuation,
            Enum.join(commands, ","),
            "declared actuation #{actuation_id} crossed the consequence boundary under #{length(commands)} commands"
          )
        ]

      _ ->
        []
    end)
  end

  defp declared?(%Receipt{
         actuation_id: %Identity{value: a},
         idempotency_key: %Identity{value: i}
       }),
       do: a != i

  defp declared?(_), do: false

  @reconstruction_checks [
    {"reconstruction_complete", :replay_receipt_missing},
    {"reconstruction_order", :replay_receipt_order_violation},
    {"reconstruction_identity", :replay_identity_divergence},
    {"reconstruction_authority", :replay_authority_divergence},
    {"reconstruction_actuation_unique", :replay_duplicate_actuation},
    {"reconstruction_basis", :replay_basis_refused},
    {"reconstruction_post_state", :replay_post_state_unbound}
  ]

  defp reconstruction_checks(%{failures: failures}) do
    for {name, code} <- @reconstruction_checks do
      reason = Atom.to_string(code)
      hits = Enum.filter(failures, &(&1["reason"] == reason))

      check(
        name,
        hits == [],
        code,
        Enum.map_join(hits, "; ", &"#{&1["command_id"]}: #{&1["detail"]}")
      )
    end
  end

  defp basis_root_checks(manifest, rec, anchor) do
    [
      check(
        "basis_root",
        rec.basis_root == manifest["basis_root"],
        :replay_root_divergence,
        "reconstructed basis root #{rec.basis_root}, manifest #{manifest["basis_root"]}"
      )
    ] ++
      case anchor.basis_root do
        nil ->
          []

        root ->
          [
            check(
              "anchor_basis_root",
              root == rec.basis_root,
              :replay_root_divergence,
              "anchored basis root #{root}, reconstructed #{rec.basis_root}"
            )
          ]
      end
  end

  defp finish(dir, manifest, checks, rec, anchor, recomputed_link_root) do
    failures = Enum.reject(checks, & &1["ok"])
    manifest = manifest || %{}

    %{
      "schema" => @schema,
      "outcome" => if(failures == [], do: "verified", else: "refused"),
      "reasons" => failures |> Enum.map(& &1["reason"]) |> Enum.uniq(),
      "checks" => checks,
      "chain" => %{
        "dir" => dir,
        "chain_ref" => EvidenceChain.chain_ref(dir),
        "chain_id" => manifest["chain_id"],
        "length" => length(List.wrap(manifest["links"])),
        "evidence_bytes" => EvidenceChain.evidence_bytes(dir, manifest),
        "link_root" => manifest["link_root"],
        "basis_root" => manifest["basis_root"],
        "reconstructed_link_root" => recomputed_link_root,
        "reconstructed_basis_root" => rec && rec.basis_root
      },
      "anchor" => %{
        "link_root" => anchor.link_root != nil,
        "basis_root" => anchor.basis_root != nil
      },
      "reconstruction" =>
        if rec do
          %{
            "commands" => length(rec.records),
            "stages_reconstructed" => rec.stages,
            "stages_expected" => length(rec.records) * length(@stages),
            "records" => rec.records
          }
        else
          nil
        end
    }
  end

  defp check(name, true, _code, _detail), do: %{"check" => name, "ok" => true}
  defp check(name, _false, code, detail), do: failed(name, code, detail)

  defp failed(name, code, detail),
    do: %{"check" => name, "ok" => false, "reason" => Atom.to_string(code), "detail" => detail}

  defp id_value(%Identity{value: value}), do: value
  defp id_value(value), do: value

  # --- in-VM acceptance boundary --------------------------------------------------

  @doc """
  Runs `verify_chain/2` in a newly spawned BEAM process (it receives only the
  chain directory and anchor options) and emits `[:ash_a2a, :replay,
  :verified]` with `mode: :in_vm`. Always returns `{:ok, verdict}`.
  """
  @spec replay(Path.t(), keyword()) :: {:ok, map()}
  def replay(dir, opts \\ []) when is_binary(dir) do
    dir = Path.expand(dir)
    anchor_opts = Keyword.take(opts, [:link_root, :basis_root])
    started = System.monotonic_time(:microsecond)
    parent = self()
    ref = make_ref()
    callers = [parent | List.wrap(Process.get(:"$callers"))]

    {pid, monitor} =
      spawn_monitor(fn ->
        # Caller lineage only (the Task convention), so telemetry emitted by
        # the verifier is attributable to whoever asked for the replay.
        Process.put(:"$callers", callers)
        t0 = System.monotonic_time(:microsecond)
        verdict = safe_verify(dir, anchor_opts)
        verify_us = System.monotonic_time(:microsecond) - t0
        {:memory, memory} = Process.info(self(), :memory)
        send(parent, {ref, verdict, verify_us, memory})
      end)

    sampler = start_sampler(fn -> process_memory(pid) end)

    {verdict, verify_us, final_memory} =
      receive do
        {^ref, verdict, verify_us, memory} ->
          {verdict, verify_us, memory}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {crash_verdict(dir, "replay process exited: #{inspect(reason)}"), nil, 0}
      after
        Keyword.get(opts, :timeout_ms, 300_000) ->
          Process.exit(pid, :kill)
          {crash_verdict(dir, "replay process timed out"), nil, 0}
      end

    Process.demonitor(monitor, [:flush])
    peak = max(stop_sampler(sampler), final_memory)

    verdict =
      verdict
      |> Map.put("mode", "in_vm")
      |> Map.put("fresh_process_accepted", false)
      |> Map.put("measurements", %{
        "verify_us" => verify_us,
        "total_us" => System.monotonic_time(:microsecond) - started,
        "peak_verifier_bytes" => peak
      })

    emit(verdict, Keyword.get(opts, :producer))
    {:ok, verdict}
  end

  defp safe_verify(dir, opts) do
    verify_chain(dir, opts)
  rescue
    exception -> crash_verdict(dir, Exception.format(:error, exception, __STACKTRACE__))
  catch
    kind, reason -> crash_verdict(dir, "#{kind}: #{inspect(reason)}")
  end

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, memory} -> memory
      nil -> 0
    end
  end

  defp start_sampler(read) do
    spawn(fn -> sample(read, read.()) end)
  end

  defp sample(read, peak) do
    receive do
      {:stop, from, ref} -> send(from, {ref, max(peak, read.())})
    after
      1 -> sample(read, max(peak, read.()))
    end
  end

  defp stop_sampler(sampler) do
    ref = make_ref()
    send(sampler, {:stop, self(), ref})

    receive do
      {^ref, peak} -> peak
    after
      5_000 -> 0
    end
  end

  defp crash_verdict(dir, detail) do
    %{
      "schema" => @schema,
      "outcome" => "refused",
      "reasons" => ["replay_crashed"],
      "checks" => [failed("replay", :replay_crashed, detail)],
      "chain" => %{"dir" => dir, "chain_ref" => EvidenceChain.chain_ref(dir)},
      "anchor" => %{},
      "reconstruction" => nil
    }
  end

  # --- fresh OS process ---------------------------------------------------------

  @doc """
  Entry point of the fresh OS process: `main([dir, link_root, basis_root])`
  (`"-"` for no anchor) verifies the chain and prints exactly one marker line
  carrying the canonical JSON verdict plus this process's facts and
  measurements. Never raises.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    entered_os_us = System.os_time(:microsecond)
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    baseline = :erlang.memory(:total)
    sampler = start_sampler(fn -> :erlang.memory(:total) end)
    t0 = System.monotonic_time(:microsecond)

    verdict =
      case argv do
        [dir, link_root, basis_root] ->
          safe_verify(dir, link_root: link_root, basis_root: basis_root)

        other ->
          crash_verdict("", "usage: main([dir, link_root, basis_root]), got #{inspect(other)}")
      end

    verify_us = System.monotonic_time(:microsecond) - t0
    peak = stop_sampler(sampler)

    verdict
    |> Map.put("process", process_facts())
    |> Map.put("child_measurements", %{
      "main_entered_os_us" => entered_os_us,
      "vm_uptime_at_main_ms" => uptime_ms,
      "verify_us" => verify_us,
      "baseline_vm_total_bytes" => baseline,
      "peak_vm_total_bytes" => peak
    })
    |> EvidenceChain.canonical_json()
    |> then(&IO.puts(@marker <> &1))
  end

  defp process_facts do
    started =
      Application.started_applications()
      |> Enum.map(&Atom.to_string(elem(&1, 0)))
      |> Enum.sort()

    %{
      "os_pid" => System.pid(),
      "ash_a2a_started" => "ash_a2a" in started,
      "do_boundary_loaded" => Enum.any?(@do_boundary, &:erlang.module_loaded/1),
      "started_applications" => started
    }
  end

  @doc """
  Verifies `dir` in a genuinely fresh `elixir` OS process and accepts (or
  refuses) its verdict; emits `[:ash_a2a, :replay, :verified]` with
  `mode: :fresh_os_process`. Always returns `{:ok, verdict}`.

  Options: `:link_root`, `:basis_root` (anchor), `:producer` (pid or pids,
  recorded as `producer_terminated`), `:timeout_ms` (default 180_000),
  `:elixir` (executable), `:code_paths` (ebin directories).
  """
  @spec verify_fresh(Path.t(), keyword()) :: {:ok, map()}
  def verify_fresh(dir, opts \\ []) when is_binary(dir) do
    dir = Path.expand(dir)
    started = System.monotonic_time(:microsecond)
    spawn_os_us = System.os_time(:microsecond)

    verdict =
      case spawn_fresh(dir, opts) do
        {:ok, child} -> accept(child, dir, spawn_os_us)
        {:error, reason, output} -> local_refusal(dir, [reason], output, nil)
      end

    measurements =
      Map.merge(verdict["measurements"] || %{}, %{
        "total_us" => System.monotonic_time(:microsecond) - started
      })

    verdict =
      verdict
      |> Map.put("mode", "fresh_os_process")
      |> Map.put("measurements", measurements)

    emit(verdict, Keyword.get(opts, :producer))
    {:ok, verdict}
  end

  defp spawn_fresh(dir, opts) do
    with {:ok, elixir} <- elixir_executable(opts),
         {:ok, paths} <- code_paths(opts) do
      args =
        Enum.flat_map(paths, &["-pa", &1]) ++
          [
            "-e",
            "AshA2A.Receipt.OfflineReplay.main(System.argv())",
            "--",
            dir,
            Keyword.get(opts, :link_root) || "-",
            Keyword.get(opts, :basis_root) || "-"
          ]

      port =
        Port.open({:spawn_executable, elixir}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: args,
          cd: System.tmp_dir!(),
          env: Enum.map(@scrubbed_env, &{String.to_charlist(&1), false})
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 180_000)
      collect(port, os_pid, [], 0, deadline)
    end
  rescue
    exception ->
      {:error, "replay_fresh_process_unavailable:spawn_failed", Exception.message(exception)}
  end

  defp collect(port, os_pid, acc, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @max_output ->
        collect(port, os_pid, [acc, data], size + byte_size(data), deadline)

      {^port, {:data, _data}} ->
        collect(port, os_pid, acc, size, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), exit_status: status, os_pid: os_pid}}
    after
      remaining ->
        if os_pid, do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])

        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:error, "replay_crashed:fresh_process_timeout", IO.iodata_to_binary(acc)}
    end
  end

  defp elixir_executable(opts) do
    case Keyword.get_lazy(opts, :elixir, fn -> System.find_executable("elixir") end) do
      nil -> {:error, "replay_fresh_process_unavailable:elixir_not_found", ""}
      path -> {:ok, path}
    end
  end

  defp code_paths(opts) do
    case Keyword.fetch(opts, :code_paths) do
      {:ok, paths} ->
        {:ok, paths}

      :error ->
        with path when is_list(path) <- :code.which(__MODULE__),
             lib = path |> List.to_string() |> Path.dirname() |> Path.dirname() |> Path.dirname(),
             [_ | _] = paths <- Path.wildcard(Path.join(lib, "*/ebin")) do
          {:ok, Enum.sort(paths)}
        else
          _ -> {:error, "replay_fresh_process_unavailable:code_path", ""}
        end
    end
  end

  defp accept(%{output: output, exit_status: status, os_pid: os_pid}, dir, spawn_os_us) do
    with {:ok, json} <- marker_line(output),
         {:ok, %{"schema" => @schema, "outcome" => outcome} = verdict}
         when outcome in ["verified", "refused"] <- JSON.decode(json) do
      child = %{"os_pid" => os_pid, "exit_status" => status}
      child_m = verdict["child_measurements"] || %{}

      measurements = %{
        "verify_us" => child_m["verify_us"],
        "startup_us" =>
          is_integer(child_m["main_entered_os_us"]) &&
            child_m["main_entered_os_us"] - spawn_os_us,
        "vm_uptime_at_main_ms" => child_m["vm_uptime_at_main_ms"],
        "peak_vm_total_bytes" => child_m["peak_vm_total_bytes"],
        "baseline_vm_total_bytes" => child_m["baseline_vm_total_bytes"]
      }

      verdict = verdict |> Map.put("child", child) |> Map.put("measurements", measurements)

      case local_acceptance(verdict, os_pid, status) do
        [] ->
          Map.put(verdict, "fresh_process_accepted", true)

        reasons ->
          verdict
          |> Map.put("outcome", "refused")
          |> Map.put("reasons", reasons ++ List.wrap(verdict["reasons"]))
          |> Map.put("fresh_process_accepted", false)
      end
    else
      _ ->
        local_refusal(dir, ["replay_crashed:no_verdict"], output, %{
          "os_pid" => os_pid,
          "exit_status" => status
        })
    end
  end

  defp marker_line(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, @marker))
    |> List.last()
    |> case do
      nil -> :error
      line -> {:ok, String.replace_prefix(line, @marker, "")}
    end
  end

  defp local_acceptance(verdict, os_pid, status) do
    process = verdict["process"] || %{}

    [
      status != 0 && "replay_process_not_fresh:exit_status:#{status}",
      process["os_pid"] == System.pid() && "replay_process_not_fresh:producer_os_pid",
      (os_pid == nil or process["os_pid"] != Integer.to_string(os_pid)) &&
        "replay_process_not_fresh:os_pid_unbound",
      process["ash_a2a_started"] != false && "replay_process_not_fresh:ash_a2a_started",
      process["do_boundary_loaded"] != false && "replay_consequence_boundary_loaded"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp local_refusal(dir, reasons, output, child) do
    %{
      "schema" => @schema,
      "outcome" => "refused",
      "reasons" => reasons,
      "checks" => [],
      "chain" => %{"dir" => dir, "chain_ref" => EvidenceChain.chain_ref(dir)},
      "anchor" => %{},
      "reconstruction" => nil,
      "child" => child,
      "fresh_process_accepted" => false,
      "output_tail" => output |> to_string() |> String.slice(-2_000, 2_000)
    }
  end

  # --- boundary telemetry -----------------------------------------------------------

  defp emit(verdict, producer) do
    chain = verdict["chain"] || %{}
    reconstruction = verdict["reconstruction"] || %{}
    measurements = verdict["measurements"] || %{}
    anchor = verdict["anchor"] || %{}

    :telemetry.execute(
      @event,
      %{
        system_time: System.system_time(),
        verify_us: measurements["verify_us"],
        total_us: measurements["total_us"],
        startup_us: measurements["startup_us"],
        peak_memory_bytes:
          measurements["peak_vm_total_bytes"] || measurements["peak_verifier_bytes"]
      },
      %{
        outcome: if(verdict["outcome"] == "verified", do: :verified, else: :refused),
        mode: if(verdict["mode"] == "in_vm", do: :in_vm, else: :fresh_os_process),
        reasons: verdict |> Map.get("reasons") |> List.wrap() |> Enum.join(";"),
        chain_ref: chain["chain_ref"],
        chain_id: chain["chain_id"],
        length: chain["length"],
        evidence_bytes: chain["evidence_bytes"],
        commands: reconstruction["commands"],
        stages_reconstructed: reconstruction["stages_reconstructed"],
        stages_expected: reconstruction["stages_expected"],
        anchored: anchor["link_root"] == true or anchor["basis_root"] == true,
        fresh_process: verdict["fresh_process_accepted"] == true,
        do_boundary_loaded: get_in(verdict, ["process", "do_boundary_loaded"]),
        child_os_pid: get_in(verdict, ["child", "os_pid"]),
        producer_terminated: producer_terminated(producer)
      }
    )
  end

  defp producer_terminated(nil), do: nil
  defp producer_terminated(pid) when is_pid(pid), do: not Process.alive?(pid)

  defp producer_terminated(pids) when is_list(pids),
    do: Enum.all?(pids, &(not Process.alive?(&1)))
end
