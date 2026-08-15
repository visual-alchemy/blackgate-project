defmodule Mix.Tasks.CompileRustApp do
  @moduledoc """
  Compiles the native Rust engine.

  ## Examples

      $ mix compile_rust_app

  """
  use Mix.Task

  @shortdoc "Compiles the native Rust engine"
  def run(_) do
    IO.puts("Compiling Rust engine...")
    {result, exit_code} = System.cmd("make", ["-C", "native"])
    IO.puts(result)

    if exit_code != 0 do
      Mix.raise("Failed to compile Rust engine")
    end

    rust_binary_path = Path.join(["native", "build", "rust", "release", "blackgate-engine"])

    unless File.exists?(rust_binary_path) do
      Mix.raise("Rust engine binary was not created at #{rust_binary_path}")
    end

    IO.puts("Rust engine compiled successfully at #{rust_binary_path}")
  end
end
