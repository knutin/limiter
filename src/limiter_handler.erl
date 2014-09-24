-module(limiter_handler).
-include("limiter.hrl").

-callback do(request()) -> response().
-callback units(request()) -> pos_integer().
-callback units(request(), response()) -> pos_integer().


-export([do/1, units/1, units/2]).

do({sleep, N}) ->
    timer:sleep(N),
    {ok, hello};

do({use_capacity, N}) ->
    {ok, {used_capacity, N}};

do(return_overload) ->
    {error, overload};

do(_Request) ->
    {ok, foo}.

units(_Request) -> 1.

units(_, {ok, {used_capacity, N}}) -> N;
units(_Request, _Response) -> 1.
    
