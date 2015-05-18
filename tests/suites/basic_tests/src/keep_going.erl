-module(keep_going).

-export([scenarios/0]).
-export([concuerror_options/0]).
-export([test/0]).

concuerror_options() ->
    [{keep_going, false}].

scenarios() ->
    [{test, inf, dpor, crash}].

test() ->
    P = self(),
    spawn(fun() -> P ! ok end),
    spawn(fun() -> P ! ok end),
    spawn(fun() -> P ! ok end),
    receive
        ok -> ok
    after
      0 ->
        receive
          ok -> exit(error)
        after
          0 ->
            receive
              ok -> ok
            after
              0 -> ok
            end
        end
    end.
