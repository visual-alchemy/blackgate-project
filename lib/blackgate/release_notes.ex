defmodule Blackgate.ReleaseNotes do
  @moduledoc "Customer-facing notes bundled with the running application release."

  def current do
    load(Application.app_dir(:blackgate, "priv/release-notes.json"))
  end

  @doc false
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"version" => version, "released_on" => date, "changes" => changes}} <-
           Jason.decode(content),
         true <- is_binary(version) and byte_size(version) > 0,
         true <- is_binary(date),
         {:ok, _} <- Date.from_iso8601(date),
         true <- is_list(changes) and changes != [],
         true <- Enum.all?(changes, &(is_binary(&1) and byte_size(&1) > 0)) do
      %{version: version, released_on: date, changes: changes}
    else
      _ -> nil
    end
  end
end
