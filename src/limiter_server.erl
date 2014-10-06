-module(limiter_server).
-behaviour(gen_server).

%% API
-export([start_link/1, stop/1]).

%% Exported for testing
-export([cancel_timer/1,
         set_ts/2,
         force_plan/2,
         get_tokens/1,
         get_capacity/1,
         get_history/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state,
        {mod,

         queue,
         tokens,

         estimated_capacity :: integer(),
         used_capacity :: integer(),
         overload :: integer(),

         estimated_capacity_history :: [{edatetime:timestamp(), integer()}],
         used_capacity_history :: [{edatetime:timestamp(), integer()}],
         overload_history :: [{edatetime:timestamp(), integer()}],

         pid,

         workers,
         num_workers,
         max_workers,

         response_times,
         predicted_response_time,

         plan_timer,
         current_ts
        }).

%%
%% API
%%

start_link(Opts) ->
    case proplists:get_value(name, Opts) of
        undefined ->
            gen_server:start_link(?MODULE, [Opts], []);
        Name ->
            gen_server:start_link({local, Name}, ?MODULE, [Opts], [])
    end.

stop(Limiter) ->
    gen_server:call(Limiter, stop).

stats(Name) ->
    ok.


%%
%% INTERNAL API FOR TESTING
%%

cancel_timer(Limiter)   -> gen_server:call(Limiter, cancel_timer).
set_ts(Limiter, Ts)     -> gen_server:call(Limiter, {set_ts, Ts}).
force_plan(Limiter, Ts) -> gen_server:call(Limiter, {force_plan, Ts}).
get_tokens(Limiter)     -> gen_server:call(Limiter, get_tokens).
get_capacity(Limiter)   -> gen_server:call(Limiter, get_estimated_capacity).
get_history(Limiter)    ->
    {ok, Overload, Estimated, Used} = gen_server:call(Limiter, get_history),
    lists:keysort(
      1,
      lists:foldl(fun ({T, E}, Acc) ->
                          O = proplists:get_value(T, Overload),
                          U = proplists:get_value(T, Used),
                          [{T, E, U, O} | Acc]
                  end, [], Estimated)).


%%
%% gen_server callbacks
%%
init([Opts]) ->
    Mod             = proplists:get_value(mod, Opts),
    InitialCapacity = proplists:get_value(initial_capacity, Opts),
    MaxConcurrency  = proplists:get_value(max_concurrency, Opts),

    P = proplists:get_value(p, Opts),
    I = proplists:get_value(i, Opts),
    D = proplists:get_value(d, Opts),

    T = proplists:get_value(initial_time, Opts, edatetime:now2ts()),

    process_flag(trap_exit, true),
    {ok, TRef} = timer:send_interval(1000, self(), plan),
    {ok, #state{mod = Mod,
                queue = queue:new(),
                tokens = InitialCapacity,
                workers = [],
                num_workers = 0,
                max_workers = MaxConcurrency,

                overload = 0,
                overload_history = [{T, 0}],
                estimated_capacity = InitialCapacity,
                estimated_capacity_history = [{T, InitialCapacity}],
                used_capacity = 0,
                used_capacity_history = [{T, 0}],


                pid = limiter_pid_controller:new(P, I, D, T),

                plan_timer = TRef,
                predicted_response_time = 100,
                current_ts = T
               }}.



handle_call({do, Request, WaitStart, {WaitTimeout, _} = Timeouts},
            From, #state{queue = Q} = State) ->
    case enough_time(WaitStart, WaitTimeout, State#state.predicted_response_time) of
        true ->
            NewQ = queue:in({From, Request, Timeouts}, Q),
            {noreply, spawn_workers(State#state{queue = NewQ})};
        false ->
            %%error_logger:info_msg("not enough time for ~p~n", [Request]),
            {noreply, State}
    end;

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};


%% TESTING
handle_call(cancel_timer, _From, State) ->
    timer:cancel(State#state.plan_timer),
    {reply, ok, State};

handle_call({set_ts, Ts}, _From, State) ->
    error_logger:info_msg("set ts to ~p~n", [Ts]),
    {reply, ok, State#state{current_ts = Ts}};

handle_call({force_plan, NewTs}, _From, State) ->
    {reply, ok, spawn_workers(plan(State#state{current_ts = NewTs}))};

handle_call(get_tokens, _From, State) ->
    {reply, {ok, State#state.tokens}, State};

handle_call(get_history, _From, State) ->
    {reply, {ok,
             State#state.overload_history,
             State#state.estimated_capacity_history,
             State#state.used_capacity_history}, State}.







handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({{Pid, Ref}, Response},
            #state{workers = Workers, num_workers = N, mod = Mod} = State) ->
    case lists:keytake({Pid, Ref}, 1, Workers) of
        {value, {{Pid, Ref}, From, Request, _, Timer},
         NewWorkers} ->
            erlang:cancel_timer(Timer),
            gen_server:reply(From, Response),

            case Response of
                {ok, _} ->
                    UsedUnits = Mod:units(Request, Response),
                    UsedCapacity = State#state.used_capacity,
                    {noreply, State#state{workers = NewWorkers,
                                          num_workers = N-1,
                                          used_capacity = UsedCapacity+UsedUnits
                                         }};
                {error, overload} ->
                    Overload = State#state.overload,
                    {noreply, State#state{workers = NewWorkers, num_workers = N-1,
                                          overload = Overload+1}}
            end;
        false ->
            {noreply, State}
    end;

handle_info({worker_timeout, {Pid, Ref}},
            #state{workers = Workers, num_workers = N} = State) ->
    case lists:keytake({Pid, Ref}, 1, Workers) of
        {value, {{Pid, Ref}, From, _, _, _}, NewWorkers} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{workers = NewWorkers, num_workers = N-1}};
        false ->
            {noreply, State}
    end;

handle_info(plan, State) ->
    %%Current = edatetime:now2ts(),
    %%Next = edatetime:shift(Current, 1, second),

    {noreply, spawn_workers(plan(State))};

handle_info({'EXIT', _Pid, normal}, State) ->
    {noreply, State}.



terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Internal functions
%%

spawn_workers(#state{workers = Workers, num_workers = N, tokens = Tokens,
                     mod = Mod, queue = Q} = State) ->

    case worker_limit(State)
        and not queue:is_empty(Q)
        and free_tokens(State) of
        true ->
            {{value, {From, Request, {WaitTimeout, WorkTimeout}}}, NewQ} = queue:out(Q),
            Parent = self(),
            Ref = make_ref(),
            Pid = spawn_link(fun () ->
                                     Parent ! {{self(), Ref}, Mod:do(Request)}
                             end),
            Timer = erlang:send_after(WorkTimeout, self(), {worker_timeout, {Pid, Ref}}),
            Worker = {{Pid, Ref}, From, Request, {WaitTimeout, WorkTimeout},
                      Timer},
            spawn_workers(State#state{workers = [Worker | Workers],
                                      tokens = Tokens-1,
                                      num_workers = N+1, queue = NewQ});
        false ->
            State
    end.

worker_limit(#state{num_workers = N, max_workers = Max}) -> N < Max.

enough_time(WaitStart, WaitTimeout, PredictedResponseTime) ->
    timer:now_diff(os:timestamp(), WaitStart) + PredictedResponseTime
        < (WaitTimeout * 1000).


free_tokens(State) ->
    State#state.tokens > 0.


plan(State) ->
    T = State#state.current_ts,
    %% error_logger:info_msg("planning t=~p~n"
    %%                       "overload_history=~w~n"
    %%                       "estimated_capacity=~w~n"
    %%                       "used_capacity=~w~n",
    %%                       [T, State#state.overload_history,
    %%                        State#state.estimated_capacity,
    %%                        State#state.used_capacity]),

    Estimate = trunc(estimate_capacity(State)),
    %%error_logger:info_msg("new estimate: ~p~n", [NewEstimatedCapacity]),


    State#state{tokens = Estimate,
                estimated_capacity = Estimate,
                used_capacity = 0,
                overload = 0,

                estimated_capacity_history = [{T, Estimate} |
                                              State#state.estimated_capacity_history],
                used_capacity_history = [{T, State#state.used_capacity} |
                                         State#state.used_capacity_history],
                overload_history = [{T, State#state.overload} |
                                    State#state.overload_history]}.


estimate_capacity(State) ->
    {_, PrevEstimate} = hd(State#state.estimated_capacity_history),
    UsedCapacity = State#state.used_capacity,

    UsedMoreThanEstimated = UsedCapacity >= PrevEstimate,
    HadOverload = State#state.overload > 0,

    case {UsedMoreThanEstimated, HadOverload} of
        {true, false}  -> UsedCapacity;
        {true, true}   -> UsedCapacity * 0.90;
        {_, true}      -> PrevEstimate * 0.90;
        {false, false} -> UsedCapacity * 1.05
    end.
