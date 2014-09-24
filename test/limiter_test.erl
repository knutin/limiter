-module(limiter_test).
-include_lib("eunit/include/eunit.hrl").


default_opts() ->
    [{mod, limiter_handler},
     {p, 1.0},
     {i, 0.01},
     {d, 1.0},
     {initial_capacity, 10},
     {max_concurrency, 100}].


simple_test() ->
    {ok, Pid} = limiter_server:start_link(default_opts()),
    limiter_server:cancel_timer(Pid),

    ?assertEqual({ok, hello}, limiter:do(Pid, {sleep, 10}, 100, 100)),
    ?assertEqual({error, timeout}, limiter:do(Pid, {sleep, 10}, 10, 10)),

    limiter_server:stop(Pid).

lowlevel_overload_test() ->
    {ok, Pid} = limiter_server:start_link([{mod, limiter_handler},
                                           {p, 1.0},
                                           {i, 0.01},
                                           {d, 100.0},
                                           {initial_capacity, 100},
                                           {max_concurrency, 100},
                                           {initial_time, 0}]),
    ok = limiter_server:cancel_timer(Pid),

    %% T=0
    ?assertEqual({ok, [{0, 100}]}, limiter_server:get_capacity(Pid)),
    ?assertEqual({ok, [{0, 100}]}, limiter_server:get_tokens(Pid)),

    ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 50}, 100, 100)),
    ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 50}, 100, 100)),
    ?assertEqual({ok, [{0, 0}]}, limiter_server:get_tokens(Pid)),

    %% T=1
    ok = limiter_server:set_ts(Pid, 1),
    ok = limiter_server:force_plan(Pid),

    ?assertMatch({ok, [{1, 110} | _]}, limiter_server:get_capacity(Pid)),

    ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 100}, 100, 100)),
    ?assertMatch({ok, [{1, 10} | _]}, limiter_server:get_tokens(Pid)),
    ?assertEqual({error, overload}, limiter:do(Pid, return_overload, 100, 100)),

    %% T=2
    ok = limiter_server:set_ts(Pid, 2),
    ok = limiter_server:force_plan(Pid),

    ?assertMatch({ok, [{2, 102} | _]}, limiter_server:get_capacity(Pid)),

    ok.



%% pid_test() ->
%%     Empty = limiter_pid_controller:new(1.0, 0.01, 1.0),
%%     {Out1, Pid1} = limiter_pid_controller:update(Empty, 300, 10),
%%     error_logger:info_msg("~p~n", [{Out1, Pid1}]),

%%     %%Pid2 = update_pid(Pid1, 290, 0),
%%     %%error_logger:info_msg("~p~n", [Pid2]),
%%     ok.

