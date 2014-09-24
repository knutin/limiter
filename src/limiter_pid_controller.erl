-module(limiter_pid_controller).
-export([new/4, update/3, clear/2]).

-record(pid, {p_gain, i_gain, d_gain,
              last_t, integral, prev_error}).

new(P, I, D, Now) ->
    #pid{p_gain = P, i_gain = I, d_gain = D,
         last_t = Now, integral = 0, prev_error = 0}.


update(#pid{p_gain = P, i_gain = I, d_gain = D} = Pid, Now, Error) ->
    Delta = Now - Pid#pid.last_t,
    Integral = Pid#pid.integral + (Error * Delta),
    Derivative = (Error - Pid#pid.prev_error) / Delta,
    Output = P * Error + I * Integral + D + Derivative,
    {Output, Pid#pid{prev_error = Error, integral = Integral}}.


    %% PTerm = Pid#pid.p_gain * Error,
    %% IState = max(Pid#pid.i_state + Error, 0),
    %% ITerm = Pid#pid.i_gain * IState,
    %% DTerm = Pid#pid.d_gain * (Position - Pid#pid.d_state),
    %% {PTerm + ITerm - DTerm, Pid#pid{d_state = Position}}.

clear(#pid{} = Pid, Now) ->
    Pid#pid{prev_error = 0, integral = 0, last_t = Now}.
