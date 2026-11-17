# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Bandit) do
  defmodule AshA2A.Sim.Email do
    @moduledoc """
    The email surface of the simulation server: `AshA2A.Email.Plug`
    (`POST /v1/email:ingest`) mounted for real, with everything it needs, and
    helpers that produce real DKIM-signed inbound mail.

    ## What the server mounts

    | Mount | Webhook authentication |
    |---|---|
    | `POST /email/v1/email:ingest` | an SES-shaped envelope; the provider check is `AshA2A.Email.Dkim.verifier/1` over the raw message in `"content"` and the SNS topic ARN |
    | `POST /email-workspace/v1/email:ingest` | `{:workspace, token: secret}`: a Bearer secret the server generates |

    Both mounts share one brief store, one durable replay ledger
    (`AshA2A.Email.TokenLedgerStore` on an `EKV` instance in a temporary
    directory that is removed when the server stops), one sender policy and one
    resolver that maps a brief action onto a skill of `AshA2A.Sim.Note` run by
    the governed kernel entry (`AshA2A.Email.KernelEntry`). Caps: 64 KiB body, 2000
    reply characters, 60 requests per sender per minute.

    The DKIM key is a fresh RSA-2048 pair per server run. The DNS `p=` value of
    its public half is what the key resolver answers for `sim.example` and the
    selector `sim`.

    | Sender | Principal | Standing grants |
    |---|---|---|
    | `approver@sim.example` | `sim-email-approver` | `create_note`, `publish_note` |
    | `other@sim.example` | `sim-email-other` | `create_note`, `publish_note` |
    | `ungranted@sim.example` | `sim-email-ungranted` | none |
    | `burst@sim.example` | `sim-email-burst` | none |

    ## Briefs

    `issue_brief/1` files a brief the way the operator would receive it: two
    numbered actions (`create_note`, `publish_note`) pinned to a graph digest.
    The simulated graph is one token per brief; `drift/1` replaces it, so the
    digests the brief carries no longer match and a reply is stale (409).

    ## Outcomes

    `outcomes/0` lists what the gateway must do, one entry per refusal and per
    success. `run/2` drives one over the real wire and answers what happened
    (status, body, whether the Ash rows changed); `evaluate/2` judges it.
    `AshA2A.Sim.Prover` and the MCP tool `sim_email_send_reply` both use them.
    """

    alias AshA2A.Email.{Brief, Dkim, TokenLedgerStore}
    alias AshA2A.Email.Plug, as: EmailPlug
    alias AshA2A.Sim.Note

    @domain "sim.example"
    @selector "sim"
    @topic_arn "arn:aws:sns:us-east-1:000000000000:ash-a2a-sim-inbound"
    @cert_url "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-sim.pem"
    @max_body 65_536
    @max_reply 2_000
    @rate {60, 60_000}
    @key {__MODULE__, :config}
    @offset {__MODULE__, :clock_offset}
    @state __MODULE__.State
    @kv __MODULE__.Kv
    @ledger __MODULE__.Ledger
    # Fixed simulation-only reply-token key (32 bytes). Never a production key.
    @token_key "ash-a2a-sim-email-token-key-0001"

    @senders %{
      "approver@sim.example" => "sim-email-approver",
      "other@sim.example" => "sim-email-other",
      "ungranted@sim.example" => "sim-email-ungranted",
      "burst@sim.example" => "sim-email-burst"
    }
    @granted ["sim-email-approver", "sim-email-other"]
    @skills ["create_note", "publish_note"]

    @outcomes [
      %{
        name: "approved_reply_dispatched",
        status: 200,
        landed: true,
        description:
          "An honest, DKIM-signed reply that approves action 1 executes the governed dispatch: the Ash row exists."
      },
      %{
        name: "held_reply_dispatches_nothing",
        status: 200,
        landed: false,
        description: "A reply that holds the action is answered 200 `held`; no row is written."
      },
      %{
        name: "replay_returns_cached_result",
        status: 200,
        landed: false,
        description:
          "The same message id again answers the cached result with `replayed: true` and changes nothing."
      },
      %{
        name: "token_reuse_refused",
        status: 409,
        landed: false,
        error: "already_consumed",
        description: "A reply token already spent, under a new message id, is refused 409."
      },
      %{
        name: "tampered_body_refused",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description:
          "One byte of the signed message flipped after signing fails the DKIM body hash."
      },
      %{
        name: "forged_webhook_auth_refused",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description:
          "A wrong or missing webhook secret, and an SNS envelope for another topic, are refused 401 even with passing `auth_results`."
      },
      %{
        name: "unsigned_fields_not_trusted",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description:
          "A valid DKIM signature on one mail does not vouch for the sender, text and tokens the envelope claims: fields that differ from the signed message are refused 401."
      },
      %{
        name: "foreign_dkim_key_refused",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description: "A message signed with a key the resolver does not publish is refused 401."
      },
      %{
        name: "dkim_length_limit_refused",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description: "A validly signed message carrying an `l=` tag is refused 401."
      },
      %{
        name: "from_misaligned_refused",
        status: 401,
        landed: false,
        error: "webhook_unauthorized",
        description: "A From address outside the signing domain `d=` is refused 401."
      },
      %{
        name: "unknown_sender_refused",
        status: 401,
        landed: false,
        error: "sender_not_allowlisted",
        description: "A correctly signed reply from a sender off the allowlist is refused 401."
      },
      %{
        name: "approver_binding_refused",
        status: 403,
        landed: false,
        error: "approver_mismatch",
        description:
          "A brief bound to one approver, answered by another allowlisted principal, is refused 403."
      },
      %{
        name: "reply_token_missing_refused",
        status: 403,
        landed: false,
        error: "invalid_reply_token",
        description: "An approval without its reply token is refused 403."
      },
      %{
        name: "reply_token_forged_refused",
        status: 403,
        landed: false,
        error: "invalid_reply_token",
        description: "An approval with a made-up reply token is refused 403."
      },
      %{
        name: "unknown_brief_refused",
        status: 404,
        landed: false,
        error: "brief_not_found",
        description: "A reply to a message id that is no brief is refused 404."
      },
      %{
        name: "oversized_body_refused",
        status: 413,
        landed: false,
        error: "payload_too_large",
        description: "A body over the 64 KiB cap is refused 413 before anything is parsed."
      },
      %{
        name: "deeply_nested_body_refused",
        status: 413,
        landed: false,
        error: "payload_too_complex",
        description: "A body nested deeper than 8 levels is refused 413."
      },
      %{
        name: "stale_graph_digest_refused",
        status: 409,
        landed: false,
        error: "stale_graph_digest",
        description:
          "A reply to a brief whose graph changed is refused 409, nothing runs, and a reconfirm brief is mailed that can then be approved."
      },
      %{
        name: "ungranted_sender_refused",
        status: 200,
        landed: false,
        description:
          "An allowlisted, authenticated sender without a standing grant is answered `refused`; authentication confers no authority."
      },
      %{
        name: "rate_limited",
        status: 429,
        landed: false,
        error: "rate_limited",
        description: "More than 60 requests per minute from one sender are refused 429."
      }
    ]

    @routes [
      %{
        name: "POST /email/v1/email:ingest",
        description: "The DKIM-verified (SES-shaped) ingest endpoint."
      },
      %{
        name: "POST /email-workspace/v1/email:ingest",
        description: "The webhook-secret (workspace-shaped) ingest endpoint."
      },
      %{
        name: "GET /email/v1/email:ingest",
        description: "The ingest endpoint refuses any other method with 405 and `allow: POST`."
      }
    ]

    # == lifecycle ================================================================

    @doc false
    @spec start(pid()) :: :ok
    def start(sup) do
      {priv, p} = dkim_key()
      secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      dir = Path.join(System.tmp_dir!(), "ash_a2a_sim_email_#{unique()}")
      File.rm_rf!(dir)
      :persistent_term.put(@offset, 0)

      {:ok, _} =
        Supervisor.start_child(sup, %{
          id: @state,
          start:
            {Agent, :start_link,
             [fn -> %{briefs: %{}, deliveries: [], attempts: []} end, [name: @state]]}
        })

      {:ok, _} =
        Supervisor.start_child(sup, AshA2A.TaskStore.Ekv.child_spec(name: @kv, data_dir: dir))

      {:ok, _} =
        Supervisor.start_child(
          sup,
          {TokenLedgerStore, name: @ledger, store: @kv, now: &__MODULE__.now/0}
        )

      resolver = fn
        @domain, @selector -> {:ok, p}
        _domain, _selector -> {:error, "no such key"}
      end

      common = [
        policy: %{allowlist: @senders},
        brief_lookup: &__MODULE__.lookup_brief/1,
        resolver: &__MODULE__.resolve_action/1,
        reply_sender: &__MODULE__.record_delivery/3,
        token_ledger: @ledger,
        token_key: @token_key,
        rate_limit: @rate,
        max_body_bytes: @max_body,
        max_reply_chars: @max_reply
      ]

      config = %{
        priv: priv,
        p: p,
        secret: secret,
        dir: dir,
        ses:
          Keyword.put(
            common,
            :webhook,
            {:ses,
             topic_arn: @topic_arn, signature_verifier: Dkim.verifier(key_resolver: resolver)}
          ),
        workspace: Keyword.put(common, :webhook, {:workspace, token: secret})
      }

      :persistent_term.put(@key, config)
      issue_grants()
    end

    @doc false
    @spec stop() :: :ok
    def stop do
      case :persistent_term.get(@key, nil) do
        %{dir: dir} -> File.rm_rf(dir)
        _ -> :ok
      end

      :persistent_term.erase(@key)
      :persistent_term.erase(@offset)
      :ok
    end

    @doc "Files the standing grants of the granted email principals (idempotent)."
    @spec issue_grants() :: :ok
    def issue_grants do
      for id <- @granted, skill <- @skills do
        {:ok, sk} = AshA2A.Info.skill(Note, skill)
        subject = AshA2A.Identity.principal(id)

        unless AshA2A.Authority.Grant.granted?(subject, sk.id),
          do: {:ok, _} = AshA2A.Authority.Grant.grant(subject, sk.id)
      end

      :ok
    end

    @doc false
    def now, do: System.monotonic_time(:millisecond) + :persistent_term.get(@offset, 0)

    @doc """
    Moves the ledger clock forward `ms` milliseconds, so the rate-limit window
    of every sender empties without waiting.
    """
    @spec advance_clock(non_neg_integer()) :: :ok
    def advance_clock(ms) do
      :persistent_term.put(@offset, :persistent_term.get(@offset, 0) + ms)
      :ok
    end

    @doc "Whether the email surface is running."
    @spec running?() :: boolean()
    def running?, do: :persistent_term.get(@key, nil) != nil

    # == the mount ================================================================

    @doc false
    def call(%Plug.Conn{path_info: [mount | rest]} = conn) do
      case :persistent_term.get(@key, nil) do
        nil ->
          Plug.Conn.send_resp(conn, 503, "email surface is starting")

        config ->
          opts = if mount == "email-workspace", do: config.workspace, else: config.ses
          Process.delete(:sim_email_brief)
          inner = %{conn | path_info: rest, script_name: conn.script_name ++ [mount]}
          answered = EmailPlug.call(inner, EmailPlug.init(opts))
          record_attempt(mount, rest, answered)
          %{answered | path_info: conn.path_info, script_name: conn.script_name}
      end
    end

    defp record_attempt(mount, rest, conn) do
      entry = %{
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "mount" => mount,
        "path" => "/" <> Enum.join(rest, "/"),
        "method" => conn.method,
        "status" => conn.status,
        "brief_id" => Process.get(:sim_email_brief)
      }

      Agent.update(@state, &Map.update!(&1, :attempts, fn a -> a ++ [entry] end))
    end

    @doc false
    def lookup_brief(id) do
      case Agent.get(@state, &Map.get(&1.briefs, id)) do
        nil ->
          :error

        %{brief: brief, graph: graph} ->
          Process.put(:sim_email_brief, id)
          {:ok, brief, digests(brief, graph)}
      end
    end

    @doc false
    def resolve_action(%{action: action, args: args}) do
      skill = Atom.to_string(action)

      if skill in @skills do
        {:ok,
         %{skill: skill, resource: Note, input: Map.new(args, fn {k, v} -> {to_string(k), v} end)}}
      else
        {:error, "unresolvable action"}
      end
    end

    @doc false
    def record_delivery(to, subject, text) do
      reconfirm =
        if subject == "Reconfirm required", do: refresh(Process.get(:sim_email_brief))

      entry = %{
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "to" => to,
        "subject" => subject,
        "text" => text,
        "reconfirm_brief" => reconfirm
      }

      Agent.update(@state, &Map.update!(&1, :deliveries, fn d -> d ++ [entry] end))
    end

    # == briefs ===================================================================

    @doc """
    Files a brief and answers it as a map: `brief_id`, `message_id`, `subject`,
    `text`, `approver`, `actions` (each with its `reply_token`) and `reply_tokens`.

    Options: `:title` (also the title of the notes the actions create),
    `:bound` (default `true`: the brief names `sim-email-approver` as its
    approver).
    """
    @spec issue_brief(keyword()) :: map()
    def issue_brief(opts \\ []) do
      title = Keyword.get(opts, :title) || "sim-email-#{unique()}"
      graph = unique()

      actions = [
        %{
          n: 1,
          summary: "Create note #{title}",
          action: :create_note,
          args: %{title: title},
          graph_digest: digest(graph, 1)
        },
        %{
          n: 2,
          summary: "Publish note #{title}",
          action: :publish_note,
          args: %{title: title},
          graph_digest: digest(graph, 2)
        }
      ]

      brief =
        %{
          title: "Sim operator brief #{title}",
          date: Date.to_iso8601(Date.utc_today()),
          sections: [%{heading: "Pending", lines: ["Two actions wait for approval."]}],
          actions: actions
        }
        |> then(fn b ->
          if Keyword.get(opts, :bound, true),
            do: Map.put(b, :approver, "sim-email-approver"),
            else: b
        end)

      store(brief, graph)
    end

    @doc """
    The brief `brief_id` as `issue_brief/1` answered it, or `nil`.
    """
    @spec brief(String.t()) :: map() | nil
    def brief(brief_id) do
      case Agent.get(@state, &Map.get(&1.briefs, brief_id)) do
        nil -> nil
        %{brief: brief, graph: graph} -> public(brief, graph, brief_id)
      end
    end

    @doc """
    Changes the simulated graph under a brief: the digests it carries no
    longer match, so a reply to it is stale. Answers `:ok`, or `:error` for an
    unknown brief.
    """
    @spec drift(String.t()) :: :ok | :error
    def drift(brief_id) do
      Agent.get_and_update(@state, fn st ->
        case st.briefs do
          %{^brief_id => rec} ->
            {:ok, %{st | briefs: Map.put(st.briefs, brief_id, %{rec | graph: unique()})}}

          _ ->
            {:error, st}
        end
      end)
      |> case do
        :ok -> :ok
        :error -> :error
      end
    end

    # A brief with the same actions against the graph as it is now.
    defp refresh(nil), do: nil

    defp refresh(brief_id) do
      case Agent.get(@state, &Map.get(&1.briefs, brief_id)) do
        nil ->
          nil

        %{brief: brief, graph: graph} ->
          actions = Enum.map(brief.actions, &%{&1 | graph_digest: digest(graph, &1.n)})
          fresh = %{brief | actions: actions, title: brief.title <> " (reconfirm)"}
          store(fresh, graph)
      end
    end

    defp store(brief, graph) do
      rendered = Brief.render(brief, domain: @domain, key: @token_key)
      id = bare(rendered.message_id)

      Agent.update(@state, fn st ->
        %{st | briefs: Map.put(st.briefs, id, %{brief: brief, graph: graph})}
      end)

      public(brief, graph, id)
    end

    defp public(brief, _graph, id) do
      rendered = Brief.render(brief, domain: @domain, key: @token_key)

      actions =
        for a <- brief.actions do
          %{
            "n" => a.n,
            "action" => Atom.to_string(a.action),
            "summary" => a.summary,
            "args" => Map.new(a.args, fn {k, v} -> {to_string(k), v} end),
            "graph_digest" => a.graph_digest,
            "reply_token" => Brief.reply_token(brief, a.n, key: @token_key)
          }
        end

      %{
        "brief_id" => id,
        "message_id" => rendered.message_id,
        "subject" => rendered.subject,
        "text" => rendered.text,
        "approver" => Map.get(brief, :approver),
        "title" => hd(brief.actions).args.title,
        "actions" => actions,
        "reply_tokens" => Map.new(actions, &{Integer.to_string(&1["n"]), &1["reply_token"]})
      }
    end

    defp digests(brief, graph), do: Map.new(brief.actions, &{&1.n, digest(graph, &1.n)})

    defp digest(graph, n),
      do:
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, "sim-graph:#{graph}:#{n}"), case: :lower)

    @doc "The mail the gateway sent (receipt summaries, reconfirm briefs) and the requests it answered."
    @spec deliveries() :: %{deliveries: [map()], attempts: [map()]}
    def deliveries do
      Agent.get(@state, &%{deliveries: &1.deliveries, attempts: &1.attempts})
    end

    @doc "Forgets every recorded delivery and attempt."
    @spec reset_deliveries() :: :ok
    def reset_deliveries do
      Agent.update(@state, &%{&1 | deliveries: [], attempts: []})
    end

    # == signed inbound mail ======================================================

    @doc """
    Everything an operator needs to sign mail as `sim.example`: the domain, the
    selector, the DNS `p=` value, the webhook secret and the topic ARN. The
    private key never leaves the server; use `build_reply/1` to sign.
    """
    @spec facts() :: map()
    def facts do
      %{p: p, secret: secret} = :persistent_term.get(@key)

      %{
        "dkim" => %{"domain" => @domain, "selector" => @selector, "public_key_p" => p},
        "webhook_secret" => secret,
        "topic_arn" => @topic_arn,
        "senders" => @senders,
        "limits" => %{
          "max_body_bytes" => @max_body,
          "max_reply_chars" => @max_reply,
          "rate_limit" => %{"max" => elem(@rate, 0), "window_ms" => elem(@rate, 1)}
        }
      }
    end

    @doc "The sender addresses and the principals they authenticate as."
    @spec senders() :: %{String.t() => String.t()}
    def senders, do: @senders

    @doc """
    Builds a real, DKIM-signed reply to a brief (rsa-sha256, relaxed/relaxed)
    and the webhook envelope that carries it.

    `brief` is the map `issue_brief/1` answered (or `nil`, then `:in_reply_to`
    is required). Options:

      * `:from` (default `approver@sim.example`), `:text` (default `"Approve 1."`),
        `:message_id`, `:in_reply_to`, `:subject`
      * `:tokens` - `:all` (default), `:none`, `:forged` or a map `n => token`
      * `:sign` - `:sim` (default) or `:foreign` (a key the resolver does not know)
      * `:d` - the signing domain (default `sim.example`); `:from_domain`
        overrides the domain of the From header
      * `:dkim_tags` - extra tag text, for example `" l=5;"`
      * `:tamper` - `:body_byte` flips one byte of the signed message
      * `:topic` - `:ok` (default) or `:wrong`

    Answers `%{raw: raw_message, envelope: map, message_id: id}`.
    """
    @spec build_reply(map() | nil, keyword()) :: map()
    def build_reply(brief, opts \\ []) do
      %{priv: priv} = :persistent_term.get(@key)
      from = Keyword.get(opts, :from, "approver@sim.example")
      from_domain = Keyword.get(opts, :from_domain) || from |> String.split("@") |> List.last()
      from_header = String.replace(from, ~r/@.*$/, "@" <> from_domain)
      mid = Keyword.get(opts, :message_id) || "reply-#{unique()}@#{@domain}"
      in_reply_to = Keyword.get(opts, :in_reply_to) || brief["brief_id"]
      text = Keyword.get(opts, :text, "Approve 1.")
      subject = Keyword.get(opts, :subject, "Re: " <> ((brief && brief["subject"]) || "brief"))
      tokens = tokens(brief, Keyword.get(opts, :tokens, :all))

      key =
        case Keyword.get(opts, :sign, :sim) do
          :sim -> priv
          :foreign -> :public_key.generate_key({:rsa, 2048, 65537})
        end

      headers =
        [
          {"From", " Approver <#{from_header}>"},
          {"To", " briefs@#{@domain}"},
          {"Subject", " " <> subject},
          {"Date", " " <> rfc_date()},
          {"Message-ID", " <#{mid}>"},
          {"In-Reply-To", " <#{in_reply_to}>"}
        ] ++
          for({n, token} <- Enum.sort(tokens), do: {"A2A-Action-#{n}", " " <> to_string(token)})

      raw =
        sign(key, headers, text <> "\r\n",
          d: Keyword.get(opts, :d, @domain),
          tags: Keyword.get(opts, :dkim_tags, "")
        )

      raw = if Keyword.get(opts, :tamper) == :body_byte, do: flip_body_byte(raw), else: raw

      %{
        raw: raw,
        message_id: mid,
        envelope: envelope(raw, from, subject, mid, in_reply_to, text, tokens, opts)
      }
    end

    @doc false
    def envelope(raw, from, subject, mid, in_reply_to, text, tokens, opts \\ []) do
      %{
        "Type" => "Notification",
        "MessageId" => "sns-#{unique()}",
        "TopicArn" =>
          if(Keyword.get(opts, :topic) == :wrong,
            do: "arn:aws:sns:us-east-1:000000000000:someone-elses-topic",
            else: @topic_arn
          ),
        "Timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "Signature" => Base.encode64("sim-sns-signature"),
        "SignatureVersion" => "1",
        "SigningCertURL" => @cert_url,
        "content" => raw,
        "from" => from,
        "to" => "briefs@#{@domain}",
        "subject" => subject,
        "message_id" => mid,
        "in_reply_to" => in_reply_to,
        "text" => text,
        "auth_results" => %{"dkim" => "pass", "spf" => "pass", "dmarc" => "pass"},
        "reply_tokens" => Map.new(tokens, fn {n, t} -> {to_string(n), t} end)
      }
    end

    defp tokens(_brief, :none), do: %{}
    defp tokens(nil, _), do: %{}

    defp tokens(brief, :all),
      do: Map.new(brief["actions"], &{&1["n"], &1["reply_token"]})

    defp tokens(brief, :forged),
      do: Map.new(brief["actions"], &{&1["n"], "0000000000000000"})

    defp tokens(_brief, %{} = given), do: given

    defp flip_body_byte(raw) do
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      <<first, rest::binary>> = body
      head <> "\r\n\r\n" <> <<Bitwise.bxor(first, 1), rest::binary>>
    end

    defp rfc_date do
      Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")
    end

    # RSA-SHA256 relaxed/relaxed signer, independent of AshA2A.Email.Dkim.
    defp sign(priv, headers, body, o) do
      h = ["from", "to", "subject", "date", "message-id", "in-reply-to"]
      bh = :crypto.hash(:sha256, canon_body(body)) |> Base.encode64()

      value =
        "v=1; a=rsa-sha256; c=relaxed/relaxed; d=#{o[:d]}; s=#{@selector}; " <>
          "h=#{Enum.join(h, ":")}; bh=#{bh};#{o[:tags]} b="

      signed =
        h
        |> Enum.map(fn name ->
          headers |> Enum.reverse() |> Enum.find(fn {n, _} -> String.downcase(n) == name end)
        end)
        |> Enum.reject(&is_nil/1)

      data =
        Enum.map_join(signed, &(canon_header(&1) <> "\r\n")) <>
          canon_header({"DKIM-Signature", value})

      sig = data |> :public_key.sign(:sha256, priv) |> Base.encode64()

      folded =
        sig
        |> String.graphemes()
        |> Enum.chunk_every(60)
        |> Enum.map_join("\r\n\t", &Enum.join/1)

      all = [{"DKIM-Signature", " " <> value <> folded}] ++ headers
      Enum.map_join(all, &"#{elem(&1, 0)}:#{elem(&1, 1)}\r\n") <> "\r\n" <> body
    end

    defp canon_body(body) do
      lines =
        body
        |> String.split("\r\n")
        |> Enum.map(&(&1 |> String.replace(~r/[ \t]+/, " ") |> String.trim_trailing()))
        |> Enum.reverse()
        |> Enum.drop_while(&(&1 == ""))
        |> Enum.reverse()

      if lines == [], do: "", else: Enum.join(lines, "\r\n") <> "\r\n"
    end

    defp canon_header({name, value}),
      do:
        String.downcase(name) <>
          ":" <> (value |> String.replace(~r/[ \t]+/, " ") |> String.trim())

    defp dkim_key do
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
        priv = :public_key.generate_key({:rsa, 2048, 65537})

      {:SubjectPublicKeyInfo, der, :not_encrypted} =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})

      {priv, Base.encode64(der)}
    end

    # == the wire =================================================================

    @doc "The ingest URL of a mount (`:ses` or `:workspace`) of the server `info` describes."
    @spec url(map(), :ses | :workspace) :: String.t()
    def url(info, :ses), do: info.base_url <> "/email/v1/email:ingest"
    def url(info, :workspace), do: info.base_url <> "/email-workspace/v1/email:ingest"

    @doc """
    Posts `body` (a map, encoded as JSON, or the bytes) to a mount over real
    HTTP. Options: `:mount` (`:ses` default, `:workspace`), `:auth`
    (`:ok` default, `:wrong`, `:none`: the workspace secret), `:method`.
    Answers `%{status, headers, raw, json}`.
    """
    @spec post(map(), map() | binary(), keyword()) :: map()
    def post(info, body, opts \\ []) do
      mount = Keyword.get(opts, :mount, :ses)
      bytes = if is_binary(body), do: body, else: Jason.encode!(body)

      auth =
        case {mount, Keyword.get(opts, :auth, :ok)} do
          {:workspace, :ok} ->
            [{"authorization", "Bearer " <> :persistent_term.get(@key).secret}]

          {:workspace, :wrong} ->
            [{"authorization", "Bearer 0000000000000000-not-the-secret"}]

          _ ->
            []
        end

      resp =
        Req.request!(
          method: Keyword.get(opts, :method, :post),
          url: url(info, mount),
          headers: [{"content-type", "application/json"}, {"connection", "close"}] ++ auth,
          body: bytes,
          retry: false,
          decode_body: false,
          redirect: false,
          receive_timeout: 20_000
        )

      raw = if is_binary(resp.body), do: resp.body, else: inspect(resp.body)

      json =
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          {:error, _} -> nil
        end

      %{
        status: resp.status,
        headers: Map.new(resp.headers, fn {k, v} -> {k, List.wrap(v) |> Enum.join(", ")} end),
        raw: raw,
        json: json
      }
    end

    @doc """
    Sends a reply and answers what happened, including whether the Ash rows
    changed. `opts` are the options of `build_reply/2` plus `:mount`, `:auth`,
    `:raw` (a signed message to send as it is; the envelope is derived from it
    and `:tokens`), `:padding` (bytes of filler in the body) and `:nest`
    (extra nesting depth in the body).
    """
    @spec send_reply(map(), map() | nil, keyword()) :: map()
    def send_reply(info, brief, opts \\ []) do
      before = snapshot()

      {envelope, message_id, raw} =
        case Keyword.get(opts, :raw) do
          raw when is_binary(raw) -> from_raw(raw, brief, opts)
          nil -> built(brief, opts)
        end

      body =
        envelope
        |> maybe_pad(Keyword.get(opts, :padding))
        |> maybe_nest(Keyword.get(opts, :nest))

      resp = post(info, body, Keyword.take(opts, [:mount, :auth]))
      after_ = snapshot()

      %{
        status: resp.status,
        json: resp.json,
        raw_body: resp.raw,
        headers: resp.headers,
        message_id: message_id,
        signed_raw: raw,
        landed: before != after_,
        added: titles(after_) -- titles(before),
        publications_before: length(before.publications),
        publications_after: length(after_.publications),
        rows_before: length(before.rows),
        rows_after: length(after_.rows)
      }
    end

    defp built(brief, opts) do
      reply = build_reply(brief, opts)
      {reply.envelope, reply.message_id, reply.raw}
    end

    # The envelope of a message the caller signed: its fields come from the
    # message itself.
    defp from_raw(raw, brief, opts) do
      {:ok, inbound} = AshA2A.Email.Inbound.parse(raw)
      from = inbound.from
      mid = inbound.message_id

      tokens =
        case Keyword.get(opts, :tokens) do
          %{} = given -> given
          other -> if brief, do: tokens(brief, other || :all), else: header_tokens(raw)
        end

      envelope =
        envelope(
          raw,
          from,
          inbound.subject,
          mid,
          inbound.in_reply_to,
          AshA2A.Email.Inbound.reply_text(inbound),
          tokens,
          opts
        )

      {envelope, mid, raw}
    end

    defp header_tokens(raw) do
      ~r/^A2A-Action-(\d+):\s*(\S+)/m
      |> Regex.scan(raw)
      |> Map.new(fn [_, n, token] -> {String.to_integer(n), token} end)
    end

    defp maybe_pad(envelope, nil), do: envelope

    defp maybe_pad(envelope, bytes),
      do: Map.put(envelope, "padding", String.duplicate("x", bytes))

    defp maybe_nest(envelope, nil), do: envelope

    defp maybe_nest(envelope, depth),
      do:
        Map.put(envelope, "extra", Enum.reduce(1..depth, "leaf", fn _, acc -> %{"k" => acc} end))

    @doc """
    The Ash rows and the recorded publications, for a before/after comparison:
    `%{rows: [...], publications: [...]}`.
    """
    @spec snapshot() :: %{rows: [tuple()], publications: [String.t()]}
    def snapshot do
      rows =
        Note
        |> Ash.read!(authorize?: false)
        |> Enum.map(&{&1.id, &1.title, &1.body, &1.updated_at})
        |> Enum.sort()

      %{rows: rows, publications: Note.publications()}
    end

    defp titles(%{rows: rows}), do: Enum.map(rows, &elem(&1, 1))

    @doc "The note row with this title, or `nil`."
    @spec row(String.t()) :: map() | nil
    def row(title), do: Note |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == title))

    # == outcomes =================================================================

    @doc "Every outcome: `%{name, status, landed, description}` (and `:error`)."
    @spec outcomes() :: [map()]
    def outcomes, do: @outcomes

    @doc "The outcome named `name`, or `nil`."
    @spec outcome(String.t()) :: map() | nil
    def outcome(name), do: Enum.find(@outcomes, &(&1.name == name))

    @doc "The routes of the email surface: `%{name, description}`."
    @spec routes() :: [map()]
    def routes, do: @routes

    @doc "The surface items of the email surface (`AshA2A.Sim.Surface` item maps)."
    @spec surface_items() :: [map()]
    def surface_items do
      for r <- @routes do
        %{
          id: "email_route:" <> r.name,
          kind: :email_route,
          name: r.name,
          source: "AshA2A.Email.Plug"
        }
      end ++
        for o <- @outcomes do
          %{
            id: "email_outcome:" <> o.name,
            kind: :email_outcome,
            name: o.name,
            source: "AshA2A.Email.Plug"
          }
        end
    end

    @doc """
    Drives the outcome `name` over the real wire against the server `info`
    describes and answers the observation: `%{outcome, status, landed, json, ...}`
    (see `send_reply/3`), plus `:steps` for outcomes that take more than one
    request.
    """
    @spec run(map(), String.t()) :: map()
    def run(info, name) do
      result = scenario(info, name)
      Map.put(result, :outcome, name)
    end

    defp scenario(info, "approved_reply_dispatched") do
      brief = issue_brief()
      r = send_reply(info, brief)
      Map.put(r, :brief, brief)
    end

    defp scenario(info, "held_reply_dispatches_nothing") do
      brief = issue_brief()
      r = send_reply(info, brief, text: "Hold 1.")
      Map.put(r, :brief, brief)
    end

    defp scenario(info, "replay_returns_cached_result") do
      brief = issue_brief()
      mid = "replay-#{unique()}@#{@domain}"
      first = send_reply(info, brief, message_id: mid)
      second = send_reply(info, brief, message_id: mid)

      second
      |> Map.put(:brief, brief)
      |> Map.put(:first, Map.take(first, [:status, :json, :landed, :added]))
    end

    defp scenario(info, "token_reuse_refused") do
      brief = issue_brief()
      first = send_reply(info, brief)
      second = send_reply(info, brief)

      second
      |> Map.put(:brief, brief)
      |> Map.put(:first, Map.take(first, [:status, :json, :landed, :added]))
    end

    defp scenario(info, "tampered_body_refused") do
      brief = issue_brief()
      send_reply(info, brief, tamper: :body_byte) |> Map.put(:brief, brief)
    end

    defp scenario(info, "forged_webhook_auth_refused") do
      brief = issue_brief()

      variants = [
        {"workspace: wrong secret", send_reply(info, brief, mount: :workspace, auth: :wrong)},
        {"workspace: no credential", send_reply(info, brief, mount: :workspace, auth: :none)},
        {"ses: envelope for another topic", send_reply(info, brief, topic: :wrong)}
      ]

      first_bad = Enum.find(variants, fn {_, r} -> r.status != 401 or r.landed end)
      {_label, shown} = first_bad || hd(variants)

      shown
      |> Map.put(:brief, brief)
      |> Map.put(
        :variants,
        for({label, r} <- variants, do: %{label: label, status: r.status, landed: r.landed})
      )
    end

    defp scenario(info, "unsigned_fields_not_trusted") do
      brief = issue_brief()
      # The signed message says "Hold 1."; the envelope claims "Approve 1.".
      signed = build_reply(brief, text: "Hold 1.")
      claimed = Map.put(signed.envelope, "text", "Approve 1.")
      before = snapshot()
      resp = post(info, claimed)
      after_ = snapshot()

      # A valid signature on an unrelated mail, with the sender, ids and tokens forged.
      other = build_reply(nil, in_reply_to: "unrelated", text: "hello", tokens: %{})

      forged =
        Map.merge(other.envelope, %{
          "from" => "approver@sim.example",
          "in_reply_to" => brief["brief_id"],
          "message_id" => "forged-#{unique()}",
          "text" => "Approve 1.",
          "reply_tokens" => brief["reply_tokens"]
        })

      resp2 = post(info, forged)
      after2 = snapshot()

      %{
        status: if(resp.status == 401, do: resp2.status, else: resp.status),
        json: if(resp.status == 401, do: resp2.json, else: resp.json),
        raw_body: resp.raw,
        headers: resp.headers,
        message_id: signed.message_id,
        signed_raw: signed.raw,
        landed: before != after_ or after_ != after2,
        added: titles(after2) -- titles(before),
        publications_before: length(before.publications),
        publications_after: length(after2.publications),
        rows_before: length(before.rows),
        rows_after: length(after2.rows),
        brief: brief
      }
    end

    defp scenario(info, "foreign_dkim_key_refused") do
      brief = issue_brief()
      send_reply(info, brief, sign: :foreign) |> Map.put(:brief, brief)
    end

    defp scenario(info, "dkim_length_limit_refused") do
      brief = issue_brief()
      send_reply(info, brief, dkim_tags: " l=5;") |> Map.put(:brief, brief)
    end

    defp scenario(info, "from_misaligned_refused") do
      brief = issue_brief()
      send_reply(info, brief, from_domain: "evil.example") |> Map.put(:brief, brief)
    end

    defp scenario(info, "unknown_sender_refused") do
      brief = issue_brief(bound: false)
      send_reply(info, brief, from: "stranger@sim.example") |> Map.put(:brief, brief)
    end

    defp scenario(info, "approver_binding_refused") do
      brief = issue_brief()
      send_reply(info, brief, from: "other@sim.example") |> Map.put(:brief, brief)
    end

    defp scenario(info, "reply_token_missing_refused") do
      brief = issue_brief()
      send_reply(info, brief, tokens: :none) |> Map.put(:brief, brief)
    end

    defp scenario(info, "reply_token_forged_refused") do
      brief = issue_brief()
      send_reply(info, brief, tokens: :forged) |> Map.put(:brief, brief)
    end

    defp scenario(info, "unknown_brief_refused") do
      send_reply(info, nil, in_reply_to: "brief.nonexistent#{unique()}@#{@domain}", tokens: %{})
    end

    defp scenario(info, "oversized_body_refused") do
      brief = issue_brief()
      send_reply(info, brief, padding: @max_body + 4_096) |> Map.put(:brief, brief)
    end

    defp scenario(info, "deeply_nested_body_refused") do
      brief = issue_brief()
      send_reply(info, brief, nest: 20) |> Map.put(:brief, brief)
    end

    defp scenario(info, "stale_graph_digest_refused") do
      brief = issue_brief()
      :ok = drift(brief["brief_id"])
      reset_deliveries()
      r = send_reply(info, brief)
      mail = Enum.find(deliveries().deliveries, &(&1["subject"] == "Reconfirm required"))
      fresh = mail && mail["reconfirm_brief"]

      reconfirmed =
        if fresh do
          second = send_reply(info, fresh)
          Map.take(second, [:status, :json, :landed, :added])
        end

      r
      |> Map.put(:brief, brief)
      |> Map.put(:reconfirm_mail, mail)
      |> Map.put(:reconfirm_approved, reconfirmed)
    end

    defp scenario(info, "ungranted_sender_refused") do
      brief = issue_brief(bound: false)
      send_reply(info, brief, from: "ungranted@sim.example") |> Map.put(:brief, brief)
    end

    defp scenario(info, "rate_limited") do
      {max, window} = @rate
      advance_clock(window + 1)

      replies =
        for _ <- 1..(max + 1) do
          send_reply(info, nil,
            from: "burst@sim.example",
            in_reply_to: "brief.nonexistent#{unique()}@#{@domain}",
            tokens: %{}
          )
        end

      statuses = Enum.map(replies, & &1.status)
      last = List.last(replies)

      result =
        last
        |> Map.put(:statuses, statuses)
        |> Map.put(:landed, Enum.any?(replies, & &1.landed))

      :ok = advance_clock(window + 1)
      result
    end

    # == judgement ================================================================

    @doc """
    Judges an observation `run/2` made against the outcome's expectation:
    `{:ok, detail}` or `{:error, reason}`. The mutation check applies to every
    outcome: a refusal must leave the rows as they were.
    """
    @spec evaluate(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
    def evaluate(name, result) do
      spec = outcome(name)

      checks =
        [
          {result.status == spec.status, "status #{result.status}, expected #{spec.status}"},
          {result.landed == spec.landed,
           "mutation #{if result.landed, do: "landed", else: "did not land"}, expected " <>
             if(spec.landed, do: "landed", else: "no change")},
          {is_nil(spec[:error]) or (result.json || %{})["error"] == spec[:error],
           "error #{inspect((result.json || %{})["error"])}, expected #{inspect(spec[:error])}"}
        ] ++ extra_checks(name, result)

      case Enum.find(checks, fn {ok, _} -> not ok end) do
        nil -> {:ok, detail(name, result)}
        {_, why} -> {:error, "#{name}: #{why}"}
      end
    end

    defp standing(result) do
      for r <- (result.json || %{})["results"] || [], do: {r["action"], r["standing"]}
    end

    defp extra_checks("approved_reply_dispatched", r) do
      title = r.brief["title"]

      [
        {standing(r) == [{1, "dispatched"}], "standing #{inspect(standing(r))}"},
        {r.added == [title], "rows added #{inspect(r.added)}, expected [#{inspect(title)}]"},
        {row(title) != nil, "no note row titled #{title}"},
        {r.publications_after == r.publications_before, "action 2 (not approved) published"}
      ]
    end

    defp extra_checks("held_reply_dispatches_nothing", r),
      do: [{standing(r) == [{1, "held"}], "standing #{inspect(standing(r))}"}]

    defp extra_checks("replay_returns_cached_result", r) do
      [
        {r.first.status == 200 and r.first.landed, "the first send did not execute"},
        {(r.json || %{})["replayed"] == true, "no `replayed: true` in #{inspect(r.json)}"},
        {standing(r) == [{1, "dispatched"}], "cached standing #{inspect(standing(r))}"},
        {length(row_titles(r.brief["title"])) == 1,
         "#{length(row_titles(r.brief["title"]))} rows for the title, expected exactly 1"}
      ]
    end

    defp extra_checks("token_reuse_refused", r) do
      [
        {r.first.status == 200 and r.first.landed, "the first send did not execute"},
        {length(row_titles(r.brief["title"])) == 1,
         "#{length(row_titles(r.brief["title"]))} rows for the title, expected exactly 1"}
      ]
    end

    defp extra_checks("forged_webhook_auth_refused", r),
      do: [
        {Enum.all?(r.variants, &(&1.status == 401 and not &1.landed)),
         "variants #{inspect(r.variants)}"}
      ]

    defp extra_checks("stale_graph_digest_refused", r) do
      mail = r.reconfirm_mail
      fresh = mail && mail["reconfirm_brief"]

      [
        {mail != nil, "no reconfirm mail was sent"},
        {fresh != nil and fresh["brief_id"] != r.brief["brief_id"],
         "no refreshed brief in the mail"},
        {r.reconfirm_approved != nil and r.reconfirm_approved.status == 200 and
           r.reconfirm_approved.landed and
           standing(%{json: r.reconfirm_approved.json}) == [{1, "dispatched"}],
         "the reconfirm brief could not be approved: #{inspect(r.reconfirm_approved)}"}
      ]
    end

    defp extra_checks("ungranted_sender_refused", r) do
      {:ok, sk} = AshA2A.Info.skill(Note, "create_note")
      subject = AshA2A.Identity.principal("sim-email-ungranted")

      [
        {standing(r) == [{1, "refused"}], "standing #{inspect(standing(r))}"},
        {not AshA2A.Authority.Grant.granted?(subject, sk.id),
         "the sender unexpectedly holds a standing grant"}
      ]
    end

    defp extra_checks("rate_limited", r) do
      {max, _} = @rate
      {ok, limited} = Enum.split(r.statuses, max)

      [
        {Enum.all?(ok, &(&1 == 404)),
         "the first #{max} requests answered #{inspect(Enum.uniq(ok))}"},
        {limited == [429], "request #{max + 1} answered #{inspect(limited)}"}
      ]
    end

    defp extra_checks(_name, _r), do: []

    defp row_titles(title),
      do: Note |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.title == title))

    defp detail(name, r) do
      error = (r.json || %{})["error"]
      base = "HTTP #{r.status}" <> if(error, do: " #{error}", else: "")
      mutation = if r.landed, do: "rows changed (#{inspect(r.added)})", else: "no row changed"
      extra = if name == "rate_limited", do: ", #{length(r.statuses)} requests", else: ""
      base <> ", " <> mutation <> extra
    end

    # == probes ===================================================================

    @doc """
    The probes of an email surface item: `[{label, fun}]`, each `fun` taking
    the server `info` and answering a detail string or raising
    `Sim.Prover.Failure`.
    """
    @spec probes(map()) :: [{String.t(), (map() -> String.t())}]
    def probes(%{kind: :email_outcome, name: name}) do
      [
        {"over the wire, and no refusal changes an Ash row",
         fn info ->
           case evaluate(name, run(info, name)) do
             {:ok, detail} -> detail
             {:error, why} -> raise AshA2A.Sim.Prover.Failure, message: why
           end
         end}
      ]
    end

    def probes(%{kind: :email_route, name: "POST /email/v1/email:ingest"}) do
      [
        {"a DKIM-signed approved reply is served and executes",
         fn info ->
           verdict(evaluate("approved_reply_dispatched", run(info, "approved_reply_dispatched")))
         end}
      ]
    end

    def probes(%{kind: :email_route, name: "POST /email-workspace/v1/email:ingest"}) do
      [
        {"a reply carrying the webhook secret is served and executes",
         fn info ->
           brief = issue_brief()
           r = send_reply(info, brief, mount: :workspace)
           check(r.status == 200, "HTTP #{r.status}: #{r.raw_body}")
           check(r.added == [brief["title"]], "rows added #{inspect(r.added)}")

           "HTTP 200, row #{inspect(brief["title"])} created through the secret-authenticated mount"
         end}
      ]
    end

    def probes(%{kind: :email_route, name: "GET /email/v1/email:ingest"}) do
      [
        {"any method but POST is 405 with allow: POST",
         fn info ->
           r = post(info, "", method: :get)
           check(r.status == 405, "HTTP #{r.status}: #{r.raw}")
           check(r.headers["allow"] == "POST", "allow header #{inspect(r.headers["allow"])}")
           "HTTP 405, allow: POST"
         end}
      ]
    end

    def probes(_item), do: []

    defp verdict({:ok, detail}), do: detail
    defp verdict({:error, why}), do: raise(AshA2A.Sim.Prover.Failure, message: why)

    defp check(true, _message), do: :ok
    defp check(_falsy, message), do: raise(AshA2A.Sim.Prover.Failure, message: message)

    # == helpers ==================================================================

    defp bare(id), do: id |> String.trim_leading("<") |> String.trim_trailing(">")
    defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
  end
end
