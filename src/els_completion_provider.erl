-module(els_completion_provider).

-behaviour(els_provider).

-include("erlang_ls.hrl").

-export([ handle_request/2
        , is_enabled/0
        ]).

%% Exported to ease testing.
-export([ keywords/0 ]).

%%==============================================================================
%% els_provider functions
%%==============================================================================

-spec is_enabled() -> boolean().
is_enabled() ->
  true.

-spec handle_request(any(), els_provider:state()) ->
  {any(), els_provider:state()}.
handle_request({completion, Params}, State) ->
  #{ <<"position">>     := #{ <<"line">>      := Line
                            , <<"character">> := Character
                            }
   , <<"textDocument">> := #{<<"uri">> := Uri}
   } = Params,
  {ok, Document} = els_utils:find_document(Uri),
  Text = els_document:text(Document),
  case maps:find(<<"context">>, Params) of
    {ok, Context} ->
      TriggerKind = maps:get(<<"triggerKind">>, Context),
      TriggerCharacter = maps:get(<<"triggerCharacter">>, Context, <<>>),
      %% We subtract 1 to strip the character that triggered the
      %% completion from the string.
      Length = case Character > 0 of true -> 1; false -> 0 end,
      Prefix = case TriggerKind of
                 ?COMPLETION_TRIGGER_KIND_CHARACTER ->
                   els_text:line(Text, Line, Character - Length);
                 ?COMPLETION_TRIGGER_KIND_INVOKED ->
                   els_text:line(Text, Line, Character)
               end,
      Opts   = #{ trigger  => TriggerCharacter
                , document => Document
                },
      {find_completion(Prefix, TriggerKind, Opts), State};
    error ->
      {null, State}
  end.

%%==============================================================================
%% Internal functions
%%==============================================================================

-spec find_completion(binary(), integer(), map()) -> any().
find_completion( Prefix
               , ?COMPLETION_TRIGGER_KIND_CHARACTER
               , #{trigger := <<":">>}
               ) ->
  case els_text:last_token(Prefix) of
    {atom, _, Module} -> exported_functions(Module, false);
    _ -> null
  end;
find_completion( _Prefix
               , ?COMPLETION_TRIGGER_KIND_CHARACTER
               , #{trigger := <<"?">>, document := Document}
               ) ->
  macros(Document);
find_completion( Prefix
               , ?COMPLETION_TRIGGER_KIND_INVOKED
               , #{document := Document}
               ) ->
  case lists:reverse(els_text:tokens(Prefix)) of
    %% Check for "[...] fun atom:atom"
    [{atom, _, _}, {':', _}, {atom, _, Module}, {'fun', _} | _] ->
      exported_functions(Module, true);
    %% Check for "[...] atom:atom"
    [{atom, _, _}, {':', _}, {atom, _, Module} | _] ->
      exported_functions(Module, false);
    %% Check for "[...] ?anything"
    [_, {'?', _} | _] ->
      macros(Document);
    %% Check for "[...] Variable"
    [{var, _, _} | _] ->
      variables(Document);
    %% Check for "[...] fun atom"
    [{atom, _, _}, {'fun', _} | _] ->
      functions(Document, false, true);
    %% Check for "[...] atom"
    [{atom, _, Name} | _] ->
      NameBinary = atom_to_binary(Name, utf8),
      keywords() ++ modules(NameBinary) ++ functions(Document, false, false);
    _ ->
      []
  end;
find_completion(_Prefix, _TriggerKind, _Opts) ->
  null.

%%==============================================================================
%% Modules
%%==============================================================================

-spec modules(binary()) -> [map()].
modules(Prefix) ->
  Modules = els_db:keys(modules),
  filter_by_prefix(Prefix, Modules, fun to_binary/1, fun item_kind_module/1).

-spec item_kind_module(binary()) -> map().
item_kind_module(Module) ->
  #{ label            => Module
   , kind             => ?COMPLETION_ITEM_KIND_MODULE
   , insertTextFormat => ?INSERT_TEXT_FORMAT_PLAIN_TEXT
   }.

%%==============================================================================
%% Functions
%%==============================================================================

-spec functions(els_document:document(), boolean(), boolean()) -> [map()].
functions(Document, _OnlyExported = false, Arity) ->
  POIs = els_document:points_of_interest(Document, [function]),
  List = [completion_item_function(POI, Arity) || POI <- POIs],
  lists:usort(List);
functions(Document, _OnlyExported = true, Arity) ->
  Exports   = els_document:points_of_interest(Document, [export_entry]),
  Functions = els_document:points_of_interest(Document, [function]),
  ExportsFA = [FA || #{id := FA} <- Exports],
  List      = [ completion_item_function(POI, Arity)
                || #{id := FA} = POI <- Functions, lists:member(FA, ExportsFA)
              ],
  lists:usort(List).

-spec completion_item_function(poi(), boolean()) -> map().
completion_item_function(#{id := {F, A}, data := ArgsNames}, false) ->
  #{ label            => list_to_binary(io_lib:format("~p/~p", [F, A]))
   , kind             => ?COMPLETION_ITEM_KIND_FUNCTION
   , insertText       => snippet_function_call(F, ArgsNames)
   , insertTextFormat => ?INSERT_TEXT_FORMAT_SNIPPET
   };
completion_item_function(#{id := {F, A}}, true) ->
  #{ label            => list_to_binary(io_lib:format("~p/~p", [F, A]))
   , kind             => ?COMPLETION_ITEM_KIND_FUNCTION
   , insertTextFormat => ?INSERT_TEXT_FORMAT_PLAIN_TEXT
   }.

-spec exported_functions(module(), boolean()) -> [map()] | null.
exported_functions(Module, Arity) ->
  case els_utils:find_module(Module) of
    {ok, Uri} ->
      {ok, Document} = els_utils:find_document(Uri),
      functions(Document, true, Arity);
    {error, _Error} ->
      null
  end.

-spec snippet_function_call(atom(), [{integer(), string()}]) -> binary().
snippet_function_call(Function, Args0) ->
  Args    = [ ["${", integer_to_list(N), ":", A, "}"]
              || {N, A} <- Args0
            ],
  Snippet = [atom_to_list(Function), "(", string:join(Args, ", "), ")"],
  iolist_to_binary(Snippet).

%%==============================================================================
%% Variables
%%==============================================================================

-spec variables(els_document:document()) -> [map()].
variables(Document) ->
  POIs = els_document:points_of_interest(Document, [variable]),
  Vars = [ #{ label => atom_to_binary(Name, utf8)
            , kind  => ?COMPLETION_ITEM_KIND_VARIABLE
            }
           || #{id := Name} <- POIs
         ],
  lists:usort(Vars).

%%==============================================================================
%% Macros
%%==============================================================================

-spec macros(els_document:document()) -> [map()].
macros(Document) ->
  Macros = lists:flatten([local_macros(Document), included_macros(Document)]),
  lists:usort(Macros).

-spec local_macros(els_document:document()) -> [map()].
local_macros(Document) ->
  POIs   = els_document:points_of_interest(Document, [define]),
   [ #{ label => atom_to_binary(Name, utf8)
      , kind  => ?COMPLETION_ITEM_KIND_CONSTANT
      }
     || #{id := Name} <- POIs
   ].

-spec included_macros(els_document:document()) -> [[map()]].
included_macros(Document) ->
  Kinds = [include, include_lib],
  POIs  = els_document:points_of_interest(Document, Kinds),
  [include_file_macros(Name) || #{id := Name} <- POIs].

-spec include_file_macros(string()) -> [map()].
include_file_macros(Name) ->
  Filename = filename:basename(Name),
  M = list_to_atom(Filename),
  case els_utils:find_module(M) of
    {ok, Uri} ->
      {ok, IncludeDocument} = els_utils:find_document(Uri),
      local_macros(IncludeDocument);
    {error, _} ->
      []
  end.

%%==============================================================================
%% Keywords
%%==============================================================================

-spec keywords() -> [map()].
keywords() ->
  Keywords = [ 'after', 'and', 'andalso', 'band', 'begin', 'bnot', 'bor', 'bsl'
             , 'bsr', 'bxor', 'case', 'catch', 'cond', 'div', 'end', 'fun'
             , 'if', 'let', 'not', 'of', 'or', 'orelse', 'receive', 'rem'
             , 'try', 'when', 'xor'],
  [ #{ label => atom_to_binary(K, utf8)
     , kind  => ?COMPLETION_ITEM_KIND_KEYWORD
     } || K <- Keywords ].

%%==============================================================================
%% Filter by prefix
%%==============================================================================

-spec filter_by_prefix(binary(), [binary()], function(), function()) -> [map()].
filter_by_prefix(Prefix, List, ToBinary, ItemFun) ->
  FilterMapFun = fun(X) ->
                     Str = ToBinary(X),
                     case string:prefix(Str, Prefix)  of
                       nomatch -> false;
                       _       -> {true, ItemFun(Str)}
                     end
                 end,
  lists:filtermap(FilterMapFun, List).

-spec to_binary(any()) -> binary().
to_binary(X) when is_atom(X) ->
  atom_to_binary(X, utf8);
to_binary(X) when is_binary(X) ->
  X.
