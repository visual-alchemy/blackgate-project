defmodule Blackgate.RouteValidatorTest do
  use ExUnit.Case, async: true

  alias Blackgate.RouteValidator

  defp valid_route do
    %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener"
      },
      "failover_enabled" => true,
      "failover_mode" => "maintain-primary",
      "active_source" => "primary",
      "auto_join" => false,
      "secondary_source" => %{
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "192.0.2.10",
          "localport" => 4202,
          "mode" => "caller"
        }
      }
    }
  end

  test "accepts complete dual-SRT configuration" do
    assert :ok = RouteValidator.validate(valid_route())
  end

  test "rejects malformed secondary SRT URI inputs" do
    route = put_in(valid_route(), ["secondary_source", "schema_options"], %{"mode" => "caller"})

    assert {:error, errors} = RouteValidator.validate(route)
    assert "secondary source address is required" in errors
    assert "secondary source port must be between 1 and 65535" in errors
  end

  test "rejects invalid passphrase and key length without returning secret values" do
    route =
      update_in(valid_route(), ["schema_options"], fn opts ->
        Map.merge(opts, %{
          "authentication" => true,
          "passphrase" => "short",
          "pbkeylen" => 12
        })
      end)

    assert {:error, errors} = RouteValidator.validate(route)
    assert "primary source passphrase must contain 10 to 79 characters" in errors
    assert "primary source key length is invalid" in errors
    refute Enum.any?(errors, &String.contains?(&1, "short"))
  end

  test "rejects failover on non-SRT primary" do
    route = Map.put(valid_route(), "schema", "UDP")
    assert {:error, errors} = RouteValidator.validate(route)
    assert "failover requires an SRT primary source" in errors
  end
end
