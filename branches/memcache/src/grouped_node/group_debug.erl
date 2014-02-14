%  @copyright 2007-2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @version $Id$
-module(group_debug).
-author('schuett@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").

-export([dbg/0, dbg_version/0, dbg3/0, dbg_mode/0, dbg_db/0,
         dbg_db_without_pid/0, check_ring/0, check_ring_uniq/0]).

-spec dbg() -> any().
dbg() ->
    gb_trees:to_list(lists:foldl(fun (Node, Stats) ->
                        State = gen_component:get_state(Node, 100),
                        View = group_state:get_view(State),
                        case group_state:get_mode(State) of
                            joined ->
                                inc(Stats, group_view:get_group_id(View));
                            _ ->
                                Stats
                        end
                end, gb_trees:empty(), pid_groups:find_all(group_node))).

inc(Stats, Label) ->
    case gb_trees:lookup(Label, Stats) of
        {value, Counter} ->
            gb_trees:update(Label, Counter + 1, Stats);
        none ->
            gb_trees:insert(Label, 1, Stats)
    end.

-spec dbg_version() -> any().
dbg_version() ->
    lists:map(fun (Node) ->
                      State = gen_component:get_state(Node, 1000),
                      %io:format("~p~n", [State]),
                      View = group_state:get_view(State),
                      case group_state:get_mode(State) of
                          joined ->
                              {Node, group_view:get_current_paxos_id(View)};
                          _ ->
                              {Node, '_'}
                      end
              end, pid_groups:find_all(group_node)).

-spec dbg3() -> any().
dbg3() ->
    lists:map(fun (Node) ->
                      State = gen_component:get_state(Node, 1000),
                      View = group_state:get_view(State),
                      case group_state:get_mode(State) of
                          joined ->
                              {Node, length(group_view:get_postponed_decisions(View))};
                          _ ->
                              {Node, '_'}
                      end
              end, pid_groups:find_all(group_node)).

-spec dbg_mode() -> any().
dbg_mode() ->
    lists:map(fun (Node) ->
                      State = gen_component:get_state(Node, 1000),
                      {Node, group_state:get_mode(State)}
              end, pid_groups:find_all(group_node)).

-spec dbg_db() -> any().
dbg_db() ->
    lists:map(fun (Node) ->
                      State = gen_component:get_state(Node, 1000),
                      DB = group_state:get_db(State),
                      Size = group_db:get_size(DB),
                      {Node, element(1, DB), Size}
              end, pid_groups:find_all(group_node)).

-spec dbg_db_without_pid() -> any().
dbg_db_without_pid() ->
    lists:map(fun (Node) ->
                      State = gen_component:get_state(Node, 1000),
                      DB = group_state:get_db(State),
                      Size = group_db:get_size(DB),
                      {element(1, DB), Size}
              end, pid_groups:find_all(group_node)).

-spec check_ring() ->
    ok | {failed, string()}.
check_ring() ->
    Data = lists:map(fun (Node) ->
                             comm:send_local(Node, {get_pred_succ, comm:this()}),
                             receive
                                 {get_pred_succ_response, Pred, Succ, Interval} ->
                                     {Interval, Pred, Succ}
                             end
                     end, pid_groups:find_all(group_node)),
    F = fun ({Interval, Pred, Succ}, Acc) ->
                case Acc of
                    {failed, _Msg} ->
                        Acc;
                    Tree ->
                        case gb_trees:lookup(Interval, Tree) of
                            none ->
                                {_, PredInterval, _, _} = Pred,
                                {_, SuccInterval, _, _} = Succ,
                                case intervals:is_all(Interval) of
                                    true ->
                                        SuccessValue = gb_trees:enter(Interval, {Pred, Succ}, Tree),
                                        check_pred_succ(intervals:is_all(PredInterval),
                                                        intervals:is_all(SuccInterval),
                                                        SuccessValue,
                                                        PredInterval, Interval, SuccInterval);
                                    false ->
                                        SuccessValue = gb_trees:enter(Interval, {Pred, Succ}, Tree),
                                        check_pred_succ(intervals:is_left_of(PredInterval, Interval),
                                                        intervals:is_left_of(Interval, SuccInterval),
                                                        SuccessValue,
                                                        PredInterval, Interval, SuccInterval)
                                    end;
                            {value, {Pred, Succ}} ->
                                Tree;
                            {value, {Pred, Succ2}} ->
                                Msg = io_lib:format("succs don't match for ~p: ~p <-> ~p",
                                                    [Interval, Succ, Succ2]),
                                {failed, lists:flatten(Msg)};
                            {value, {Pred2, Succ}} ->
                                Msg = io_lib:format("preds don't match for ~p: ~p <-> ~p",
                                                    [Interval, Pred, Pred2]),
                                {failed, lists:flatten(Msg)};
                            {value, {Pred2, Succ2}} ->
                                Msg = io_lib:format("preds and succs don't match for ~p: ~p <-> ~p",
                                                    [Interval, {Pred, Succ}, {Pred2, Succ2}]),
                                {failed, lists:flatten(Msg)}
                        end
                end
        end,
    Result = lists:foldl(F, gb_trees:empty(), Data),
    case Result of
        {failed, _} ->
            Result;
        _ ->
            ok
    end.

-spec check_ring_uniq() ->
    list().
check_ring_uniq() ->
    Data = lists:map(fun (Node) ->
                             comm:send_local(Node, {get_pred_succ, comm:this()}),
                             receive
                                 {get_pred_succ_response, Pred, Succ, Interval} ->
                                     {Interval, Pred, Succ}
                             end
                     end, pid_groups:find_all(group_node)),
    Set = gb_sets:from_list(Data),
    gb_sets:to_list(Set).

% @private
% @doc create error messages if Succ and/or Pred interval is wrong
check_pred_succ(PredP, SuccP, SuccessValue, PredInterval, Interval, SuccInterval) ->
    case {PredP, SuccP} of
        {true, true} ->
            SuccessValue;
        {true, false} ->
            Msg = io_lib:format("wrong succ interval: ~w -> ~w",
                                [Interval, SuccInterval]),
            {failed, lists:flatten(Msg)};
        {false, true} ->
            Msg = io_lib:format("wrong pred interval: ~w -> ~w",
                                [PredInterval, Interval]),
            {failed, lists:flatten(Msg)};
        {false, false} ->
            Msg = io_lib:format("wrong pred and succ interval: ~w -> ~w -> ~w",
                                [PredInterval, Interval, SuccInterval]),
            {failed, lists:flatten(Msg)}
    end.