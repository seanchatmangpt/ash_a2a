defmodule Ultracode.Repo do
  use AshPostgres.Repo, otp_app: :ultracode

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end
end
