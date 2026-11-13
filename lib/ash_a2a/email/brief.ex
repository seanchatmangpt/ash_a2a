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
    * reply token for action `n`: first 16 hex of
      sha256(`brief_digest`, `n`, `action_digest`).

  Output is deterministic: identical input yields byte-identical output. No IO,
  no clock, no randomness. `opts`: `:domain` (default `"a2a.local"`).
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

  @doc "Render a brief map into subject, Message-ID, headers, text and html."
  @spec render(brief(), keyword()) :: rendered()
  def render(brief, opts \\ []) when is_map(brief) do
    domain = Keyword.get(opts, :domain, @default_domain)
    actions = sorted_actions(brief)
    Enum.each(actions, &validate_action!/1)

    digest = brief_digest(brief)
    short = short(digest)
    message_id = "<brief.#{short}@#{domain}>"
    subject = "[A2A Brief] #{brief.title} - #{brief.date}"

    headers =
      [
        {"Message-ID", message_id},
        {"X-A2A-Brief-Digest", "sha256:" <> digest}
      ] ++
        Enum.map(actions, fn a ->
          {"A2A-Action-#{a.n}", reply_token(brief, a.n)}
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

  @doc "Per-action reply token (16 hex) bound to the brief digest and action `n`."
  @spec reply_token(brief(), pos_integer()) :: String.t()
  def reply_token(brief, n) when is_integer(n) do
    action = Enum.find(sorted_actions(brief), &(&1.n == n))

    if is_nil(action), do: raise(ArgumentError, "no action numbered #{n}")

    [brief_digest(brief), Integer.to_string(n), sha256_hex(canonical_action(action))]
    |> Enum.join(":")
    |> sha256_hex()
    |> short()
  end

  @doc """
  Verify a reply token for action `n`. Returns `:ok` or
  `{:error, :unknown_action | :bad_token}`.
  """
  @spec verify_reply_token(brief(), pos_integer(), term()) ::
          :ok | {:error, :unknown_action | :bad_token}
  def verify_reply_token(brief, n, token) do
    cond do
      not is_integer(n) or not Enum.any?(sorted_actions(brief), &(&1.n == n)) ->
        {:error, :unknown_action}

      is_binary(token) and secure_equal?(String.trim(token), reply_token(brief, n)) ->
        :ok

      true ->
        {:error, :bad_token}
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

  defp secure_equal?(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_, _), do: false
end
