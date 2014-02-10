% @copyright 2013-2014 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Florian Schintke <schintke@zib.de>
%% @doc Allow to centrally schedule all messages involved in a certain
%%   protocol execution and calculate the number of possible
%%   interleavings for convenience (so one can guess how often the
%%   protocol has to be run randomly to cover all possible
%%   interleavings).

%% How it works: We use same mechanism as trace_mpath and send all
%% messages to the scheduler. The scheduler maintains a mailbox for
%% each pair of (Src, Dest) to maintain FIFO ordering of channels, but
%% allowing all other possible message interleavings. It delivers -
%% steered by the given random seed - a single message for execution
%% and receives a confirmation when the corresponding message handler
%% is done. All messages generated by this message handler will arrive
%% at the scheduler before the on_handler_done message, as Erlang
%% provides FIFO on single channels and all comm:sends are redirected
%% to the central scheduler.

%% How is the number of possible message interleavings calculated: At
%% each step, we know how many messages we can choose from. So the
%% number of different interleavings is the product of the
%% possibilities in each step.

%% How to detect the end of the protocol? When no more messages are
%% handable, the protocol is finished.

%% Why this cannot be done with the breakpoints that gen_components
%% provide? Breakpoints only have the execution of a message handler
%% under its control. If a message handler generates new messages in
%% the system, the VM directly enqueues them to the corresponding
%% mailboxes of the receivers. As there is no shuffeling in the
%% mailboxes of each receiver, there is only a limited amount of
%% message interleaving simulated using breakpoints. In contrast with
%% proto_sched, messages generated by different message handlers can
%% overhaul each other, as long as the do not correspond to the same
%% communication channel, were FIFO ordering is maintained.

%% Fast tests for timeouts: For msg_delay, we could add a modification
%% so timeouts are just directly put in the pool of deliverable
%% messages. So this would simulate a long lasting execution in a
%% short timeframe (time compression). Actually msg_delay events
%% somehow must be sorted according to the time they 'can' be
%% delivered?  if req A is send and wants to be delivered after 10 sec
%% and B is then send and wants to be delivererd after 5 secons, each
%% could be delivered first?!

%% @version $Id:$
-module(proto_sched).
-author('schintke@zib.de').
-vsn('$Id:$').

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Quick start:
%% 1. call proto_sched:start() %% seed has to be put somehow in
%% 2. call proto_sched:start_deliver()
%% 3. perform a synchronous request like api_tx:read("a")
%% 4. call proto_sched:stop() %% trace_id is taken from the calling
%%                               process implicitly
%% 5. call proto_sched:cleanup().
%%
%% or
%%
%% 1. call proto_sched:start()
%% 2. start all asynchronous call you want to run interleaved
%% 3. call proto_sched:start_deliver() to initiate protocol execution
%% 4. wait until everything is done; use ?SCALARIS_RECV to receive answers
%% 5. call proto_sched:stop()
%% 6. call proto_sched:get_infos() to retrieve some statistics like
%%    the number of possible interleavings, the number of local or
%%    globally send messages, etc.
%% 7. call proto_sched:cleanup() to forget about the run and
%%    delete statistics data
%%
%% You can also provide a trace_id, so that the module can be used
%% independently for several protocols at the same time (e.g. in concurrent
%% unittests). See the interfaces and exported functions below.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%-define(TRACE(X,Y), log:log(X,Y)).
-define(TRACE(X,Y), ok).

-include("scalaris.hrl").
-include("record_helpers.hrl").
-behaviour(gen_component).

%% client functions
-export([start/0, start/1, start/2, stop/0]).
-export([start_deliver/0, start_deliver/1]).
-export([get_infos/0, get_infos/1]).
-export([register_callback/1, register_callback/2]).
-export([infected/0]).
-export([clear_infection/0, restore_infection/0]).
-export([cleanup/0, cleanup/1]).

%% report messages from other modules
-export([log_send/5]).
-export([epidemic_reply_msg/4]).

%% gen_component behaviour
-export([start_link/1, init/1]).
-export([on/2]). %% internal message handler as gen_component

-type logger()       :: {proto_sched, comm:mypid()}.
-type anypid()       :: pid() | comm:mypid().
-type trace_id()     :: atom().
-type send_event()   :: {log_send, Time::'_', trace_id(),
                         Source::anypid(), Dest::anypid(), comm:message(),
                         local | global}.

-type passed_state() :: {trace_id(), logger()}.
-type gc_mpath_msg() :: {'$gen_component', trace_mpath, passed_state(),
                         Src::anypid(), Dest::anypid(), comm:message()}.

-ifdef(with_export_type_support).
-export_type([logger/0]).
-export_type([passed_state/0]).
-endif.

-type queue_key()        :: {Src :: comm:mypid(), Dest :: comm:mypid()}.
-type delay_queue_key()  :: {Dest :: comm:mypid()}.
-type msg_queues()       :: [queue_key()].
-type msg_delay_queues() :: [delay_queue_key()].

-type callback_on_deliver() ::
        fun((Src::comm:mypid(), Dest::comm:mypid(), Msg::comm:message()) -> ok).

-record(state,
        {msg_queues              = ?required(state, msg_queues)
                                       :: msg_queues(),
         msg_delay_queues        = ?required(state, msg_delay_queues)
                                       :: msg_delay_queues(),
         status                  = ?required(state, status)
                                       :: stopped | running | start_delivery,
         passed_state            = ?required(state, passed_state)
                                       :: none | passed_state(),
         num_possible_executions = ?required(state, passed_state)
                                       :: pos_integer(),
         callback_on_deliver     = ?required(state, callback_on_deliver)
                                       :: callback_on_deliver()
        }).

-type state_t() :: #state{}.
-type state()   :: [{trace_id(), state_t()}].

-spec start() -> ok.
start() -> start(default).

-spec start(trace_id() | passed_state()) -> ok.
start(TraceId) when is_atom(TraceId) ->
    LoggerPid = pid_groups:find_a(?MODULE),
    Logger = comm:make_global(LoggerPid),
    start(TraceId, {proto_sched, Logger});
start(PState) when is_tuple(PState) ->
    start(passed_state_trace_id(PState),
          passed_state_logger(PState)).

-spec start(trace_id(), logger()) -> ok.
start(TraceId, Logger) ->
    PState = passed_state_new(TraceId, Logger),
    own_passed_state_put(PState).

-spec start_deliver() -> ok.
start_deliver() ->
    start_deliver(default).

-spec start_deliver(trace_id()) -> ok.
start_deliver(TraceId) ->
    LoggerPid = pid_groups:find_a(?MODULE),
    Logger = comm:make_global(LoggerPid),
    %% send not as an infected message, but directly to the logger process
    send_log_msg(erlang:get(trace_mpath), Logger, {start_deliver, TraceId}),
    ok.

-spec stop() -> ok.
stop() ->
    %% stop sending epidemic messages
    erlang:erase(trace_mpath),
    ok.

-spec register_callback(CallbackFun::callback_on_deliver()) -> ok | failed.
register_callback(CallbackFun) ->
    register_callback(CallbackFun, default).

-spec register_callback(CallbackFun::callback_on_deliver(), trace_id()) -> ok | failed.
register_callback(CallbackFun, TraceId) ->
    %% clear infection
    clear_infection(),
    %% register the callback function
    LoggerPid = pid_groups:find_a(proto_sched),
    comm:send_local(LoggerPid, {register_callback, CallbackFun, TraceId, comm:this()}),
    %% restore infection
    restore_infection(),
    receive
        ?SCALARIS_RECV({register_callback_reply, Result}, Result)
    end.

-spec get_infos() -> [tuple()].
get_infos() -> get_infos(default).

-spec get_infos(trace_id()) -> [tuple()].
get_infos(TraceId) ->
    LoggerPid = pid_groups:find_a(proto_sched),
    comm:send_local(LoggerPid, {get_infos, comm:this(), TraceId}),
    receive
        ?SCALARIS_RECV({get_infos_reply, Infos}, Infos)
    end.

-spec infected() -> boolean().
infected() ->
    trace_mpath:infected().

-spec clear_infection() -> ok.
clear_infection() ->
    trace_mpath:clear_infection().

-spec restore_infection() -> ok.
restore_infection() ->
    trace_mpath:restore_infection().

-spec cleanup() -> ok.
cleanup() -> cleanup(default).

-spec cleanup(trace_id()) -> ok.
cleanup(TraceId) ->
    ProtoSchedPid = pid_groups:find_a(?MODULE),
    comm:send_local(ProtoSchedPid, {cleanup, TraceId}),
    ok.

%% Functions used to report tracing events from other modules
-spec epidemic_reply_msg(passed_state(), anypid(), anypid(), comm:message()) ->
                                gc_mpath_msg().
epidemic_reply_msg(PState, FromPid, ToPid, Msg) ->
    {'$gen_component', trace_mpath, PState, FromPid, ToPid, Msg}.

-spec log_send(passed_state(), anypid(), anypid(), comm:message(), local|global) -> ok.
log_send(PState, FromPid, ToPid, Msg, LocalOrGlobal) ->
    case passed_state_logger(PState) of
        {proto_sched, LoggerPid} ->
            TraceId = passed_state_trace_id(PState),
            send_log_msg(
              PState,
              LoggerPid,
              {log_send, '_', TraceId, FromPid, ToPid, Msg, LocalOrGlobal})
    end,
    ok.

-spec send_log_msg(passed_state(), comm:mypid(), send_event() | comm:message()) -> ok.
send_log_msg(RestoreThis, LoggerPid, Msg) ->
    %% don't log the sending of log messages ...
    stop(),
    comm:send(LoggerPid, Msg),
    own_passed_state_put(RestoreThis).


-spec start_link(pid_groups:groupname()) -> {ok, pid()}.
start_link(ServiceGroup) ->
    gen_component:start_link(?MODULE, fun ?MODULE:on/2, [],
                             [{erlang_register, ?MODULE},
                              {pid_groups_join_as, ServiceGroup, ?MODULE}]).

-spec init(any()) -> state().
init(_Arg) -> [].

-spec on(send_event() | comm:message(), state()) -> state().
on({log_send, _Time, TraceId, From, To, UMsg, LorG}, State) ->
    ?TRACE("got msg to schedule ~p -> ~p: ~.0p~n", [From, To, UMsg]),
    TmpEntry = case lists:keyfind(TraceId, 1, State) of
                   false ->
                       add_message(From, To, UMsg, LorG, new(TraceId));
                   {TraceId, OldTrace} ->
                       add_message(From, To, UMsg, LorG, OldTrace)
               end,
    case TmpEntry#state.status of
        start_delivery ->
            NewEntry = TmpEntry#state{status = running},
            NewState = lists:keystore(TraceId, 1, State, {TraceId, NewEntry}),
            gen_component:post_op({deliver, TraceId}, NewState);
        _ ->
            lists:keystore(TraceId, 1, State, {TraceId, TmpEntry})
    end;

on({start_deliver, TraceId}, State) ->
    %% initiate delivery: if messages are already queued, deliver
    %% first message, otherwise when first message arrives, start
    %% delivery with that message.
    case lists:keyfind(TraceId, 1, State) of
        false ->
            Entry = new(TraceId),
            NewEntry = {TraceId, Entry#state{status = start_delivery}},
            lists:keystore(TraceId, 1, State, NewEntry);
        {TraceId, OldTrace} ->
            NewEntry = {TraceId, OldTrace#state{status = running}},
            NewState = lists:keystore(TraceId, 1, State, NewEntry),
            gen_component:post_op({deliver, TraceId}, NewState)
    end;

on({deliver, TraceId}, State) ->
    case lists:keyfind(TraceId, 1, State) of
        false ->
            %%log:log("Nothing to deliver, unknown trace id!~n"),
            State;
        {TraceId, TraceEntry} ->
            case TraceEntry#state.msg_queues of
                [] ->
                    ?TRACE("Running out of messages, "
                           "waiting for further ones to arrive on id '~p'.~n"
                           "When protocol is finished, call proto_sched:stop(~p) and~n"
                           "proto_sched:cleanup(~p)",
                           [TraceId, TraceId, TraceId]),
                    ?TRACE("Seen ~p possible executions so far for id '~p'.~n",
                           [TraceEntry#state.num_possible_executions, TraceId]),
                    %% restart delivering when new messages arrive
                    NewEntry = TraceEntry#state{status = start_delivery},
                    lists:keystore(TraceId, 1, State, {TraceId, NewEntry});
                _ ->
                    {From, To, _LorG, Msg, NumPossible, TmpEntry} =
                        pop_random_message(TraceEntry),
                    ?TRACE("Chosen from ~p possible next messages~n", [NumPossible]),
                    NewEntry =
                        TmpEntry#state{num_possible_executions
                                       = NumPossible * TmpEntry#state.num_possible_executions},
                    %% we want to get raised messages, so we have to infect this message
                    PState = TraceEntry#state.passed_state,
                    InfectedMsg = epidemic_reply_msg(PState, From, To, Msg),
                    ?TRACE("delivering msg to execute: ~.0p~n", [InfectedMsg]),
                    %% call the callback function (if any) before sending out the msg
                    ?TRACE("executing callback function~n", []),
                    CallbackFun = TraceEntry#state.callback_on_deliver,
                    CallbackFun(From, To, Msg),
                    %% Send infected message with a shepherd. In case of send errors,
                    %% we will be informed by a {send_error, Pid, Msg, Reason} message.
                    comm:send(comm:make_global(To), InfectedMsg, [{shepherd, self()}]),
                    lists:keystore(TraceId, 1, State, {TraceId, NewEntry})
            end
    end;

on({on_handler_done, TraceId}, State) ->
    ?TRACE("on handler execution done~n", []),
    gen_component:post_op({deliver, TraceId}, State);

on({send_error, _Pid, Msg, _Reason} = _ShepherdMsg, State) ->
    %% call on_handler_done and continue with message delivery
    TraceId = get_trace_id(get_passed_state(Msg)),
    ?TRACE("send error for trace id ~p: ~p calling on_handler_done~n", [TraceId, _ShepherdMsg]),
    gen_component:post_op({on_handler_done, TraceId}, State);

on({register_callback, CallbackFun, TraceId, Client}, State) ->
    case lists:keyfind(TraceId, 1, State) of
        false ->
            comm:send(Client, {register_callback_reply, failed}),
            State;
        {TraceId, TraceEntry} ->
            comm:send(Client, {register_callback_reply, ok}),
            NewEntry = TraceEntry#state{callback_on_deliver = CallbackFun},
            lists:keyreplace(TraceId, 1, State, {TraceId, NewEntry})
    end;

on({get_infos, Client, TraceId}, State) ->
    case lists:keyfind(TraceId, 1, State) of
        false ->
            comm:send(Client, {get_infos_reply, []});
        {TraceId, TraceEntry} ->
            Infos =
                [{num_possible_executions,
                  TraceEntry#state.num_possible_executions}],
            comm:send(Client, {get_infos_reply, Infos})
    end,
    State;

on({cleanup, TraceId}, State) ->
    case lists:keytake(TraceId, 1, State) of
        {value, {TraceId, TraceEntry}, TupleList2} ->
            send_out_pending_messages(TraceEntry#state.msg_queues),
            send_out_pending_messages(TraceEntry#state.msg_delay_queues),
            TupleList2;
        false -> State
    end.

passed_state_new(TraceId, Logger) ->
    {TraceId, Logger}.

passed_state_trace_id(State)      -> element(1, State).
passed_state_logger(State)        -> element(2, State).

own_passed_state_put(State)       -> erlang:put(trace_mpath, State), ok.
%%own_passed_state_get()            -> erlang:get(trace_mpath).


new(TraceId) ->
    LoggerPid = pid_groups:find_a(?MODULE),
    Logger = comm:make_global(LoggerPid),
    #state{ msg_queues = [],
            msg_delay_queues = [],
            status = stopped,
            passed_state = passed_state_new(TraceId, {proto_sched, Logger}),
            num_possible_executions = 1,
            callback_on_deliver = fun(_From, _To, _Msg) -> ok end
          }.

%% @doc Sends out all messages remaining in queues
send_out_pending_messages(Queues) ->
    lists:foreach(fun(Key) ->
                          {_Src, Dest} = Key,
                          Queue = queue:to_list(erlang:erase(Key)),
                          To = comm:make_global(Dest),
                          _ = [comm:send(To, Msg) || {_LorG, Msg} <- Queue]
                  end,
                  Queues).

-spec add_message(comm:mypid(), comm:mypid(), comm:message(), local | global, state_t()) -> state_t().
add_message(Src, Dest, Msg, LorG, #state{msg_queues = OldQueues} = State) ->
    Key = {Src, Dest},
    NewQueues = add_to_list_of_queues(Key, {LorG, Msg}, OldQueues),
    State#state{msg_queues = NewQueues}.

%% -spec add_delay_message(comm:mypid(), comm:message(), state_t()) -> state_t().
%% add_delay_message(Dest, Msg, #state{msg_delay_queues = OldQueues} =
%% State) ->
%%     Key = {Dest},
%%     NewQueues = add_to_list_of_queues(Key, Msg, OldQueues),
%%     State#state{msg_delay_queues = NewQueues}.

-spec pop_random_message(state_t()) ->
                                {Src::comm:mypid(), Dest::comm:mypid(),
                                 local | global, Msg::comm:message(),
                                 Possibilities::pos_integer(),
                                 state_t()}.
pop_random_message(#state{msg_queues = OldQueues} = State) ->
    {{Src, Dest} = Key, Len} = util:randomelem_and_length(OldQueues),
    Q = erlang:get(Key),
    {{value, {LorG, M}}, Q2} = queue:out(Q),
    NewQueues = update_queue_in_list_of_queues(Key, Q2, OldQueues),
    State2 = State#state{msg_queues = NewQueues},
    {Src, Dest, LorG, M, Len, State2}.

%% -spec pop_random_delay_message(state_t()) -> {comm:mypid(), comm:message(), state_t()}.
%% pop_random_delay_message(#state{msg_delay_queues = OldQueues} = State) ->
%%     {{Dest} = Key, Q} = util:randomelem(OldQueues),
%%     {{value, M}, Q2} = queue:out(Q),
%%     NewQueues = update_queue_in_list_of_queues(Key, Q2, OldQueues),
%%     State2 = State#state{msg_delay_queues = NewQueues},
%%     {Dest, M, State2}.

-spec add_to_list_of_queues
        (queue_key(), {local | global, comm:message()}, msg_queues()) -> msg_queues().%;
        %(delay_queue_key(), comm:message(), msg_delay_queues()) -> msg_delay_queues().
add_to_list_of_queues(Key, M, Queues) ->
    case erlang:get(Key) of
        undefined ->
            _ = erlang:put(Key, queue:from_list([M])),
            [Key | Queues];
        Queue ->
            _ = erlang:put(Key, queue:in(M, Queue)),
            Queues
    end.

-spec update_queue_in_list_of_queues
        (queue_key(), queue(), msg_queues()) -> msg_queues().%;
        %(delay_queue_key(), queue(), msg_delay_queues()) -> msg_delay_queues().
update_queue_in_list_of_queues(Key, Q, Queues) ->
    case queue:is_empty(Q) of
        true ->
            erlang:erase(Key),
            lists:delete(Key, Queues);
        false ->
            _ = erlang:put(Key, Q),
            Queues
    end.

-spec get_passed_state(gc_mpath_msg()) -> passed_state().
get_passed_state(Msg) ->
    element(3, Msg).

-spec get_trace_id(passed_state()) -> trace_id().
get_trace_id(State) ->
    element(1, State).