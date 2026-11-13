defmodule AshA2A.Email.Sender.Spool do
  @moduledoc """
  Real file-spool `AshA2A.Email.Sender`: writes each message as an RFC 5322
  `.eml` file under `:spool_dir` (opts or `config :ash_a2a, :email_spool_dir`,
  default `System.tmp_dir!/ash_a2a_spool`). An MTA pickup process or operator
  drains the directory. `gen_smtp` is not a dependency of this package.
  """
  @behaviour AshA2A.Email.Sender

  @impl true
  def deliver(msg, opts \\ []) do
    dir =
      Keyword.get(opts, :spool_dir) ||
        Application.get_env(:ash_a2a, :email_spool_dir) ||
        Path.join(System.tmp_dir!(), "ash_a2a_spool")

    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    path = Path.join(dir, "#{System.system_time(:microsecond)}-#{id}.eml")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, render(msg, id), [:exclusive]) do
      {:ok, %{path: path, message_id: id}}
    end
  end

  @doc false
  def render(msg, id) do
    extra =
      msg
      |> Map.get(:headers, %{})
      |> Enum.reject(fn {k, v} -> String.contains?(k <> v, ["\r", "\n"]) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{v}\r\n" end)

    IO.iodata_to_binary([
      "Message-ID: <#{id}@ash_a2a.spool>\r\n",
      "From: #{msg.from}\r\n",
      "To: #{msg.to}\r\n",
      "Subject: #{msg.subject}\r\n",
      "MIME-Version: 1.0\r\n",
      "Content-Type: text/plain; charset=utf-8\r\n",
      extra,
      "\r\n",
      msg.body
    ])
  end
end

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
