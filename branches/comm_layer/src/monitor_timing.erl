%  Copyright 2007-2008 Konrad-Zuse-Zentrum f�r Informationstechnik Berlin
%
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
%%%-------------------------------------------------------------------
%%% File    : monitor_timing.erl
%%% Author  : Thorsten Schuett <schuett@zib.de>
%%% Description : monitors timing behaviour of transactions
%%%
%%% Created :  24 September 2009 by Thorsten Schuett <schuett@zib.de>
%%%-------------------------------------------------------------------
%% @author Thorsten Schuett <schuett@zib.de>
%% @copyright 2009 Konrad-Zuse-Zentrum f�r Informationstechnik Berlin
%% @version $Id$
-module(monitor_timing).

-author('schuett@zib.de').
-vsn('$Id$ ').

-behaviour(gen_component).

-export([start_link/0, get_timers/0, log/2]).

-export([on/2, init/1]).

% state of the vivaldi loop
-type(state() :: {any()}).

% accepted messages of vivaldi processes
-type(message() :: any()).

%% @doc log a timespan for a given timer
log(Timer, Time) ->
    cs_send:send_local(?MODULE, {log, Timer, Time}).

%% @doc read the statistics about the known timers
get_timers() ->
    cs_send:send_local(?MODULE, {get_timers, self()}),
    receive
        {get_timers_response, Timers} ->
            Timers
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Message Loop
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% start
%% @doc message handler
-spec(on/2 :: (Message::message(), State::state()) -> state()).
on({log, Timer, Time}, State) ->
    case ets:lookup(?MODULE, Timer) of
        [{Timer, Sum, Count, Min, Max}] ->
            ets:insert(?MODULE, {Timer,
                                 Sum + Time,
                                 Count + 1,
                                 min(Min, Time),
                                 max(Max, Time)});
        [] ->
            ets:insert(?MODULE, {Timer, Time, 1, Time, Time})
    end,
    State;

on({get_timers, From}, State) ->
    Result = [{Timer, Count, Min, Sum / Count, Max} ||
                 {Timer, Sum, Count, Min, Max} <- ets:tab2list(?MODULE)],
    cs_send:send_local(From, {get_timers_response, Result}),
    ets:delete_all_objects(?MODULE),
    State;

on(_, _State) ->
    unknown_event.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Init
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(init/1 :: (any()) -> monitor_timing:state()).
init(_) ->
    ets:new(?MODULE, [set, protected, named_table]),
    {}.

-spec(start_link/0 :: () -> {ok, pid()}).
start_link() ->
    gen_component:start_link(?MODULE, [], [{register_native, ?MODULE}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

max(X, Y) when X > Y ->
    X;
max(_X, Y) ->
    Y.

min(X, Y) when X < Y ->
    X;
min(_X, Y) ->
    Y.