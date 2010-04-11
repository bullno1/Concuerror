%%%----------------------------------------------------------------------
%%% File : scheduler.erl
%%% Modified by : Alkis Gotovos <el3ctrologos@hotmail.com> and
%%%               Maria Christakis <christakismaria@gmail.com>
%%% Description : 
%%%
%%% Created : 1 Apr 2010 by Maria Christakis <christakismaria@gmail.com>
%%%----------------------------------------------------------------------

-module(scheduler).

-export(['after'/0, consumed/1, event/1, exit/1, exit/2, instrumented/0,
         link/1, monitor/2, process_flag/2, receiving/1, receivingAfterX/3,
         send/2, side_effect/3, sleep/1, spawn/1, spawn/2, spawn_link/1,
         spawn_link/2, start/1, start/2, yield/0]).

-include("../include/gui.hrl").

-record(state,
        {actives  = [],
         blocks   = [],
         after0s  = [],
         yields   = [],
         queues   = [],
         links    = [],
         monitors = [],
         trapping = [],
         names    = [],
         schedule = random,
         log      = [],
         events   = events,
         verbose  = true}).

% ----------------------------------------------------------------
% Translations

% 1.
% spawn(Fun)  --->
%   ?MODULE:spawn(Fun)

% 2.
% Pid ! Msg  --->
%   ?MODULE:send(Pid,Msg)

% 3a.
% receive
%   Pat* -> Expr*
% end
%   --->
%     ?MODULE:receiving(fun(After0) ->
%       receive
%         Pat*    -> Expr*
%         after 0 -> After0()
%       end
%     end)

% 3b.
% receive
%   Pat*    -> Expr*
%   after 0 -> ExprAfter0
% end
%   --->
%     ?MODULE:receivingAfter0(fun(After0) ->
%       receive
%         Pat*    -> Expr*
%         after 0 -> After0()
%       end
%     end,
%     fun() -> ExprAfter0 end)

% ----------------------------------------------------------------
% Functions to use for processes

% to be used instead of spawn(Fun)
spawn(Fun) ->
    ?MODULE:spawn(noname,Fun).

spawn(NameHint,Fun) ->
    Pid = erlang:spawn(fun() ->
                               receive
                                   {?MODULE, go} -> Fun()
                               end
                       end),
    ?MODULE ! {fork, NameHint, Pid},
    Pid.

% to be used instead of spawn_link(Fun)
spawn_link(Fun) ->
    ?MODULE:spawn_link(noname, Fun).

spawn_link(NameHint, Fun) ->
    Pid = ?MODULE:spawn(NameHint, Fun),
    ?MODULE ! {link, Pid},
    Pid.

% to be used instead of yield()
yield() ->
    ?MODULE ! {yield},
    receive
        {?MODULE, go} -> ok
    end.

% to be used instead of link(Pid)
link(Pid) ->
    ?MODULE:yield(),
    ?MODULE ! {link, Pid},
    ok.

% to be used instead of process_flag
process_flag(Flag,Value) ->
    ?MODULE:yield(),
    case Flag of
        trap_exit -> 
            ?MODULE ! {trap_exit, Value};
        _ ->
            ok
    end,
    erlang:process_flag(Flag,Value).

exit(Reason) ->
    erlang:exit(Reason).
exit(undefined, _) ->
    erlang:exit(badarg);
exit(Pid, Reason) when is_atom(Pid) ->
    scheduler:exit(whereis(Pid), Reason);
exit(Pid, Reason) ->
    ?MODULE ! {unblock, Pid},
    receive
        {?MODULE, go} ->
            erlang:exit(Pid, Reason)
    end.

monitor(process,Pid) when is_pid(Pid) ->
    ?MODULE:yield(),
    Ref = make_ref(),
    ?MODULE ! {monitor, Pid, Ref},
    Ref.

% to be used instead of Pid ! Msg
send(undefined, _Msg) ->
    erlang:exit(badarg);

send(Pid, Msg) when is_atom(Pid) ->
    send(whereis(Pid), Msg);

send(Pid, Msg) ->
    ?MODULE ! {send, Pid, Msg},
    Msg.

% to be used around a receive statement without "after 0"
receiving(Receive) ->
    Receive(fun() ->
                    ?MODULE ! {block},
                    receive
                        {?MODULE, go} -> receiving(Receive)
                    end
            end).

% to be used around a receive statement with "after 0"
receivingAfterX(Receive, ExprAfterX, AfterX) ->
    Receive(fun() ->
                    ?MODULE ! {blockAfterX, AfterX},
                    receive
                        {?MODULE, afterX} ->
                            receive {?MODULE, go} -> ExprAfterX() end;
                        {?MODULE, go}     ->
                            receivingAfterX(Receive, ExprAfterX, AfterX)
                    end
            end).

% to be used to make a side-effecting call
side_effect(M, F, Args) ->
    ?MODULE:yield(),
    Res = apply(M, F, Args),
    ?MODULE ! {side_effect, M, F, Args, Res},
    Res.

event(Event) ->
    ?MODULE ! {event, Event}.

% sleep
sleep(Timeout) ->
    receivingAfterX(fun(F) -> F() end, fun() -> ok end, Timeout).

% to start the scheduler

% argument list:
%   - {verbose, Verbose}    verbosity, default: true
%   - {seed, Seed}          random seed to use
%   - {schedule, Schedule}  schedule to use
%   - {eventLog, EventLog}  event logging on/off, default: true

% result list:
%   - {schedule, Schedule}  schedule to be used for replay
%   - {live, Live}          the pids of processes alive
%                           when scheduler terminated
%                           (Live /= [] means deadlock)
%   - {events, Events}      event log (to be fed to dot:dot/2 for dot-file)

% for an example of the above, see driver:drive0/1.

start(Fun) ->
    start([], Fun).

start(Config,Fun) ->
    erlang:process_flag(trap_exit, true),
    % seed
    case lists:keyfind(seed, 1, Config) of
        {seed, {A, B, C}} -> random:seed(A, B, C);
        _                 -> ok
    end,
    % schedule
    case lists:keyfind(schedule, 1, Config) of
        {schedule, Sched} -> ok;
        _                 -> Sched = random
    end,
    % verbose
   case lists:keyfind(verbose, 1, Config) of
       {verbose, Verbose} -> ok;
       _                  -> Verbose = true
   end,
    % event logging
    Events =
        case lists:keyfind(eventLog, 1, Config) of
            {eventLog, false} -> noEventLogging;
            _ -> erlang:spawn_link(fun() -> collectEvents(Verbose,[]) end)
        end,
    register(?MODULE, self()),
    Root = erlang:spawn_link(fun() ->
                                     receive
                                         {?MODULE, go} ->
                                             Result = Fun(),
                                             erlang:exit({result, Result})
                                     end
                             end),
    State = #state{actives = [Root],
                   names = [{Root,root}],
                   schedule = Sched,
                   verbose  = Verbose,
                   events   = Events},
    print(Verbose, "*** scheduler started.~n"),
    Result = schedule(State),
    print(Verbose, "*** scheduler finished.~n"),
    unregister(?MODULE),
    Result.

% ----------------------------------------------------------------
% implementation of the scheduler

% the main scheduler
schedule(#state{actives = Actives, after0s = After0s, blocks = Blocks,
                events = StEvents, log = StLog, queues = Queues,
                yields = Yields} = State) ->
    case {Actives, Queues, After0s, Yields} of
        % run a process
        {[Pid|Pids], _, _, _} ->
            Pid ! {?MODULE, go},
            runProcess(Pid, State#state{actives = Pids});
        % all processes are blocked; there are no messages to deliver
        {[],[],[],[]} ->
            [{schedule, lists:reverse(StLog)},
             {live,     State#state.blocks}] ++
                case StEvents of
                    noEventLogging -> [];
                    Events         -> Events ! {done, self()},
                                      receive
                                          Log = {events, _} -> [Log]
                                      end
                end;
        % choose a process to unblock
        _ ->
            Pids = lists:usort([To || {{_, To}, _} <- Queues] ++
                                   [Pid || {Pid,0} <- After0s] ++
                                   Yields),
            case Pids of
                [] -> %% We have only afterXs with non-zero timeout
                    [{Pid, Timeout}|AfterXs] = 
                        lists:sort(fun({_, A}, {_, B}) ->
                                           A =< B
                                   end, After0s),
                    State1 = State#state{after0s = [{Pid1, TO-Timeout}
                                                    || {Pid1, TO} <- AfterXs],
                                         blocks = Blocks -- [Pid],
                                         actives = [Pid]},
                    event(State,{continue, name(State1, Pid)}),
                    Pid ! {?MODULE, afterX},
                    schedule(State1);
                _ ->
                    {Pid, State1} = choosePid(State, Pids),
                    unblockProcess(Pid, State1)
            end
    end.

% runs all active processes
runProcess(Pid, #state{actives = Actives, after0s = After0s,
                       blocks = Blocks, links = Links,
                       monitors = Monitors, names = Names,
                       queues = Queues, trapping = Trapping,
                       yields = Yields} = State) ->
    receive
        % fork a new process with a given name
        {fork, NameHint, Pid2} ->
            Name = createName(Names, NameHint, Pid2),
            State1 = State#state{actives = [Pid2|Actives],
                                 names = [{Pid2,Name}|Names]},
            event(State, {fork, name(State1, Pid), name(State1, Pid2), Pid2}),
            erlang:link(Pid2),
            runProcess(Pid, State1);
        % link to a process
        {link, Pid2} when Pid =/= Pid2 ->
            event(State, {link, name(State, Pid), name(State, Pid2)}),
            case lists:member(Pid2, Actives ++ Blocks) of
                true ->
                    runProcess(Pid, State#state{links = [{Pid, Pid2}|Links]});
                false ->
                    event(State, {send, name(State, Pid2),
                                  {'EXIT', Pid2, noproc}, name(State, Pid)}),
                    runProcess(Pid, State#state{queues = sendOff(Pid2, Pid,
                                                                 {exit, Pid2,
                                                                  noproc},
                                                                 Queues)})
            end;        
        {link, Pid} ->
            event(State, {link, name(State, Pid), name(State, Pid)}),
            runProcess(Pid, State);
        {monitor, Pid2, Ref} when is_pid(Pid2), Pid =/= Pid2 ->
            event(State, {monitor, name(State, Pid), name(State, Pid2), Ref}),
            case lists:member(Pid2, Actives ++ Blocks) of
                true ->
                    runProcess(Pid,
                               State#state{monitors =
                                               [{Pid, Pid2, Ref}|Monitors]});
                false -> event(State, {send, name(State, Pid2),
                                      {'DOWN', Ref, process, Pid, noproc},
                                       name(State, Pid)}),
                         runProcess(Pid, State#state{queues =
                                                         sendOff(Pid2, Pid,
                                                                 {msg,{'DOWN',
                                                                       Ref,
                                                                       process,
                                                                       Pid2,
                                                                       noproc}},
                                                                 Queues)})
            end;
        % process flag
        {trap_exit, Value} ->
            event(State, {trap, name(State, Pid), Value}),
            runProcess(Pid, State#state{trapping = unitIf(Pid, Value) ++
                                            (Trapping -- [Pid])});
        % send a message
        {send, To, Msg} ->
            event(State, {send, name(State, Pid), Msg, name(State, To)}),
            runProcess(Pid, State#state{queues = sendOff(Pid, To, {msg, Msg},
                                                         Queues)});
        % block (in a receive)
        {block} ->
            event(State, {block, name(State, Pid)}),
            schedule(State#state{blocks = [Pid|Blocks]});
        % fall through to "after 0" (in a receive)
        {blockAfterX,Timeout} ->
            event(State, {afterX, Timeout, name(State, Pid)}),
            schedule(State#state{after0s = [{Pid,Timeout}|After0s],
                                 blocks  = [Pid|Blocks]});
        % yield
        {yield} ->
            event(State, {yield, name(State, Pid)}),
            schedule(State#state{yields = [Pid|Yields],
                                 blocks = [Pid|Blocks]});
        % consuming a message
        {consumed, Who, What} ->
            event(State, {consumed, name(State, Who), What}),
            runProcess(Who, State);
        % made a side-effect
        {side_effect, M, F, A, Res} ->
            event(State, {side_effect, name(State, Pid), M, F, A, Res}),
            runProcess(Pid, State);
        {event, Event} ->
            event(State, Event),
            runProcess(Pid, State);
        {unblock, Pid2} ->
            case {lists:member(Pid2, Blocks),
                  lists:member(Pid2, Yields),
                  lists:member(Pid2, After0s)} of
                {true, false, false} ->
                    NewState = State#state{blocks = Blocks -- [Pid2],
                                           actives = [Pid2|Actives]};
                _ -> NewState = State
            end,
            Pid ! {?MODULE, go},
            runProcess(Pid, NewState);
        % finish
        {'EXIT', Pid, Reason} = Exit ->
            event(State, {exit, name(State, Pid), Reason}),
            LinksToSend = lists:usort([{exit, Pid1}
                                       || {Pid1, Pid2} <- Links,
                                          Pid2 =:= Pid] ++
                                          [{exit, Pid2}
                                           || {Pid1, Pid2} <- Links,
                                              Pid1 =:= Pid]),
            MonitorsToSend = lists:usort([{mon, Pid1, Ref}
                                          || {Pid1, Pid2, Ref} <- Monitors, 
                                             Pid2 =:= Pid]),
            schedule(State#state{links = [PidT || {Pid1, Pid2} = PidT<- Links,
                                                          Pid =/= Pid1,
                                                          Pid =/= Pid2],
                                 queues = lists:foldl(
                                            fun({exit, Pid1}, Qs) ->
                                                    event(State, {send,
                                                                  name(State, 
                                                                       Pid),
                                                                  Exit,
                                                                  name(State,
                                                                       Pid1)}),
                                                    sendOff(Pid, Pid1,
                                                            {exit, Pid, Reason},
                                                            Qs);
                                               ({mon, Pid1, Ref}, Qs) ->
                                                    event(State, {send,
                                                                  name(State,
                                                                       Pid),
                                                                  D = {'DOWN',
                                                                       Ref,
                                                                       process,
                                                                       Pid,
                                                                       Reason},
                                                                  name(State,
                                                                       Pid1)}),
                                                    sendOff(Pid, Pid1, {msg, D},
                                                            Qs)
                                            end,
                                            [Queue
                                             || Queue = {{_, To}, _} <- Queues,
                                                To =/= Pid],
                                            LinksToSend ++ MonitorsToSend),
                                 after0s = [T
                                            || T = {Pid1, _} <- After0s,
                                               Pid1 /= Pid],
                                 blocks  = [Pid1
                                            || Pid1 <- Blocks, Pid1 =/= Pid]})
    end.

% adding a message to a queue
sendOff(From, To, Msg, Queues) ->
    case lists:keyfind(FromTo = {From, To}, 1, Queues) of
        {_, Queue} ->
            lists:keyreplace(FromTo, 1, Queues, {FromTo, Queue ++ [Msg]});
        false ->
            [{FromTo, [Msg]}|Queues]
    end.

% unblock a process
unblockProcess(Pid, State) ->
  {Action, State1} =
        chooseAction(State,
                     case lists:member(Pid, State#state.yields) of
                         true -> [yield];
                         false ->
                             [{deliver, From}
                              || {{From, Pid1}, _} <- State#state.queues,
                                                      Pid =:= Pid1] ++
                                 [afterX || {Pid1, 0} <- State#state.after0s,
                                                         Pid =:= Pid1]
                     end),
  State2 = State1#state{blocks  = State1#state.blocks -- [Pid],
                        after0s = [T || T = {Pid1, _} <- State1#state.after0s,
                                                         Pid =/= Pid1],
                        yields  = State1#state.yields   -- [Pid],
                        actives = [Pid || lists:member(Pid, 
                                                       State1#state.blocks)] ++
                                  (State1#state.actives -- [Pid]),
                        log     = [{name(State1, Pid),
                                    case Action of
                                        {deliver, From1} ->
                                            {deliver, name(State1, From1)};
                                        _ -> Action
                                    end}|State1#state.log]},
    case Action of
        % deliver a message from a queue
        {deliver, From} ->
            {_, [Msg|Queue]} =
                lists:keyfind(FromPid = {From, Pid}, 1, State2#state.queues),
            case Msg of
                {exit, Who, Reason} ->
                    Msg1 = {'EXIT', Who, Reason},
                    event(State, {deliver, name(State2, Pid), Msg1,
                                  name(State2, From)}),
                    case lists:member(Pid, State#state.trapping) of
                        false when Reason =/= normal ->
                            erlang:exit(Pid, Reason);
                        true -> 
                            Pid ! Msg1;
                        % Pid is not trapping exits and Reason is normal
                        _ -> ok
                    end;
                {msg, Msg0} ->
                    event(State, {deliver, name(State2, Pid), Msg0,
                                  name(State2, From)}),
                    Pid ! Msg0
            end,
            Queues =
                case Queue of
                    [] -> lists:keydelete(FromPid, 1, State2#state.queues);
                    _ ->
                        lists:keyreplace(FromPid, 1, State2#state.queues,
                                         {FromPid, Queue})
                end,
            schedule(State2#state{queues = Queues});
        % trigger the "after 0"
        afterX ->
            event(State, {continue, name(State2, Pid)}),
            Pid ! {?MODULE, afterX},
            schedule(State2);
        % restart the yielded process
        yield ->
            event(State, {continue, name(State2, Pid)}),
            schedule(State2)
    end.

% create the name
createName(Names, NameHint, Pid) ->
  hd([Name || Name <- [NameHint] ++
                  [case is_atom(NameHint) of
                       true ->
                           list_to_atom(atom_to_list(NameHint) ++
                                            integer_to_list(N));
                       false -> {NameHint,N}
                   end
                   || N <- lists:seq(1,99)] ++
                  [{NameHint,Pid}],
              not lists:member(Name, [Name1 || {_,Name1} <- Names])]).

% ----------------------------------------------------------------
% helper functions

choose(Xs) ->
    K = random:uniform(length(Xs)),
    lists:nth(K, Xs).

choosePid(State, Pids) ->
    case State#state.schedule of
        [{Name,_}|_] -> {pid(State, Name), State};
        _            -> {choose(Pids), State}
    end.

chooseAction(State, Actions) ->
    case State#state.schedule of
        [{_,Action}|Sched] -> {case Action of
                                   {deliver,Name} ->
                                       {deliver, pid(State, Name)};
                                   _              ->
                                       Action
                               end,
                               State#state{schedule=Sched}};
        _                  -> {choose(Actions),State}
    end.

name(State, Pid) ->
    case lists:keyfind(Pid, 1, State#state.names) of
        {_, Name} -> Name;
        _         -> Pid
    end.

pid(State, Name) ->
    case lists:keyfind(Name, 2, State#state.names) of
        {Pid, _} -> Pid;
        _               -> erlang:exit({bad_name, Name})
    end.

unitIf(X, true) -> [X];
unitIf(_, _)    -> [].

% ----------------------------------------------------------------
% collecting / printing events

consumed(What) ->
    ?MODULE ! {consumed, self(), What}.

event(State, Event) ->
    case State#state.verbose of
        Verbose = true ->
            case Event of
                {fork, Name1, Name2, Pid} ->
                    print(Verbose, " -> <~p> forks <~p> = ~p.~n",
                          [Name1, Name2, Pid]);
                {link, Name1, Name2} ->
                    print(Verbose, " -> <~p> links to <~p>.~n",
                          [Name1, Name2]);
                {monitor, Name1, Name2, Ref} ->
                    print(Verbose, " -> <~p> monitors <~p> (Ref: ~p).~n",
                          [Name1, Name2, Ref]);
                {trap, Name, Value} ->
                    print(Verbose, " -> <~p> traps exit messages: ~p.~n",
                          [Name, Value]);
                {send, Name1, Msg, Name2} ->
                    print(Verbose, " -> <~p> sends '~p' to <~p>.~n",
                          [Name1, Msg, Name2]);
                {block, Name} ->
                    print(Verbose, " -> <~p> blocks.~n", [Name]);
                {afterX, Timeout, Name} ->
                    print(Verbose, " -> <~p> hits an after ~p.~n",
                          [Name, Timeout]);
                {yield, Name} ->
                    print(Verbose, " -> <~p> yields.~n", [Name]);
                {consumed, Name, What} ->
                    print(Verbose, " -> <~p> consumed '~p'~n",[Name, What]);
                {exit, Name, Reason} ->
                    print(Verbose, " -> <~p> exits with '~p'.~n",
                          [Name, Reason]);
                {deliver, Name1, Msg, Name2} ->
                    print(Verbose, "*** unblocking <~p> by delivering '~p' "
                          "sent by <~p>.~n",
                          [Name1, Msg, Name2]);
                {continue, Name} ->
                    print(Verbose, "*** unblocking <~p> by continuing "
                          "from afterX/yield.~n",
                          [Name]);
                {side_effect, Name, M, F, A, Res} ->
                    print(Verbose, " -> <~p> calls ~p:~p ~p returning ~p.~n",
                          [Name, M, F, A, Res]);
                _ ->
                    io:format("UNKNOWN EVENT: ~p.~n", [Event])
            end;
        _ -> ok
    end,
    case State#state.events of
        noEventLogging -> ok;
        Events         -> Events ! Event
    end.

collectEvents(Verbose, Events) ->
    receive
        {done, Pid} -> Pid ! {events, lists:reverse(Events)};
        Event       -> collectEvents(Verbose, [cleanup(Event)|Events])
    end.

cleanup({fork, Name1, Name2, _}) -> {fork, Name1, Name2};
cleanup(Event)                   -> Event.

print(Verbose,S) -> print(Verbose, S, []).

print(false,_,_) -> ok;

print(_, S, Xs) ->
    case whereis(loop) of
	undefined -> io:format(S, Xs);
	Pid ->
            Pid ! #gui{type = log, msg = io_lib:format(S, Xs)}
    end.

% ----------------------------------------------------------------
% instrumentation information

'after'() ->
    0.

instrumented() ->
    [{erlang, spawn, [name]},
     {erlang, spawn_link, [name]},
     {erlang, link, []},
     {erlang, process_flag, [yield]},
     {erlang, yield, []},
     {erlang, now, [dont_capture, yield]},
     {erlang, is_process_alive, [dont_capture, yield]},
     {erlang, demonitor, [dont_capture, yield]},
     {erlang, monitor, []},
     {erlang, exit, [yield]},
     {erlang, is_process_alive, [dont_capture,yield]},
     {timer, sleep, []},
     {io, format, [dont_capture]},
     {ets, lookup, [dont_capture, yield]},
     {ets, insert, [dont_capture, yield]},
     {ets, insert_new, [dont_capture, yield]},
     {ets, delete_object, [dont_capture, yield]},
     {ets, delete, [dont_capture, yield]},
     {ets, delete_all_objects, [dont_capture, yield]},
     {ets, select_delete, [dont_capture, yield]},
     {ets, match_delete, [dont_capture, yield]},
     {ets, match_object, [dont_capture, yield]},
     {ets, new, [dont_capture, yield]},
     {file, write_file, [dont_capture, yield]},
     {gen_server, start_link, [{replace_with, genserver, start_link}]},
     {gen_server, start, [{replace_with, genserver, start}]},
     {gen_server, call, [{replace_with, genserver, call}]},
     {gen_server, cast, [{replace_with, genserver, cast}]},
     {gen_server, server, [{replace_with, genserver, server}]},
     {gen_server, loop, [{replace_with, genserver, loop}]}].

% ----------------------------------------------------------------