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
%% protocol execution and calculate the number of possible
%% interleavings for convenience (so one can guess how often the
%% protocol has to be run randomly to cover a good fraction of all
%% possible interleavings).

%% How it works: We use the same mechanism as trace_mpath and redirect
%% all messages to the scheduler. The scheduler maintains a mailbox
%% for each pair of (Src, Dest) to maintain FIFO ordering of channels,
%% but allowing all other possible message interleavings. It delivers
%% - steered by the given random seed - a single message for execution
%% and receives a confirmation when the corresponding message handler
%% is done. All messages generated by this message handler will arrive
%% at the scheduler before the on_handler_done message, as Erlang
%% provides FIFO on channels and all comm:sends are redirected
%% to the central scheduler.

%% How is the number of possible message interleavings calculated: At
%% each step, we know how many messages we can choose from. So the
%% number of different interleavings is the product of the
%% possibilities in each step.

%% How to detect the end of the protocol? When no more messages are
%% queued, the protocol is finished. You can easily wait for this with
%% the wait_for_end() function.

%% Why this cannot be done with the breakpoints that gen_components
%% provide? Breakpoints only have the execution of a message handler
%% under its control. If a message handler generates new messages in
%% the system, the VM directly enqueues them to the corresponding
%% mailboxes of the receivers. As there is no shuffeling in the
%% mailboxes of each receiver, there is only a limited amount of
%% message interleaving simulated using breakpoints. In contrast, with
%% proto_sched, messages generated by different message handlers can
%% overhaul each other, as long as they do not correspond to the same
%% communication channel, where FIFO ordering is maintained.

%% Fast tests for timeouts: For msg_delay, we could add a modification
%% so timeouts are just directly put in the pool of deliverable
%% messages. So this would simulate a long lasting execution in a
%% short timeframe (time compression). Actually msg_delay events
%% somehow must be sorted according to the time they 'can' be
%% delivered?  if req A is send and wants to be delivered after 10 sec
%% and B is then send and wants to be delivered after 5 seconds, each
%% could be delivered first?!

%% @version $Id:$
-module(proto_sched).
-author('schintke@zib.de').
-vsn('$Id:$').

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Quick start:
%% 1. call proto_sched:thread_num(N) %% seed has to be put somehow in
%% 2. in each process/thread partifipating call
%% 2.1. call proto_sched:thread_begin()
%% 2.2. perform a synchronous request like api_tx:read("a")
%% 2.3. call proto_sched:thread_end()
%% 3. call proto_sched:wait_for_end()
%% 4. call proto_sched:get_infos() to retrieve some statistics like
%%    the number of possible interleavings, the number of local or
%%    globally send messages, etc.
%% 5. call proto_sched:cleanup() to forget about the run and
%%    delete statistics data.
%%
%% immediately before every receive statement using SCALARIS_RECV
%% insert a trace_mpath:thread_yield() to pass the control flow back
%% to the proto_sched.
%%
%% You can also provide a trace_id, so that the proto_sched can be used
%% independently for several protocols at the same time (e.g. in
%% concurrent unittests). See the interfaces and exported functions
%% below.
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%-define(TRACE(X,Y), log:log("proto_sched: " ++ X,Y)).
-define(TRACE(X,Y), ok).

-include("scalaris.hrl").
-include("record_helpers.hrl").
-behaviour(gen_component).

%% client functions

%% declare how many threads you will have (with optional trace_id):
%% when thread_num threads called thread_begin(), proto_sched starts
%% the scheduled execution
-export([thread_num/1, thread_num/2]).

%% in each thread, give control to proto_sched (with optional trace_id)
-export([thread_begin/0, thread_begin/1]).
%% in each thread, declare its end (with optional trace_id)
-export([thread_end/0, thread_end/1]).

%% (1) before a receive, yield each thread to pass control to central
%%     scheduler
-export([thread_yield/0]).

-export([get_infos/0, get_infos/1, info_shorten_messages/2]).
-export([register_callback/1, register_callback/2]).
-export([infected/0]).
-export([clear_infection/0, restore_infection/0]).
-export([wait_for_end/0, wait_for_end/1]).
-export([cleanup/0, cleanup/1]).

%% report messages from other modules
-export([start/2]).
-export([log_send/5]).
-export([epidemic_reply_msg/4]).

%% gen_component behaviour
-export([start_link/1, init/1]).
-export([on/2]). %% internal message handler as gen_component

-type logger()       :: {proto_sched, comm:mypid()}.
-type anypid()       :: pid() | comm:mypid().
-type trace_id()     :: term().
-type send_event()   :: {log_send, Time::'_', trace_id(),
                         Source::anypid(), Dest::anypid(), comm:message(),
                         local | global}.

-type passed_state() :: {trace_id(), logger()}.
-type gc_mpath_msg() :: {'$gen_component', trace_mpath, passed_state(),
                         Src::anypid(), Dest::anypid(), comm:message()}.

-ifdef(with_export_type_support).
-export_type([logger/0]).
-export_type([passed_state/0]).
-export_type([callback_on_deliver/0]).
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
         :: new | stopped | running
          | {delivered, comm:mypid(), reference()},
         to_be_cleaned           = ?required(state, to_be_cleaned)
         :: false | {to_be_cleaned, pid()},
         passed_state            = ?required(state, passed_state)
         :: none | passed_state(),
         num_possible_executions = ?required(state, num_possible_executions)
         :: pos_integer(),
         num_delivered_msgs      = ?required(state, num_delivered_msgs)
         :: non_neg_integer(),
         delivered_msgs          = ?required(state, delivered_msgs)
         :: [send_event()], %% delivered messages in reverse order
         nums_chosen_from        = ?required(state, nums_chosen_from)
         :: [pos_integer()], %% #possibilities for each delivered msg in reverse order
         callback_on_deliver     = ?required(state, callback_on_deliver)
         :: callback_on_deliver(),
         thread_num              = ?required(state, thread_num)
         :: non_neg_integer(),
         threads_registered      = ?required(state, threads_registered)
         :: non_neg_integer(),
         inform_on_end           = ?required(state, inform_on_end)
         :: pid() | none
        }).

-type state_t() :: #state{}.
-type state()   :: [{trace_id(), state_t()}].

-spec thread_num(pos_integer()) -> ok.
thread_num(N) -> thread_num(N, default).

-spec thread_num(pos_integer(), trace_id()) -> ok.
thread_num(N, TraceId) ->
    send_steer_msg({thread_num, TraceId, N, comm:make_global(self())}),
    receive
        ?SCALARIS_RECV({thread_num_done}, ok);
        ?SCALARIS_RECV({thread_num_failed},
                       util:do_throw('proto_sched:thread_num_failed'))
        end.

-spec thread_begin() -> ok.
thread_begin() -> thread_begin(default).

-spec thread_begin(trace_id()) -> ok.
thread_begin(TraceId) ->
    ?ASSERT2(not infected(), duplicate_thread_begin),
    %% We could send this as normal traced client message to
    %% ourselves?!  But we better send in a special way to be able to
    %% detect these thread_begin messages in a separate handler
    %% clause as we want to detect when thread_num was set to small.
    send_steer_msg({thread_begin, TraceId, comm:make_global(self())}),
    %% proto_sched will then schedule itself a proper infected
    %% message, that we then receive, which atomatically infects this
    %% client thread
    receive
        ?SCALARIS_RECV({thread_begin_but_already_running},
                       util:do_throw('proto_sched:thread_begin-but_already_running'));
        ?SCALARIS_RECV(
           {thread_release_to_run},
           %% Yippie, we were chosen for execution, so we go on now up
           %% to the next trace_mpath:thread_yield() (in front of a
           %% receive) or proto_sched:thread_stop() that we pass.
           ok)
    end,
    ?DBG_ASSERT2(infected(), not_infected_after_thread_begin),
    ok.

-spec thread_yield() -> ok.
thread_yield() ->
    ?ASSERT2(infected(), yield_outside_thread_start_thread_end),
    trace_mpath:thread_yield().

-spec thread_end() -> ok.
thread_end() -> thread_end(default).

-spec thread_end(trace_id()) -> ok.
thread_end(TraceId) ->
    ?ASSERT2(infected(), duplicate_or_uninfected_thread_end),
    %% inform proto_sched that we are finished.
    send_steer_msg({on_handler_done, TraceId, thread_end}),
    %% switch off the infection
    clear_infection(),
    ?DBG_ASSERT2(not infected(), infected_after_thread_end),
    ok.

-spec wait_for_end() -> ok.
wait_for_end() -> wait_for_end(default).

-spec wait_for_end(trace_id()) -> ok.
wait_for_end(TraceId) ->
    ?ASSERT2(not infected(), wait_for_end_when_infected),
    send_steer_msg({wait_for_end, TraceId, self()}),
    receive
        ?SCALARIS_RECV({proto_sched_done}, ok);
        ?SCALARIS_RECV({wait_for_end_trace_not_found},
           util:do_throw('proto_sched:wait_for_end-trace not found'))
        end.

-spec start(trace_id(), logger()) -> ok.
start(TraceId, Logger) ->
    PState = passed_state_new(TraceId, Logger),
    own_passed_state_put(PState).

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

-spec info_shorten_messages(Infos, CharsPerMsg::pos_integer()) -> Infos
        when is_subtype(Infos, [tuple()]).
info_shorten_messages(Infos, CharsPerMsg) ->
    {value, {delivered_msgs, DeliveredMsgs}, RestInfos} =
        lists:keytake(delivered_msgs, 1, Infos),
    DeliveredMsgs1 =
        [begin
             MsgStr = lists:flatten(io_lib:format("~111610.0p", [Msg])),
             element(1, util:safe_split(CharsPerMsg, MsgStr))
         end || Msg <- DeliveredMsgs],
    [{delivered_msgs, DeliveredMsgs1} | RestInfos].

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
     %% clear infection
    ?ASSERT2(not infected(), 'proto_sched:cleanup_called_infected'),
    ProtoSchedPid = pid_groups:find_a(?MODULE),
    comm:send_local(ProtoSchedPid, {cleanup, TraceId, self()}),
    receive {cleanup_done} -> ok;
            {cleanup_trace_not_found} ->
            erlang:throw('proto_sched:cleanup_trace_not_found')
    end,
    ok.

%% Functions used to report tracing events from other modules
-spec epidemic_reply_msg(passed_state(), anypid(), anypid(), comm:message()) ->
                                gc_mpath_msg().
epidemic_reply_msg(PState, FromPid, ToPid, Msg) ->
    {'$gen_component', trace_mpath, PState, FromPid, ToPid, Msg}.

-spec log_send(passed_state(), anypid(), anypid(), comm:message(),
               local | global | local_after) -> ok.
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
    clear_infection(),
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
on({thread_begin, TraceId, Client}, State) ->
    ?TRACE("proto_sched:on({thread_begin, ~p, ~p})", [TraceId, Client]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    T1 = get_or_create(TraceId, State),
    case T1#state.status of
        new ->
            T2 = T1#state{
                   threads_registered = 1 + T1#state.threads_registered},
            %% trigger start_deliver when thread_num = threads_registered
            T3 = start_deliver_when_ready(TraceId, T2),
            NewState = lists:keystore(TraceId, 1, State, {TraceId, T3}),
            gen_component:post_op({log_send, os:timestamp(),
                                   TraceId, Client, Client,
                                   {thread_release_to_run}, global}, NewState);
        _ ->
            log:log("Wrong proto_sched:thread_begin, found state is: ~.0p",
                    [T1]),
            %% wrong call to proto_sched:thread_begin(),
            %% send fail message to raise exception at caller code
            %% position.
            comm:send(Client, {thread_begin_but_already_running}),
            State
    end;

on({thread_num, TraceId, N, Client}, State) ->
    ?TRACE("proto_sched:on({thread_num, ~p, ~p})", [TraceId, N]),
    ?DBG_ASSERT(not infected()),
    T1 = get_or_create(TraceId, State),
    case new =:= T1#state.status andalso 0 =:= T1#state.thread_num of
        true ->
            T2 = T1#state{thread_num = N},
            %% trigger start_deliver when thread_num = threads_registered
            T3 = start_deliver_when_ready(TraceId, T2),
            comm:send(Client, {thread_num_done}),
            lists:keystore(TraceId, 1, State, {TraceId, T3});
        _ ->
            log:log("Wrong proto_sched:thread_num, "
                    "(duplicate call or already running) "
                    "- found state is: ~.0p",
                    [T1]),
            %% wrong call to proto_sched:thread_begin(),
            %% send fail message to raise exception at
            %% caller code position.
            comm:send(Client, {thread_num_failed}),
            State
    end;

on({log_send, _Time, TraceId, From, To, UMsg, LorG}, State) ->
    ?TRACE("proto_sched:on({log_send ... ~.0p (~.0p) -> ~.0p (~.0p): ~.0p})",
           [From,
            pid_groups:group_and_name_of(From),
            To,
            pid_groups:group_and_name_of(To),
            UMsg]),
    FromGPid = comm:make_global(From),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    TmpEntry = case lists:keyfind(TraceId, 1, State) of
                   false ->
                       add_message(From, To, UMsg, LorG, new(TraceId));
                   {TraceId, OldTrace} ->
                       add_message(From, To, UMsg, LorG, OldTrace)
               end,
    case TmpEntry#state.status of
        new ->
            %% still waiting for all threads to join
            ?DBG_ASSERT2(UMsg =:= {thread_release_to_run}, wrong_starting_msg),
            lists:keystore(TraceId, 1, State, {TraceId, TmpEntry});
        {delivered, FromGPid, _Ref} ->
            %% only From is allowed to enqueue messages
            %% only when delivered or to_be_cleaned (during execution
            %% of a scheduled piece of code) new arbitrary messages
            %% can be added to the schedule
            lists:keystore(TraceId, 1, State, {TraceId, TmpEntry})
    end;

on({start_deliver, TraceId}, State) ->
    ?TRACE("proto_sched:on({start_deliver, ~p})", [TraceId]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    %% initiate delivery: if messages are already queued, deliver
    %% first message, otherwise when first message arrives, start
    %% delivery with that message.
    case lists:keyfind(TraceId, 1, State) of
        %% Entry is always there, as start_deliver is only called after
        %% enough thread_num and thread_begin calls
        {TraceId, OldTrace} ->
            case new =/= OldTrace#state.status of
                true ->
                    log:log("Duplicate proto_sched:start_deliver() call"
                            " probably not what you intend to do for"
                            " reproducible results~n"),
                    case util:is_unittest() of
                        true ->
                            erlang:throw(proto_sched_duplicate_start_deliver);
                        false ->
                            ok
                    end;
                _ -> ok
            end,
            NewEntry = OldTrace#state{status = running},
            NewState = lists:keystore(TraceId, 1, State, {TraceId, NewEntry}),
            ?TRACE("proto_sched:on({start_deliver, ~p}) postop deliver", [TraceId]),
            gen_component:post_op({deliver, TraceId}, NewState)
    end;

on({deliver, TraceId}, State) ->
    ?TRACE("proto_sched:on({deliver, ~p})", [TraceId]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    case lists:keyfind(TraceId, 1, State) of
        false ->
            ?TRACE("proto_sched:on({deliver, ~p}) Nothing to deliver, unknown trace id!", [TraceId]),
            State;
        {TraceId, TraceEntry} ->
            case TraceEntry#state.status of
                {delivered, _ToPid, _Ref} ->
                    ?TRACE("There is already message delivered to ~.0p",
                           [_ToPid]),
                    erlang:throw(proto_sched_already_in_delivered_mode);
                _ -> ok
            end,
            case TraceEntry#state.msg_queues of
                [] ->
                    ?TRACE("Running out of messages, "
                           "waiting for further ones to arrive on id '~p'.~n"
                           "When protocol is finished, call proto_sched:stop(~p) and~n"
                           "proto_sched:cleanup(~p)",
                           [TraceId, TraceId, TraceId]),
                    ?TRACE("Seen ~p possible executions so far for id '~p'.",
                           [TraceEntry#state.num_possible_executions, TraceId]),
                    case TraceEntry#state.inform_on_end of
                        none -> ok;
                        Client ->
                            comm:send_local(Client, {proto_sched_done})
                    end,
                    NewEntry = TraceEntry#state{status = stopped},
                    lists:keystore(TraceId, 1, State, {TraceId, NewEntry});
                _ ->
                    {From, To, LorG, Msg, NumPossible, TmpEntry} =
                        pop_random_message(TraceEntry),
                    ?TRACE("Chosen from ~p possible next messages.", [NumPossible]),
                    Monitor = case comm:is_local(comm:make_global(To)) of
                                  true -> erlang:monitor(process,
                                                         comm:make_local(To));
                                  false -> none
                              end,
                    NewEntry =
                        TmpEntry#state{num_possible_executions
                                       = NumPossible * TmpEntry#state.num_possible_executions,
                                      status = {delivered,
                                                comm:make_global(To),
                                                Monitor},
                                      num_delivered_msgs
                                       = 1 + TmpEntry#state.num_delivered_msgs,
                                      delivered_msgs
                                       = [ {From, To, LorG, Msg}
                                           | TmpEntry#state.delivered_msgs],
                                      nums_chosen_from
                                      = [ NumPossible
                                          | TmpEntry#state.nums_chosen_from] },
                    %% we want to get raised messages, so we have to infect this message
                    PState = TraceEntry#state.passed_state,
                    InfectedMsg = epidemic_reply_msg(PState, From, To, Msg),
                    ?TRACE("delivering msg to execute:"
                           " ~.0p (~.0p) -> ~.0p (~.0p): ~.0p.",
                           [From,
                            pid_groups:group_and_name_of(comm:make_local(From)),
                            To,
                            pid_groups:group_and_name_of(comm:make_local(To)),
                            Msg]),
                    %% call the callback function (if any) before sending out the msg
                    CallbackFun = TraceEntry#state.callback_on_deliver,
                    ?TRACE("executing callback function ~p.", [CallbackFun]),
                    CallbackFun(From, To, Msg),
                    %% Send infected message with a shepherd. In case of send errors,
                    %% we will be informed by a {send_error, Pid, Msg, Reason} message.
                    comm:send(comm:make_global(To), InfectedMsg, [{shepherd, self()}]),
                    lists:keystore(TraceId, 1, State, {TraceId, NewEntry})
            end
    end;

on({on_handler_done, TraceId, _Tag}, State) ->
     ?TRACE("proto_sched:on({on_handler_done, ~p}).", [TraceId]),
     %% do not use gen_component:post_op to allow a pending cleanup
     %% call to interrupt us early.
     case lists:keyfind(TraceId, 1, State) of
         false ->
             %% this is a bug
             log:log("This is a bug"),
             State;
         {TraceId, TraceEntry} ->
             case TraceEntry#state.status of
                 {delivered, _To, Ref} ->
                     %% this delivered was done, so we can schedule a new msg.
                     erlang:demonitor(Ref),

                     %% enqueue a new deliver request for this TraceId
                     ?TRACE("~p proto_sched:on({on_handler_done, ~p})"
                            " trigger next deliver 1.", [_To, TraceId]),
                     comm:send_local(self(), {deliver, TraceId}),
                     %% set status to running
                     NewEntry = TraceEntry#state{status = running},
                     NewState = lists:keystore(TraceId, 1, State,
                                               {TraceId, NewEntry}),
                     case NewEntry#state.to_be_cleaned of
                         {to_be_cleaned, CallerPid} ->
                             ?TRACE("proto_sched:on({on_handler_done, ~p})"
                                    " doing cleanup.", [TraceId]),
                             gen_component:post_op({do_cleanup,
                                                    TraceId,
                                                    CallerPid}, NewState);
                         false -> NewState
                     end;
                  new ->
                      %% proto_sched:end() immediately after proto_sched:start()?
                      %% enqueue a new deliver request for this TraceId
                      ?TRACE("proto_sched:on({on_handler_done, ~p})"
                             "trigger next deliver 2 ~p.", [TraceId, new]),
                      comm:send_local(self(), {deliver, TraceId}),
                      State
             end
     end;

on({send_error, Pid, Msg, _Reason} = _ShepherdMsg, State) ->
    %% call on_handler_done and continue with message delivery
    TraceId = get_trace_id(get_passed_state(Msg)),
    ?TRACE("send error for trace id ~p: ~p calling on_handler_done.", [TraceId, _ShepherdMsg]),
    case lists:keyfind(TraceId, 1, State) of
        false -> State;
        {TraceId, TraceEntry} ->
            case TraceEntry#state.status of
                {delivered, Pid, _Ref} ->
                    %% send error, generate on_handler_done
                    gen_component:post_op({on_handler_done, TraceId, send_error}, State);
                _  ->
                    %% not in state delivered, so probably the monitor
                    %% already cleaned up for the died process with
                    %% its 'DOWN' message.
                    State
            end
    end;

on({register_callback, CallbackFun, TraceId, Client}, State) ->
    ?TRACE("proto_sched:on({register_callback, ~p, ~p, ~p}).", [CallbackFun, TraceId, Client]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
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
    ?TRACE("proto_sched:on({get_infos, ~p, ~p}).", [Client, TraceId]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    case lists:keyfind(TraceId, 1, State) of
        false ->
            comm:send(Client, {get_infos_reply, []});
        {TraceId, TraceEntry} ->
            BranchingFactor =
                case length(TraceEntry#state.nums_chosen_from) of
                    0 -> 0;
                    N -> lists:sum(TraceEntry#state.nums_chosen_from) / N
                end,
            Infos =
                [{delivered_msgs,
                  lists:reverse(TraceEntry#state.delivered_msgs)},
                 {nums_chosen_from,
                  lists:reverse(TraceEntry#state.nums_chosen_from)},
                 {avg_branching_factor, BranchingFactor},
                 {num_delivered_msgs,
                  TraceEntry#state.num_delivered_msgs},
                 {num_possible_executions,
                  TraceEntry#state.num_possible_executions}],
            comm:send(Client, {get_infos_reply, Infos})
    end,
    State;

on({wait_for_end, TraceId, CallerPid}, State) ->
    ?TRACE("proto_sched:on({wait_for_end, ~p, ~p}).", [TraceId, CallerPid]),
    case lists:keyfind(TraceId, 1, State) of
        false ->
            comm:send_local(CallerPid, {wait_for_end_trace_not_found}),
            State;
        {TraceId, TraceEntry} ->
            case TraceEntry#state.status of
                stopped ->
                    comm:send_local(CallerPid, {proto_sched_done}),
                    State;
                _ ->
                    ?ASSERT2(none =:=  TraceEntry#state.inform_on_end,
                             'proto_sched:wait_for_end_already_called'),
                    NewEntry = TraceEntry#state{inform_on_end = CallerPid},
                    lists:keyreplace(TraceId, 1, State, {TraceId, NewEntry})
            end
    end;

on({cleanup, TraceId, CallerPid}, State) ->
    ?TRACE("proto_sched:on({cleanup, ~p, ~p}).", [TraceId, CallerPid]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    case lists:keyfind(TraceId, 1, State) of
        false ->
            comm:send_local(CallerPid, {cleanup_trace_not_found}),
            State;
        {TraceId, TraceEntry} ->
            case TraceEntry#state.status of
                {delivered, _To, _Ref} ->
                    ?TRACE("proto_sched:on({cleanup, ~p, ~p}) set status to to_be_cleaned.", [TraceId, CallerPid]),
                    NewEntry = TraceEntry#state{
                                 to_be_cleaned = {to_be_cleaned, CallerPid}},
                    lists:keyreplace(TraceId, 1, State, {TraceId, NewEntry});
                _ ->
                    gen_component:post_op({do_cleanup, TraceId, CallerPid}, State)
            end
    end;

on({do_cleanup, TraceId, CallerPid}, State) ->
    ?TRACE("proto_sched:on({do_cleanup, ~p, ~p}).", [TraceId, CallerPid]),
    ?DBG_ASSERT2(not infected(), infected_in_on_handler),
    case lists:keytake(TraceId, 1, State) of
        {value, {TraceId, TraceEntry}, TupleList2} ->
            send_out_pending_messages(TraceEntry#state.msg_queues),
            send_out_pending_messages(TraceEntry#state.msg_delay_queues),
            comm:send_local(CallerPid, {cleanup_done}),
            TupleList2;
        false ->
            comm:send_local(CallerPid, {cleanup_done}),
            State
    end;

on({'DOWN', Ref, process, Pid, Reason}, State) ->
    ?TRACE("proto_sched:on({'DOWN', ~p, process, ~p, ~p}).",
           [Ref, Pid, Reason]),
    log:log("proto_sched:on({'DOWN', ~p, process, ~p, ~p}).",
            [Ref, Pid, Reason]),
    %% search for trace with status delivered, Pid and Ref
    StateTail = lists:dropwhile(fun({_TraceId, X}) ->
                                        case X#state.status of
                                            {delivered, _Pid, Ref} -> false;
                                            _ -> true
                                        end end,
                                State),
    case StateTail of
        [] -> State; %% outdated 'DOWN' message - ok
        [TraceEntry | _] ->
            %% the process we delivered to has died, so we generate us a
            %% gc_on_done message ourselves.
            %% use post_op to avoid concurrency with send_error
            %% message when delivering to already dead nodes.
            gen_component:post_op({on_handler_done,
                                     element(1, TraceEntry),
                                     pid_ended_died_or_killed}, State)
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
            status = new,
            to_be_cleaned = false,
            passed_state = passed_state_new(TraceId, {proto_sched, Logger}),
            num_possible_executions = 1,
            num_delivered_msgs = 0,
            delivered_msgs = [],
            nums_chosen_from = [],
            callback_on_deliver = fun(_From, _To, _Msg) -> ok end,
            thread_num = 0,
            threads_registered = 0,
            inform_on_end = none
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

send_steer_msg(Msg) ->
    LoggerPid = pid_groups:find_a(?MODULE),
    Logger = comm:make_global(LoggerPid),
    %% send not as an infected message, but directly to the logger process
    send_log_msg(erlang:get(trace_mpath), Logger, Msg).

-spec get_or_create(trace_id(), state()) -> state_t().
get_or_create(TraceId, State) ->
    case lists:keyfind(TraceId, 1, State) of
        false ->            new(TraceId);
        {TraceId, Entry} -> Entry
    end.

-spec start_deliver_when_ready(trace_id(), state_t()) -> state_t().
start_deliver_when_ready(TraceId, Entry) ->
    case Entry#state.thread_num =:= Entry#state.threads_registered of
        true ->
            comm:send_local(self(), {start_deliver, TraceId}),
            Entry;
        false ->
            Entry
    end.
