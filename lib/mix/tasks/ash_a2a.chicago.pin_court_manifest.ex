defmodule Mix.Tasks.AshA2a.Chicago.PinCourtManifest do
  @shortdoc "Rebuilds priv/sa2a/chicago_court_manifest.json from the compiled courts"

  @moduledoc """
  Recomputes the admitted Chicago court manifest (RFC-SA2A-002 §136, §137)
  from every compiled discoverable court and the default OCEL validator, and
  writes it as canonical JSON:

      mix ash_a2a.chicago.pin_court_manifest
      mix ash_a2a.chicago.pin_court_manifest --check

  Every value is derived from court declarations (falsifier corpus, query
  predicates, OCEL mapping declarations, validator identity), so running it
  over unchanged courts is byte-for-byte a no-op. Run it after a reviewed
  change to court machinery; until then `AshA2A.Chicago.Runner` records the
  drift and no run over the changed machinery is issued `CONFORMANT`.

  `--check` writes nothing and exits non-zero when the committed manifest
  differs from the compiled courts.

  Courts compiled only under `MIX_ENV=test` are included only when the task
  runs in that environment.
  """

  use Mix.Task

  alias AshA2A.Chicago.CourtManifest

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    Mix.Task.run("app.config")

    {parsed, _, _} = OptionParser.parse(argv, strict: [check: :boolean])
    doc = CourtManifest.build()
    path = CourtManifest.default_path()

    if parsed[:check] do
      case CourtManifest.load(path) do
        {:ok, ^doc} ->
          Mix.shell().info("court manifest current: #{doc["digest"]}")

        {:ok, committed} ->
          Mix.raise(
            "court manifest drift: committed #{committed["digest"]}, compiled #{doc["digest"]}"
          )

        {:error, reason} ->
          Mix.raise("court manifest unreadable at #{path}: #{inspect(reason)}")
      end
    else
      CourtManifest.write!(doc, path)

      Mix.shell().info("""
      wrote #{path}
        digest : #{doc["digest"]}
        courts : #{length(doc["courts"])}
        version: #{doc["court_version"]}
      """)
    end
  end
end
