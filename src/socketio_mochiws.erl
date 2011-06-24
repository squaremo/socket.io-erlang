-module(socketio_mochiws).

-behaviour(gen_fsm).

%% A gen_fsm for managing a WS Connection.

-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

% Interface and states
-export([start_link/1, send_frame/2, close/2]).
-export([wait_for_socket/2, wait_for_frame/2, close_sent/2]).

-record(state, {http_server, receiver, socket, parse_state, buffered = []}).

-record(parse, {type = unknown, fragments_rev = [], remaining = unknown}).

-define(TEXT_FRAME_START, 0).
-define(TEXT_FRAME_END, 255).

-define(CLOSE_TIMEOUT, 3000).

start_link(HttpServer) ->
    gen_fsm:start_link(?MODULE, [HttpServer], []).

send_frame(Pid, Frame) ->
    gen_fsm:send_event(Pid, {send, Frame}).

close(Pid, Reason) ->
    gen_fsm:send_event(Pid, {close, Reason}).

% States

wait_for_socket({send, Msg}, State = #state{ buffered = Buf }) ->
    {next_state, wait_for_socket, State#state{ buffered = [Msg | Buf] }};
wait_for_socket({socket_ready, Sock, ReceiverPid},
                State = #state{ buffered = Buf }) ->
    mochiweb_socket:setopts(Sock, [{active, once}]),
    State1 = State#state{ parse_state = initial_parse_state(),
                          socket = Sock,
                          buffered = [],
                          receiver = ReceiverPid },
    State2 = lists:foldr(fun send_data/2, State1, Buf),
    %error_logger:info_msg("Connection started ~p~n", [i(State1)]),
    {next_state, wait_for_frame, State2}.

wait_for_frame({data, Data}, State = #state{
                               socket = Sock,
                               receiver = Receiver,
                               parse_state = ParseState}) ->
    case parse_frame(Data, ParseState) of
        {more, ParseState1} ->
            mochiweb_socket:setopts(Sock, [{active, once}]),
            {next_state, wait_for_frame, State#state{parse_state = ParseState1}};
        {close, _ParseState1} ->
            %% TODO really necessary to reset here?
            %error_logger:info_msg("Client initiated close ~p~n", [i(State)]),
            State1 = State#state{ parse_state = rabbit_socks_ws:initial_parse_state() },
            {stop, normal, close_connection(State1)};
        {frame, {utf8, Str}, Rest} ->
            gen_server:call(Receiver, {websocket, Str, self()}),
            wait_for_frame({data, Rest},
                           State#state{
                             parse_state = rabbit_socks_ws:initial_parse_state()})
    end;
wait_for_frame({send, Frame}, State) ->
    {next_state, wait_for_frame, send_data(Frame, State)};
wait_for_frame({close, Reason}, State) ->
    error_logger:info_msg("Server initiated close ~p~n", [i(State)]),
    State1 = terminate_protocol(State),
    {next_state, close_sent, send_close(initiate_close(State1))};
wait_for_frame(_Other, State) ->
    {next_state, wait_for_frame, State}.

close_sent({send, _Data}, State) ->
    {next_state, close_sent, State};
close_sent({data, Data}, State = #state{ parse_state = ParseState,
                                         socket = Sock }) ->
    case rabbit_socks_ws:parse_frame(Data, ParseState) of
        {more, ParseState1} ->
            mochiweb_socket:setopts(Sock, [{active, once}]),
            {next_state, close_sent, State#state{ parse_state = ParseState1 }};
        {close, _ParseState} ->
            {stop, normal, finalise_connection(State)};
        {frame, _Frame, Rest} ->
            close_sent({data, Rest},
                       State#state{
                         parse_state = rabbit_socks_ws:initial_parse_state()})
    end;
close_sent({timeout, _Ref, close_handshake}, State) ->
    {stop, normal, finalise_connection(State)}.

%% internal

%% ff are state() -> state()

initiate_close(State) ->
    _TimerRef = gen_fsm:start_timer(?CLOSE_TIMEOUT, close_handshake),
    State.

send_data({utf8, Data}, State) ->
    send_data(State, Data);
send_data(IoList, State = #state { socket = Socket }) ->
    mochiweb_socket:send(Socket, [<<?TEXT_FRAME_START>>, IoList, <<?TEXT_FRAME_END>>]),
    State.

send_close(State = #state {
             socket = Socket }) ->
    mochiweb_socket:send(Socket, <<255,0>>),
    State.

close_connection(State) ->
    finalise_connection(send_close(State)).

finalise_connection(State = #state{ socket = Socket }) ->
    mochiweb_socket:close(Socket),
    State#state{ socket = closed }.

terminate_protocol(State = #state{ receiver = Receiver }) ->
    gen_server:call(Receiver, stop),
    State.

%% Frame parsing

initial_parse_state() ->
    #parse{}.

parse_frame(<<>>, Parse) ->
    {more, Parse};
parse_frame(<<255, 0, _Rest/binary>>, Parse) ->
    {close, Parse};
parse_frame(<<?TEXT_FRAME_START, Rest/binary>>,
            Parse = #parse{type = unknown,
                           fragments_rev = [],
                           remaining = unknown}) ->
    parse_frame(Rest, Parse#parse{type = utf8});
parse_frame(Bin, Parse = #parse{type = utf8}) ->
    parse_utf8_frame(Bin, Parse, 0);
%% TODO binary frames
parse_frame(Bin, Parse) ->
    {error, unrecognised_frame, {Bin, Parse}}.

parse_utf8_frame(Bin, Parse = #parse{type = utf8,
                                     fragments_rev = Frags},
                 Index) ->
    case Bin of
        <<Head:Index/binary, ?TEXT_FRAME_END, Rest/binary>> ->
            {frame, {utf8, lists:reverse([Head | Frags])}, Rest};
        <<Whole:Index/binary>> ->
            {more, Parse#parse{ fragments_rev = [ Whole | Frags] }};
        Bin ->
            parse_utf8_frame(Bin, Parse, Index + 1)
    end.

%% info for log messages

i(#state{ socket = closed }) ->
    closed;
i(#state{ socket = Socket }) ->
    socket_info(Socket).

socket_info(Socket) ->
    Peer = case mochiweb_socket:peername(Socket) of
               {ok, P1} -> P1;
               Else1    -> Else1
           end,
    Port = case mochiweb_socket:port(Socket) of
               {ok, P2} -> P2;
               Else2    -> Else2
           end,
    {Peer, Port}.

%% gen_fsm callbacks

init([HttpServer]) ->
    process_flag(trap_exit, true),
    State = #state{http_server = HttpServer},
    {ok, wait_for_socket, State}.

handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

handle_info({tcp, _Sock, Data}, State, StateData) ->
    ?MODULE:State({data, Data}, StateData);
handle_info({tcp_closed, Socket}, StateName,
            #state{socket = Socket} = StateData) ->
    error_logger:warning_msg("Connection unexpectedly dropped (in ~p)",
                             [StateName]),
    {stop, normal, terminate_protocol(StateData)};
handle_info({tcp_error, Socket, Reason}, StateName,
            #state{socket = Socket} = StateData) ->
    error_logger:warning_msg("Connection error reason=~p (in ~p)",
                             [Reason, StateName]),
    {stop, normal, terminate_protocol(StateData)};
handle_info(Info, StateName, StateData) ->
    {stop, {unexpected_info, StateName, Info}, StateData}.

%% If things happened cleanly, the protocol shoudl already be shut
%% down. However, if we crashed, we should tell it.
terminate(_Reason, _StateName, S = #state{socket = closed}) ->
    terminate_protocol(S);
terminate(_Reason, _StateName, S = #state{socket = Socket}) ->
    terminate_protocol(S),
    case catch mochiweb_socket:close(Socket) of
        _ -> ok
    end.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.
