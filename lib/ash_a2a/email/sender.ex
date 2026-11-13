defmodule AshA2A.Email.Sender do
  @moduledoc """
  Behaviour for outbound email delivery of governed-action briefs.

  Implementations: `AshA2A.Email.Sender.Spool` (file spool, no deps) and
  `AshA2A.Email.Sender.SMTP` (gen_smtp, only when that optional dep is present).
  """

  @type message :: %{
          required(:to) => String.t(),
          required(:from) => String.t(),
          required(:subject) => String.t(),
          required(:body) => String.t(),
          optional(:headers) => %{optional(String.t()) => String.t()}
        }

  @callback deliver(message(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Validate required message fields. Rejects CR/LF in header-bound fields."
  @spec validate(map()) :: :ok | {:error, {:invalid_message, atom()}}
  def validate(msg) when is_map(msg) do
    Enum.find_value([:to, :from, :subject, :body], :ok, fn key ->
      case Map.get(msg, key) do
        v when is_binary(v) and v != "" ->
          if key != :body and String.contains?(v, ["\r", "\n"]),
            do: {:error, {:invalid_message, key}},
            else: nil

        _ ->
          {:error, {:invalid_message, key}}
      end
    end)
  end

  def validate(_), do: {:error, {:invalid_message, :message}}

  @doc "Deliver through `module` (a `#{inspect(__MODULE__)}` implementation)."
  @spec deliver(module(), message(), keyword()) :: {:ok, term()} | {:error, term()}
  def deliver(module, msg, opts \\ []) do
    with :ok <- validate(msg), do: module.deliver(msg, opts)
  end
end
