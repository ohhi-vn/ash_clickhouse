defmodule ClickHouse.Interface.HTTP.Client do
  @moduledoc false

  alias ClickHouse.{ConnectionError, StreamError}

  @opts_schema KeywordValidator.schema!(
                 checkout_timeout: [is: :timeout, required: false, default: 8_000],
                 connect_timeout: [is: :timeout, required: false, default: 8_000],
                 recv_timeout: [is: :timeout, required: false, default: 15_000],
                 buffer_size: [is: :integer, required: false],
                 wait_end_of_query: [is: :integer, required: false],
                 session_id: [is: :binary, required: false],
                 session_timeout: [is: :integer, required: false],
                 send_progress_in_http_headers: [is: :integer, required: false],
                 http_headers_progress_interval_ms: [is: :integer, required: false],
                 database: [is: :binary, required: false],
                 settings: [is: :map, required: false],
                 content_encoding: [
                   is: {:in, [:gzip, :deflate, :br, :xz, :zstd, :lz4, :bz2, :snappy]},
                   required: false
                 ],
                 accept_encoding: [
                   is: {:in, [:gzip, :deflate, :br, :xz, :zstd, :lz4, :bz2, :snappy]},
                   required: false
                 ],
                 output_format_parquet_version: [
                   is: {:in, [:"1.0", :"2.4", :"2.6", :"2.latest"]},
                   required: false
                 ],
                 output_format_parquet_compression_method: [
                   is: {:in, [:snappy, :lz4, :brotli, :zstd, :gzip, :none]},
                   required: false
                 ],
                 decompress: [is: :boolean, required: false],
                 default_format: [is: :binary, required: false],
                 async_insert: [is: :integer, required: false],
                 wait_for_async_insert: [is: :integer, required: false],
                 query: [is: :binary, required: false],
                 stream: [is: :boolean, required: false]
               )

  @closed_retries 3
  @accept_header "Accept-Encoding"
  @content_header "Content-Encoding"
  @format_header "X-ClickHouse-Format"
  @error_header "X-ClickHouse-Exception-Code"
  @error_regex ~r/(?<=displayText\(\) = )(.*?)(?=: )/
  @error_types %{
    "Coordination::Exception" => ClickHouse.CoordinationError,
    "DB::Exception" => ClickHouse.DatabaseError,
    "DB::ErrnoException" => ClickHouse.SystemError,
    "DB::NetException" => ClickHouse.NetworkError,
    "DB::ParsingException" => ClickHouse.ParsingError
  }

  ################################
  # Public API
  ################################

  @doc false
  def request(pool, urls, body_or_stream, opts) do
    {url, headers, body_or_stream, http_opts, opts} = do_prepare(pool, urls, body_or_stream, opts)
    do_request(1, url, headers, body_or_stream, http_opts, opts)
  end

  @doc false
  def stream_next(ref, opts \\ []) do
    case :hackney.stream_next(ref) do
      :ok ->
        do_stream_receive(ref, opts)

      {:error, :req_not_found} ->
        {:error, %StreamError{message: "HTTP stream complete"}}
    end
  end

  def send_body(ref, body) do
    case :hackney.send_body(ref, body) do
      :ok ->
        :ok

      {:error, error} ->
        error = %StreamError{message: "Stream body error: #{inspect(error)}"}
        raise error
    end
  end

  def start_response(ref, opts) do
    case :hackney.start_response(ref) do
      {:ok, 200, headers, body} -> build_result(headers, body, opts)
      error -> build_error(error)
    end
  end

  def close(ref) do
    :hackney.close(ref)
  end

  ################################
  # Private API
  ################################

  defp do_prepare(pool, [url], body, opts) do
    do_prepare(pool, url, body, opts)
  end

  defp do_prepare(pool, urls, body, opts) when is_list(urls) do
    url = Enum.random(urls)
    do_prepare(pool, url, body, opts)
  end

  defp do_prepare(pool, url, body, opts) do
    opts = KeywordValidator.validate!(opts, @opts_schema)
    url = build_url(url, opts)
    headers = build_headers(opts)
    body = maybe_compress(body, opts)
    http_opts = build_http_opts(pool, opts)
    {url, headers, body, http_opts, opts}
  end

  defp do_request(attempt, url, headers, body_or_stream, http_opts, opts) do
    case :hackney.request(:post, url, headers, body_or_stream, http_opts) do
      {:ok, 200, headers, body} ->
        build_result(headers, body, opts)

      {:ok, ref} ->
        opts = Keyword.take(http_opts, [:recv_timeout])
        {:ok, {ref, opts}}

      {:error, :closed} when attempt < @closed_retries ->
        do_request(attempt + 1, url, headers, body_or_stream, http_opts, opts)

      error ->
        build_error(error)
    end
  end

  defp do_stream_receive(ref, opts) do
    timeout = Keyword.get(opts, :recv_timeout, 15_000)

    receive do
      {:hackney_response, ^ref, {:status, 200, _}} ->
        :begin

      {:hackney_response, ^ref, {:status, _, _}} ->
        do_stream_receive_error(ref, opts)

      {:hackney_response, ^ref, {:headers, headers}} ->
        {:headers, headers}

      {:hackney_response, ^ref, chunk} when is_binary(chunk) ->
        {:chunk, chunk}

      {:hackney_response, ^ref, :done} ->
        :halt

      {:tcp_closed = reason, _} ->
        build_error({:error, reason})
    after
      timeout ->
        build_error({:error, :timeout})
    end
  end

  defp do_stream_receive_error(ref, opts) do
    with {:headers, headers} <- stream_next(ref, opts),
         {:chunk, body} <- stream_next(ref, opts),
         :halt <- stream_next(ref, opts) do
      build_error({:ok, nil, headers, body})
    end
  end

  defp build_url(url, opts) do
    settings = Keyword.get(opts, :settings, %{})

    params =
      opts
      |> maybe_compression_param()
      |> Keyword.take([
        :buffer_size,
        :wait_end_of_query,
        :session_id,
        :session_timeout,
        :database,
        :enable_http_compression,
        :send_progress_in_http_headers,
        :http_headers_progress_interval_ms,
        :default_format,
        :async_insert,
        :wait_for_async_insert,
        :query,
        :output_format_parquet_version,
        :output_format_parquet_compression_method
      ])
      |> Enum.into(%{})
      |> Map.merge(settings)

    case URI.encode_query(params) do
      "" -> url
      params -> "#{url}?#{params}"
    end
  end

  defp maybe_compression_param(opts) do
    if Keyword.has_key?(opts, :accept_encoding) do
      Keyword.put(opts, :enable_http_compression, 1)
    else
      opts
    end
  end

  defp build_headers(opts) do
    []
    |> maybe_accept_encoding(opts)
    |> maybe_content_encoding(opts)
  end

  defp maybe_accept_encoding(headers, opts) do
    if accept_encoding = Keyword.get(opts, :accept_encoding) do
      [{@accept_header, to_string(accept_encoding)} | headers]
    else
      headers
    end
  end

  defp maybe_content_encoding(headers, opts) do
    if content_encoding = Keyword.get(opts, :content_encoding) do
      [{@content_header, to_string(content_encoding)} | headers]
    else
      headers
    end
  end

  defp maybe_compress(:stream, _), do: :stream

  defp maybe_compress(statement, opts) do
    if compression = Keyword.get(opts, :content_encoding) do
      compress(compression, statement)
    else
      statement
    end
  end

  defp compress(:gzip, statement), do: :zlib.gzip(statement)
  defp compress(:deflate, statement), do: :zlib.compress(statement)

  defp compress(type, _) do
    raise ArgumentError, """
    Cannot compress #{type} encoding. Only gzip and deflate compression can be used with a query statement.

    To use other compression types - use ClickHouse.stream!/4 combined with a compressed Enumerable.
    """
  end

  defp build_http_opts(pool, opts) do
    stream =
      if Keyword.get(opts, :stream) do
        [async: :once]
      else
        [with_body: true]
      end

    opts
    |> Keyword.take([:checkout_timeout, :connect_timeout, :recv_timeout])
    |> Keyword.merge(stream)
    |> Keyword.put(:pool, pool)
  end

  defp build_result(headers, body, opts) do
    format = find_header(headers, @format_header)
    encoding = find_header(headers, @content_header)
    {body, compressed} = maybe_decompress(encoding, body, opts)
    meta = get_meta(headers)
    {:ok, {body, format, meta, compressed}}
  end

  defp build_error({:error, reason}) do
    {:error, %ConnectionError{message: to_string(reason)}}
  end

  defp build_error({:ok, _code, headers, body}) do
    encoding = find_header(headers, @content_header)
    {body, _} = maybe_decompress(encoding, body, decompress: true)
    type = get_error_type(body)
    code = find_header(headers, @error_header)
    message = get_error_message(body)
    meta = get_meta(headers)
    error = struct(type, code: code, message: message, meta: meta)

    {:error, error}
  end

  defp get_meta(headers) do
    %{
      query_id: find_header(headers, "X-ClickHouse-Query-Id"),
      server_display_name: find_header(headers, "X-ClickHouse-Server-Display-Name"),
      timezone: find_header(headers, "X-ClickHouse-Timezone"),
      summary: find_header(headers, "X-ClickHouse-Summary")
    }
  end

  defp get_error_type(body) do
    case Regex.run(@error_regex, body, capture: :first) do
      [error] -> Map.fetch!(@error_types, error)
      nil -> find_error_type(body)
    end
  end

  # This is a temporary hack for newer CH versions that seem to have a different
  # error format.
  defp find_error_type(body) do
    {_, type} =
      Enum.find(@error_types, fn {error, _type} ->
        String.contains?(body, error)
      end)

    type
  end

  defp get_error_message(body) do
    body
    |> String.split("e.displayText() = ")
    |> List.last()
  end

  defp find_header([], _), do: nil

  defp find_header([{key, val} | _headers], header) when key == header do
    val
  end

  defp find_header([_ | headers], header) do
    find_header(headers, header)
  end

  defp maybe_decompress(nil, body, _opts), do: {body, false}

  defp maybe_decompress(compression, body, opts) do
    if Keyword.get(opts, :decompress) do
      {decompress(compression, body), false}
    else
      {body, true}
    end
  end

  defp decompress("gzip", body), do: :zlib.gunzip(body)
  defp decompress("deflate", body), do: :zlib.uncompress(body)

  defp decompress(type, _) do
    raise ArgumentError, """
    Cannot decompress #{type} encoding. Specify decompress: false in your query options to avoid this error.
    """
  end
end
