defmodule AshA2A.Email.Brief do
  @moduledoc """
  Pure renderer for the Email-to-A2A daily brief.

  The operator receives a plain-text (plus minimal HTML) brief with numbered
  escalations and replies with the action number. Each action is pinned to a
  content-addressed `graph_digest` (the same `"sha256:" <> 64 lowercase hex`
  shape `AshA2A.Hilt.WorkOrder` carries as checkpoint evidence), so the
  digest the operator approves is the digest the later
  `WorkOrder.bind_command/2` / graph-digest checkpoint compares against.

  Digests:

    * brief digest: sha256 over the canonical actions (`n`, `summary`,
      `action`, `args`, `graph_digest`), ordered by `n`.
    * action digest: sha256 over one canonical action.
    * reply token for action `n`: a keyed MAC, `key_id <> base64url(HMAC-SHA256)` (49
      characters, URL and email safe), over the canonical bytes of (brief digest, `n`,
      the action's `graph_digest`, the brief's `:approver` or `""`, the brief's
      `:expires_at` unix seconds or `0` for no expiry). The server secret is
      `config :ash_a2a, :email_token_key` (at least 32 bytes; no default). The previous key
      `:email_token_key_previous` still verifies, so keys rotate. Per-call `:key`,
      `:previous_key` and `:now` options override the configuration. With no key the
      functions refuse with `:email_token_key_missing`; a short key is refused with
      `:email_token_key_too_short`. The key id is public (4 bytes of a hash of the key).

  Output is deterministic for a given key: identical input yields byte-identical output.
  No IO, no randomness; `verify_reply_token/4` reads the clock only to check `:expires_at`. `opts`: `:domain` (default `"a2a.local"`).
  """

  @type action :: %{
          required(:n) => pos_integer(),
          required(:summary) => String.t(),
          required(:action) => atom(),
          required(:args) => map(),
          required(:graph_digest) => binary()
        }

  @type section :: %{heading: String.t(), lines: [String.t()]}

  @type brief :: %{
          required(:title) => String.t(),
          required(:date) => String.t(),
          required(:sections) => [section()],
          required(:actions) => [action()]
        }

  @type rendered :: %{
          subject: String.t(),
          message_id: String.t(),
          headers: [{String.t(), String.t()}],
          text: String.t(),
          html: String.t()
        }

  @default_domain "a2a.local"
  @min_key_bytes 32
  @kid_bytes 4
  @token_bytes 6 + 43

  defmodule TokenKeyError do
    @moduledoc "Raised when the email token key is missing or too short. `reason` is the typed code."
    defexception [:reason]
    @impl true
    def message(%{reason: reason}), do: "email reply token key refused: #{reason}"
  end

  @doc """
  `true` when `config :ash_a2a, :email_token_key` holds a usable key (a binary of at least
  32 bytes). Reads only the configuration; never returns the key.
  """
  @spec token_key_configured?() :: boolean()
  def token_key_configured?, do: match?({:ok, _}, keyring([]))

  @doc """
  Resolve the signing and verification keys from `opts` (`:key`, `:previous_key`) or the
  application config. `{:ok, [current | previous]}` or
  `{:error, :email_token_key_missing | :email_token_key_too_short}`.
  """
  @spec keyring(keyword()) ::
          {:ok, [binary()]} | {:error, :email_token_key_missing | :email_token_key_too_short}
  def keyring(opts) do
    current = Keyword.get(opts, :key) || Application.get_env(:ash_a2a, :email_token_key)

    previous =
      Keyword.get(opts, :previous_key) || Application.get_env(:ash_a2a, :email_token_key_previous)

    cond do
      is_nil(current) or current == "" -> {:error, :email_token_key_missing}
      not is_binary(current) -> {:error, :email_token_key_missing}
      byte_size(current) < @min_key_bytes -> {:error, :email_token_key_too_short}
      is_nil(previous) -> {:ok, [current]}
      is_binary(previous) and byte_size(previous) >= @min_key_bytes -> {:ok, [current, previous]}
      true -> {:error, :email_token_key_too_short}
    end
  end

  @doc "Render a brief map into subject, Message-ID, headers, text and html."
  @spec render(brief(), keyword()) :: rendered()
  def render(brief, opts \\ []) when is_map(brief) do
    domain = Keyword.get(opts, :domain, @default_domain)
    actions = sorted_actions(brief)
    Enum.each(actions, &validate_action!/1)

    digest = brief_digest(brief)
    short = short(digest)
    keys = keyring!(opts)
    message_id = "<brief.#{short}@#{domain}>"
    subject = "[A2A Brief] #{brief.title} - #{brief.date}"

    headers =
      [
        {"Message-ID", message_id},
        {"X-A2A-Brief-Digest", "sha256:" <> digest}
      ] ++
        Enum.map(actions, fn a ->
          {"A2A-Action-#{a.n}", mint(brief, a.n, keys)}
        end)

    %{
      subject: subject,
      message_id: message_id,
      headers: headers,
      text: render_text(brief, actions),
      html: render_html(brief, actions)
    }
  end

  @doc "Hex sha256 (no prefix) over the canonical actions of the brief."
  @spec brief_digest(brief()) :: String.t()
  def brief_digest(brief) do
    brief
    |> sorted_actions()
    |> Enum.map(&canonical_action/1)
    |> Enum.join("\n")
    |> sha256_hex()
  end

  @doc """
  Per-action keyed reply token bound to the brief, action `n`, its graph digest, the
  approver and the expiry. Raises `AshA2A.Email.Brief.TokenKeyError` without a usable key.
  """
  @spec reply_token(brief(), pos_integer(), keyword()) :: String.t()
  def reply_token(brief, n, opts \\ []) when is_integer(n) do
    mint(brief, n, keyring!(opts))
  end

  @doc """
  Verify a reply token for action `n`. Returns `:ok` or
  `{:error, :unknown_action | :bad_token | :expired_token | :email_token_key_missing |
  :email_token_key_too_short}`. The MAC is checked first (against the current, then the
  previous key named by the token's key id) and compared in constant time; only a
  genuine token is then checked against `:expires_at`.
  """
  @spec verify_reply_token(brief(), pos_integer(), term(), keyword()) ::
          :ok
          | {:error,
             :unknown_action
             | :bad_token
             | :expired_token
             | :email_token_key_missing
             | :email_token_key_too_short}
  def verify_reply_token(brief, n, token, opts \\ []) do
    with {:ok, keys} <- keyring(opts) do
      cond do
        not is_integer(n) or not Enum.any?(sorted_actions(brief), &(&1.n == n)) ->
          {:error, :unknown_action}

        not is_binary(token) ->
          {:error, :bad_token}

        true ->
          token = String.trim(token)
          <<kid::binary-size(6), _::binary>> = token <> String.duplicate("\0", 6)
          key = Enum.find(keys, &(key_id(&1) == kid))

          cond do
            byte_size(token) != @token_bytes or is_nil(key) ->
              {:error, :bad_token}

            not Plug.Crypto.secure_compare(token, mint(brief, n, [key])) ->
              {:error, :bad_token}

            expired?(brief, opts) ->
              {:error, :expired_token}

            true ->
              :ok
          end
      end
    end
  end

  defp keyring!(opts) do
    case keyring(opts) do
      {:ok, keys} -> keys
      {:error, reason} -> raise TokenKeyError, reason: reason
    end
  end

  defp mint(brief, n, [key | _]) do
    action = Enum.find(sorted_actions(brief), &(&1.n == n))
    if is_nil(action), do: raise(ArgumentError, "no action numbered #{n}")

    payload =
      canon([
        "ash_a2a.email.reply_token.v2",
        brief_digest(brief),
        n,
        action.graph_digest,
        approver(brief),
        expires_at(brief)
      ])

    key_id(key) <> Base.url_encode64(:crypto.mac(:hmac, :sha256, key, payload), padding: false)
  end

  defp key_id(key) do
    :crypto.hash(:sha256, "ash_a2a.email.token_key_id" <> key)
    |> binary_part(0, @kid_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp approver(brief), do: to_string(Map.get(brief, :approver) || "")

  defp expires_at(brief) do
    case Map.get(brief, :expires_at) do
      i when is_integer(i) and i > 0 -> i
      _ -> 0
    end
  end

  defp expired?(brief, opts) do
    case expires_at(brief) do
      0 -> false
      at -> Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end) > at
    end
  end

  # -- rendering ------------------------------------------------------------

  defp render_text(brief, actions) do
    sections =
      Enum.map(sections(brief), fn s ->
        [s.heading, String.duplicate("-", String.length(s.heading)), Enum.join(s.lines, "\n")]
        |> Enum.join("\n")
      end)

    acts =
      case actions do
        [] ->
          []

        _ ->
          [
            "ACTIONS\n-------\n" <>
              Enum.map_join(actions, "\n", fn a ->
                "[#{a.n}] #{a.summary}\n    Reply with the number to approve.\n" <>
                  "    graph_digest: #{a.graph_digest}"
              end)
          ]
      end

    ([brief.title <> " - " <> brief.date] ++ sections ++ acts)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp render_html(brief, actions) do
    sections =
      Enum.map_join(sections(brief), "", fn s ->
        "<h2>#{esc(s.heading)}</h2>\n<ul>\n" <>
          Enum.map_join(s.lines, "", &"<li>#{esc(&1)}</li>\n") <> "</ul>\n"
      end)

    acts =
      case actions do
        [] ->
          ""

        _ ->
          "<h2>Actions</h2>\n<ol>\n" <>
            Enum.map_join(actions, "", fn a ->
              "<li value=\"#{a.n}\">[#{a.n}] #{esc(a.summary)} " <>
                "<em>Reply with the number to approve.</em></li>\n"
            end) <> "</ol>\n"
      end

    "<!DOCTYPE html>\n<html><body>\n<h1>#{esc(brief.title)} - #{esc(brief.date)}</h1>\n" <>
      sections <> acts <> "</body></html>\n"
  end

  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # -- canonical encoding -----------------------------------------------------

  defp sections(brief), do: Map.get(brief, :sections, [])

  defp sorted_actions(brief),
    do: brief |> Map.get(:actions, []) |> Enum.sort_by(& &1.n)

  defp validate_action!(%{n: n, action: a, graph_digest: "sha256:" <> hex})
       when is_integer(n) and n > 0 and is_atom(a) and byte_size(hex) == 64 do
    if String.match?(hex, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: raise(ArgumentError, "graph_digest must be sha256: followed by 64 lowercase hex")
  end

  defp validate_action!(other),
    do: raise(ArgumentError, "invalid brief action: #{inspect(other)}")

  defp canonical_action(a) do
    canon([a.n, a.summary, a.action, Map.get(a, :args, %{}), a.graph_digest])
  end

  # Deterministic term encoding: maps are key-sorted, atoms/strings tagged.
  defp canon(m) when is_map(m) do
    body =
      m
      |> Enum.map(fn {k, v} -> {canon(k), canon(v)} end)
      |> Enum.sort()
      |> Enum.map_join(",", fn {k, v} -> k <> "=>" <> v end)

    "{" <> body <> "}"
  end

  defp canon(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &canon/1) <> "]"
  defp canon(t) when is_tuple(t), do: canon({:tuple, Tuple.to_list(t)})
  defp canon(b) when is_binary(b), do: "s" <> Integer.to_string(byte_size(b)) <> ":" <> b
  defp canon(nil), do: "nil"
  defp canon(a) when is_atom(a), do: "a:" <> Atom.to_string(a)
  defp canon(i) when is_integer(i), do: "i:" <> Integer.to_string(i)
  defp canon(f) when is_float(f), do: "f:" <> Float.to_string(f)
  defp canon(other), do: "x:" <> inspect(other)

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  defp short(hex), do: binary_part(hex, 0, 16)
end
