-module(socketio_http_mochiweb_sup).

-behaviour(supervisor).

% Behaviour
-export([init/1]).

% Interface
-export([start_link/1, start_connection/1]).

init([connection]) ->
    {ok, {{simple_one_for_one, 10, 10},
          [{undefined, {socketio_mochiws, start_link, []},
           transient, 50, worker, []}]}};
init([listener, MochiOpts]) ->
    {ok, {{rest_for_one, 10, 10},
          [{listener, {mochiweb_http, start, [MochiOpts]},
            permanent, 200, worker, [mochiweb_http]},
           {connection_sup, {?MODULE, start_connection_sup, []},
            permanent, infinity, supervisor, [?MODULE]}]}}.

%% Start a listener supervisor
start_link(MochiOpts) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [listener, MochiOpts]).

%% Start a connection
start_connection(Server) ->
    [Sup] =
        [Sup || {connection_sup, Sup, _, _} <-
                    supervisor:which_children(?MODULE)],
    supervisor:start_child(Sup, [Server]).
