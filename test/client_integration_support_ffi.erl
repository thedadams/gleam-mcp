-module(client_integration_support_ffi).
-export([get_env/1, sleep_ms/1]).

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> unicode:characters_to_binary(Value)
    end.

sleep_ms(Duration) ->
    timer:sleep(Duration).
