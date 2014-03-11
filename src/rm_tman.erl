%  @copyright 2009-2014 Zuse Institute Berlin

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

%% @author Christian Hennig <hennig@zib.de>
%% @doc    T-Man ring maintenance
%% @end
%% @reference Mark Jelasity, Ozalp Babaoglu. T-Man: Gossip-Based Overlay
%% Topology Management. Engineering Self-Organising Systems 2005:1-15
%% @version $Id$
-module(rm_tman).
-author('hennig@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-behavior(rm_beh).

-type state_t() :: {Neighbors      :: nodelist:neighborhood(),
                    RandomViewSize :: pos_integer(),
                    Cache          :: [node:node_type()], % random cyclon nodes
                    Churn          :: boolean()}.
-opaque state() :: state_t().

% accepted messages of an initialized rm_tman process in addition to rm_loop
-type(custom_message() ::
    {rm_trigger} |
    {rm_trigger_action} |
    {{cy_cache, Cache::[node:node_type()]}, rm} |
    {rm, {get_node_details_response, NodeDetails::node_details:node_details()}} |
    {rm, buffer, OtherNeighbors::nodelist:neighborhood(), RequestPredsMinCount::non_neg_integer(), RequestSuccsMinCount::non_neg_integer()} |
    {rm, buffer_response, OtherNeighbors::nodelist:neighborhood()}).

-define(SEND_OPTIONS, [{channel, prio}, {?quiet}]).

% note include after the type definitions for erlang < R13B04!
-include("rm_beh.hrl").

-spec get_neighbors(state()) -> nodelist:neighborhood().
get_neighbors({Neighbors, _RandViewSize, _Cache, _Churn}) ->
    Neighbors.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Startup
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Initialises the state when rm_loop receives an init_rm message.
-spec init(Me::node:node_type(), Pred::node:node_type(),
           Succ::node:node_type()) -> state().
init(Me, Pred, Succ) ->
    msg_delay:send_trigger(0, {rm_trigger}),
    Neighborhood = nodelist:new_neighborhood(Pred, Me, Succ),
    cyclon:get_subset_rand_next_interval(1, comm:reply_as(self(), 2, {rm, '_'})),
    {Neighborhood, config:read(cyclon_cache_size), [], true}.

-spec unittest_create_state(Neighbors::nodelist:neighborhood()) -> state().
unittest_create_state(Neighbors) ->
    {Neighbors, 1, [], true}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message Loop (custom messages not already handled by rm_loop:on/2)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Message handler when the module is fully initialized.
-spec handle_custom_message(custom_message(), state())
        -> {ChangeReason::rm_loop:reason(), state()} | unknown_event.
handle_custom_message({rm_trigger}, State) ->
    msg_delay:send_trigger(get_base_interval(), {rm_trigger}),
    rm_trigger_action(State);

handle_custom_message({rm_trigger_action}, State) ->
    rm_trigger_action(State);

% got empty cyclon cache
handle_custom_message({rm, {cy_cache, []}},
   {_Neighborhood, RandViewSize, _Cache, _Churn} = State)  ->
    % ignore empty cache from cyclon
    cyclon:get_subset_rand_next_interval(RandViewSize,
                                         comm:reply_as(self(), 2, {rm, '_'})),
    {{unknown}, State};

% got cyclon cache
handle_custom_message({rm, {cy_cache, NewCache}},
   {Neighborhood, RandViewSize, _Cache, Churn}) ->
    % increase RandViewSize (no error detected):
    RandViewSizeNew =
        case (RandViewSize < config:read(cyclon_cache_size)) of
            true  -> RandViewSize + 1;
            false -> RandViewSize
        end,
    % trigger new cyclon cache request
    cyclon:get_subset_rand_next_interval(RandViewSizeNew,
                                         comm:reply_as(self(), 2, {rm, '_'})),
    MyRndView = get_RndView(RandViewSizeNew, NewCache),
    OtherNeighborhood =
        nodelist:mk_neighborhood(NewCache, nodelist:node(Neighborhood),
                                 get_pred_list_length(), get_succ_list_length()),
    NewNeighborhood = trigger_update(Neighborhood, MyRndView, OtherNeighborhood),
    {{node_discovery}, {NewNeighborhood, RandViewSizeNew, NewCache, Churn}};

% got shuffle request
handle_custom_message({rm, buffer, OtherNeighbors, RequestPredsMinCount, RequestSuccsMinCount},
   {Neighborhood, RandViewSize, Cache, Churn}) ->
    MyRndView = get_RndView(RandViewSize, Cache),
    MyView = lists:append(MyRndView, nodelist:to_list(Neighborhood)),
    OtherNode = nodelist:node(OtherNeighbors),
    OtherNodeId = node:id(OtherNode),
    OtherLastPredId = node:id(lists:last(nodelist:preds(OtherNeighbors))),
    OtherLastSuccId = node:id(lists:last(nodelist:succs(OtherNeighbors))),
    % note: the buffer message, esp. OtherNode, might already be outdated
    % and our own view may contain a newer version of the node
    {[OtherNodeUpd], MyViewUpd} = nodelist:lupdate_ids([OtherNode], MyView),
    NeighborsToSendTmp = nodelist:mk_neighborhood(MyViewUpd, OtherNodeUpd,
                                                  get_pred_list_length(),
                                                  get_succ_list_length()),
    NeighborsToSend =
        nodelist:filter_min_length(
          NeighborsToSendTmp,
          fun(N) ->
                  intervals:in(node:id(N), intervals:new('(', OtherNodeId, OtherLastSuccId, ')')) orelse
                      intervals:in(node:id(N), intervals:new('(', OtherLastPredId, OtherNodeId, ')'))
          end,
          RequestPredsMinCount, RequestSuccsMinCount),
    comm:send(node:pidX(nodelist:node(OtherNeighbors)),
              {rm, buffer_response, NeighborsToSend}, ?SEND_OPTIONS),
    NewNeighborhood = trigger_update(Neighborhood, MyRndView, OtherNeighbors),
    {{node_discovery}, {NewNeighborhood, RandViewSize, Cache, Churn}};

handle_custom_message({rm, buffer_response, OtherNeighbors},
   {Neighborhood, RandViewSize, Cache, Churn}) ->
    MyRndView = get_RndView(RandViewSize, Cache),
    NewNeighborhood = trigger_update(Neighborhood, MyRndView, OtherNeighbors),
    % increase RandViewSize (no error detected):
    NewRandViewSize =
        case RandViewSize < config:read(cyclon_cache_size) of
            true ->  RandViewSize + 1;
            false -> RandViewSize
        end,
    {{node_discovery}, {NewNeighborhood, NewRandViewSize, Cache, Churn}};

% we asked another node we wanted to add for its node object -> now add it
% (if it is not in the process of leaving the system)
handle_custom_message({rm, {get_node_details_response, NodeDetails}}, State) ->
    case node_details:get(NodeDetails, is_leaving) of
        false ->
            NewState =
                update_nodes(State, [node_details:get(NodeDetails, node)], [], null),
            {{node_discovery}, NewState};
        true ->
            {{unknown}, State}
    end;

handle_custom_message(_, _State) -> unknown_event.

-spec rm_trigger_action(State::state_t())
        -> {ChangeReason::rm_loop:reason(), state()}.
rm_trigger_action({Neighborhood, RandViewSize, Cache, Churn} = State) ->
    % Trigger an update of the Random view
    % Test for being alone:
    case nodelist:has_real_pred(Neighborhood) andalso
             nodelist:has_real_succ(Neighborhood) of
        false -> % our node is the only node in the system
            % no need to set a new trigger - we will be actively called by
            % any new node and set the trigger then (see handling of
            % notify_new_succ and notify_new_pred)
            {{unknown}, State};
        _ -> % there is another node in the system
            RndView = get_RndView(RandViewSize, Cache),
            %log:log(debug, " [RM | ~p ] RNDVIEW: ~p", [self(),RndView]),
            {Pred, Succ} = get_safe_pred_succ(Neighborhood, RndView),
            %io:format("~p~n",[{Preds,Succs,RndView,Me}]),
            RequestPredsMinCount =
                case nodelist:has_real_pred(Neighborhood) of
                    true -> get_pred_list_length() - length(nodelist:preds(Neighborhood));
                    _    -> get_pred_list_length()
                end,
            RequestSuccsMinCount =
                case nodelist:has_real_succ(Neighborhood) of
                    true -> get_succ_list_length() - length(nodelist:succs(Neighborhood));
                    _    -> get_succ_list_length()
                end,
            % send succ and pred our known nodes and request their nodes
            Message = {rm, buffer, Neighborhood, RequestPredsMinCount, RequestSuccsMinCount},
            comm:send(node:pidX(Succ), Message, ?SEND_OPTIONS),
            case Pred =/= Succ of
                true -> comm:send(node:pidX(Pred), Message, ?SEND_OPTIONS);
                _    -> ok
            end,
            {{unknown}, {Neighborhood, RandViewSize, Cache, Churn}}
    end.

-spec new_pred(State::state(), NewPred::node:node_type()) ->
          {ChangeReason::rm_loop:reason(), state()}.
new_pred(State, NewPred) ->
    % if we do not want to trust notify_new_pred messages to provide an alive node, use this instead:
%%     trigger_update(OldNeighborhood, [], nodelist:new_neighborhood(nodelist:node(OldNeighborhood), NewPred)),
    % we trust NewPred to be alive -> integrate node:
    {{unknown}, update_nodes(State, [NewPred], [], null)}.

-spec new_succ(State::state(), NewSucc::node:node_type())
        -> {ChangeReason::rm_loop:reason(), state()}.
new_succ(State, NewSucc) ->
    % similar to new_pred/2
    {{unknown}, update_nodes(State, [NewSucc], [], null)}.

%% @doc Removes the given predecessor as a result from a graceful leave only!
-spec remove_pred(State::state(), OldPred::node:node_type(),
                  PredsPred::node:node_type())
        -> {ChangeReason::rm_loop:reason(), state()}.
remove_pred(State, OldPred, PredsPred) ->
    {{graceful_leave, pred, OldPred}, remove_pred_(State, OldPred, PredsPred)}.

-compile({inline, [remove_pred_/3]}).

% private fun with non-opaque types to make dialyzer happy:
-spec remove_pred_(State::state_t(), OldPred::node:node_type(),
                   PredsPred::node:node_type()) -> state_t().
remove_pred_(State, OldPred, PredsPred) ->
    State2 = update_nodes(State, [PredsPred], [OldPred], null),
    % in order for incremental leaves to finish correctly, we must remove any
    % out-dated PredsPred in our state here!
    NewNeighborhood = element(1, State2),

    MyNewPred = nodelist:pred(NewNeighborhood),
    case node:same_process(MyNewPred, PredsPred) of
        true -> State2;
        false ->
            % assume the pred in my neighborhood is old
            % (the previous pred must know better about his pred)
            % -> just in case he was wrong, try to add it:
            contact_new_nodes([MyNewPred]),
            % try as long as MyNewPred is the same as PredsPred
            remove_pred_(State2, MyNewPred, PredsPred)
    end.

%% @doc Removes the given successor as a result from a graceful leave only!
-spec remove_succ(State::state(), OldSucc::node:node_type(),
                  SuccsSucc::node:node_type())
        -> {ChangeReason::rm_loop:reason(), state()}.
remove_succ(State, OldSucc, SuccsSucc) ->
    % in contrast to remove_pred/3, let rm repair a potentially wrong new succ
    % on its own
    {{graceful_leave, succ, OldSucc},
     update_nodes(State, [SuccsSucc], [OldSucc], null)}.

-spec update_node(State::state(), NewMe::node:node_type())
        -> {ChangeReason::rm_loop:reason(), state()}.
update_node({Neighborhood, RandViewSize, Cache, Churn}, NewMe) ->
    NewNeighborhood = nodelist:update_node(Neighborhood, NewMe),
    % inform neighbors
    rm_trigger_action({NewNeighborhood, RandViewSize, Cache, Churn}).

-spec contact_new_nodes(NewNodes::[node:node_type()]) -> ok.
contact_new_nodes(NewNodes) ->
    % TODO: add a local cache of contacted nodes in order not to contact them again
    ThisWithCookie = comm:reply_as(comm:this(), 2, {rm, '_'}),
    case comm:is_valid(ThisWithCookie) of
        true ->
            _ = [begin
                     Msg = {get_node_details, ThisWithCookie, [node, is_leaving]},
                     comm:send(node:pidX(Node), Msg, ?SEND_OPTIONS)
                 end || Node <- NewNodes],
            ok;
        false -> ok
    end.

-spec leave(State::state()) -> ok.
leave(_State) -> ok.

% failure detector reported dead node
-spec crashed_node(State::state(), DeadPid::comm:mypid())
        -> {ChangeReason::rm_loop:reason(), state()}.
crashed_node(State, DeadPid) ->
    {{node_crashed, DeadPid},
     update_nodes(State, [], [DeadPid], fun dn_cache:add_zombie_candidate/1)}.

% dead-node-cache reported dead node to be alive again
-spec zombie_node(State::state(), Node::node:node_type())
        -> {ChangeReason::rm_loop:reason(), state()}.
zombie_node(State, Node) ->
    % this node could potentially be useful as it has been in our state before
    {{node_discovery}, update_nodes(State, [Node], [], null)}.

-spec get_web_debug_info(State::state()) -> [{string(), string()}].
get_web_debug_info(_State) -> [].

%% @doc Checks whether config parameters of the rm_tman process exist and are
%%      valid.
-spec check_config() -> boolean().
check_config() ->
    config:cfg_is_integer(stabilization_interval_base) and
    config:cfg_is_greater_than(stabilization_interval_base, 0) and

    config:cfg_is_integer(cyclon_cache_size) and
    config:cfg_is_greater_than(cyclon_cache_size, 2) and

    config:cfg_is_integer(succ_list_length) and
    config:cfg_is_greater_than_equal(succ_list_length, 1) and

    config:cfg_is_integer(pred_list_length) and
    config:cfg_is_greater_than_equal(pred_list_length, 1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internal Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Get N peers from the cyclon cache.
-spec get_RndView(integer(), [node:node_type()]) -> [node:node_type()].
get_RndView(N, Cache) ->
    lists:sublist(Cache, N).

%% @doc Gets the node's current successor and predecessor in a safe way.
%%      If either is unknown, the random view is used to get a replacement. If
%%      this doesn't help either, the own node is returned as this is the
%%      current node's view.
-spec get_safe_pred_succ(
        Neighborhood::nodelist:neighborhood(), RndView::[node:node_type()]) ->
              {Pred::node:node_type(), Succ::node:node_type()}.
get_safe_pred_succ(Neighborhood, RndView) ->
    case nodelist:has_real_pred(Neighborhood) andalso
             nodelist:has_real_succ(Neighborhood) of
        true -> {nodelist:pred(Neighborhood), nodelist:succ(Neighborhood)};
        _    -> NewNeighbors = nodelist:add_nodes(Neighborhood, RndView, 1, 1),
                {nodelist:pred(NewNeighbors), nodelist:succ(NewNeighbors)}
    end.

% @doc is there churn in the system
-spec has_churn(OldNeighborhood::nodelist:neighborhood(),
                NewNeighborhood::nodelist:neighborhood()) -> boolean().
has_churn(OldNeighborhood, NewNeighborhood) ->
    OldNeighborhood =/= NewNeighborhood.

%% @doc Triggers the integration of new nodes from OtherNeighborhood and
%%      RndView into our Neighborhood by contacting every useful node.
%%      NOTE: no node is (directly) added by this function, the returned
%%            neighborhood may contain updated node IDs though!
-spec trigger_update(OldNeighborhood::nodelist:neighborhood(),
                     RndView::[node:node_type()],
                     OtherNeighborhood::nodelist:neighborhood())
        -> NewNeighborhood::nodelist:neighborhood().
trigger_update(OldNeighborhood, MyRndView, OtherNeighborhood) ->
    % update node ids with information from the other node's neighborhood
    OldNeighborhood2 =
        nodelist:update_ids(OldNeighborhood,
                            nodelist:to_list(OtherNeighborhood)),
    PredL = get_pred_list_length(),
    SuccL = get_succ_list_length(),
    NewNeighborhood1 =
        nodelist:add_nodes(OldNeighborhood2, MyRndView, PredL, SuccL),
    NewNeighborhood2 =
        nodelist:merge(NewNeighborhood1, OtherNeighborhood, PredL, SuccL),

    OldView = nodelist:to_list(OldNeighborhood2),
    NewView = nodelist:to_list(NewNeighborhood2),
    ViewOrd = fun(A, B) ->
                      nodelist:succ_ord_node(A, B, nodelist:node(OldNeighborhood2))
              end,
    {_, _, NewNodes} = util:ssplit_unique(OldView, NewView, ViewOrd),

    contact_new_nodes(NewNodes),
    OldNeighborhood2.

%% @doc Adds and removes the given nodes from the rm_tman state.
%%      Note: Sets the new RandViewSize to 0 if NodesToRemove is not empty and
%%      the new neighborhood is different to the old one. If either churn
%%      occurred or was already determined, min_interval if chosen for the next
%%      interval, otherwise max_interval. If the successor or predecessor
%%      changes, the trigger will be called immediately.
-spec update_nodes(State::state_t(),
                   NodesToAdd::[node:node_type()],
                   NodesToRemove::[node:node_type() | comm:mypid() | pid()],
                   RemoveNodeEvalFun::fun((node:node_type()) -> any()) | null)
        -> NewState::state_t().
update_nodes(State, [], [], _RemoveNodeEvalFun) ->
    State;
update_nodes({OldNeighborhood, RandViewSize, OldCache, _Churn},
             NodesToAdd, NodesToRemove, RemoveNodeEvalFun) ->
    % keep all nodes that are not in NodesToRemove
    % note: NodesToRemove should have 0 or 1 element in most cases
    case NodesToRemove of
        [] ->
            Nbh1 = OldNeighborhood,
            NewCache = OldCache;
        [Node] when is_function(RemoveNodeEvalFun) ->
            FilterFun = fun(N) -> not node:same_process(N, Node) end,
            Nbh1 = nodelist:filter(OldNeighborhood, FilterFun, RemoveNodeEvalFun),
            NewCache = nodelist:lfilter(OldCache, FilterFun);
        [Node] ->
            FilterFun = fun(N) -> not node:same_process(N, Node) end,
            Nbh1 = nodelist:filter(OldNeighborhood, FilterFun),
            NewCache = nodelist:lfilter(OldCache, FilterFun);
        [_,_|_] when is_function(RemoveNodeEvalFun) ->
            FilterFun = fun(N) -> not lists:any(
                                    fun(B) -> node:same_process(N, B) end,
                                    NodesToRemove)
                        end,
            Nbh1 = nodelist:filter(OldNeighborhood, FilterFun, RemoveNodeEvalFun),
            NewCache = nodelist:lfilter(OldCache, FilterFun);
        [_,_|_] ->
            FilterFun = fun(N) -> not lists:any(
                                    fun(B) -> node:same_process(N, B) end,
                                    NodesToRemove)
                        end,
            Nbh1 = nodelist:filter(OldNeighborhood, FilterFun),
            NewCache = nodelist:lfilter(OldCache, FilterFun)
    end,

    NewNeighborhood = nodelist:add_nodes(Nbh1, NodesToAdd,
                                         get_pred_list_length(),
                                         get_succ_list_length()),

    NewChurn = has_churn(OldNeighborhood, NewNeighborhood),
%%    NewInterval = case Churn orelse NewChurn of
%%                      true -> min_interval; % increase ring maintenance frequenc%%y
%%                      _    -> max_interval
%%                  end,
    NewRandViewSize = case NewChurn andalso NodesToRemove =/= [] of
                          true -> 0;
                          _    -> RandViewSize
                      end,
    NewState = {NewNeighborhood, NewRandViewSize, NewCache, NewChurn},
    case nodelist:pred(OldNeighborhood) =/= nodelist:pred(NewNeighborhood) orelse
        nodelist:succ(OldNeighborhood) =/= nodelist:succ(NewNeighborhood) of
        true -> element(2, rm_trigger_action(NewState));
        _    -> NewState
    end.

-spec get_base_interval() -> pos_integer().
get_base_interval() -> config:read(stabilization_interval_base) div 1000.

-spec get_pred_list_length() -> pos_integer().
get_pred_list_length() -> config:read(pred_list_length).

-spec get_succ_list_length() -> pos_integer().
get_succ_list_length() -> config:read(succ_list_length).