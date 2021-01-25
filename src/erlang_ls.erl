-module(erlang_ls).

-export([ main/1 ]).

-export([ parse_args/1
        , log_root/0
        , print_version/0]).
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include_lib("kernel/include/logger.hrl").

-define(APP, erlang_ls).
-define(DEFAULT_LOGGING_LEVEL, "info").

-spec main([any()]) -> ok.
main(Args) ->
  application:load(getopt),
  application:load(?APP),
  ok = parse_args(Args),
  configure_logging(),
  application:ensure_all_started(?APP),
  patch_logging(),
  ?LOG_INFO("Started erlang_ls server", []),
  receive _ -> ok end.

-spec print_version() -> ok.
print_version() ->
  {ok, Vsn} = application:get_key(?APP, vsn),
  io:format("Version: ~s~n", [Vsn]),
  ok.

%%==============================================================================
%% Argument parsing
%%==============================================================================

-spec parse_args([string()]) -> ok.
parse_args(Args) ->
  case getopt:parse(opt_spec_list(), Args) of
    {ok, {[version | _], _BadArgs}} ->
      print_version(),
      halt(1);
    {ok, {[check | Rest], OtherArgs}} ->
      set_args(Rest),
      ok = lager_config(),
      els_cli:test_config(Rest, OtherArgs),
      halt(1);
    {ok, {ParsedArgs, _BadArgs}} ->
      set_args(ParsedArgs);
    {error, {invalid_option, _}} ->
      getopt:usage(opt_spec_list(), "Erlang LS"),
      halt(1)
  end.

-spec opt_spec_list() -> [getopt:option_spec()].
opt_spec_list() ->
  [ { version
    , $v
    , "version"
    , undefined
    , "Print the current version of Erlang LS"
    }
  , { transport
    , $t
    , "transport"
    , {string, "stdio"}
    , "Specifies the transport the server will use for "
      "the connection with the client, either \"tcp\" or \"stdio\"."
    }
  , { port
    , $p
    , "port"
    , {integer, 10000}
    , "Used when the transport is tcp."
    }
 ,  { log_dir
    , $d
    , "log-dir"
    , {string, filename:basedir(user_log, "erlang_ls")}
    , "Directory where logs will be written."
    }
 ,  { log_level
    , $l
    , "log-level"
    , {string, ?DEFAULT_LOGGING_LEVEL}
    , "The log level that should be used."
    }
 ,  { check
    , $c
    , "check"
    , undefined
    , "Check the server against the current directory,"
      " trying to load all the files in it."
    }
 ,  { check_dir
    , $k
    , "check-dir"
    , {string, "."}
    , "Directory to be checked."
    }
 ,  { check_indexing_on
    , $i
    , "check-index"
    , undefined
    , "Run indexing before checking"
    }
  ].

-spec set_args([] | [getopt:compound_option()]) -> ok.
set_args([]) -> ok;
set_args([version | Rest]) -> set_args(Rest);
set_args([check_indexing_on | Rest]) -> set_args(Rest);
set_args([{check_dir, _} | Rest]) -> set_args(Rest);
set_args([{check_indexing_on, _} | Rest]) -> set_args(Rest);
set_args([{Arg, Val} | Rest]) ->
  set(Arg, Val),
  set_args(Rest).

-spec set(atom(), getopt:arg_value()) -> ok.
set(transport, Name) ->
  Transport = case Name of
                "tcp"   -> els_tcp;
                "stdio" -> els_stdio
              end,
  application:set_env(?APP, transport, Transport);
set(port, Port) ->
  application:set_env(?APP, port, Port);
set(log_dir, Dir) ->
  application:set_env(?APP, log_dir, Dir);
set(log_level, Level) ->
  application:set_env(?APP, log_level, list_to_atom(Level));
set(port_old, Port) ->
  application:set_env(?APP, port, Port).

%%==============================================================================
%% Logger configuration
%%==============================================================================

-spec configure_logging() -> ok.
configure_logging() ->
  LogFile = filename:join([log_root(), "server.log"]),
  {ok, LoggingLevel} = application:get_env(?APP, log_level),
  ok = filelib:ensure_dir(LogFile),
  Handler = #{ config => #{ file => LogFile }
             , level => LoggingLevel
             , formatter => { logger_formatter
                            , #{ template => [ "[", time, "] "
                                             , file, ":", line, " "
                                             , pid, " "
                                             , "[", level, "] "
                                             , msg, "\n"
                                             ]
                               }
                            }
             },
  [logger:remove_handler(H) || H <-  logger:get_handler_ids()],
  logger:add_handler(erlang_ls_handler, logger_std_h, Handler),
  logger:set_primary_config(level, LoggingLevel),
  ok.

-spec patch_logging() -> ok.
patch_logging() ->
  %% The ssl_handler is added by ranch -> ssl
  logger:remove_handler(ssl_handler),
  ok.

-spec log_root() -> string().
log_root() ->
  {ok, LogDir} = application:get_env(?APP, log_dir),
  {ok, CurrentDir} = file:get_cwd(),
  Dirname = filename:basename(CurrentDir),
  filename:join([LogDir, Dirname]).
