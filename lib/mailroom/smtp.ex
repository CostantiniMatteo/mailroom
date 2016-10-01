defmodule Mailroom.SMTP do
  alias Mailroom.Socket

  def connect(server, options \\ []) do
    port = Keyword.get(options, :port, 25)
    {:ok, socket} = Socket.connect(server, port, options)
    with {:ok, _banner} <- read_banner(socket),
         {:ok, extensions} <- greet(socket),
         {:ok, socket, _extensions} <- try_starttls(socket, extensions),
         {:ok, socket} <- try_auth(socket, extensions, options),
      do: {:ok, socket}
  end

  defp read_banner(socket) do
    {:ok, line} = Socket.recv(socket)
    parse_banner(line)
  end

  defp parse_banner(<<"220 ", banner :: binary>>),
    do: {:ok, banner}
  defp parse_banner(_),
    do: {:error, "Unexpected banner"}

  defp greet(socket) do
    case try_ehlo(socket) do
      {:ok, lines} ->
        {:ok, parse_exentions(lines)}
      :error ->
        {:ok, {"250", _}} = send_helo(socket)
        {:ok, []}
    end
  end

  defp try_ehlo(socket) do
    Socket.send(socket, ["EHLO ", fqdn, "\r\n"])
    {:ok, lines} = read_potentially_multiline_response(socket)
    case hd(lines) do
      {"500", _} -> :error
      {<<"4", _ :: binary>>, _} -> :temp_error
      _ -> {:ok, lines}
    end
  end

  defp send_helo(socket) do
    Socket.send(socket, ["HELO ", fqdn, "\r\n"])
    {:ok, data} = Socket.recv(socket)
    parse_smtp_response(data)
  end

  defp parse_smtp_response(<<"2", code :: binary-size(2), " ", domain :: binary>>),
    do: {:ok, {"2" <> code, domain}}
  defp parse_smtp_response(<<"3", code :: binary-size(2), " ", domain :: binary>>),
    do: {:ok, {"3" <> code, domain}}
  defp parse_smtp_response(<<"4", code :: binary-size(2), " ", reason :: binary>>),
    do: {:temp_error, {"4" <> code, reason}}
  defp parse_smtp_response(<<"5", code :: binary-size(2), " ", reason :: binary>>),
    do: {:error, {"5" <> code, reason}}

  defp parse_exentions(lines, acc \\ [])
  defp parse_exentions([], acc), do: Enum.reverse(acc)
  defp parse_exentions([line | tail], acc),
    do: parse_exentions(tail, [parse_exention(line) | acc])

  defp parse_exention({_code, line}),
    do: String.split(line, " ", parts: 2)

  defp read_potentially_multiline_response(socket) do
    {:ok, data} = Socket.recv(socket)
    parse_potentially_multiline_response(data, socket)
  end

  defp parse_potentially_multiline_response(data, socket, acc \\ [])
  defp parse_potentially_multiline_response(<<code :: binary-size(3), " ", rest :: binary>>, _socket, acc) do
    acc = [{code, rest} | acc]
    {:ok, Enum.reverse(acc)}
  end
  defp parse_potentially_multiline_response(<<code :: binary-size(3), "-", rest :: binary>>, socket, acc) do
    acc = [{code, rest} | acc]
    {:ok, data} = Socket.recv(socket)
    parse_potentially_multiline_response(data, socket, acc)
  end

  defp try_starttls(socket, extensions) do
    if supports_extension?("STARTTLS", extensions) do
      {:ok, socket} = do_starttls(socket) # TODO: Need to handle error case
      {:ok, extensions} = try_ehlo(socket)            # TODO: Need to handle error case
      {:ok, socket, extensions}
    else
      {:ok, socket, extensions}
    end
  end

  defp supports_extension?(_name, []), do: false
  defp supports_extension?(name, [[name | _] | _tail]), do: true
  defp supports_extension?(name, [_ | tail]), do: supports_extension?(name, tail)

  defp do_starttls(socket) do
    Socket.send(socket, "STARTTLS\r\n")
    {:ok, data} = Socket.recv(socket)
    {:ok, {"220", _message}} = parse_smtp_response(data)
    Socket.ssl_client(socket)
  end

  defp try_auth(socket, extensions, options) do
    if supports_extension?("AUTH", extensions) do
      {:ok, _} = do_auth(socket, options) # TODO: Need to handle error case
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  defp do_auth(socket, options) do
    username = Keyword.get(options, :username)
    password = Keyword.get(options, :password)

    auth_string = Base.encode64("\0" <> username <> "\0" <> password)
    Socket.send(socket, ["AUTH PLAIN ", auth_string, "\r\n"])
    {:ok, data} = Socket.recv(socket)
    parse_smtp_response(data)
  end

  def send_message(socket, from, to, message) do
    Socket.send(socket, ["MAIL FROM: <", from, ">\r\n"])
    {:ok, data} = Socket.recv(socket)
    {:ok, {"250", _ok}} = parse_smtp_response(data)

    Socket.send(socket, ["RCPT TO: <", to, ">\r\n"])
    {:ok, data} = Socket.recv(socket)
    {:ok, {"250", _}} = parse_smtp_response(data)

    Socket.send(socket, "DATA\r\n")
    {:ok, data} = Socket.recv(socket)
    {:ok, {"354", _ok}} = parse_smtp_response(data)

    message
    |> String.split(~r/\r\n/)
    |> Enum.each(fn(line) ->
      :ok = Socket.send(socket, [line, "\r\n"])
    end)

    :ok = Socket.send(socket, ".\r\n")
    {:ok, data} = Socket.recv(socket)
    {:ok, {"250", _}} = parse_smtp_response(data)
    :ok
  end

  def quit(socket) do
    Socket.send(socket, "QUIT\r\n")
    {:ok, data} = Socket.recv(socket)
    {:ok, {"221", _message}} = parse_smtp_response(data)
  end

  def fqdn do
    {:ok, name} = :inet.gethostname
    {:ok, hostent} = :inet.gethostbyname(name)
    {:hostent, fqdn, _aliases, :inet, _, _addresses} = hostent
    to_string(fqdn)
  end
end
