defmodule AshA2A.Email.Sender.SMTP do
  @moduledoc """
  SMTP `AshA2A.Email.Sender`. Requires the optional `:gen_smtp` dependency in the
  host app; without it `deliver/2` returns `{:error, :gen_smtp_not_available}`.
  Opts: `:relay`, `:port`, `:username`, `:password`.
  """
  @behaviour AshA2A.Email.Sender

  @impl true
  def deliver(msg, opts \\ []) do
    if Code.ensure_loaded?(:gen_smtp_client) do
      raw =
        IO.iodata_to_binary([
          "From: #{msg.from}\r\nTo: #{msg.to}\r\nSubject: #{msg.subject}\r\n",
          "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n",
          msg.body
        ])

      smtp_opts =
        Keyword.take(opts, [:relay, :port, :username, :password]) ++ [auth: :if_available]

      # credo:disable-for-next-line
      case apply(:gen_smtp_client, :send_blocking, [{msg.from, [msg.to], raw}, smtp_opts]) do
        {:error, _, _} = e -> {:error, e}
        {:error, _} = e -> e
        receipt -> {:ok, receipt}
      end
    else
      {:error, :gen_smtp_not_available}
    end
  end
end
