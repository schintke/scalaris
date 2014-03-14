% @copyright 2010-2014 Zuse Institute Berlin

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

%% @author Nico Kruber <kruber@zib.de>
%% @doc    Unit tests for src/dht_node_join.erl in combination with
%%         src/dht_node_move.erl.
%% @end
%% @version $Id$
-module(join_leave_proto_sched_SUITE).
-author('kruber@zib.de').
-vsn('$Id$').

-compile(export_all).

%% start proto scheduler for this suite
%% start proto scheduler for this suite
-define(proto_sched(Action),
        fun() -> %% use fun to have fresh, locally scoped variables
                case Action of
                    start ->
                        %% ct:pal("Starting proto scheduler"),
                        proto_sched:thread_num(1),
                        proto_sched:thread_begin();
                    stop ->
                        %% is a ring running?
                        case erlang:whereis(pid_groups) =:= undefined
                            orelse pid_groups:find_a(proto_sched) =:= failed of
                            true -> ok;
                            false ->
                                %% then finalize proto_sched run:
                                %% try to call thread_end(): if this
                                %% process was running the proto_sched
                                %% thats fine, otherwise thread_end()
                                %% will raise an exception
                                catch(proto_sched:thread_end()),
                                proto_sched:wait_for_end(),
                                ct:pal("Proto scheduler stats: ~.2p",
                                       [proto_sched:get_infos()]),
                                proto_sched:cleanup()
                        end
                end
        end()).

suite() -> [ {timetrap, {seconds, 60}} ].

-include("join_leave_SUITE.hrl").