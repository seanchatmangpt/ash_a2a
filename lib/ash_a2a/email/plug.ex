if Code.ensure_loaded?(Plug) do
  defmodule AshA2A.Email.Plug do
    @moduledoc """
    Email-to-A2A gateway endpoint: `POST /v1/email:ingest` with a JSON webhook body.

    An inbound email reply to a brief is turned into per-action dispatches, each
    executed under the sender principal's live authority grant. Authentication
    (`Inbound.verify_sender/2`) confers identity only; actions the reply does not
    explicitly approve are never dispatched.

    ## Options

    - `:policy` -- `AshA2A.Email.Inbound.policy()` (required).
    - `:brief_lookup` -- `(message_id -> {:ok, brief} | {:ok, brief, current_digests} | :error)`
      (required). `message_id` is the inbound `In-Reply-To` (angle brackets stripped).
      `brief` is the map given to `AshA2A.Email.Brief.render/2`. `current_digests` is an
      optional `%{n => graph_digest}` of what the live graph hashes to now.
    - `:dispatch` -- `(principal, action -> {:ok, receipt} | {:error, reason})`. Owns the
      live-authority check; refusals are recorded as `:refused`, never raised. Default:
      `default_dispatch/3`.
    - `:resolver` -- `(action -> {:ok, %{skill:, resource:, input:}} | {:error, reason})`
      used by `default_dispatch/3` to map a brief action
      (`:n, :summary, :action, :args, :graph_digest`) onto `AshA2A.Dispatcher.dispatch/6`
      arguments. Default refuses every action with `:unresolvable`.
    - `:reply_sender` -- `(to, subject, text -> any)`; receipt summary or reconfirm mail
      (default: no-op).
    - `:webhook` -- required. `{provider, opts}` handed to `AshA2A.Email.Webhook.verify/3`
      (`:sendgrid | :workspace | :ses`); the provider's request authentication gates the whole
      request (401 `webhook_unauthorized`) BEFORE any `auth_results` in the body is trusted.
      `:trusted_ingress` states that an upstream hop already authenticated the provider; absent,
      the plug refuses with 503 `webhook_auth_unconfigured`.
    - `:max_body_bytes` (default 262_144; 413 `payload_too_large`), `:max_reply_chars`
      (default 16_384; 413). Parsed bodies deeper than 8 levels or with more than 2_000 nodes
      are refused (413 `payload_too_complex`).
    - `:unsafe_no_replay_ledger` -- `true` permits running without `:token_ledger`
      (tests only); otherwise a missing ledger refuses with 503 `replay_protection_unconfigured`.

    Approver binding: when the brief map carries `:approver` (a principal id), the verified
    sender principal must equal it, else 403 `approver_mismatch`. Without `:approver` any
    allowlisted sender holding a valid reply token may approve; set it for per-approver briefs.

    ## Request body

    Webhook map understood by `Inbound.parse/1`, plus `"reply_tokens"`: a map
    `action number (string or int) => token` (`Brief.reply_token/2`). A token is required
    for every approved action.

    ## Flow

    parse (400) -> verify sender (401) -> find brief via `in_reply_to` (404) ->
    `ReplyIntent.parse/2` (422) -> verify tokens of approved actions (403) -> staleness
    (409 + reconfirm email, no dispatch) -> dispatch approved -> reply email ->
    200 `%{"results" => [...]}`.

    Staleness (fail-closed): an approved action is stale when `action.graph_digest` or
    `current_digests[n]` is missing, or they differ. Stale => 409, no dispatch.

    Replay and rate limit (`:token_ledger`, an `AshA2A.Email.TokenLedger`
    server, required unless `:unsafe_no_replay_ledger`): approved `(brief_id, n, token)` triples are single-use (409 `already_consumed`);
    an identical inbound `message_id` replays the cached response without re-dispatch.
    `:rate_limit` (`{max, window_ms}`) bounds requests per sender (429 `rate_limited`).
    Status: UNVERIFIED (no Elixir toolchain was available when these checks were written).

    Per-action standing: `dispatched | held | refused`. Unmentioned actions are omitted.
    """

    @behaviour Plug

    import Plug.Conn

    alias AshA2A.Email.{Brief, Inbound, ReplyIntent}

    @path ["v1", "email:ingest"]

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{method: "POST", path_info: @path} = conn, opts), do: ingest(conn, opts)

    def call(%Plug.Conn{path_info: @path} = conn, _opts) do
      conn
      |> put_resp_header("allow", "POST")
      |> send_json(405, %{"error" => "method_not_allowed"})
    end

    def call(conn, _opts), do: send_json(conn, 404, %{"error" => "not_found"})

    # -- pipeline ---------------------------------------------------------------

    defp ingest(conn, opts) do
      with :ok <- require_config(opts),
           {:ok, body, conn} <- read_json(conn, opts),
           :ok <- bounded(body, opts),
           :ok <- webhook_auth(conn, body, opts),
           {:ok, inbound} <- stage(400, Inbound.parse(body)),
           :ok <- reply_cap(inbound, opts),
           {:ok, principal} <- stage(401, Inbound.verify_sender(inbound, policy(opts))),
           :ok <- rate_limit(inbound, opts),
           {:ok, brief, digests} <- find_brief(inbound, opts),
           :ok <- bind_approver(brief, principal),
           {:ok, entries, approved} <- intent(inbound, brief),
           :ok <- verify_tokens(brief, approved, body),
           :ok <- check_fresh(approved, digests),
           :ok <- consume(inbound, approved, body, opts) do
        run(conn, inbound, principal, entries, approved, opts)
      else
        {:replay, cached} ->
          send_json(conn, 200, Map.merge(cached || %{"results" => []}, %{"replayed" => true}))

        :stale ->
          {:ok, inbound} = Inbound.parse(conn.body_params)
          send_reply(opts, inbound, "Reconfirm required", reconfirm_text())
          send_json(conn, 409, %{"error" => "stale_graph_digest", "results" => []})

        {:halt, status, reason} ->
          send_json(conn, status, %{"error" => to_string_safe(reason)})
      end
    end

    defp policy(opts), do: Keyword.get(opts, :policy) || %{allowlist: %{}}

    defp stage(_status, {:ok, _} = ok), do: ok
    defp stage(status, {:error, reason}), do: {:halt, status, reason}
    defp stage(status, other), do: {:halt, status, other}

    @max_body 262_144
    @max_reply 16_384
    @max_depth 8
    @max_nodes 2_000

    defp require_config(opts) do
      cond do
        Keyword.get(opts, :webhook) in [nil, false] ->
          {:halt, 503, :webhook_auth_unconfigured}

        is_nil(Keyword.get(opts, :token_ledger)) and
            Keyword.get(opts, :unsafe_no_replay_ledger) != true ->
          {:halt, 503, :replay_protection_unconfigured}

        true ->
          :ok
      end
    end

    defp read_json(%Plug.Conn{body_params: %{} = params} = conn, _opts)
         when map_size(params) > 0 and not is_struct(params, Plug.Conn.Unfetched),
         do: {:ok, params, conn}

    defp read_json(conn, opts) do
      max = Keyword.get(opts, :max_body_bytes, @max_body)

      case read_body(conn, length: max) do
        {:ok, raw, conn} when byte_size(raw) <= max ->
          case Jason.decode(raw) do
            {:ok, %{} = map} -> {:ok, map, %{conn | body_params: map}}
            _ -> {:halt, 400, :invalid_json}
          end

        _ ->
          {:halt, 413, :payload_too_large}
      end
    end

    # Depth and node caps on the parsed body (it may come pre-parsed from Plug.Parsers).
    defp bounded(body, _opts) do
      case walk(body, 0, 0) do
        {:ok, _} -> :ok
        :error -> {:halt, 413, :payload_too_complex}
      end
    end

    defp walk(_, depth, _) when depth > @max_depth, do: :error
    defp walk(_, _, count) when count > @max_nodes, do: :error

    defp walk(%{} = m, depth, count) when not is_struct(m),
      do: walk_all(Map.to_list(m) |> Enum.flat_map(fn {k, v} -> [k, v] end), depth + 1, count + 1)

    defp walk(l, depth, count) when is_list(l), do: walk_all(l, depth + 1, count + 1)
    defp walk(_, _, count), do: {:ok, count + 1}

    defp walk_all(items, depth, count) do
      Enum.reduce_while(items, {:ok, count}, fn item, {:ok, c} ->
        case walk(item, depth, c) do
          {:ok, c2} -> {:cont, {:ok, c2}}
          :error -> {:halt, :error}
        end
      end)
    end

    defp reply_cap(%Inbound{body_text: t}, opts) do
      if byte_size(t) > Keyword.get(opts, :max_reply_chars, @max_reply),
        do: {:halt, 413, :payload_too_large},
        else: :ok
    end

    defp webhook_auth(conn, body, opts) do
      case Keyword.get(opts, :webhook) do
        :trusted_ingress ->
          :ok

        {provider, wopts} when is_atom(provider) and is_list(wopts) ->
          input = if provider == :ses, do: body, else: conn

          case AshA2A.Email.Webhook.verify(provider, input, wopts) do
            :ok -> :ok
            {:error, _} -> {:halt, 401, :webhook_unauthorized}
          end

        _ ->
          {:halt, 401, :webhook_unauthorized}
      end
    end

    defp bind_approver(brief, principal) do
      case Map.get(brief, :approver) do
        nil -> :ok
        id when id == principal.id -> :ok
        _ -> {:halt, 403, :approver_mismatch}
      end
    end

    defp find_brief(%Inbound{in_reply_to: id}, opts) when is_binary(id) and id != "" do
      id = id |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

      case Keyword.fetch!(opts, :brief_lookup).(id) do
        {:ok, brief} -> {:ok, brief, %{}}
        {:ok, brief, digests} -> {:ok, brief, digests || %{}}
        _ -> {:halt, 404, :brief_not_found}
      end
    end

    defp find_brief(_, _), do: {:halt, 400, :missing_in_reply_to}

    defp intent(inbound, brief) do
      actions = Map.get(brief, :actions, [])
      numbers = Enum.map(actions, & &1.n)

      case ReplyIntent.parse(Inbound.reply_text(inbound), numbers) do
        {:ok, entries} -> {:ok, entries, ReplyIntent.resolve(entries, actions)}
        {:error, reason} -> {:halt, 422, reason}
      end
    end

    defp verify_tokens(brief, approved, body) do
      tokens = body["reply_tokens"] || body[:reply_tokens] || %{}
      tokens = if is_map(tokens), do: tokens, else: %{}

      Enum.reduce_while(approved, :ok, fn %{n: n}, :ok ->
        token = Map.get(tokens, Integer.to_string(n), Map.get(tokens, n))

        case Brief.verify_reply_token(brief, n, token) do
          :ok -> {:cont, :ok}
          _ -> {:halt, {:halt, 403, :invalid_reply_token}}
        end
      end)
    end

    # Fail-closed: a missing digest on either side cannot prove freshness, so it is stale.
    defp check_fresh(approved, digests) do
      stale? =
        Enum.any?(approved, fn a ->
          case {Map.get(a, :graph_digest), Map.get(digests, a.n)} do
            {nil, _} -> true
            {_, nil} -> true
            {same, same} -> false
            _ -> true
          end
        end)

      if stale?, do: :stale, else: :ok
    end

    defp rate_limit(inbound, opts) do
      with ledger when not is_nil(ledger) <- Keyword.get(opts, :token_ledger),
           {max, window} <- Keyword.get(opts, :rate_limit) do
        sender = String.downcase(to_string(inbound.from))

        case AshA2A.Email.TokenLedger.rate_check(ledger, sender, max, window) do
          :ok -> :ok
          {:error, reason} -> {:halt, 429, reason}
        end
      else
        _ -> :ok
      end
    end

    defp consume(inbound, approved, body, opts) do
      case Keyword.get(opts, :token_ledger) do
        nil ->
          :ok

        ledger ->
          tokens = body["reply_tokens"] || body[:reply_tokens] || %{}

          pairs =
            Enum.map(approved, fn %{n: n} ->
              {n,
               tokens
               |> then(&Map.get(&1, Integer.to_string(n), Map.get(&1, n)))
               |> to_string()
               |> String.trim()}
            end)

          case AshA2A.Email.TokenLedger.reserve(
                 ledger,
                 brief_id(inbound),
                 pairs,
                 inbound.message_id
               ) do
            :ok -> :ok
            {:replay, cached} -> {:replay, cached}
            {:error, :already_consumed} -> {:halt, 409, :already_consumed}
            {:error, reason} -> {:halt, 503, reason}
          end
      end
    end

    defp brief_id(%Inbound{in_reply_to: id}),
      do: id |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

    defp run(conn, inbound, principal, entries, approved, opts) do
      approved_ns = MapSet.new(approved, & &1.n)

      results =
        for %{n: n, decision: d} <- entries, d != :unknown do
          cond do
            MapSet.member?(approved_ns, n) ->
              dispatch_one(n, Enum.find(approved, &(&1.n == n)), principal, opts)

            d == :hold ->
              %{action: n, standing: :held}

            true ->
              %{action: n, standing: :refused, reason: :not_approved}
          end
        end

      send_reply(opts, inbound, "Re: #{inbound.subject}", summary(results))
      body = %{"results" => Enum.map(results, &serialize/1)}

      if ledger = Keyword.get(opts, :token_ledger),
        do:
          AshA2A.Email.TokenLedger.record_result(
            ledger,
            brief_id(inbound),
            inbound.message_id,
            body
          )

      send_json(conn, 200, body)
    end

    defp dispatch_one(n, action, principal, opts) do
      dispatch = Keyword.get(opts, :dispatch) || (&default_dispatch(opts, &1, &2))

      try do
        case dispatch.(principal, action) do
          {:ok, receipt} -> %{action: n, standing: :dispatched, receipt: receipt}
          {:error, reason} -> %{action: n, standing: :refused, reason: reason}
          other -> %{action: n, standing: :refused, reason: {:unexpected, other}}
        end
      rescue
        e -> %{action: n, standing: :refused, reason: {:exception, Exception.message(e)}}
      end
    end

    @doc """
    Default dispatch: resolves the brief action through the opts-supplied `:resolver`
    (default refuses `:unresolvable`) and hands `(skill, input, resource, principal)` to the
    opts-supplied `:kernel_entry` (arity 4, the governed kernel path; default
    `AshA2A.Email.KernelEntry.run/4`, which runs `AshA2A.CommandBus` under the principal's
    live grant). This module never calls `AshA2A.Dispatcher` directly.
    """
    @spec default_dispatch(keyword(), map(), map()) :: {:ok, term()} | {:error, term()}
    def default_dispatch(opts, principal, action) do
      resolver = Keyword.get(opts, :resolver) || fn _ -> {:error, :unresolvable} end

      case resolver.(action) do
        {:ok, %{skill: skill, resource: resource} = r} ->
          # The gateway never names a DO entry itself (C1 closure: kernel-only DO). The kernel
          # entry (a function through the governed CommandBus/kernel path) is injected via
          # `:kernel_entry`; absent, the action is refused.
          entry = Keyword.get(opts, :kernel_entry) || (&AshA2A.Email.KernelEntry.run/4)

          case entry.(skill, Map.get(r, :input, %{}), resource, principal) do
            {:error, reason} -> {:error, reason}
            {:ok, _} = ok -> ok
            reply -> {:ok, reply}
          end

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :unresolvable}
      end
    end

    # -- helpers ----------------------------------------------------------------

    # Subject comes from the sender: strip CR/LF/control chars (header injection) and cap length.
    defp safe_header(v) do
      v
      |> to_string()
      |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
      |> String.slice(0, 200)
    end

    defp send_reply(opts, %Inbound{from: from}, subject, text) do
      case Keyword.get(opts, :reply_sender) do
        fun when is_function(fun, 3) -> fun.(safe_header(from), safe_header(subject), text)
        _ -> :ok
      end
    end

    defp reconfirm_text,
      do:
        "The graph changed since this brief was issued. No action was taken. " <>
          "Please reconfirm against the refreshed brief."

    defp summary(results) do
      lines =
        for r <- results do
          "#{r.action}: #{r.standing}" <> if(r[:reason], do: " (#{inspect(r.reason)})", else: "")
        end

      Enum.join(["Receipt summary:" | lines], "\n")
    end

    defp serialize(r) do
      %{"action" => r.action, "standing" => Atom.to_string(r.standing)}
      |> put_unless_nil("reason", r[:reason] && inspect(r.reason))
      |> put_unless_nil("receipt", r[:receipt] && inspect(r.receipt))
    end

    defp put_unless_nil(map, _k, nil), do: map
    defp put_unless_nil(map, k, v), do: Map.put(map, k, v)

    defp to_string_safe(v) when is_binary(v), do: v
    defp to_string_safe(v) when is_atom(v), do: Atom.to_string(v)
    defp to_string_safe(v), do: inspect(v)

    defp send_json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
