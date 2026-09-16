defmodule AshA2A.Semantic.LogicClosure.RuleDocument do
  @moduledoc """
  Shape recogniser for an SA2A-LOGIC N3 rule document (RFC-SA2A-002 §47-§48).

  It answers admission questions about a rule document *before* the real
  `praxis-graphlaw` engine is allowed to execute it. It never evaluates a
  rule, never derives a triple, and never decides what a closure contains --
  that is the engine's job through `AshA2A.Semantic.LogicClosure`.

  ## Why a recogniser is needed at all (measured, not assumed)

  Against the vendored `praxis_graphlaw.wasm` (praxis-graphlaw v26.7.5,
  sha256 `187688d9...`):

    * `TripleStore::from/1` computes Datalog safety/stratification with
      `datalog::validate_rules` and **discards the error**. A rule whose head
      variable is not bound by its body (`{ ?x ex:p ?y } => { ?x ex:q ?w }`)
      is reported `DATALOG ADMITTED -- Materialized 1 triples`, and a denial
      over `ex:a ex:q ?any` then matches: the engine materialised a triple
      with an unbound variable in it.
    * A blank node in a rule head is read as one constant, not an
      existential, and a list term in a head (`{ ?x ex:v ?n } => { ?x ex:v (?n) }`)
      creates new terms until fuel runs out.
    * `log:semantics` (a network fetch in N3) traps the instance with
      `unreachable`.

  So function-freeness, range restriction and builtin admissibility cannot
  be read back from the engine; they are checked here, fail-closed.

  ## Inverted burden

  The accepted grammar is a deliberately small subset of N3. Anything outside
  it is refused as `:rule_document_unclassifiable` rather than guessed at:

    * statements: `@prefix p: <iri> .` (each label declared once),
      `{ body } => { head } .`, `{ body } => false .`, `{ head } <= { body } .`
    * terms: `<absolute-iri>`, `p:local` (declared prefix), `?var`, `_:b`,
      `[ ... ]`, `( ... )`, nested `{ ... }`, literals, numbers, `true`/`false`, `a`
    * refused: `@base`/`BASE`/`PREFIX`/`@keywords`/`@forAll`/`@forSome`,
      relative IRIs, `\\u`/`\\U` or `\\` escapes in IRIs and local names,
      path syntax (`!`, `^`), a top-level statement that is not a rule, a
      prefix used before or without declaration, a prefix label declared twice.

  Rule-level checks (`check/1`):

    * **range restriction** -- every head variable occurs in the body
      (`:rule_not_range_restricted`)
    * **function-free head** -- no blank node, list, or nested formula in a
      head (`:rule_not_function_free`)
    * **builtin admissibility** -- every IRI in an N3 builtin namespace must be
      in `pure_builtins/0`; `log:semantics`, `log:content`, `log:outputString`,
      the `os:` namespace, dynamic-rule builtins (`log:implies` used as a
      predicate, `log:conclusion`, `log:parsedAsN3`, `log:conjunction`) and any
      builtin this module does not list are refused (`:unadmitted_builtin`)
    * **no knowledge hooks** -- the GraphLaw `kh:`/`hook:` namespaces are
      executable law with their own admission (`:hook_in_rule_document`)
  """

  @swap "http://www.w3.org/2000/10/swap/"
  @builtin_namespaces [
    @swap,
    "http://eulersharp.sourceforge.net/2003/03swap/",
    "https://eyereasoner.github.io/",
    "http://www.w3.org/2007/rif-builtin-function#"
  ]
  @hook_namespaces [
    "http://seanchatmangpt.github.io/praxis/kh#",
    "http://seanchatmangpt.github.io/praxis/hook#"
  ]
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @owl_same_as "http://www.w3.org/2002/07/owl#sameAs"

  # Every builtin the vendored engine implements in `builtins::classify` whose
  # evaluation is a pure function of its operands (read out of the engine's
  # own source at the vendored revision), plus the scoped-SNAF reasoner-level
  # constructs. Deliberately absent: log:semantics / log:content /
  # log:outputString (I/O), os:* (environment), and the dynamic-rule builtins
  # log:implies / log:conclusion / log:parsedAsN3 / log:conjunction, which turn
  # data into executed rules and so bypass rule identity.
  @pure_builtins MapSet.new(
                   Enum.map(
                     ~w(md5 sha sha256 sha512),
                     &(@swap <> "crypto#" <> &1)
                   ) ++
                     Enum.map(
                       ~w(append first firstRest in iterate last length member memberAt notMember remove rest reverse sort unique),
                       &(@swap <> "list#" <> &1)
                     ) ++
                     Enum.map(
                       ~w(bound dtlit equalTo localName n3String notEqualTo rawType uri includes notIncludes collectAllIn forAllIn ifThenElseIn),
                       &(@swap <> "log#" <> &1)
                     ) ++
                     Enum.map(
                       ~w(absoluteValue acos asin atan atan2 ceiling cos difference equalTo exponentiation floor greaterThan lessThan logarithm max memberCount min negation notEqualTo notLessThan notGreaterThan product quotient remainder rounded sin sum tan integerQuotient),
                       &(@swap <> "math#" <> &1)
                     ) ++
                     Enum.map(
                       ~w(concat contains containsIgnoringCase endsWith equalIgnoringCase notEqualIgnoringCase format greaterThan length lessThan matches notMatches replace scrape split startsWith substring toLowerCase toUpperCase),
                       &(@swap <> "string#" <> &1)
                     ) ++
                     Enum.map(
                       ~w(day dayOfWeek hour inSeconds localTime minute month second timeZone year),
                       &(@swap <> "time#" <> &1)
                     )
                 )

  @type failure :: %{required(:code) => atom(), required(:reason) => String.t()}

  @type rule :: %{
          index: non_neg_integer(),
          kind: :forward | :backward | :denial,
          body_vars: MapSet.t(String.t()),
          head_vars: MapSet.t(String.t()),
          head_function_terms: [atom()]
        }

  @type analysis :: %{rules: [rule()], iris: [String.t()], prefixes: %{String.t() => String.t()}}

  @doc "The builtin IRIs admitted as side-effect-free."
  @spec pure_builtins() :: MapSet.t(String.t())
  def pure_builtins, do: @pure_builtins

  @doc "Namespaces whose IRIs are treated as N3 builtins."
  @spec builtin_namespaces() :: [String.t()]
  def builtin_namespaces, do: @builtin_namespaces

  @doc """
  Parses and checks `document`. `{:ok, analysis}` only when every statement is
  a recognised rule shape and every rule-level check holds.

      iex> {:ok, a} = AshA2A.Semantic.LogicClosure.RuleDocument.check(
      ...>   "@prefix e: <http://e/> .\\n{ ?x e:p ?y . ?y e:p ?z } => { ?x e:p ?z } ."
      ...> )
      iex> length(a.rules)
      1

      iex> {:error, f} = AshA2A.Semantic.LogicClosure.RuleDocument.check(
      ...>   "@prefix e: <http://e/> .\\n{ ?x e:p ?y } => { ?x e:q ?w } ."
      ...> )
      iex> f.code
      :rule_not_range_restricted
  """
  @spec check(String.t()) :: {:ok, analysis()} | {:error, failure()}
  def check(document) when is_binary(document) do
    with {:ok, analysis} <- analyze(document),
         :ok <- check_hooks(analysis),
         :ok <- check_builtins(analysis),
         :ok <- check_rules(analysis) do
      {:ok, analysis}
    end
  end

  @doc "Parses `document` into rules, used IRIs and prefixes without rule-level checks."
  @spec analyze(String.t()) :: {:ok, analysis()} | {:error, failure()}
  def analyze(document) when is_binary(document) do
    with {:ok, tokens} <- tokenize(document, []) do
      statements(tokens, %{prefixes: %{}, rules: [], iris: []})
    end
  end

  # --- rule-level checks ---------------------------------------------------

  defp check_hooks(%{iris: iris}) do
    case Enum.find(iris, fn iri -> Enum.any?(@hook_namespaces, &String.starts_with?(iri, &1)) end) do
      nil -> :ok
      iri -> fail(:hook_in_rule_document, "knowledge-hook vocabulary #{iri} in a rule document")
    end
  end

  defp check_builtins(%{iris: iris}) do
    offending =
      Enum.find(iris, fn iri ->
        Enum.any?(@builtin_namespaces, &String.starts_with?(iri, &1)) and
          not MapSet.member?(@pure_builtins, iri)
      end)

    case offending do
      nil ->
        :ok

      iri ->
        fail(:unadmitted_builtin, "builtin #{iri} is not an admitted side-effect-free builtin")
    end
  end

  defp check_rules(%{rules: rules}) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      unbound = MapSet.difference(rule.head_vars, rule.body_vars)

      cond do
        MapSet.size(unbound) > 0 ->
          {:halt,
           fail(
             :rule_not_range_restricted,
             "rule #{rule.index}: head variable(s) #{Enum.join(Enum.sort(unbound), ", ")} not bound by the body"
           )}

        rule.head_function_terms != [] ->
          {:halt,
           fail(
             :rule_not_function_free,
             "rule #{rule.index}: head creates #{Enum.join(Enum.uniq(rule.head_function_terms), ", ")} terms"
           )}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # --- statements ------------------------------------------------------------

  defp statements([], acc) do
    {:ok,
     %{
       rules: Enum.reverse(acc.rules),
       iris: acc.iris |> Enum.uniq() |> Enum.sort(),
       prefixes: acc.prefixes
     }}
  end

  defp statements([{:directive, "@prefix"}, {:pname, label, ""}, {:iri, iri}, :dot | rest], acc) do
    cond do
      Map.has_key?(acc.prefixes, label) ->
        fail(:rule_document_unclassifiable, "prefix #{label}: declared twice")

      true ->
        statements(rest, %{acc | prefixes: Map.put(acc.prefixes, label, iri)})
    end
  end

  defp statements([{:directive, other} | _], _acc),
    do:
      fail(:rule_document_unclassifiable, "directive #{other} is not admitted in a rule document")

  defp statements([:lbrace | _] = tokens, acc) do
    with {:ok, left, rest} <- formula(tokens),
         {:ok, rule, rest} <- rule_tail(left, rest, acc),
         {:ok, rest} <- expect_dot(rest) do
      rule = Map.put(rule, :index, length(acc.rules))
      statements(rest, %{acc | rules: [rule | acc.rules], iris: rule.iris ++ acc.iris})
    end
  end

  defp statements([token | _], _acc),
    do:
      fail(:rule_document_unclassifiable, "top-level statement is not a rule: #{inspect(token)}")

  defp rule_tail(left, [:implies, {:boolean, "false"} | rest], acc) do
    with {:ok, body} <- terms(left, acc.prefixes) do
      {:ok,
       %{
         kind: :denial,
         body_vars: body.vars,
         head_vars: MapSet.new(),
         head_function_terms: [],
         iris: body.iris
       }, rest}
    end
  end

  defp rule_tail(left, [:implies, :lbrace | _] = tokens, acc) do
    with {:ok, right, rest} <- formula(tl(tokens)),
         {:ok, body} <- terms(left, acc.prefixes),
         {:ok, head} <- terms(right, acc.prefixes) do
      {:ok, rule(:forward, body, head), rest}
    end
  end

  defp rule_tail(left, [:backward, :lbrace | _] = tokens, acc) do
    with {:ok, right, rest} <- formula(tl(tokens)),
         {:ok, head} <- terms(left, acc.prefixes),
         {:ok, body} <- terms(right, acc.prefixes) do
      {:ok, rule(:backward, body, head), rest}
    end
  end

  defp rule_tail(_left, rest, _acc),
    do:
      fail(
        :rule_document_unclassifiable,
        "a top-level formula must be followed by => { ... }, => false or <= { ... }, got #{inspect(Enum.take(rest, 1))}"
      )

  defp rule(kind, body, head) do
    %{
      kind: kind,
      body_vars: body.vars,
      head_vars: head.vars,
      head_function_terms: head.function_terms,
      iris: body.iris ++ head.iris
    }
  end

  defp expect_dot([:dot | rest]), do: {:ok, rest}

  defp expect_dot(rest),
    do:
      fail(
        :rule_document_unclassifiable,
        "rule not terminated by '.': #{inspect(Enum.take(rest, 1))}"
      )

  # A top-level `{ ... }` formula: returns its inner tokens (balanced).
  defp formula([:lbrace | rest]), do: balanced(rest, 1, [])

  defp balanced([], _depth, _acc),
    do: fail(:rule_document_unclassifiable, "unbalanced '{' in rule document")

  defp balanced([:rbrace | rest], 1, acc), do: {:ok, Enum.reverse(acc), rest}
  defp balanced([:rbrace | rest], depth, acc), do: balanced(rest, depth - 1, [:rbrace | acc])
  defp balanced([:lbrace | rest], depth, acc), do: balanced(rest, depth + 1, [:lbrace | acc])
  defp balanced([token | rest], depth, acc), do: balanced(rest, depth, [token | acc])

  # Variables, IRIs and function-creating terms inside one side of a rule.
  defp terms(tokens, prefixes) do
    Enum.reduce_while(tokens, {:ok, %{vars: MapSet.new(), iris: [], function_terms: []}}, fn
      {:var, name}, {:ok, acc} ->
        {:cont, {:ok, %{acc | vars: MapSet.put(acc.vars, name)}}}

      {:iri, iri}, {:ok, acc} ->
        {:cont, {:ok, %{acc | iris: [iri | acc.iris]}}}

      {:pname, label, local}, {:ok, acc} ->
        case Map.fetch(prefixes, label) do
          {:ok, ns} ->
            {:cont, {:ok, %{acc | iris: [ns <> local | acc.iris]}}}

          :error ->
            {:halt, fail(:rule_document_unclassifiable, "prefix #{label}: used but not declared")}
        end

      :a, {:ok, acc} ->
        {:cont, {:ok, %{acc | iris: [@rdf_type | acc.iris]}}}

      :same_as, {:ok, acc} ->
        {:cont, {:ok, %{acc | iris: [@owl_same_as | acc.iris]}}}

      :bnode, {:ok, acc} ->
        {:cont, {:ok, %{acc | function_terms: [:blank_node | acc.function_terms]}}}

      :lbracket, {:ok, acc} ->
        {:cont, {:ok, %{acc | function_terms: [:blank_node | acc.function_terms]}}}

      :lparen, {:ok, acc} ->
        {:cont, {:ok, %{acc | function_terms: [:list | acc.function_terms]}}}

      :lbrace, {:ok, acc} ->
        {:cont, {:ok, %{acc | function_terms: [:formula | acc.function_terms]}}}

      :implies, _acc ->
        {:halt, fail(:rule_document_unclassifiable, "nested implication inside a rule formula")}

      :backward, _acc ->
        {:halt, fail(:rule_document_unclassifiable, "nested implication inside a rule formula")}

      {:directive, d}, _acc ->
        {:halt, fail(:rule_document_unclassifiable, "directive #{d} inside a rule formula")}

      _other, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  # --- tokenizer -------------------------------------------------------------

  @iri_re ~r/\A<([^<>"{}|^`\\\x00-\x20]*)>/u
  # Turtle PN_PREFIX / PN_LOCAL (ASCII subset): neither may end with '.',
  # which terminates the statement instead (`e:o.` is `e:o` then `.`).
  @pname_re ~r/\A((?:[A-Za-z](?:[A-Za-z0-9_\-.]*[A-Za-z0-9_\-])?)?):((?:[A-Za-z0-9_:%](?:[A-Za-z0-9_\-.:%]*[A-Za-z0-9_\-:%])?)?)/u
  @var_re ~r/\A\?([A-Za-z0-9_][A-Za-z0-9_\-]*)/u
  @bnode_re ~r/\A_:([A-Za-z0-9_](?:[A-Za-z0-9_\-.]*[A-Za-z0-9_\-])?)/u
  @number_re ~r/\A[+-]?(?:\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)/
  @word_re ~r/\A([A-Za-z][A-Za-z0-9_\-]*)/u

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n], do: tokenize(rest, acc)

  defp tokenize(<<?#, rest::binary>>, acc) do
    case :binary.split(rest, "\n") do
      [_comment, more] -> tokenize(more, acc)
      [_comment] -> tokenize(<<>>, acc)
    end
  end

  defp tokenize(<<"\"\"\"", rest::binary>>, acc), do: long_string(rest, "\"\"\"", acc)
  defp tokenize(<<"'''", rest::binary>>, acc), do: long_string(rest, "'''", acc)
  defp tokenize(<<q, rest::binary>>, acc) when q in [?", ?'], do: short_string(rest, q, acc)

  defp tokenize(<<"=>", rest::binary>>, acc), do: tokenize(rest, [:implies | acc])

  defp tokenize(<<"<=", c, rest::binary>>, acc) when c in [?\s, ?\t, ?\r, ?\n, ?{],
    do: tokenize(<<c, rest::binary>>, [:backward | acc])

  defp tokenize(<<?<, _::binary>> = doc, acc) do
    case Regex.run(@iri_re, doc) do
      [whole, iri] ->
        if absolute_iri?(iri) do
          tokenize(binary_part(doc, byte_size(whole), byte_size(doc) - byte_size(whole)), [
            {:iri, iri} | acc
          ])
        else
          fail(:rule_document_unclassifiable, "relative IRI <#{iri}> (no base is admitted)")
        end

      nil ->
        fail(
          :rule_document_unclassifiable,
          "unrecognised IRI near #{inspect(String.slice(doc, 0, 40))} (escapes are not admitted)"
        )
    end
  end

  defp tokenize(<<"^^", rest::binary>>, acc), do: tokenize(rest, [:datatype | acc])
  defp tokenize(<<?{, rest::binary>>, acc), do: tokenize(rest, [:lbrace | acc])
  defp tokenize(<<?}, rest::binary>>, acc), do: tokenize(rest, [:rbrace | acc])
  defp tokenize(<<?(, rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<?), rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize(<<?[, rest::binary>>, acc), do: tokenize(rest, [:lbracket | acc])
  defp tokenize(<<?], rest::binary>>, acc), do: tokenize(rest, [:rbracket | acc])
  defp tokenize(<<?;, rest::binary>>, acc), do: tokenize(rest, [:semicolon | acc])
  defp tokenize(<<?,, rest::binary>>, acc), do: tokenize(rest, [:comma | acc])
  defp tokenize(<<?=, rest::binary>>, acc), do: tokenize(rest, [:same_as | acc])

  defp tokenize(<<?@, rest::binary>> = doc, acc) do
    case Regex.run(@word_re, rest) do
      [word, _] -> directive("@" <> word, skip(doc, word, 1), acc)
      nil -> fail(:rule_document_unclassifiable, "stray '@'")
    end
  end

  defp tokenize(<<??, _::binary>> = doc, acc) do
    case Regex.run(@var_re, doc) do
      [whole, name] -> tokenize(skip(doc, whole, 0), [{:var, name} | acc])
      nil -> fail(:rule_document_unclassifiable, "malformed variable")
    end
  end

  defp tokenize(<<"_:", _::binary>> = doc, acc) do
    case Regex.run(@bnode_re, doc) do
      [whole, _label] -> tokenize(skip(doc, whole, 0), [:bnode | acc])
      nil -> fail(:rule_document_unclassifiable, "malformed blank node label")
    end
  end

  defp tokenize(<<?., rest::binary>> = doc, acc) do
    case Regex.run(@number_re, doc) do
      [whole] -> tokenize(skip(doc, whole, 0), [:literal | acc])
      _ -> tokenize(rest, [:dot | acc])
    end
  end

  defp tokenize(<<c, _::binary>> = doc, acc) when c in ?0..?9 or c in [?+, ?-] do
    case Regex.run(@number_re, doc) do
      [whole | _] -> tokenize(skip(doc, whole, 0), [:literal | acc])
      nil -> fail(:rule_document_unclassifiable, "malformed number")
    end
  end

  defp tokenize(doc, acc) do
    cond do
      match = Regex.run(@pname_re, doc) ->
        [whole | groups] = match
        rest = skip(doc, whole, 0)

        if String.starts_with?(rest, "\\") do
          fail(:rule_document_unclassifiable, "escaped local name is not admitted")
        else
          tokenize(rest, [{:pname, Enum.at(groups, 0) || "", Enum.at(groups, 1) || ""} | acc])
        end

      match = Regex.run(@word_re, doc) ->
        [word, _] = match
        rest = skip(doc, word, 0)

        case word do
          "a" -> tokenize(rest, [:a | acc])
          "true" -> tokenize(rest, [{:boolean, "true"} | acc])
          "false" -> tokenize(rest, [{:boolean, "false"} | acc])
          other -> fail(:rule_document_unclassifiable, "unrecognised token #{inspect(other)}")
        end

      true ->
        fail(
          :rule_document_unclassifiable,
          "unrecognised input near #{inspect(String.slice(doc, 0, 20))}"
        )
    end
  end

  defp directive("@prefix", rest, acc), do: tokenize(rest, [{:directive, "@prefix"} | acc])

  # A language tag after a literal: `"x"@en`.
  defp directive(_word, rest, [:literal | _] = acc), do: tokenize(rest, acc)

  defp directive(word, _rest, _acc),
    do:
      fail(:rule_document_unclassifiable, "directive #{word} is not admitted in a rule document")

  defp short_string(doc, quote, acc) do
    case scan_string(doc, quote) do
      {:ok, rest} -> tokenize(rest, [:literal | acc])
      :error -> fail(:rule_document_unclassifiable, "unterminated string literal")
    end
  end

  defp scan_string(<<?\\, _c::utf8, rest::binary>>, q), do: scan_string(rest, q)
  defp scan_string(<<q, rest::binary>>, q), do: {:ok, rest}
  defp scan_string(<<?\n, _::binary>>, _q), do: :error
  defp scan_string(<<_c::utf8, rest::binary>>, q), do: scan_string(rest, q)
  defp scan_string(_other, _q), do: :error

  defp long_string(doc, delimiter, acc) do
    case :binary.split(doc, delimiter) do
      [_content, rest] -> tokenize(rest, [:literal | acc])
      [_] -> fail(:rule_document_unclassifiable, "unterminated long string literal")
    end
  end

  defp skip(doc, whole, extra) do
    n = byte_size(whole) + extra
    binary_part(doc, n, byte_size(doc) - n)
  end

  defp absolute_iri?(iri), do: Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.\-]*:/, iri)

  defp fail(code, reason), do: {:error, %{code: code, reason: reason}}
end
