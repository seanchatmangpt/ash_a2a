# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Enterprise.DLPFilterTest do
  @moduledoc """
  DLP & Sovereignty court (PRD v26.10.4, FR-02.1/02.2).

  Real payloads with planted PAN/SSN/API key/PHI: tokens on the wire,
  plaintext never persisted (raw store scan), determinism (same input =>
  same token), reversal with the key, wrong-key non-reversal, and the 64KB
  <= 2.5ms inline-inspection perf budget. Zero mocks: the plug court drives
  a real Plug pipeline through `Plug.Test`.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Security.DLPFilter
  alias AshA2A.Security.DLPFilter.Plug, as: DLPPlug

  @key "dlp-court-key-0123456789abcdef-0123456789abcdef"
  @pan "4111111111111111"
  @ssn "219-09-9999"
  @api_key "sk-live-9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  @mrn "MRN: A1B2C3D4"

  defp opts(extra \\ []), do: Keyword.merge([key: @key], extra)

  # -- detection and redaction ------------------------------------------------

  describe "detection" do
    test "redacts a planted PAN, SSN, API key and PHI entity" do
      payload = %{
        "note" => "card #{@pan} charged",
        "detail" => %{"subject" => "SSN #{@ssn} verified"},
        "creds" => [@api_key],
        "chart" => "patient record #{@mrn} on file"
      }

      {redacted, findings} = DLPFilter.redact(payload, opts())

      assert %{
               "note" => "card dlt1_" <> _,
               "detail" => %{"subject" => "SSN dlt1_" <> _},
               "creds" => ["dlt1_" <> _],
               "chart" => "patient record MRN: dlt1_" <> _ <> " on file"
             } = redacted

      types = findings |> Enum.map(& &1.type) |> Enum.sort()
      assert types == [:api_key, :pan, :phi, :ssn]
      assert Enum.all?(findings, &is_map_key(&1, :token))
    end

    test "Luhn rejects non-card digit runs; valid PANs pass" do
      {redacted, findings} = DLPFilter.redact_string("invoice 1234567812345678 due", opts())
      assert redacted == "invoice 1234567812345678 due"
      assert findings == []

      {redacted, findings} = DLPFilter.redact_string("card 5555555555554444 on file", opts())
      assert redacted != "card 5555555555554444 on file"
      assert [%{type: :pan}] = findings
    end

    test "low-entropy tokens are not redacted (no false positive)" do
      {redacted, findings} =
        DLPFilter.redact_string("contact administrator-at-the-main-office", opts())

      assert redacted == "contact administrator-at-the-main-office"
      assert findings == []
    end

    test "PHI patterns are configurable" do
      patterns = [%{id: :dea, pattern: ~r/\bDEA[:#\s]*[A-Z]{2}\d{7}\b/}]

      {redacted, findings} =
        DLPFilter.redact_string("DEA: AB1234563 filed", opts(phi_patterns: patterns))

      assert redacted == "DEA: dlt1_" <> _ <> " filed"
      assert [%{type: :phi, pattern: :dea}] = findings
    end

    test "disabled filter is a no-op" do
      payload = %{"note" => "card #{@pan}"}
      assert {^payload, []} = DLPFilter.redact(payload, opts(enabled: false))
    end
  end

  # -- wire form and persistence ----------------------------------------------

  describe "wire and persistence" do
    test "wire form carries tokens, never plaintext" do
      payload = build_payload()

      {redacted, _} = DLPFilter.redact(payload, opts())
      wire = Jason.encode!(redacted)

      refute wire =~ @pan
      refute wire =~ @ssn
      refute wire =~ @api_key
      refute wire =~ "A1B2C3D4"
      assert wire =~ "dlt1_"
    end

    test "raw store scan: redacted payload persists with zero plaintext bytes" do
      path = Path.join(System.tmp_dir!(), "dlp-court-store-#{System.unique_integer()}.json")
      payload = build_payload()

      {redacted, _} = DLPFilter.redact(payload, opts())
      File.write!(path, Jason.encode!(redacted))

      raw = File.read!(path)
      refute raw =~ @pan
      refute raw =~ @ssn
      refute raw =~ @api_key
      refute raw =~ "A1B2C3D4"

      # and the persisted form still reverses with the key
      restored = path |> File.read!() |> Jason.decode!() |> DLPFilter.restore(opts())
      assert restored == payload

      File.rm(path)
    end
  end

  # -- determinism and reversal ------------------------------------------------

  describe "pseudonymization" do
    test "same PAN yields the same token across occurrences and calls" do
      {r1, f1} = DLPFilter.redact(%{"a" => "card #{@pan}", "b" => "again #{@pan}"}, opts())
      %{"a" => ta, "b" => tb} = r1
      assert ta == tb
      assert [f1a, f1b] = f1
      assert f1a.token == f1b.token

      {r2, _} = DLPFilter.redact(%{"a" => "card #{@pan}", "b" => "again #{@pan}"}, opts())
      assert r1 == r2
    end

    test "reversal with the key restores the original payload" do
      payload = build_payload()
      {redacted, _} = DLPFilter.redact(payload, opts())
      assert DLPFilter.restore(redacted, opts()) == payload
    end

    test "wrong key fails authenticated decryption and leaves tokens in place" do
      payload = %{"note" => "card #{@pan}"}
      {redacted, _} = DLPFilter.redact(payload, opts(key: @key))
      wrong = DLPFilter.restore(redacted, opts(key: String.duplicate("x", 32)))
      assert wrong == redacted
      refute wrong =~ @pan
    end

    test "tokens are typed: same digits as PAN vs raw string give distinct tokens" do
      {_, [f1]} = DLPFilter.redact_string("card #{@pan}", opts())
      token1 = AshA2A.Security.DLP.Pseudonym.token(@pan, :pan, @key)
      token2 = AshA2A.Security.DLP.Pseudonym.token(@pan, :ssn, @key)
      assert f1.token == token1
      refute token1 == token2
    end
  end

  # -- perf budget (FR: <= 2.5ms per 64KB payload) ------------------------------

  describe "perf budget" do
    @tag :dlp_perf
    test "inspecting a 64KB payload stays within the 2.5ms budget" do
      payload = perf_payload()
      assert byte_size(payload) >= 64 * 1024
      runs = 25

      times =
        for _ <- 1..runs do
          {us, {_, findings}} = :timer.tc(fn -> DLPFilter.redact_string(payload, opts()) end)
          assert length(findings) >= 3
          us
        end

      median = times |> Enum.sort() |> Enum.at(div(runs, 2))
      best = Enum.min(times)
      assert median <= 2_500, "median #{median}us exceeds 2.5ms/64KB budget (best #{best}us)"
      IO.puts("[dlp perf] 64KB redact: median #{median}us, best #{best}us over #{runs} runs")
    end
  end

  # -- plug integration ----------------------------------------------------------

  describe "plug (both directions)" do
    defmodule EchoPlug do
      @moduledoc "Real inner plug: reflects the decoded body it actually received."
      @behaviour Plug
      def init(opts), do: opts
      def call(conn, _opts) do
        body = conn.assigns[:raw] || read_inbound(conn)

        resp_body =
          case Jason.decode(body) do
            {:ok, %{"params" => params}} ->
              Jason.encode!(%{
                jsonrpc: "2.0",
                id: 1,
                result: %{"echo" => params, "pan" => "4111111111111111"}
              })

            _ ->
              Jason.encode!(%{jsonrpc: "2.0", id: 1, result: %{"echo" => nil}})
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, resp_body)
      end

      defp read_inbound(conn) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Process.put(:dlp_echo_inbound, body)
        body
      end
    end

    test "inbound params are redacted before the inner plug reads the body" do
      conn =
        Plug.Test.conn(:post, "/a2a", inbound_body())
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> DLPPlug.call(DLPPlug.init(inner: EchoPlug, dlp: opts()))

      assert conn.status == 200
      inbound = Process.get(:dlp_echo_inbound)
      refute inbound =~ @pan
      refute inbound =~ @ssn
      assert inbound =~ "dlt1_"
    end

    test "outbound response body is redacted before it leaves" do
      conn =
        Plug.Test.conn(:post, "/a2a", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "message/send", params: %{}}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> DLPPlug.call(DLPPlug.init(inner: EchoPlug, dlp: opts()))

      body = conn.resp_body || ""
      refute body =~ @pan
      assert body =~ "dlt1_"
    end

    defp inbound_body do
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "message/send",
        params: %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"kind" => "text", "text" => "card #{@pan} SSN #{@ssn} key #{@api_key}"}]
          }
        }
      })
    end
  end

  # -- fixtures ------------------------------------------------------------

  defp build_payload do
    %{
      "note" => "card #{@pan}",
      "detail" => %{"subject" => "SSN #{@ssn}"},
      "creds" => [@api_key],
      "chart" => "patient record #{@mrn} on file"
    }
  end

  defp perf_payload do
    secret =
      "card 4111111111111111 SSN 219-09-9999 MRN: A1B2C3D4 " <>
        "key sk-live-9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 "

    filler = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor "

    1..1300
    |> Enum.map(fn i ->
      prefix = if rem(i, 100) == 0, do: secret, else: ""
      prefix <> filler <> Integer.to_string(i) <> " "
    end)
    |> Enum.join()
    |> String.slice(0, 64 * 1024)
  end
end
