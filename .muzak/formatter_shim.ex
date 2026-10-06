defmodule Muzak.Code.Formatter do
  @moduledoc false
  # MUZAK-PATCH (Elixir 1.19): muzak 1.1.1 (last released 2022-12) vendors a
  # 2021-era copy of Elixir's code formatter that crashes on any modern
  # Elixir (Inspect.Algebra doc AST changed; `fits?/4` FunctionClauseError).
  # This redefinition keeps the same API but renders through the modern
  # `Code.quoted_to_algebra/2`, returning old-style "string docs" (list of
  # line elements, lines after the first prefixed with "\n") which
  # Muzak.Mutations.get_lines/3 and Muzak.Runner.compile_mutation/1 expect.

  def to_forms_and_state(string, opts \\ [])
  def to_forms_and_state(string, _opts) when is_binary(string) do
    ast =
      Code.string_to_quoted!(string,
        file: "nofile",
        token_metadata: true,
        literal_encoder: &{:ok, {:__block__, &2, [&1]}}
      )

    {ast, nil}
  end

  def to_ast(string), do: to_forms_and_state(string) |> elem(0)

  def to_string(forms, state \\ nil), do: IO.iodata_to_binary(to_algebra(forms, state))

  def to_algebra(string) when is_binary(string) do
    {forms, _} = to_forms_and_state(string)
    to_algebra(forms, nil)
  end

  def to_algebra(forms, _state) when is_list(forms) or is_tuple(forms) do
    rendered = Macro.to_string(normalize_meta(forms))

    case String.split(rendered, "\n") do
      [only] -> [only]
      [first | rest] -> [first | Enum.map(rest, &("\n" <> &1))]
    end
  end

  # The old vendored formatter tolerated arbitrary token metadata on AST
  # nodes; Code.quoted_to_algebra/2 requires a well-formed, formatter-
  # compatible metadata set (it Keyword.fetch!es :token on wrapped literals).
  # Drop mutator noise (:unique_tag) and formatter-private keys, guarantee
  # :token on literals, keep the structural keys the modern formatter
  # consumes (:line, :closing, :do, :end, :format, :indentation, :delimiter).
  defp normalize_meta(ast) do
    Macro.prewalk(ast, fn
      {:__block__, meta, [lit]} = node when is_number(lit) or is_atom(lit) ->
        if Keyword.has_key?(meta, :token) do
          node
        else
          {:__block__, Keyword.put(meta, :token, Kernel.to_string(lit)), [lit]}
        end

      # Strings: drop delimiter/indentation metadata -- rendering paths
      # (quoted_to_algebra and Macro.to_string) reproduce heredoc SHAPE from
      # that metadata but re-ESCAPE the content, producing source that does
      # not even parse (verified empirically). A plain quoted string is valid
      # Elixir regardless of content.
      {:__block__, meta, [lit]} when is_binary(lit) and is_list(meta) ->
        {:__block__, Keyword.take(meta, [:line]), [lit]}

      {form, meta, args} when is_atom(form) and is_list(meta) and is_list(args) ->
        {form,
         Keyword.take(meta, [:line, :closing, :do, :end, :format, :indentation, :delimiter]),
         args}

      node ->
        node
    end)
  end
end
