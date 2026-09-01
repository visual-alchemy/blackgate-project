defmodule Blackgate.RouteValidator do
  @moduledoc false

  @srt_modes ["caller", "listener", "rendezvous"]
  @failover_modes ["maintain-primary", "maintain-stability", "manual-switchback", "manual"]
  @active_sources ["primary", "secondary"]
  @key_lengths [0, 16, 24, 32]

  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(route) when is_map(route) do
    errors =
      []
      |> validate_primary_source(route)
      |> validate_failover(route)
      |> validate_seamless_sdi(route)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_route), do: {:error, ["route must be an object"]}

  defp validate_primary_source(errors, %{"schema" => "SRT"} = route) do
    validate_srt_source(errors, Map.get(route, "schema_options"), "primary source")
  end

  defp validate_primary_source(errors, _route), do: errors

  defp validate_failover(errors, %{"failover_enabled" => true} = route) do
    errors =
      if Map.get(route, "schema") == "SRT" do
        errors
      else
        ["failover requires an SRT primary source" | errors]
      end

    errors =
      if Map.get(route, "failover_mode") in @failover_modes do
        errors
      else
        ["failover mode is invalid" | errors]
      end

    errors =
      if Map.get(route, "active_source", "primary") in @active_sources do
        errors
      else
        ["active source is invalid" | errors]
      end

    errors =
      case Map.fetch(route, "auto_join") do
        :error -> errors
        {:ok, value} when is_boolean(value) -> errors
        {:ok, _value} -> ["auto_join must be boolean" | errors]
      end

    case Map.get(route, "secondary_source") do
      %{"schema" => "SRT", "schema_options" => opts} ->
        validate_srt_source(errors, opts, "secondary source")

      _other ->
        ["secondary source must be configured as SRT" | errors]
    end
  end

  defp validate_failover(errors, _route), do: errors

  defp validate_seamless_sdi(errors, route) do
    case Map.fetch(route, "seamless_sdi_failover") do
      :error ->
        errors

      {:ok, false} ->
        errors

      {:ok, true} ->
        errors
        |> require_setting(
          Map.get(route, "failover_enabled") == true,
          "seamless SDI failover requires failover to be enabled"
        )
        |> require_setting(
          Map.get(route, "auto_join", true) == true,
          "seamless SDI failover requires auto_join=true"
        )

      {:ok, _value} ->
        ["seamless_sdi_failover must be boolean" | errors]
    end
  end

  defp require_setting(errors, true, _message), do: errors
  defp require_setting(errors, false, message), do: [message | errors]

  defp validate_srt_source(errors, opts, label) when is_map(opts) do
    errors
    |> require_nonempty_string(Map.get(opts, "localaddress"), "#{label} address is required")
    |> require_port(Map.get(opts, "localport"), "#{label} port must be between 1 and 65535")
    |> require_mode(Map.get(opts, "mode"), "#{label} mode is invalid")
    |> validate_passphrase(opts, label)
    |> validate_key_length(Map.get(opts, "pbkeylen"), label)
  end

  defp validate_srt_source(errors, _opts, label),
    do: ["#{label} options must be an object" | errors]

  defp require_nonempty_string(errors, value, message) when is_binary(value) do
    if String.trim(value) == "", do: [message | errors], else: errors
  end

  defp require_nonempty_string(errors, _value, message), do: [message | errors]

  defp require_port(errors, value, _message)
       when is_integer(value) and value >= 1 and value <= 65_535,
       do: errors

  defp require_port(errors, _value, message), do: [message | errors]

  defp require_mode(errors, value, _message) when value in @srt_modes, do: errors
  defp require_mode(errors, _value, message), do: [message | errors]

  defp validate_passphrase(errors, opts, label) do
    passphrase = Map.get(opts, "passphrase")
    authentication = Map.get(opts, "authentication", false)

    cond do
      authentication == true and not valid_passphrase?(passphrase) ->
        ["#{label} passphrase must contain 10 to 79 characters" | errors]

      passphrase in [nil, ""] ->
        errors

      valid_passphrase?(passphrase) ->
        errors

      true ->
        ["#{label} passphrase must contain 10 to 79 characters" | errors]
    end
  end

  defp valid_passphrase?(value) when is_binary(value) do
    length = String.length(value)
    length >= 10 and length <= 79
  end

  defp valid_passphrase?(_value), do: false

  defp validate_key_length(errors, nil, _label), do: errors
  defp validate_key_length(errors, value, _label) when value in @key_lengths, do: errors

  defp validate_key_length(errors, _value, label),
    do: ["#{label} key length is invalid" | errors]
end
