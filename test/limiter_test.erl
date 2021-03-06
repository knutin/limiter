-module(limiter_test).
-include_lib("eunit/include/eunit.hrl").

limiter_test_() ->
    {foreach,
     fun () -> ok end,
     fun (_) -> ok end,
     [
      ?_test(simulation())
     ]}.

default_opts() ->
    [{mod, limiter_handler},
     {p, 1.0},
     {i, 0.01},
     {d, 1.0},
     {initial_capacity, 10},
     {max_concurrency, 100}].


%% simple_test() ->
%%     {ok, Pid} = limiter_server:start_link(default_opts()),
%%     limiter_server:cancel_timer(Pid),

%%     ?assertEqual({ok, hello}, limiter:do(Pid, {sleep, 10}, 100, 100)),
%%     ?assertEqual({error, timeout}, limiter:do(Pid, {sleep, 10}, 10, 10)),

%%     limiter_server:stop(Pid).

%% lowlevel_overload_test() ->
%%     {ok, Pid} = limiter_server:start_link([{mod, limiter_handler},
%%                                            {p, 1.0},
%%                                            {i, 0.01},
%%                                            {d, 100.0},
%%                                            {initial_capacity, 100},
%%                                            {max_concurrency, 100},
%%                                            {initial_time, 0}]),
%%     ok = limiter_server:cancel_timer(Pid),

%%     %% T=0
%%     ?assertEqual({ok, [{0, 100}]}, limiter_server:get_capacity(Pid)),
%%     ?assertEqual({ok, [{0, 100}]}, limiter_server:get_tokens(Pid)),

%%     ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 50}, 100, 100)),
%%     ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 50}, 100, 100)),
%%     ?assertEqual({ok, [{0, 0}]}, limiter_server:get_tokens(Pid)),

%%     %% T=1
%%     ok = limiter_server:set_ts(Pid, 1),
%%     ok = limiter_server:force_plan(Pid),

%%     ?assertMatch({ok, [{1, 110} | _]}, limiter_server:get_capacity(Pid)),

%%     ?assertMatch({ok, _}, limiter:do(Pid, {use_capacity, 100}, 100, 100)),
%%     ?assertMatch({ok, [{1, 10} | _]}, limiter_server:get_tokens(Pid)),
%%     ?assertEqual({error, overload}, limiter:do(Pid, return_overload, 100, 100)),

%%     %% T=2
%%     ok = limiter_server:set_ts(Pid, 2),
%%     ok = limiter_server:force_plan(Pid),

%%     ?assertMatch({ok, [{2, 102} | _]}, limiter_server:get_capacity(Pid)),

%%     ok.

simulation() ->
    ok = init_time_mock(),
    ok = set_time(0),
    {ok, Limiter} = limiter_server:start_link([{mod, limiter_handler},
                                               {p, 1.0},
                                               {i, 0.01},
                                               {d, 1.0},
                                               {initial_capacity, 20},
                                               {max_concurrency, 100},
                                               {initial_time, 0}]),
    ok = limiter_server:cancel_timer(Limiter),
    Parent = self(),

    %% One entry per second
    Capacity =
        lists:duplicate(60, 100) ++
        lists:duplicate(60, 50) ++
        lists:duplicate(60, 200),

    Resource = spawn_link(fun () -> resource_loop(Capacity, 0, Parent) end),


    Do = fun (Units) ->
                 limiter:do(Limiter, {use_resource, Resource, Units, 0},
                            1000, 1000)
         end,

    lists:map(fun (T) ->
                      Do(50),
                      Do(40),
                      Do(randrange(5)),
                      Do(randrange(5)),
                      Do(randrange(5)),

                      ok = set_time(T),
                      receive resource_shifting -> ok end,
                      ok = limiter_server:force_plan(Limiter, T)

              end, lists:seq(1, length(Capacity))),

    History = limiter_server:get_history(Limiter),
    error_logger:info_msg("~p~n", [History]),
    timer:sleep(1000),
    ok = limiter_server:stop(Limiter),
    ok = clear_time_mock().



resource_loop([Units | UnitSeries], Ts, Parent) ->
    resource_loop(UnitSeries, Ts, Units, Parent).

resource_loop(UnitSeries, Ts, UnitsLeft, Parent) ->
    case edatetime:now2ts() =:= Ts of
        true ->
            receive
                {do_work, From, UnitsToUse, Sleep} ->
                    NewUnitsLeft = UnitsLeft - UnitsToUse,

                    case NewUnitsLeft >= 0 of
                        true ->
                            timer:sleep(Sleep),
                            From ! {self(), {ok, {used_capacity, UnitsToUse}}},
                            resource_loop(UnitSeries, Ts, NewUnitsLeft, Parent);
                        false ->
                            From ! {self(), {error, overload}},
                            %%Parent ! {self(), empty},
                            %%error_logger:info_msg("wait for refill~n"),
                            %%wait_for_refill(UnitSeries, Ts, Parent)
                            resource_loop(UnitSeries, Ts, UnitsLeft, Parent)
                    end
            after 0 ->
                    resource_loop(UnitSeries, Ts, UnitsLeft, Parent)
            end;
        false ->
            Parent ! resource_shifting,
            case UnitSeries of
                [Units | Rest] ->
                    resource_loop(Rest, edatetime:now2ts(), Units, Parent);
                [] ->
                    Parent ! resource_done,
                    ok
            end
    end.

%% pid_test() ->
%%     Empty = limiter_pid_controller:new(1.0, 0.01, 1.0),
%%     {Out1, Pid1} = limiter_pid_controller:update(Empty, 300, 10),
%%     error_logger:info_msg("~p~n", [{Out1, Pid1}]),

%%     %%Pid2 = update_pid(Pid1, 290, 0),
%%     %%error_logger:info_msg("~p~n", [Pid2]),
%%     ok.

init_time_mock() ->
    ets:new(mocked_time, [public, ordered_set, named_table]),
    ok = meck:new(edatetime, [passthrough, no_link]),
    ok = meck:expect(edatetime, now2ts, 0,
                     fun () ->
                             [{time, T}] = ets:tab2list(mocked_time),
                             T
                     end),
    ok.

set_time(T) ->
    ets:insert(mocked_time, {time, T}),
    T = edatetime:now2ts(),
    ok.

clear_time_mock() ->
    ets:delete(mocked_time),
    meck:unload(edatetime).

randrange(Range) ->
    random:uniform(Range).
