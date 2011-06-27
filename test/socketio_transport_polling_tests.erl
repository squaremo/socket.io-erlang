-module(socketio_transport_polling_tests).
-include_lib("eunit/include/eunit.hrl").

transport_xhr_polling_test_() ->
    [socketio_transport_tests:transport_tests(B, "xhr-polling") ||
        B <- [chrome, firefox]].

transport_jsonp_polling_test_() ->
    [socketio_transport_tests:transport_tests(B, "jsonp-polling") ||
        B <- [chrome, firefox]].
