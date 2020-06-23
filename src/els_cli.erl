-module(els_cli).

-export([ test_config/2
        , send_telemetry/1
        , resulter/1 %% Just to make unused warning happy
        ]).

%%==============================================================================
%% Defines
%%==============================================================================
-define(HOSTNAME, {127, 0, 0, 1}).
-define(PORT    , 10000).

%%==============================================================================
%% API
%%==============================================================================

-spec test_config(any(), any()) -> ok.
test_config(Args, OtherArgs) ->
  %% io:format("Args,OtherArgs: ~p~n", [{Args, OtherArgs}]),
  erlang_ls:print_version(),
  {ok, Cwd} = file:get_cwd(),
  io:format("Directory: ~s~n", [Cwd]),
  CheckDir = proplists:get_value(check_dir, Args, Cwd),
  IndexingOn = proplists:get_value(check_indexing_on, Args, false),
  io:format("Check Directory: ~s~n", [CheckDir]),
  AbsDir = els_utils:make_normalized_path(CheckDir),
  do_test(IndexingOn, AbsDir, OtherArgs),
  ok.

%%==============================================================================
%% Internal
%%==============================================================================

%% @doc Use the given directory as the project root, and test all files in it.
-spec do_test(boolean(), file:filename(), [file:filename()]) -> ok.
do_test(IndexingOn, RootDir, Files) ->
  Transport = tcp,
  _Started   = start(Transport),
  %% io:format("Started: ~p~n", [Started]),
  RootPath  = els_utils:to_binary(RootDir),
  io:format("RootPath: ~p~n", [RootPath]),
  RootUri   = els_uri:uri(RootPath),
  %% Get following bool from CLI opts
  case IndexingOn of
    true ->
      els_client:initialize(RootUri, #{indexingEnabled => true}),
      els_client:initialized(),
      wait_for_indexing();
    false ->
      els_client:initialize(RootUri, #{indexingEnabled => false}),
      els_client:initialized(),
      wait_for_initialized_complete()
  end,
  io:format("Files: ~p~n", [Files]),
  %% io:format("FilesPaths: ~p~n", [FilePaths]),
  AllFiles = find_files_of_interest(RootDir),
  io:format("AllFiles: ~p~n", [AllFiles]),
  case {Files, AllFiles} of
    {[], []} ->
      io:format("Nothing to be done~n"),
      ok;
    {[], _} ->
      do_process(AllFiles);
    _ ->
      do_process(Files),
      done()
  end,
  ok.

-spec do_process([file:filename()]) -> ok.
do_process(Files) ->
  ResulterPid = proc_lib:spawn_link(?MODULE, resulter,
                                    [#{ files => maps:new()
                                      , bad => []
                                      , ignored => []
                                      , parent => self()
                                      , todo_count => length(Files) }]),
  process_file_list(ResulterPid, Files),
  done().

-spec process_file_list(pid(), [file:filename()]) -> ok.
process_file_list(ResulterPid, Files) ->
  process_file_list(ResulterPid, length(Files), Files).

-spec process_file_list(pid(), integer(), [file:filename()]) -> ok.
process_file_list(_ResulterPid, _, []) -> ok;
process_file_list(ResulterPid, TotalCount, [File|Files]) ->
  %% Invariant: TotalCount = CompletedCount + TodoCount + InFlight
  %% So,  Inflight = TotalCount - CompletedCount - TodoCount
  {_Progress, Completed} = els_diagnostics_provider:get_in_progress(),
  TodoCount = length([File|Files]),
  CompletedCount = length(Completed),
  Inflight = TotalCount - CompletedCount - TodoCount,
  case Inflight > 2 of
    true -> timer:sleep(100),
            process_file_list(ResulterPid, TotalCount, [File|Files]);
    false ->
      check_one_file(ResulterPid,
                     els_utils:to_binary(els_utils:make_normalized_path(File))),

      process_file_list(ResulterPid, TotalCount, Files)
  end,
  ok.


%% @doc Receive handshake from the resulter when it is done
-spec done() -> ok.
done() ->
  receive
    {done, {Files, Bads}} ->
      io:format("~nDone:~nprocessed ~p files~n", [maps:size(Files)]),
      BadFiles = lists:sort(sets:to_list(sets:from_list(
                                [F||{F, _} <- lists:flatten(Bads)]))),
      io:format("bad files:~n~p~n", [BadFiles]),
      ok;
    Oops ->
      io:format("Done: got: ~p~n", [Oops])
  end,
  ok.

%% Copied from els_test_utils. Perhaps harmonise?
-spec start(tcp) -> [atom()].
start(tcp) ->
  ok = application:set_env(erlang_ls, transport, els_tcp),
  {ok, Started} = application:ensure_all_started(erlang_ls),
  els_client:start_link(tcp, #{host => ?HOSTNAME, port => ?PORT}),
  Started.

%% ---------------------------------------------------------------------

-spec wait_for_indexing() -> ok.
wait_for_indexing() ->
  io:format("Waiting for initialization to complete ....~n"),
  wait_for_initialized_complete(),
  io:format("Waiting for indexing to complete ....~n"),
  wait_for_indexing_jobs(),
  ok.

-spec wait_for_initialized_complete() -> ok.
wait_for_initialized_complete() ->
  %% io:format("wait_for_initialized_complete: sleeping~n"),
  timer:sleep(100),
  Ns = els_client:get_notifications(),
  case [ N || #{ method := <<"telemetry/event">> } = N <- Ns ] of
    [] -> wait_for_initialized_complete();
    T ->
      io:format("wait_for_initialized_complete: got telemetry~n"),
      lists:foreach(fun show_telemetry/1, T),
      ok
  end,
  ok.

-spec show_telemetry(map()) -> ok.
show_telemetry(#{ params := #{ message := Message }}) ->
  io:format("~p~n", [Message]),
  ok.

-spec wait_for_indexing_jobs() -> ok.
wait_for_indexing_jobs() ->
  %% io:format("wait_for_indexing_jobs: sleeping ~n"),
  timer:sleep(100),
  case els_background_job:list() of
    [] ->
      io:format("wait_for_indexing_jobs: done ~n"),
      ok;
    _Pids ->
      %% io:format("wait_for_indexing_jobs: jobs= ~p~n", [length(Pids)]),
      wait_for_indexing_jobs()
  end,
  ok.

%% ---------------------------------------------------------------------

%% @doc Trigger the diagnostics process for a file.
-spec check_one_file(pid(), binary()) -> ok | {error, any()}.
check_one_file(ResulterPid, FilePath) ->
  io:format("Checking: ~p~n", [FilePath]),
  Uri = els_uri:uri(FilePath),
  {ok, Contents} = file:read_file(FilePath),
  els_client:did_open(Uri, <<"erlang">>, 0, Contents),
  ResulterPid ! {checking, Uri},
  ok.

%% ---------------------------------------------------------------------

%% @doc local process to keep track of which files have been checked so far, and
%% their results.
-spec resulter(map()) -> no_return().
resulter(#{ files := Files
          , bad := AllBads
          , ignored := Ignored
          , parent := ParentPid
          , todo_count := TodoCount
          } = State) ->
  %% io:format("els_cli:resulter: top of loop~n"),
  Good = fun(R) ->
             case R of
               {_, []} -> true;
               _ -> false
             end
         end,
  receive
    {checking, Uri} ->
      resulter(State#{ files => maps:put(Uri, [], Files)});
    {nowork} ->
      ParentPid ! {done, {Files, AllBads}},
      ok;
    Oops ->
      io:format("els_cli:resulter: receive got [~p]~n", [Oops]),
      resulter(State)
    after 500 ->
      {Progress, Completed} = els_diagnostics_provider:get_in_progress(),
      Msg = io_lib:format("els_cli:resulter: counts : [~p]~n",
                [{TodoCount, maps:size(Files), length(Completed)
                 , length(Progress), length(AllBads), length(Ignored)}]),
      io:format(Msg),
      lager:info(Msg),
      Ns = els_client:get_notifications(),
      case [ {Uri, D}
            || #{ method := <<"textDocument/publishDiagnostics">>
                , params := #{ uri := Uri
                             , diagnostics := D}} <- Ns ] of
        [] -> ok;
        T ->
          {_Goods, MaybeBads} = lists:partition(Good, T),
          case MaybeBads of
            [] -> ok;
            _ ->
              Exploded = [ {File, D} || {File, Ds} <- MaybeBads, D <- Ds ],
              {Ignoreds, Bads} = lists:partition( fun ignore_diagnostic/1
                                                , Exploded),
              resulter(State#{ bad => [Bads | AllBads]
                             , ignored => [Ignoreds | Ignored ]})
          end
      end,
      OneLess = TodoCount - 1,
      case {TodoCount, length(Completed)} of
        {X, X} ->
          %% Done, we have processed all the files file
          ParentPid ! {done, {Files, AllBads}},
          ok;
        {_, OneLess} -> %% AZ temporary
          io:format("els_cli:resulter: last in-progress [~p]~n", [Progress]),
          ParentPid ! {done, {Files, AllBads}},
          %% resulter(State);
          ok;
        _ ->
          resulter(State)
      end
  end,
  resulter(State),
  ok.

%% ---------------------------------------------------------------------

%% @doc Used to filter diagnostics into ones that are not considered a
%% misconfiguration, and ones that could be evidence of it.
%% -spec ignore_diagnostic({file:filename(), map()}) -> boolean.
-spec ignore_diagnostic({_, #{'message':=_, _=>_}}) -> boolean().
ignore_diagnostic({_, #{ message := Message }}) ->
  case Message of
    <<"export_all flag enabled - all functions will be exported">> -> true;
    _ -> false
  end.

%% ---------------------------------------------------------------------

-spec send_telemetry(any()) -> ok.
send_telemetry(Payload) ->
  Method = <<"telemetry/event">>,
  els_server:send_notification(Method, Payload).

%% ---------------------------------------------------------------------

-spec find_files_of_interest(file:filename()) -> [file:filename()].
find_files_of_interest(RootDir) ->
  io:format("Processing directory. [dir=~s]~n", [RootDir]),
  F = fun(FileName, Found) ->
          [FileName | Found]
      end,
  Filter = fun(Key, Path) ->
               case Key of
                 file ->
                   Ext = filename:extension(Path),
                   lists:member(Ext, [".erl", ".hrl", ".escript"]);
                 dir ->
                   %% Do not recurse into the "_build" directory, or one that
                   %% has an erlang_ls.config dir in it.
                   filter_dir(RootDir, Path)
               end
           end,

  AllFiles = fold_files(F, Filter, RootDir, []),
  %% Filter out anything in the '_build' directory.
  lists:filter(fun nobuild/1, AllFiles).

%% ---------------------------------------------------------------------

-spec filter_dir(file:filename(), file:filename()) -> boolean().
filter_dir( RootDir, RootDir) -> true;
filter_dir(_RootDir, Dir) ->
  %% io:format("filter_dir. [dir=~p]~n", [Dir]),
  case lists:reverse(filename:split(Dir)) of
    ["_build"|_] -> false;
    _ ->
      {ok, Files} = file:list_dir(Dir),
      %% io:format("filter_dir. [Files=~p]~n", [Files]),
      not(lists:member("erlang_ls.config", Files))
  end.

%% ---------------------------------------------------------------------

-spec nobuild(file:filename()) -> boolean().
nobuild(FileName) ->
  case lists:filter( fun(P) -> string:equal(P, "_build")
                                 or string:equal(P, "priv")
                     end
                    , filename:split(FileName)) of
    [] -> true;
    _ -> false
  end.

%% ---------------------------------------------------------------------

%% Copied from els_utils for now, need a filter per directory too.

%% @doc Folds over all files in a directory recursively
%%
%% Applies function F to each file and the accumulator,
%% skipping all symlinks.
-spec fold_files(function(), function(), els_utils:path(), any()) -> any().
fold_files(F, Filter, Dir, Acc) ->
  do_fold_dir(F, Filter, Dir, Acc).

-spec do_fold_files(function(), function(), els_utils:path()
                   , [els_utils:path()], any()) -> any().
do_fold_files(_F, _Filter,  _Dir, [], Acc0) ->
  Acc0;
do_fold_files(F, Filter, Dir, [File | Rest], Acc0) ->
  Path = filename:join(Dir, File),
  %% Symbolic links are not regular files
  Acc  = case filelib:is_regular(Path) of
           true  -> do_fold_file(F, Filter, Path, Acc0);
           false -> do_fold_dir(F, Filter, Path, Acc0)
         end,
  do_fold_files(F, Filter, Dir, Rest, Acc).

-spec do_fold_file(function(), function(), els_utils:path(), any()) ->
  any().
do_fold_file(F, Filter, Path, Acc) ->
  case Filter(file, Path) of
    true  -> F(Path, Acc);
    false -> Acc
  end.

-spec do_fold_dir(function(), function(), els_utils:path(), any()) ->
  any().
do_fold_dir(F, Filter, Dir, Acc) ->
  case not is_symlink(Dir) andalso filelib:is_dir(Dir)
                           andalso Filter(dir, Dir) of
    true ->
      {ok, Files} = file:list_dir(Dir),
      do_fold_files(F, Filter, Dir, Files, Acc);
    false ->
      Acc
  end.

-spec is_symlink(els_utils:path()) -> boolean().
is_symlink(Path) ->
  case file:read_link(Path) of
    {ok, _} -> true;
    {error, _} -> false
  end.
