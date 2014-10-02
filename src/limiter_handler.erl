-module(limiter_handler).
-include("limiter.hrl").

-callback do(request()) -> response().
-callback units(request()) -> pos_integer().
-callback units(request(), response()) -> pos_integer().


-export([do/1, units/1, units/2]).

%%
%% ENTRY-POINT FROM LIMITER
%%

do({sleep, N}) ->
    timer:sleep(N),
    {ok, hello};

do({use_capacity, N}) ->
    {ok, {used_capacity, N}};

do(return_overload) ->
    {error, overload};

do({use_resource, Pid, UnitsToUse, Sleep}) ->
    Pid ! {do_work, self(), UnitsToUse, Sleep},
    receive
        {Pid, Reply} ->
            %%error_logger:info_msg("resource reply: ~p~n", [Reply]),
            Reply
    end;

do(_Request) ->
    {ok, foo}.


%%
%% BOOKEEPING
%%

units(_Request) -> 1.

units(_, {ok, {used_capacity, N}}) -> N;
units(_Request, _Response) -> 1.
    
