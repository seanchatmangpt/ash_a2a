# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Security.DLPFilter do
  @moduledoc """
  Inline bidirectional DLP for A2A payloads (PRD FR-02.1 / FR-02.2).

  Walks inbound task parameters and outbound results, detects sensitive
  spans, and replaces each with a deterministic, reversible pseudonym
  (`AshA2A.Security.DLP.Pseudonym`):

    * PCI-DSS PAN -- digit runs validated by Luhn (`AshA2A.Security.DLP.Luhn`)
    * US SSN -- with invalid-area rejection (000/666/9xx areas, 00 group, 0000 serial)
    * high-entropy API keys -- Shannon entropy scoring (`AshA2A.Security.DLP.Entropy`)
    * PHI entities -- configurable pattern set (defaults: MRN, patient/member id)

  ## API

      {redacted, findings} = AshA2A.Security.DLPFilter.redact(payload, key: key)
      restored = AshA2A.Security.DLPFilter.restore(redacted, key: key)

  `findings` entries are `%{type: :pan | :ssn | :api_key | :phi, token: token,
  span: {offset, length}}` (plus `:pattern` for PHI) and never carry the
  matched plaintext, so they are safe to keep, count, or emit.

  ## Wire integration (FR-02.1)

  `AshA2A.Security.DLPFilter.Plug` wraps any inner transport plug and
  redacts both directions: the JSON-RPC `params` of the request body and the
  JSON response body. Wiring point once lane V4-14's pipeline chain lands:
  its step 4 (after `AuthZEN.DecisionGate`, before `FinOps.BudgetCeiling`)
  should call `redact/2` on inbound `params` and outbound results; until
  then the plug is the integration surface:

      forward "/a2a", AshA2A.Security.DLPFilter.Plug,
        inner: AshA2A.A2ATransport.Plug,
        agent: MyAgent,
        dlp: [key: Application.fetch_env!(:ash_a2a, ...)]

  ## Configuration

      config :ash_a2a, AshA2A.Security.DLPFilter,
        key: <at least 16 bytes of secret>,       # never logged
        entropy_floor: 3.5,                        # bits/char for API keys
        phi_patterns: [%{id: :mrn, pattern: ~r/.../}, ...],  # or regex strings
        enabled: true

  `:key` falls back to an ephemeral per-VM key (generated once, cached in
  `:persistent_term`, a warning is logged once -- the key itself is never
  logged); ephemeral-key pseudonyms are stable within the VM lifetime only.

  Redaction is idempotent: the filter never re-tokenizes its own `dlt1_`
  tokens, so a tokenized payload can be re-inspected safely.

  Telemetry: `[:ash_a2a, :security, :dlp]` with `%{duration_ms, findings}`
  measurements and `%{types}` count metadata (no plaintext, no keys).
  """

  alias AshA2A.Security.DLP.{Entropy, Luhn, Pseudonym}

  require Logger

  @typedoc "A detection/redaction finding (no plaintext)."
  @type finding :: %{
          required(:type) => :pan | :ssn | :api_key | :phi,
          required(:token) => String.t(),
          required(:span) => {non_neg_integer, pos_integer},
          optional(:pattern) => atom | String.t()
        }

  @default_entropy_floor 3.5

  @default_phi_patterns [
    %{id: :mrn, pattern: ~r/(?i)\bMRN[:#\s]*[A-Z0-9][A-Z0-9-]{5,}/},
    %{
      id: :patient_id,
      pattern: ~r/(?i)\b(?:patient|member)[\s_-]*(?:id|no|number)[:#\s]*[A-Z0-9][A-Z0-9-]{5,}/
    }
  ]

  @pan ~r/(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/
  @ssn ~r/(?<![\d-])(?!000|666|9\d\d)\d{3}-\d{2}-\d{4}(?![\d-])/
  @entropy_candidate ~r/[A-Za-z][A-Za-z0-9_\-+=\/]{19,}/
  @token_scan ~r/dlt1_[A-Za-z0-9_\-]+/

  @doc """
  Redacts every sensitive span in `term` (map/list/tuple/binary tree).

  Returns `{redacted_term, findings}`. Map keys are structural and are not
  redacted; only values are inspected.
  """
  @spec redact(term, keyword) :: {term, [finding]}
  def redact(term, opts \\ []) do
    cfg = config(opts)

    if cfg.enabled do
      started = System.monotonic_time()
      {term, nested} = walk_redact(term, cfg, [])
      findings = List.flatten(nested)
      duration = System.monotonic_time() - started

      :telemetry.execute(
        [:ash_a2a, :security, :dlp],
        %{duration_ns: duration, findings: length(findings)},
        %{types: type_counts(findings)}
      )

      {term, findings}
    else
      {term, []}
    end
  end

  @doc """
  Redacts a single binary. Returns `{redacted, findings}`.
  """
  @spec redact_string(String.t(), keyword) :: {String.t(), [finding]}
  def redact_string(binary, opts \\ []) when is_binary(binary) do
    cfg = config(opts)

    if cfg.enabled do
      redact_binary(binary, cfg)
    else
      {binary, []}
    end
  end

  @doc """
  Reverses `redact/2` (and `redact_string/2`) with the same key. Tokens that
  fail authenticated decryption (wrong key) are left in place.
  """
  @spec restore(term, keyword) :: term
  def restore(term, opts \\ []) do
    cfg = config(opts)
    if cfg.enabled, do: walk_restore(term, cfg), else: term
  end

  @doc """
  Reverses a single redacted binary with the key from `opts`.
  """
  @spec restore_string(String.t(), keyword) :: String.t()
  def restore_string(binary, opts \\ []) when is_binary(binary) do
    cfg = config(opts)
    if cfg.enabled, do: restore_binary(binary, cfg), else: binary
  end

  @doc """
  The default PHI pattern set (MRN, patient/member id).
  """
  @spec default_phi_patterns() :: list
  def default_phi_patterns, do: @default_phi_patterns

  # -- redaction ------------------------------------------------------------

  defp walk_redact(binary, cfg, findings) when is_binary(binary) do
    {redacted, found} = redact_binary(binary, cfg)
    {redacted, [found | findings]}
  end

  defp walk_redact(map, cfg, findings) when is_map(map) do
    {entries, findings} =
      Enum.reduce(map, {[], findings}, fn {k, v}, {acc, fs} ->
        {v, fs} = walk_redact(v, cfg, fs)
        {[{k, v} | acc], fs}
      end)

    {Map.new(entries), findings}
  end

  defp walk_redact(list, cfg, findings) when is_list(list) do
    {list, findings} =
      list
      |> Enum.reverse()
      |> Enum.reduce({[], findings}, fn item, {acc, fs} ->
        {item, fs} = walk_redact(item, cfg, fs)
        {[item | acc], fs}
      end)

    {list, findings}
  end

  defp walk_redact(tuple, cfg, findings) when is_tuple(tuple) do
    {values, findings} = walk_redact(Tuple.to_list(tuple), cfg, findings)
    {List.to_tuple(values), findings}
  end

  defp walk_redact(other, _cfg, findings), do: {other, findings}

  defp redact_binary(binary, cfg) do
    case spans(binary, cfg) do
      [] ->
        {binary, []}

      spans ->
        spans = Enum.sort_by(spans, fn %{span: {start, _}} -> start end)

        {rev_parts, rev_findings, offset} =
          Enum.reduce(spans, {[], [], 0}, fn finding, {parts, fs, off} ->
            {start, len} = finding.span
            plain = binary_part(binary, start, len)
            token = Pseudonym.token(plain, finding.type, cfg.key, Map.get(finding, :pattern, ""))
            finding = Map.put(finding, :token, token)

            chunk = if start == off, do: "", else: binary_part(binary, off, start - off)

            {
              [token, chunk | parts],
              [finding | fs],
              start + len
            }
          end)

        tail = binary_part(binary, offset, byte_size(binary) - offset)

        redacted = IO.iodata_to_binary(Enum.reverse([tail | rev_parts]))
        findings = Enum.reverse(rev_findings)

        {redacted, findings}
    end
  end

  # -- restoration ----------------------------------------------------------

  defp walk_restore(binary, cfg) when is_binary(binary), do: restore_binary(binary, cfg)

  defp walk_restore(map, cfg) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, walk_restore(v, cfg)} end)

  defp walk_restore(list, cfg) when is_list(list),
    do: for(item <- list, do: walk_restore(item, cfg))

  defp walk_restore(tuple, cfg) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&walk_restore(&1, cfg)) |> List.to_tuple()

  defp walk_restore(other, _cfg), do: other

  defp restore_binary(binary, cfg) do
    matches =
      @token_scan
      |> Regex.scan(binary, return: :index)
      |> List.flatten()
      |> Enum.sort_by(fn {start, _} -> start end)

    {rev_parts, offset} =
      Enum.reduce(matches, {[], 0}, fn {start, len}, {parts, off} ->
        token = binary_part(binary, start, len)

        case Pseudonym.reveal(token, cfg.key) do
          {:ok, plain, _type} ->
            chunk = if start == off, do: "", else: binary_part(binary, off, start - off)
            {[plain, chunk | parts], start + len}

          :error ->
            {parts, off}
        end
      end)

    if offset == 0 do
      binary
    else
      tail = binary_part(binary, offset, byte_size(binary) - offset)
      IO.iodata_to_binary(Enum.reverse([tail | rev_parts]))
    end
  end

  # -- detection ------------------------------------------------------------

  # Inspection is chunked: payloads larger than one chunk are partitioned
  # into owned windows (+ an overlap tail so a match is only ever missed if
  # a single sensitive run exceeds @chunk_overlap bytes) and scanned in
  # parallel across schedulers. This is what keeps FR-02's <= 2.5ms/64KB
  # budget: per-chunk scan cost is bounded and scales out with cores.
  @chunk_size 4096
  @chunk_overlap 1024

  defp spans(binary, cfg) do
    ranges = chunk_ranges(byte_size(binary))
    size = byte_size(binary)

    results =
      if ranges == [{0, size}] do
        Enum.map(ranges, &scan_chunk(binary, &1, cfg, size))
      else
        ranges
        |> Task.async_stream(&scan_chunk(binary, &1, cfg, size),
          max_concurrency: System.schedulers_online(),
          timeout: 30_000,
          ordered: true
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end

    {pans, ssns, phis, keys} =
      Enum.reduce(results, {[], [], [], []}, fn {p, s, ph, k}, {ap, as, aph, ak} ->
        {ap ++ p, as ++ s, aph ++ ph, ak ++ k}
      end)

    [pans, ssns, phis, keys]
    |> claim_non_overlapping()
    |> Enum.sort_by(fn %{span: {start, _}} -> start end)
  end

  defp chunk_ranges(size) when size <= @chunk_size, do: [{0, size}]

  defp chunk_ranges(size) do
    for start <- 0..(size - 1)//@chunk_size do
      owned_end = min(start + @chunk_size, size)
      {start, min(owned_end + @chunk_overlap, size) - start}
    end
  end

  defp scan_chunk(binary, {offset, scan_len}, cfg, size) do
    text = binary_part(binary, offset, scan_len)
    owned_end = min(offset + @chunk_size, size)

    local =
      [
        pan_spans(text),
        ssn_spans(text),
        phi_spans(text, cfg.phi_patterns),
        api_key_spans(text, cfg.entropy_floor)
      ]

    kept =
      local
      |> claim_non_overlapping()
      |> Enum.filter(fn %{span: {start, _}} -> offset + start < owned_end end)
      |> Enum.map(fn %{span: {start, len}} = finding ->
        %{finding | span: {offset + start, len}}
      end)

    {
      Enum.filter(kept, &(&1.type == :pan)),
      Enum.filter(kept, &(&1.type == :ssn)),
      Enum.filter(kept, &(&1.type == :phi)),
      Enum.filter(kept, &(&1.type == :api_key))
    }
  end

  defp pan_spans(binary) do
    @pan
    |> Regex.scan(binary, return: :index)
    |> List.flatten()
    |> Enum.flat_map(fn {start, len} ->
      matched = binary_part(binary, start, len)
      digits = String.replace(matched, [" ", "-"], "")

      if byte_size(digits) in 13..19 and Luhn.valid?(digits) do
        [%{type: :pan, span: {start, len}}]
      else
        []
      end
    end)
  end

  defp ssn_spans(binary) do
    @ssn
    |> Regex.scan(binary, return: :index)
    |> List.flatten()
    |> Enum.map(&%{type: :ssn, span: &1})
  end

  defp phi_spans(binary, patterns) do
    Enum.flat_map(patterns, fn %{id: id, pattern: pattern} ->
      pattern
      |> Regex.scan(binary, return: :index)
      |> List.flatten()
      |> Enum.map(&%{type: :phi, span: &1, pattern: id})
    end)
  end

  defp api_key_spans(binary, entropy_floor) do
    @entropy_candidate
    |> Regex.scan(binary, return: :index)
    |> List.flatten()
    |> Enum.filter(fn {start, len} ->
      Entropy.secret?(binary_part(binary, start, len), entropy_floor)
    end)
    |> Enum.map(&%{type: :api_key, span: &1})
  end

  # Detector priority is list order: PAN > SSN > PHI > API key, so a digit
  # run claimed as a PAN is never double-claimed as something else.
  defp claim_non_overlapping([first | rest]) do
    {kept, _claimed} =
      Enum.reduce(rest, {first, Enum.map(first, & &1.span)}, fn spans, {kept, claimed} ->
        new =
          Enum.reject(spans, fn %{span: {start, len}} ->
            Enum.any?(claimed, fn {cstart, clen} ->
              start < cstart + clen and cstart < start + len
            end)
          end)

        {kept ++ new, Enum.map(new, & &1.span) ++ claimed}
      end)

    kept
  end

  defp type_counts(findings) do
    findings
    |> Enum.frequencies_by(& &1.type)
  end

  # -- configuration --------------------------------------------------------

  defp config(opts) do
    env = Application.get_env(:ash_a2a, __MODULE__, [])

    %{
      enabled: Keyword.get(opts, :enabled, Keyword.get(env, :enabled, true)),
      key: key(Keyword.get(opts, :key, Keyword.get(env, :key))),
      entropy_floor:
        Keyword.get(
          opts,
          :entropy_floor,
          Keyword.get(env, :entropy_floor, @default_entropy_floor)
        ),
      phi_patterns:
        compile_phi(
          Keyword.get(opts, :phi_patterns, Keyword.get(env, :phi_patterns, @default_phi_patterns))
        )
    }
  end

  defp key(nil) do
    case :persistent_term.get({__MODULE__, :ephemeral_key}, :missing) do
      :missing ->
        generated = :crypto.strong_rand_bytes(32)
        :persistent_term.put({__MODULE__, :ephemeral_key}, generated)

        Logger.warning(
          "AshA2A.Security.DLPFilter: no :key configured; using an ephemeral per-VM key " <>
            "(pseudonyms reset on restart). The key itself is never logged."
        )

        generated

      generated ->
        generated
    end
  end

  defp key(key) when is_binary(key) and byte_size(key) >= 16, do: key

  defp key(key) when is_binary(key) do
    raise ArgumentError,
          "AshA2A.Security.DLPFilter :key must be at least 16 bytes (got #{byte_size(key)})"
  end

  defp key(key) do
    raise ArgumentError, "AshA2A.Security.DLPFilter :key must be a binary (got #{inspect(key)})"
  end

  defp compile_phi(patterns) do
    Enum.map(patterns, fn
      %{id: id, pattern: %Regex{} = pattern} ->
        %{id: id, pattern: pattern}

      %{id: id, pattern: source} when is_binary(source) ->
        case Regex.compile(source) do
          {:ok, compiled} -> %{id: id, pattern: compiled}
          {:error, reason} -> raise ArgumentError, "invalid PHI pattern #{inspect(id)}: #{reason}"
        end

      other ->
        raise ArgumentError,
              "PHI patterns must be %{id: term, pattern: Regex | String.t()} (got #{inspect(other)})"
    end)
  end
end
