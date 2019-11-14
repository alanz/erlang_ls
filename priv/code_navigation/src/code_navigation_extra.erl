-module(code_navigation_extra).

-export([ do/1, do_2/0 ]).

do(_Config) ->
  ok.

do_2() ->
  code_navigation:function_h().

-spec do_3(X, wot(bar())) ->
              {atom(), code_navigation_types:type_a()} when X :: atom().
do_3(_, _) ->
  code_navigation:function_j().
