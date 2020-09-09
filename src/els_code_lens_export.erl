%%==============================================================================
%% Code Lens: export : show export status of functions, allow toggling it.
%%==============================================================================

-module(els_code_lens_export).

-behaviour(els_code_lens).
-export([ command/1
        , command_args/2
        , is_default/0
        , pois/1
        , precondition/1
        , title/2
        ]).

-include("erlang_ls.hrl").

-spec command(poi()) -> els_command:command_id().
command(_POI) ->
  <<"export">>.

-spec command_args(els_dt_document:item(), poi()) -> [map()].
command_args(#{ uri := Uri }, #{ id := {Id, Arity} }) ->
  lager:info("command_args [~p]", [{Uri, Id, Arity}]),
  [#{ uri => Uri, id => Id, arity => Arity}];
command_args(Document, Id) ->
  lager:info("command_args not matched [~p]", [{Document, Id}]),
  [].

-spec is_default() -> boolean().
is_default() ->
  true.

-spec precondition(els_dt_document:item()) -> boolean().
precondition(Document) ->
  %% A behaviour is defined by the presence of one more functions
  Functions = els_dt_document:pois(Document, [function]),
  length(Functions) > 0.

-spec pois(els_dt_document:item()) -> [poi()].
pois(Document) ->
  els_dt_document:pois(Document, [function]).

-spec title(els_dt_document:item(), poi()) -> binary().
title(Document, POI) ->
  %% {ok, Refs} = els_dt_references:find_by_id(behaviour, Id),
  %% Count = length(Refs),
  %% Msg = io_lib:format("Behaviour used in ~p place(s)", [Count]),
  %% els_utils:to_binary(Msg).
  Exports = els_completion_provider:resolve_exports(Document, [POI]
                                                   , function, true, true),
  %% Msg = io_lib:format("export lens: [~p]", [{Id, Exports}]),
  Msg = case Exports of
    [] -> io_lib:format("local", []);
    _  -> io_lib:format("exported", [])
  end,
  els_utils:to_binary(Msg).

%% -spec foo() -> ok.
%% foo() ->
%%    ok.
