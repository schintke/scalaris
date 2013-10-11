%  @copyright 2010-2012 Zuse Institute Berlin

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
%% @doc    Type definitions of non-existing, opaque or custom types which can
%%         be used independently from the erlang version.
%% @end
%% @version $Id$

-ifdef(term_not_builtin).
-type term() :: any().
-endif.

-ifdef(node_not_builtin).
-type node() :: erlang:node().
-endif.

-ifdef(module_not_builtin).
-type module() :: erlang:module().
-endif.

-ifdef(boolean_not_builtin).
-type boolean() :: bool().
-endif.

-ifdef(tid_not_builtin).
-type tid() :: ets:tid().
-endif.

-ifdef(types_not_builtin).
-type reference() :: erlang:reference().
-type gb_set() :: gb_sets:gb_set().
-type queue() :: queue:queue().
-type gb_tree() :: gb_trees:gb_tree().
-type dict() :: dict:dictionary().
-endif.

-ifdef(have_erlang_timestamp).
-type erlang_timestamp() :: erlang:timestamp().
-else.
-type erlang_timestamp() :: {MegaSecs::non_neg_integer(),
                             Secs::non_neg_integer(),
                             MicroSecs::non_neg_integer()}.
-endif.
