defmodule Blackgate.RtmpStats do
  @moduledoc """
  Fetches and parses RTMP statistics from nginx-rtmp's stats module.
  """

  require Logger

  @nginx_rtmp_stats_url "http://127.0.0.1:8080/stat"

  @doc """
  Fetches stats for a specific stream from nginx-rtmp.
  Returns parsed stats or nil if stream not found.
  """
  def get_stream_stats(stream_key) do
    case fetch_stats() do
      {:ok, xml} ->
        parse_stream_stats(xml, stream_key)

      {:error, reason} ->
        Logger.warning("Failed to fetch nginx-rtmp stats: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Fetches all active streams from nginx-rtmp.
  """
  def list_active_streams do
    case fetch_stats() do
      {:ok, xml} ->
        parse_all_streams(xml)

      {:error, _reason} ->
        []
    end
  end

  defp fetch_stats do
    case :httpc.request(:get, {@nginx_rtmp_stats_url |> String.to_charlist(), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, List.to_string(body)}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_stream_stats(xml, stream_key) do
    # Parse XML to find the specific stream
    # nginx-rtmp XML structure:
    # <rtmp><server><application><live><stream><name>KEY</name>...</stream></live></application></server></rtmp>
    try do
      # Build regex pattern dynamically to find the specific stream
      escaped_key = Regex.escape(stream_key)
      pattern = "<stream>.*?<name>" <> escaped_key <> "</name>.*?</stream>"
      {:ok, stream_pattern} = Regex.compile(pattern, [:dotall])

      case Regex.run(stream_pattern, xml) do
        [stream_xml] ->
          %{
            "active" => true,
            "source-type" => "rtmpsrc",
            "bw_in" => extract_value(stream_xml, "bw_in") |> to_mbps(),
            "bw_out" => extract_value(stream_xml, "bw_out") |> to_mbps(),
            "bytes_in" => extract_value(stream_xml, "bytes_in"),
            "bytes_out" => extract_value(stream_xml, "bytes_out"),
            "time" => extract_value(stream_xml, "time"),
            "clients" => extract_value(stream_xml, "nclients"),
            "video_width" => extract_value(stream_xml, "width"),
            "video_height" => extract_value(stream_xml, "height"),
            "video_frame_rate" => extract_value(stream_xml, "frame_rate"),
            "video_codec" => extract_text(stream_xml, "codec", "video"),
            "audio_codec" => extract_text(stream_xml, "codec", "audio")
          }

        nil ->
          nil
      end
    rescue
      e ->
        Logger.warning("Failed to parse nginx-rtmp stats: #{inspect(e)}")
        nil
    end
  end

  defp parse_all_streams(xml) do
    # Extract all stream names
    {:ok, pattern} = Regex.compile("<stream>.*?<name>([^<]+)</name>.*?</stream>", [:dotall])
    pattern
    |> Regex.scan(xml, capture: :all_but_first)
    |> List.flatten()
  end

  defp extract_value(xml, tag) do
    {:ok, pattern} = Regex.compile("<#{tag}>(\\d+)</#{tag}>")
    case Regex.run(pattern, xml) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  defp extract_text(xml, tag, section) do
    pattern_str =
      if section do
        "<#{section}>.*?<#{tag}>([^<]+)</#{tag}>.*?</#{section}>"
      else
        "<#{tag}>([^<]+)</#{tag}>"
      end

    {:ok, pattern} = Regex.compile(pattern_str, if(section, do: [:dotall], else: []))

    case Regex.run(pattern, xml) do
      [_, value] -> value
      nil -> nil
    end
  end

  # Convert bits per second to Mbps
  defp to_mbps(bps) when is_integer(bps), do: Float.round(bps / 1_000_000, 2)
  defp to_mbps(_), do: 0.0
end
