defmodule Blackgate.Repo do
  use Ecto.Repo,
    otp_app: :blackgate,
    adapter: Ecto.Adapters.SQLite3
end
