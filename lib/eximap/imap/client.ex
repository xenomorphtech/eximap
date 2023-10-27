defmodule Eximap.Imap.Client do
  use GenServer
  alias Eximap.Imap.Request
  alias Eximap.Imap.Response
  alias Eximap.Socket

  @moduledoc """
  Imap Client GenServer

  @initial_state %{
    socket: nil,
    tag_number: 1,
    host: "outlook.office365.com",
    port: 993,
    account: "example",
    pass: "example",
    proxy: nil
  }
  """
  @literal ~r/{([0-9]*)}\r\n/s

  def start_link(st) do
    GenServer.start_link(__MODULE__, st)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call(
        {:command, %{} = req},
        _from,
        %{socket: socket, tag_number: tag_number} = state
      ) do
    resp =
      try do
        imap_send(socket, %Eximap.Imap.Request{req | tag: "EX#{tag_number}"})
      catch
        a, b -> {:error, {a, b}}
      end

    {:reply, resp, %{state | tag_number: tag_number + 1}}
  end

  def handle_call(
        {:login, params},
        _from,
        _state
      ) do
    %{host: host, port: port, account: account, pass: pass} = params
    proxy = Map.get(params, :proxy, nil)

    opts = [:binary, {:active, false}]

    timeout = 30000

    # todo: Hardcoded SSL connection until I implement the Authentication algorithms to allow login over :gen_tcp
    # host = 
    # port = 993
    {res, socket, state} =
      try do
        {:ok, socket} =
          case proxy do
            %{type: :http} ->
              {:ok, socket} =
                Socket.connect(false, :binary.bin_to_list(proxy.ip), proxy.port, opts)

              base64 = Base.encode64(<<proxy.username::binary, ":", proxy.password::binary>>)
              proxy_auth = <<"Basic ", base64::binary>>
              # proxy_auth = "Proxy-Authorization" <> proxyAuth

              hostPort = <<host::binary, ":", Integer.to_string(port)::binary>>
              pConn = <<"keep-alive">>

              proxyRequestBin = [
                "CONNECT ",
                hostPort,
                " HTTP/1.1\r\n",
                "Host: ",
                hostPort,
                "\r\n",
                "Proxy-Authorization: ",
                proxy_auth,
                "\r\n",
                "Proxy-Connection: ",
                pConn,
                "\r\n\r\n"
              ]

              # IO.inspect(proxyRequestBin)

              :gen_tcp.send(socket, proxyRequestBin)

              {:ok, 200, _headers, _peplyBody} = :comsat_core_http.get_response(socket, timeout)
              {:ok, socket}

            %{type: :sock5} ->
              {:ok, socket} =
                Socket.connect(false, :binary.bin_to_list(proxy.ip), proxy.port, opts)

              :ok =
                :comsat_socks5.do_server_handshake(
                  host,
                  port,
                  socket,
                  :undefined,
                  :undefined,
                  30000
                )

              {:ok, socket}

            _ ->
              {:ok, _socket} = Socket.connect(false, :binary.bin_to_list(host), port, opts)
          end

        ssl_options = [verify_type: :verify_none, log_level: :none, mode: :binary, active: false]
        {:ok, socket} = :ssl.connect(socket, ssl_options, timeout)

        state = %{params | socket: socket}

        # todo: parse the server attributes and store them in the state
        imap_receive_raw(socket)

        # login using the account name and password
        req = Request.login(account, pass) |> Request.add_tag("EX_LGN")
        res = imap_send(socket, req)
        {res, socket, state}
      catch
        a, b ->
          {{:error, {a, b}}, nil, params}
      end

    case res do
      %Eximap.Imap.Response{
        message: "LOGIN failed."
      } ->
        {:reply, {:error, :wrong_credentials}, state}

      {:error, err} ->
        {:reply, err, state}

      _ ->
        {:reply, :ok, %{state | socket: socket}}
    end
  end

  def execute(pid, req) do
    GenServer.call(pid, {:command, req})
  end

  def handle_info(resp, state) do
    IO.inspect(resp)
    {:noreply, state}
  end

  #
  # Private methods
  #

  defp imap_send(socket, req) do
    message = Request.raw(req)
    imap_send_raw(socket, message)
    imap_receive(socket, req)
  end

  defp imap_send_raw(socket, msg) do
    # IO.inspect "C: #{msg}"
    Socket.send(socket, msg)
  end

  defp imap_receive(socket, req) do
    msg = assemble_msg(socket, req.tag)
    # IO.inspect("R: #{msg}")
    %Eximap.Imap.Response{request: req} |> parse_message(msg)
  end

  # assemble a complete message
  defp assemble_msg(socket, tag), do: assemble_msg(socket, tag, "")

  defp assemble_msg(socket, tag, msg) do
    {:ok, recv} = Socket.recv(socket, 0)
    msg = msg <> recv

    if Regex.match?(~r/^.*#{tag} .*\r\n$/s, msg),
      do: msg,
      else: assemble_msg(socket, tag, msg)
  end

  defp parse_message(resp, ""), do: resp

  defp parse_message(resp, msg) do
    [part, other_parts] = get_msg_part(msg)
    {:ok, resp, other_parts} = Response.parse(resp, part, other_parts)
    if resp.partial, do: parse_message(resp, other_parts), else: resp
  end

  # get [message part, other message parts] that recognises {size}\r\n literals
  defp get_msg_part(msg), do: get_msg_part("", msg)

  defp get_msg_part(part, other_parts) do
    if other_parts =~ @literal do
      [_match | [size]] = Regex.run(@literal, other_parts)
      size = String.to_integer(size)
      [head, tail] = String.split(other_parts, @literal, parts: 2)
      # literal = for i <- 0..(size - 1), do: Enum.at(String.codepoints(tail), i)
      # Performace boost.  Large messages and attachments killed this and took > 2 minutes for a 40K attachment.
      cp = String.codepoints(tail)
      {literal, _post_literal_cp} = Enum.split(cp, size)
      literal = to_string(literal)
      {_, post_literal} = String.split_at(tail, String.length(literal))

      case post_literal do
        "\r\n" <> next -> [part <> head <> literal, next]
        _ -> get_msg_part(part <> head <> literal, post_literal)
      end
    else
      [h, t] = String.split(other_parts, "\r\n", parts: 2)
      [part <> h, t]
    end
  end

  defp imap_receive_raw(socket) do
    {:ok, msg} = Socket.recv(socket, 0)
    msgs = String.split(msg, "\r\n", parts: 2)
    msgs = Enum.drop(msgs, -1)
    #    Enum.map(msgs, &(IO.inspect "S: #{&1}"))
    msgs
  end
end
