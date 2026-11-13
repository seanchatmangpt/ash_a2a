defmodule AshA2A.Email.Inbound do
  @moduledoc """
  Pure inbound-email parsing and sender verification for the Email-to-A2A gateway.

  * `parse/1` accepts either a raw RFC 5322 message (binary) or a webhook map
    (SES / SendGrid / Workspace style, string or atom keys) and returns an `%Inbound{}`.
  * `verify_sender/2` consumes the upstream-supplied Authentication-Results verdicts
    (dkim / spf / dmarc) plus a sender allowlist. No DKIM cryptography is performed here.
    It fails closed: missing or non-`pass` verdicts, or a sender absent from the allowlist,
    are errors.
  * `reply_text/1` strips quoted reply text.

  Principle: authentication never confers authority. The principal map returned by
  `verify_sender/2` carries identity only (`authority: :none`); any authority must come
  from an `AshA2A.Authority.Grant` evaluated downstream by the governed pipeline.

  This module performs no IO.

  ## Policy

      %{
        allowlist: %{"vito@example.com" => "principal:vito"},
        require: [:dkim, :spf, :dmarc]   # optional, default shown
      }
  """

  defstruct from: nil,
            to: [],
            subject: "",
            message_id: nil,
            in_reply_to: nil,
            references: [],
            body_text: "",
            attachments: [],
            auth_results: %{}

  @type verdict :: :pass | :fail | :none
  @type auth_results :: %{optional(:dkim | :spf | :dmarc) => verdict()}

  @type t :: %__MODULE__{
          from: String.t() | nil,
          to: [String.t()],
          subject: String.t(),
          message_id: String.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          body_text: String.t(),
          attachments: [map()],
          auth_results: auth_results()
        }

  @type policy :: %{
          required(:allowlist) => %{optional(String.t()) => String.t()},
          optional(:require) => [:dkim | :spf | :dmarc]
        }

  @type principal :: %{
          id: String.t(),
          address: String.t(),
          authenticated_via: :email,
          authority: :none
        }

  @type verify_error ::
          :dkim_fail | :spf_fail | :dmarc_fail | :sender_not_allowlisted | :unsigned

  @default_require [:dkim, :spf, :dmarc]

  # ---------------------------------------------------------------- parse

  @spec parse(binary() | map()) :: {:ok, t()} | {:error, term()}
  def parse(raw) when is_binary(raw), do: parse_raw(raw)

  def parse(%{} = map) do
    m = stringify(map)

    case address(first(m, ["from", "sender"])) do
      nil ->
        {:error, :missing_from}

      from ->
        headers = headers_map(m["headers"])

        auth =
          cond do
            is_map(m["auth_results"]) -> normalize_auth(m["auth_results"])
            is_map(m["authentication_results"]) -> normalize_auth(m["authentication_results"])
            is_binary(m["authentication_results"]) -> parse_auth_header(m["authentication_results"])
            h = headers["authentication-results"] -> parse_auth_header(h)
            true -> normalize_auth(%{"dkim" => m["dkim"], "spf" => m["spf"], "dmarc" => m["dmarc"]})
          end

        {:ok,
         %__MODULE__{
           from: from,
           to: addresses(first(m, ["to", "recipient"])),
           subject: to_string(m["subject"] || headers["subject"] || ""),
           message_id: clean_id(first(m, ["message_id", "message-id"]) || headers["message-id"]),
           in_reply_to:
             clean_id(first(m, ["in_reply_to", "in-reply-to"]) || headers["in-reply-to"]),
           references: ids(first(m, ["references"]) || headers["references"]),
           body_text: to_string(first(m, ["text", "body_text", "body", "plain"]) || ""),
           attachments: List.wrap(m["attachments"]) |> Enum.filter(&is_map/1),
           auth_results: auth
         }}
    end
  end

  def parse(_), do: {:error, :unsupported_input}

  defp parse_raw(raw) do
    raw = String.replace(raw, "\r\n", "\n")

    case String.split(raw, "\n\n", parts: 2) do
      [head, body] -> build_raw(head, body)
      [head] -> build_raw(head, "")
    end
  end

  defp build_raw(head, body) do
    h = parse_headers(head)

    case address(h["from"]) do
      nil ->
        {:error, :missing_from}

      from ->
        {text, atts} = extract_body(h["content-type"], body)

        {:ok,
         %__MODULE__{
           from: from,
           to: addresses(h["to"]),
           subject: h["subject"] || "",
           message_id: clean_id(h["message-id"]),
           in_reply_to: clean_id(h["in-reply-to"]),
           references: ids(h["references"]),
           body_text: text,
           attachments: atts,
           auth_results: parse_auth_header(h["authentication-results"] || "")
         }}
    end
  end

  defp parse_headers(head) do
    head
    |> String.split("\n")
    |> Enum.reduce([], fn
      <<c, _::binary>> = line, [{k, v} | rest] when c in [?\s, ?\t] ->
        [{k, v <> " " <> String.trim(line)} | rest]

      line, acc ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> [{String.downcase(String.trim(k)), String.trim(v)} | acc]
          _ -> acc
        end
    end)
    |> Enum.reverse()
    # first occurrence wins
    |> Enum.reduce(%{}, fn {k, v}, m -> Map.put_new(m, k, v) end)
  end

  defp extract_body(content_type, body) do
    ct = content_type || "text/plain"

    case Regex.run(~r/boundary="?([^";\s]+)"?/i, ct) do
      [_, boundary] when is_binary(boundary) ->
        parts =
          body
          |> String.split("--" <> boundary)
          |> Enum.drop(1)
          |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "--"))
          |> Enum.map(fn part ->
            part = String.trim_leading(part, "\n")

            case String.split(part, "\n\n", parts: 2) do
              [ph, pb] -> {parse_headers(ph), pb}
              [ph] -> {parse_headers(ph), ""}
            end
          end)

        text =
          Enum.find_value(parts, "", fn {ph, pb} ->
            pct = String.downcase(ph["content-type"] || "text/plain")

            if String.starts_with?(pct, "text/plain") and
                 not String.contains?(String.downcase(ph["content-disposition"] || ""), "attachment"),
               do: String.trim_trailing(pb)
          end)

        atts =
          for {ph, _} <- parts,
              String.contains?(String.downcase(ph["content-disposition"] || ""), "attachment") do
            %{
              "content_type" => ph["content-type"],
              "filename" =>
                case Regex.run(~r/filename="?([^";]+)"?/i, ph["content-disposition"] || "") do
                  [_, f] -> f
                  _ -> nil
                end
            }
          end

        {text, atts}

      _ ->
        {String.trim_trailing(body), []}
    end
  end

  # --------------------------------------------------------- verify_sender

  @spec verify_sender(t(), policy()) :: {:ok, principal()} | {:error, verify_error()}
  def verify_sender(%__MODULE__{} = inbound, %{} = policy) do
    required = Map.get(policy, :require, @default_require)
    auth = inbound.auth_results || %{}

    with :ok <- check_signed(auth, required),
         :ok <- check_verdicts(auth, required),
         {:ok, principal_id} <- check_allowlist(inbound.from, Map.get(policy, :allowlist, %{})) do
      {:ok,
       %{
         id: principal_id,
         address: inbound.from,
         authenticated_via: :email,
         authority: :none
       }}
    end
  end

  defp check_signed(auth, required) do
    if map_size(auth) == 0 or Enum.all?(required, &(Map.get(auth, &1, :none) == :none)),
      do: {:error, :unsigned},
      else: :ok
  end

  defp check_verdicts(auth, required) do
    Enum.find_value(required, :ok, fn k ->
      if Map.get(auth, k, :none) == :pass, do: nil, else: {:error, :"#{k}_fail"}
    end)
  end

  defp check_allowlist(nil, _), do: {:error, :sender_not_allowlisted}

  defp check_allowlist(from, allowlist) do
    table = Map.new(allowlist, fn {k, v} -> {String.downcase(to_string(k)), v} end)

    case Map.fetch(table, String.downcase(from)) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :sender_not_allowlisted}
    end
  end

  # ------------------------------------------------------------ reply_text

  @doc """
  Returns the new text of a reply, with quoted lines (`>`), the `On ... wrote:` tail,
  and a trailing `-- ` signature removed.
  """
  @spec reply_text(t() | String.t()) :: String.t()
  def reply_text(%__MODULE__{body_text: body}), do: reply_text(body)

  def reply_text(body) when is_binary(body) do
    lines = body |> String.replace("\r\n", "\n") |> String.split("\n")
    {kept, _} = Enum.split_while(lines, &(not attribution?(&1)))

    kept
    |> Enum.take_while(&(&1 != "-- "))
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), ">"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp attribution?(line) do
    t = String.trim(line)

    (String.starts_with?(t, "On ") and String.ends_with?(t, "wrote:")) or
      Regex.match?(~r/^-{2,}\s*Original Message\s*-{2,}$/i, t) or
      # attribution wrapped onto next line: "On Mon, ... <a@b>" without terminator
      (String.starts_with?(t, "On ") and Regex.match?(~r/\d{4}.*(<[^>]+>|at \d)/, t) and
         not String.ends_with?(t, "."))
  end

  # --------------------------------------------------------------- helpers

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp first(m, keys), do: Enum.find_value(keys, &m[&1])

  defp headers_map(nil), do: %{}

  defp headers_map(list) when is_list(list) do
    Enum.reduce(list, %{}, fn
      %{} = h, acc ->
        h = stringify(h)
        name = h["name"] || h["key"]
        if name, do: Map.put_new(acc, String.downcase(to_string(name)), h["value"]), else: acc

      {k, v}, acc ->
        Map.put_new(acc, String.downcase(to_string(k)), v)

      _, acc ->
        acc
    end)
  end

  defp headers_map(%{} = m), do: Map.new(m, fn {k, v} -> {String.downcase(to_string(k)), v} end)
  defp headers_map(_), do: %{}

  defp address(nil), do: nil
  defp address(%{} = m), do: address(stringify(m)["email"] || stringify(m)["address"])

  defp address(s) when is_binary(s) do
    case Regex.run(~r/<([^<>\s]+@[^<>\s]+)>/, s) || Regex.run(~r/([^\s<>,;"]+@[^\s<>,;"]+)/, s) do
      [_, a] -> String.downcase(a)
      _ -> nil
    end
  end

  defp address(_), do: nil

  defp addresses(nil), do: []
  defp addresses(l) when is_list(l), do: l |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)

  defp addresses(s) when is_binary(s),
    do: s |> String.split(",") |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)

  defp addresses(_), do: []

  defp clean_id(nil), do: nil

  defp clean_id(s) when is_binary(s) do
    case String.trim(s) |> String.trim_leading("<") |> String.trim_trailing(">") do
      "" -> nil
      id -> id
    end
  end

  defp clean_id(_), do: nil

  defp ids(nil), do: []
  defp ids(l) when is_list(l), do: l |> Enum.map(&clean_id/1) |> Enum.reject(&is_nil/1)

  defp ids(s) when is_binary(s) do
    case Regex.scan(~r/<([^<>\s]+)>/, s) do
      [] -> s |> String.split() |> Enum.map(&clean_id/1) |> Enum.reject(&is_nil/1)
      m -> Enum.map(m, fn [_, i] -> i end)
    end
  end

  defp ids(_), do: []

  defp parse_auth_header(s) when is_binary(s) do
    for k <- ["dkim", "spf", "dmarc"], reduce: %{} do
      acc ->
        case Regex.run(~r/(?:^|[;\s])#{k}=([a-z]+)/i, s) do
          [_, v] -> Map.put(acc, String.to_atom(k), verdict(v))
          _ -> acc
        end
    end
  end

  defp parse_auth_header(_), do: %{}

  defp normalize_auth(m) do
    m = stringify(m)

    for k <- ["dkim", "spf", "dmarc"], v = m[k], not is_nil(v), into: %{} do
      {String.to_atom(k), verdict(v)}
    end
  end

  defp verdict(v) do
    case v |> to_string() |> String.downcase() do
      "pass" -> :pass
      "none" -> :none
      "" -> :none
      _ -> :fail
    end
  end
end
