-module(socketio_http_mochiweb).

-behaviour(socketio_http_server).

-export([start_link/1, file/2, respond/2, respond/3, respond/4]).
-export([parse_post/1, headers/2, chunk/2, stream/2, socket/1]).
-export([get_headers/1, websocket_send/2, ensure_longpolling_request/1]).

start_link(Opts) ->
    Port = proplists:get_value(port, Opts),
    HttpProcess = proplists:get_value(http_process, Opts),
    Prefix = proplists:get_value(resource, Opts),
    SSL = proplists:get_value(ssl, Opts),
    MochiOpts = mochiweb_options(Port, HttpProcess, Prefix, SSL),
    Name = "socketio-mochiweb-" ++ integer_to_list(Port),
    %% This does, ultimately, start_link a gen_server.
    socketio_http_mochiweb_sup:start_link([{name, Name} | MochiOpts]).

file(Req, Filename) ->
    %% Euw, frankly.
    Req:serve_file(Filename, "").

respond(Req, Code) ->
    Req:respond({Code, [], ""}).

respond(Req, Code, Content) ->
    Req:respond({Code, [], Content}).

respond(Req, Code, Headers, Content) ->
    Req:respond({Code, Headers, Content}).

parse_post(Req) ->
    Req:parse_post().

headers(Req, Headers) ->
    %% TODO socketio_http will send a Transfer-Encoding if it's
    %% intending to send a chunked response. Do we want to detect this
    %% and use the special case {200, Headers, chunked} for mochiweb?
    Req:start_raw_response({200, Headers}).

chunk(Req, Chunk) ->
    Res = mochiweb_response:new(Req, 200, []),
    Res:write_chunk(Chunk).

stream(Req, Data) ->
    Req:send(Data).

socket(Req) ->
    Req:get(socket).

get_headers(Req) ->
    mochiweb_headers:to_list(Req:get(headers)).

websocket_send(Ws, Data) ->
    socketio_mochiws:send_frame(Ws, Data).

ensure_longpolling_request(Req) ->
    %% TODO anything to do here?
    Req.

%% ------------- Internal

mochiweb_options(Port, HttpProcess, Resource, SSL) ->
    [{port, Port},
     {loop, fun(Req) -> handle_request(Req, Resource, HttpProcess) end} |
     case SSL of
         undefined ->
             [];
         SSLOpts ->
             [{ssl, true},
              {ssl_opts, SSLOpts}]
     end].

handle_request(Req, Prefix, HttpServer) ->
    Path = Req:get(path),
    ResourceRev = lists:reverse(string:tokens(Path, "/")),
    case ResourceRev of
        ["websocket"|Prefix] ->
            maybe_ws(Req, Prefix, HttpServer);
        ["flashsocket"|Prefix] ->
            maybe_ws(Req, Prefix, HttpServer);
        %% ["websocket"] ->
        %%     maybe_ws(Req, Prefix, HttpServer);
        _ ->
            gen_server:call(HttpServer,
                            {request, Req:get(method), ResourceRev, Req},
                            infinity)
    end.

maybe_ws(Req, Prefix, HttpServer) ->
    Scheme = case Req:get(socket) of
                 {ssl, _Sock} -> "wss";
                 _Sock        -> "ws"
             end,
    case process_handshake(Scheme, Req) of
        {error, DoesNotCompute} ->
            close_error(Req);
        {response, Headers, Body} ->
            send_headers(Req, Headers),
            Req:send(Body),
            {ok, Ws} = start_ws(HttpServer),
            {SessionId, Pid} = gen_server:call(HttpServer,
                                               {session, generate, {websocket, Ws},
                                                socketio_transport_websocket}),
            Sock = Req:get(socket),
            handover_socket(Sock, Ws),
            gen_fsm:send_event(Ws, {socket_ready, Sock, Pid}),
            %% We do this so that the mochiweb acceptor process does
            %% not try to clean up the socket.
            exit(normal)
    end.

process_handshake(Scheme, Req) ->
    %% TODO: check the origin, using something akin to misultin's
    %% code.
    Origin = Req:get_header_value("Origin"),
    Location = make_location(Scheme, Req),
    FirstBit = [{"Upgrade", "WebSocket"},
                {"Connection", "Upgrade"}],
    case Req:get_header_value("Sec-WebSocket-Key1") of
        undefined ->
            {response,
             FirstBit ++
             [{"WebSocket-Origin", Origin},
              {"WebSocket-Location", Location}],
             <<>>};
        Key1 ->
            Key2 = Req:get_header_value("Sec-WebSocket-Key2"),
            Key3 = Req:recv(8),
            Hash = handshake_hash(Key1, Key2, Key3),
            {response,
             FirstBit ++
             [{"Sec-WebSocket-Origin", Origin},
              {"Sec-WebSocket-Location", Location}],
             Hash}
    end.

handshake_hash(Key1, Key2, Key3) ->
    erlang:md5([reduce_key(Key1), reduce_key(Key2), Key3]).

make_location(Scheme, Req) ->
    Host = Req:get_header_value("Host"),
    Resource = Req:get(raw_path),
    mochiweb_util:urlunsplit(
      {Scheme, Host, Resource, "", ""}).

reduce_key(Key) when is_list(Key) ->
    {NumbersRev, NumSpaces} = lists:foldl(
                             fun (32, {Nums, NumSpaces}) ->
                                     {Nums, NumSpaces + 1};
                                 (Digit, {Nums, NumSpaces})
                                   when Digit > 47 andalso Digit < 58 ->
                                     {[Digit | Nums], NumSpaces};
                                 (_Other, Res) ->
                                     Res
                             end, {[], 0}, Key),
    OriginalNum = list_to_integer(lists:reverse(NumbersRev)) div NumSpaces,
    <<OriginalNum:32/big-unsigned-integer>>.

close_error(Req) ->
    Req:respond({400, [], ""}).

send_headers(Req, Headers) ->
    Req:start_raw_response({"101 Web Socket Protocol Handshake",
                            mochiweb_headers:from_list(Headers)}).

start_ws(HttpServer) ->
    socketio_http_mochiweb_sup:start_connection(HttpServer).

handover_socket({ssl, Sock}, Pid) ->
    ssl:controlling_process(Sock, Pid);
handover_socket(Sock, Pid) ->
    gen_tcp:controlling_process(Sock, Pid).
