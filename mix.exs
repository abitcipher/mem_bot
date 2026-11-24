defmodule MemBot.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/abitcipher/mem_bot"

  def project do
    [
      app: :mem_bot,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Client for the local link of mem-botd, the MEM node of a Mini App's service",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      # A stand-in node for the tests.
      {:bandit, "~> 1.6", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
