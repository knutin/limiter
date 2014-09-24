-module(limiter).
-export([do/4, async/4]).
-export([mk_req/3]).

%% API


do(Name, Request, WaitTimeout, WorkTimeout) ->
    try
        gen_server:call(Name, mk_req(Request, WaitTimeout, WorkTimeout),
                        WaitTimeout)
    catch
        exit:{timeout, _} ->
            {error, timeout}
    end.

async(Name, Request, WaitTimeout, WorkTimeout) ->
    Parent = self(),
    Tag = make_ref(),
    Pid = spawn_link(fun () ->
                             Result = do(Name, Request, WaitTimeout, WorkTimeout),
                             Parent ! {self(), Tag, Result}
                     end),
    Promise = fun () ->
                      receive
                          {Pid, Tag, Result} ->
                              Result
                      end
              end,
    Promise.


mk_req(Request, WaitTimeout, WorkTimeout) ->
    {do, Request, os:timestamp(), {WaitTimeout, WorkTimeout}}.
