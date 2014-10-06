-module(limiter_test).
-include_lib("eunit/include/eunit.hrl").

limiter_test_() ->
    {foreach,
     fun () -> ok end,
     fun (_) -> ok end,
     [
      {timeout, 10, ?_test(simulation())}
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


    Resource = spawn_link(fun () -> resource_loop(lists:duplicate(60, 100),
                                                  0, Parent) end),


    %% 100 clients hammering the resource
    spawn(fun () ->
                  simulate_clients(200, 10000, {Limiter, Resource, 10, 0,
                                                10000, 10000}),
                  Parent ! simulation_done
          end),


    lists:map(fun (T) ->
                      receive {Resource, empty} -> ok end,
                      ok = limiter_server:force_plan(Limiter, T)
                      %%ok = set_time(T)
              end, lists:seq(1, 60)),
    %%receive simulation_done -> ok end,


    History = limiter_server:get_history(Limiter),
    error_logger:info_msg("~p~n", [History]),
    timer:sleep(1000),
    limiter_server:stop(Limiter).


simulate_clients(Concurrency, NumRequests, Args) ->
    Parent = self(),
    MakeClient = fun (_) ->
                         spawn_link(
                           fun () ->
                                   client_loop(Parent, NumRequests, Args)
                           end)
                 end,
    Clients = lists:map(MakeClient, lists:seq(1, Concurrency)),

    %%[C ! {go, self(), Args} || C <- Clients],
    simulate_clients_loop(Clients).


simulate_clients_loop([]) ->
    %%[C ! die || C <- Clients],
    error_logger:info_msg("done!~n"),
    ok;
simulate_clients_loop(Clients) ->
    receive
        {Pid, done} ->
            simulate_clients_loop(lists:delete(Pid, Clients))
    end.


client_loop(Parent, 0, _) ->
    Parent ! {self(), done},
    ok;
client_loop(Parent, N, {Limiter, Resource, UnitsToUse, ResourceSleep,
                WaitTimeout, WorkTimeout} = Args) ->
    limiter:do(Limiter,
               {use_resource, Resource, UnitsToUse, ResourceSleep},
               WaitTimeout, WorkTimeout),
    client_loop(Parent, N-1, Args).





resource_loop([Units | UnitSeries], Ts, Parent) ->
    resource_loop(UnitSeries, Ts, Units, Parent).

resource_loop(UnitSeries, Ts, UnitsLeft, Parent) ->
    receive
        {do_work, From, UnitsToUse, Sleep} ->
            NewUnitsLeft = UnitsLeft - UnitsToUse,
            case NewUnitsLeft >= 0 of
                true ->
                    timer:sleep(Sleep),
                    From ! {self(), {ok, {used_capacity, UnitsToUse}}},
                    %%error_logger:info_msg("units ~p~n", [NewUnitsLeft]),
                    resource_loop(UnitSeries, Ts, NewUnitsLeft, Parent);
                false ->
                    From ! {self(), {error, overload}},
                    Parent ! {self(), empty},
                    error_logger:info_msg("wait for refill~n"),
                    wait_for_refill(UnitSeries, Ts, Parent)
            end
    end.

wait_for_refill(UnitSeries, Ts, Parent) ->
    receive
        {do_work, From, _, _} ->
            From ! {self(), {error, overload}},

            case edatetime:now2ts() =:= Ts of
                true ->
                    timer:sleep(10),
                    wait_for_refill(UnitSeries, Ts, Parent);
                false ->
                    error_logger:info_msg("resource shifting time, new_t=~p~n",
                                          [edatetime:now2ts()]),
                    case UnitSeries of
                        [Units | Rest] ->
                            resource_loop(Rest, edatetime:now2ts(), Units, Parent);
                        [] ->
                            Parent ! resource_done,
                            ok
                    end
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
