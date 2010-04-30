%  Copyright 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin
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
%%% File    : tester.erl
%%% Author  : Thorsten Schuett <schuett@zib.de>
%%% Description : value collector for test generator
%%%
%%% Created :  30 April 2010 by Thorsten Schuett <schuett@zib.de>
%%%-------------------------------------------------------------------
%% @author Thorsten Schuett <schuett@zib.de>
%% @copyright 2010 Konrad-Zuse-Zentrum fuer Informationstechnik Berlin
%% @version $Id$
-module(tester_parse_state).

-author('schuett@zib.de').
-vsn('$Id$ ').

-export([new_parse_state/0,

         get_type_infos/1, get_unknown_types/1, get_atoms/1, get_integers/1,

         % add types
         add_type_spec/3, add_unknown_type/3,

         % add values
         add_atom/2, add_integer/2, add_string/2,

         reset_unknown_types/1,

         is_known_type/3, lookup_type/2]).

-include_lib("tester.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% parse state
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec new_parse_state/0 :: () -> #parse_state{}.
new_parse_state() ->
    #parse_state{type_infos = gb_trees:empty(),
                 unknown_types = gb_sets:add_element({type, tester, test_any} ,
                                                     gb_sets:new()),
                atoms = gb_sets:new(),
                integers = gb_sets:new(),
                strings = gb_sets:new()}.

-spec get_type_infos/1 :: (#parse_state{}) -> type_infos().
get_type_infos(#parse_state{type_infos=TypeInfo}) ->
    TypeInfo.

-spec get_unknown_types/1 :: (#parse_state{}) -> list(type_name()).
get_unknown_types(#parse_state{unknown_types=UnknownTypes}) ->
    gb_sets:to_list(UnknownTypes).

-spec get_atoms/1 :: (#parse_state{}) -> list(atom()).
get_atoms(#parse_state{atoms=Atoms}) ->
    gb_sets:to_list(Atoms).

-spec get_integers/1 :: (#parse_state{}) -> list(integer()).
get_integers(#parse_state{integers=Integers}) ->
    gb_sets:to_list(Integers).

-spec add_type_spec/3 :: (type_name(), type_spec(), #parse_state{}) -> #parse_state{}.
add_type_spec(TypeName, TypeSpec, #parse_state{type_infos=TypeInfos} = ParseState) ->
    NewTypeInfos = gb_trees:enter(TypeName, TypeSpec, TypeInfos),
    ParseState#parse_state{type_infos=NewTypeInfos}.

-spec add_unknown_type/3 :: (module(), atom(), #parse_state{}) -> #parse_state{}.
add_unknown_type(TypeModule, TypeName, #parse_state{unknown_types=UnknownTypes} = ParseState) ->
    ParseState#parse_state{unknown_types=
                           gb_sets:add_element({type, TypeModule, TypeName},
                                               UnknownTypes)}.

-spec reset_unknown_types/1 :: (#parse_state{}) -> #parse_state{}.
reset_unknown_types(ParseState) ->
    ParseState#parse_state{unknown_types=gb_sets:new()}.

-spec is_known_type/3 :: (module(), atom(), #parse_state{}) -> boolean().
is_known_type(TypeModule, TypeName, #parse_state{type_infos=TypeInfos}) ->
    gb_trees:is_defined({type, TypeModule, TypeName}, TypeInfos).

add_atom(Atom, #parse_state{atoms=Atoms} = ParseState) ->
    ParseState#parse_state{atoms=gb_sets:add_element(Atom, Atoms)}.

add_integer(Integer, #parse_state{integers=Integers} = ParseState) ->
    ParseState#parse_state{integers=gb_sets:add_element(Integer, Integers)}.

add_string(String, #parse_state{strings=Strings} = ParseState) ->
    ParseState#parse_state{strings=gb_sets:add_element(String, Strings)}.

lookup_type(Type, #parse_state{type_infos=TypeInfos}) ->
    gb_trees:lookup(Type, TypeInfos).
