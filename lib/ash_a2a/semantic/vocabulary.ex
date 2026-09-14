defmodule AshA2A.Semantic.Vocabulary do
  @moduledoc "Prior-art-first namespace registry for semantic alignment."

  @prefixes %{
    "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
    "owl" => "http://www.w3.org/2002/07/owl#",
    "prov" => "http://www.w3.org/ns/prov#",
    "time" => "http://www.w3.org/2006/time#",
    "odrl" => "http://www.w3.org/ns/odrl/2/",
    "skos" => "http://www.w3.org/2004/02/skos/core#",
    "schema" => "https://schema.org/",
    "oa" => "http://www.w3.org/ns/oa#",
    "sosa" => "http://www.w3.org/ns/sosa/"
  }

  def prefixes, do: @prefixes

  def expand(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [prefix, local] when is_map_key(@prefixes, prefix) -> Map.fetch!(@prefixes, prefix) <> local
      _ -> local(value)
    end
  end

  def local(value) do
    suffix = value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]+/u, "_")
    "urn:ash-a2a:semantic:#{suffix}"
  end
end
