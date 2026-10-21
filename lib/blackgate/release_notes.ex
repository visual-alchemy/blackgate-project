defmodule Blackgate.ReleaseNotes do
  @moduledoc """
  What the deployed release says about itself.

  `priv/release-notes.json` is baked in by `scripts/package-signed-update.sh`, so a release deployed
  through an update package knows its own release version (a date-based string the updater uses for
  its directories) and the changes in it. A release built by a plain `make build` carries no notes,
  and the dashboard falls back to the application version.
  """

  @notes_relative_path "priv/release-notes.json"

  @doc """
  `%{version: String.t(), released_on: String.t() | nil, changes: [String.t()]}` or `nil`.
  """
  @spec current() :: map() | nil
  def current do
    load(Application.app_dir(:blackgate, @notes_relative_path))
  end

  @doc false
  @spec load(Path.t()) :: map() | nil
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         %{"version" => version} when is_binary(version) and version != "" <- decoded do
      %{
        version: version,
        released_on: decoded["released_on"],
        changes: decoded["changes"] |> List.wrap() |> Enum.filter(&is_binary/1)
      }
    else
      _ -> nil
    end
  end
end
