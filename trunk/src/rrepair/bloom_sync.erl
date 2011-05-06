% @copyright 2011 Zuse Institute Berlin

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

%% @author Maik Lange <malange@informatik.hu-berlin.de>
%% @doc    bloom filter synchronization protocol
%% @end
%% @version $Id$

-module(bloom_sync).

-behaviour(gen_component).

-include("record_helpers.hrl").
-include("scalaris.hrl").

-export([init/1, on/2, start_bloom_sync/1]).

-define(TRACE(X,Y), io:format("[~p] " ++ X ++ "~n", [self()] ++ Y)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% type definitions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(bloom_sync_struct, 
        {
         interval = intervals:empty()                       :: intervals:interval(), 
         srcNode  = ?required(bloom_sync_struct, srcNode)   :: comm:mypid(),
         keyBF    = ?required(bloom_sync_struct, keyBF)     :: ?REP_BLOOM:bloomFilter(),
         versBF   = ?required(bloom_sync_struct, versBF)    :: ?REP_BLOOM:bloomFilter()                          
        }).

-type bloom_sync_struct() :: #bloom_sync_struct{}.

-type state() :: 
    {
        Owner       ::  comm:erl_local_pid(),
        SyncStruct  ::  bloom_sync_struct()
    }.

-type exit_reason() :: empty_interval.
-type message() ::  
    {get_state_response, intervals:interval()} |
    {get_chunk_response, rep_upd:db_chunk()} |
    {shutdown, exit_reason()}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message handling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec on(message(), state()) -> state().
on({get_state_response, NodeDBInterval}, {_, SyncStruct} = State) ->
    BloomInterval = SyncStruct#bloom_sync_struct.interval,
    SyncInterval = intervals:intersection(NodeDBInterval, BloomInterval),
    case intervals:is_empty(SyncInterval) of
         true ->
            comm:send_local(self(), {shutdown, empty_interval});
         false ->
            DhtNodePid = pid_groups:get_my(dht_node),
            comm:send_local(DhtNodePid, {get_chunk, self(), SyncInterval, 10000}) %TODO remove 10k constant
    end,
    State;
on({get_chunk_response, {_ChunkInterval, DBList}}, {_, SyncStruct}) ->
    {_, _SrcNode, KeyBF, VersBF} = SyncStruct,
    Diff = [ Key || {Key, _, _, _, Ver} <- DBList, Ver > -1, not ?REP_BLOOM:is_element(VersBF, Key) ],
    Missing = [ Key || Key <- Diff, not ?REP_BLOOM:is_element(KeyBF, Key) ],
    _ = lists:subtract(Diff, Missing), %=ObsolteKeys
    %TODO inform SrcNode about Diff Entries - IMPL DETAIL SYNC
    ok;
on({shutdown, _Reason}, _) ->
    %TODO post reason somewhere
    kill.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Startup
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Initialises the module
-spec init({comm:erl_local_pid(), bloom_sync_struct()}) -> state().
init({Owner, SyncStruct}) ->
    DhtNodePid = pid_groups:get_my(dht_node),
    comm:send_local(DhtNodePid, {get_state, comm:this(), my_range}),
    {Owner, SyncStruct}.

-spec start_bloom_sync(bloom_sync_struct()) -> {ok, pid()}.
start_bloom_sync(SyncStruct) ->
    gen_component:start(?MODULE, {self(), SyncStruct}, []).
