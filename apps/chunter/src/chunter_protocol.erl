-module(chunter_protocol).
-behaviour(gen_server).
-behaviour(ranch_protocol).

-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ignore_xref([start_link/4]).

-record(state, {socket,
                transport,
                ok,
                error,
                closed,
                type = normal,
                state = undefined}).

start_link(ListenerPid, Socket, Transport, Opts) ->
    proc_lib:start_link(?MODULE, init, [[ListenerPid, Socket, Transport, Opts]]).

init([ListenerPid, Socket, Transport, _Opts]) ->
    ok = proc_lib:init_ack({ok, self()}),
    %% Perform any required state initialization here.
    ok = ranch:accept_ack(ListenerPid),
    ok = Transport:setopts(Socket, [{active, true}, {packet,4}, {nodelay, true}]),
    {OK, Closed, Error} = Transport:messages(),
    gen_server:enter_loop(?MODULE, [], #state{
                                     ok = OK,
                                     closed = Closed,
                                     error = Error,
                                     socket = Socket,
                                     transport = Transport}).

handle_info({data,Data}, State = #state{socket = Socket,
                                        transport = Transport}) ->
    Transport:send(Socket, Data),
    {noreply, State};

handle_info({_Closed, _Socket}, State = #state{
                                  type = mornal,
                                  closed = _Closed}) ->
    {stop, normal, State};

handle_info({_OK, Socket, BinData}, State = #state{
                                      type = normal,
                                      transport = Transport,
                                      ok = _OK}) ->
    Msg = binary_to_term(BinData),
    case Msg of
        {dtrace, Script} ->
            lager:info("Compiling DTrace script: ~p.", [Script]),
            {ok, Handle} = erltrace:open(),
            ok = erltrace:compile(Handle, Script),
            ok = erltrace:go(Handle),
            lager:debug("DTrace running."),
            {noreply, State#state{state = Handle,
                                  type = dtrace}};
        {console, UUID} ->
            lager:info("Console: ~p.", [UUID]),
            chunter_vm_fsm:console_link(UUID, self()),
            {noreply, State#state{state = UUID,
                                  type = console}};
        ping ->
            lager:info("Ping."),
            Transport:send(Socket, term_to_binary(pong)),
            ok = Transport:close(Socket),
            {stop, normal, State};
        Data ->
            case handle_message(Data, undefined) of
                {stop, Reply, _} ->
                    Transport:send(Socket, term_to_binary({reply, Reply})),
                    Transport:close(Socket),
                    {stop, normal, State};
                {stop, _} ->
                    ok = Transport:close(Socket),
                    {stop, normal, State}
            end
    end;

handle_info({_OK, Socket, BinData},  State = #state{
                                       state = Handle,
                                       type = dtrace,
                                       transport = Transport,
                                       ok = _OK}) ->
    case binary_to_term(BinData) of
        stop ->
            erltrace:stop(Handle);
        go ->
            erltrace:go(Handle);
        {Act, Ref, Fn} ->
            lager:info("<~p> Starting ~p.", [Ref, Act]),
            Transport:send(Socket, term_to_binary({ok, Ref})),
            {Time, Res} = timer:tc(fun() ->
                                           case Act of
                                               walk ->
                                                   erltrace:walk(Handle);
                                               consume ->
                                                   erltrace:consume(Handle)
                                           end
                                   end),
            {Time1, Res1} = timer:tc(fun () ->
                                             case Res of
                                                 {ok, D} ->
                                                     case Fn of
                                                         llquantize ->
                                                             {ok, llquantize(D)};
                                                         identity ->
                                                             {ok, D}
                                                     end;
                                                 D ->
                                                     D
                                             end
                                     end),
            Now = now(),
            Transport:send(Socket, term_to_binary(Res1)),
            lager:info("<~p> Dtrace ~p  took ~pus + ~pus + ~pus.", [Ref, Act, Time, Time1, timer:now_diff(now(), Now)])
    end,
    {noreply, State};

handle_info({_OK, _S, Data}, State = #state{
                               type = console,
                               state = UUID,
                               ok = _OK}) ->
    chunter_vm_fsm:console_send(UUID, Data),
    {noreply, State};

handle_info({_Closed, _}, State = #state{ closed = _Closed}) ->
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

-spec handle_message(Message::fifo:chunter_message(), State::term()) ->
                            {stop, term()} | {stop, term(), term()}.

handle_message({machines, start, UUID}, State) when is_binary(UUID) ->
    chunter_vmadm:start(UUID),
    {stop, State};

handle_message({machines, update, UUID, Package, Config}, State) when is_binary(UUID) ->
    chunter_vm_fsm:update(UUID, Package, Config),
    {stop, State};

handle_message({machines, start, UUID, Image}, State) when is_binary(UUID),
                                                           is_binary(Image) ->
    chunter_vmadm:start(UUID, Image),
    {stop, State};

handle_message({machines, snapshot, UUID, SnapId}, State) when is_binary(UUID),
                                                               is_binary(SnapId) ->
    {stop, chunter_vm_fsm:snapshot(UUID, SnapId), State};

handle_message({machines, snapshot, delete, UUID, SnapId}, State) when is_binary(UUID),
                                                                       is_binary(SnapId) ->
    {stop, chunter_vm_fsm:delete_snapshot(UUID, SnapId), State};

handle_message({machines, snapshot, rollback, UUID, SnapId}, State) when is_binary(UUID),
                                                                         is_binary(SnapId) ->
    {stop, chunter_vm_fsm:rollback_snapshot(UUID, SnapId), State};

handle_message({machines, snapshot, store, UUID, SnapId, Img}, State) when is_binary(UUID),
                                                                           is_binary(SnapId) ->
    spawn(fun() ->
                  write_snapshot(UUID, SnapId, Img)
          end),
    {stop, ok, State};


handle_message({machines, stop, UUID}, State) when is_binary(UUID) ->
    chunter_vmadm:stop(UUID),
    {stop, State};

handle_message({machines, stop, force, UUID}, State) when is_binary(UUID) ->
    chunter_vmadm:force_stop(UUID),
    {stop, State};

handle_message({machines, reboot, UUID}, State) when is_binary(UUID) ->
    chunter_vmadm:reboot(UUID),
    {stop, State};

handle_message({machines, reboot, force, UUID}, State) when is_binary(UUID) ->
    chunter_vmadm:force_reboot(UUID),
    {stop, State};

handle_message({machines, create, UUID, PSpec, DSpec, Config}, State) when is_binary(UUID),
                                                                           is_list(PSpec),
                                                                           is_list(DSpec),
                                                                           is_list(Config) ->
    chunter_vm_fsm:create(UUID, PSpec, DSpec, Config),
    {stop, State};

handle_message({machines, delete, UUID}, State) when is_binary(UUID) ->
    chunter_vm_fsm:delete(UUID),
    {stop, State};

handle_message(Oops, State) ->
    io:format("oops: ~p~n", [Oops]),
    {stop, State}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknwon}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


llquantize(Data) ->
    lists:foldr(fun ({_, Path, Vals}, Obj) ->
                        BPath = lists:map(fun(L) when is_list(L) ->
                                                  list_to_binary(L);
                                             (B) when is_binary(B) ->
                                                  B;
                                             (N) when is_number(N) ->
                                                  list_to_binary(integer_to_list(N))
                                          end, Path),
                        lists:foldr(fun({{Start, End}, Value}, Obj1) ->
                                            B = list_to_binary(io_lib:format("~p-~p", [Start, End])),
                                            jsxd:set(BPath ++ [B], Value, Obj1)
                                    end, Obj, Vals)
                end, [], Data).


write_snapshot(UUID, SnapId, Img) ->
    Cmd = code:priv_dir(chunter) ++ "/zfs_send.gzip.sh",
    lager:debug("Running ZFS command: ~p", [Cmd]),
    Port = open_port({spawn_executable, Cmd},
                     [{args, [UUID, SnapId]}, use_stdio, binary,
                      stderr_to_stdout, exit_status, stream]),
    libsniffle:dataset_set(Img, <<"imported">>, 0),
    write_snapshot(Port, Img, <<>>, 0).

write_snapshot(Port, Img, <<MB:1048576/binary, Acc/binary>>, Idx) ->
    libsniffle:img_create(Img, Idx, binary:copy(MB)),
    write_snapshot(Port, Img, Acc, Idx+1);

write_snapshot(Port, Img, Acc, Idx) ->
    receive
        {Port, {data, Data}} ->
            write_snapshot(Port, Img, <<Acc/binary, Data/binary>>, Idx);
        {Port,{exit_status, 0}} ->
            case Acc of
                <<>> ->
                    ok;
                _ ->
                    libsniffle:img_create(Img, Idx, binary:copy(Acc))
            end,
            lager:info("Writing image ~s finished with ~p parts.", [Img, Idx]),
            libsniffle:dataset_set(Img, <<"imported">>, 1),
            ok;
        {Port,{exit_status, S}} ->
            lager:error("Writing image ~s failed after ~p parts with exit status ~p.", [Img, Idx, S]),
            ok
    end.
