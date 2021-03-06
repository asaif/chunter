%%%-------------------------------------------------------------------
%%% @author Heinz N. Gies <heinz@licenser.net>
%%% @copyright (C) 2012, Heinz N. Gies
%%% @doc
%%%
%%% @end
%%% Created :  1 May 2012 by Heinz N. Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(chunter_server).

-behaviour(gen_server).

-include("chunter_version.hrl").

%% API
-export([start_link/0,
         provision_memory/1,
         unprovision_memory/1,
         connect/0,
         disconnect/0]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ignore_xref([start_link/0]).

-define(CPU_CAP_MULTIPLYER, 8).

-define(SERVER, ?MODULE).

-record(state, {name,
                port,
                sysinfo,
                connected = false,
                capabilities = [],
                total_memory = 0,
                provisioned_memory = 0}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

provision_memory(M) ->
    gen_server:cast(?SERVER, {prov_mem, M}).

unprovision_memory(M) ->
    gen_server:cast(?SERVER, {unprov_mem, M}).

connect() ->
    gen_server:cast(?SERVER, connect).

disconnect() ->
    gen_server:cast(?SERVER, disconnect).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    lager:info([{fifi_component, chunter}],
               "chunter:init.", []),
    {Host, IPStr} = host_info(),
    %% We subscribe to sniffle register channel - that way we can reregister to dead sniffle processes.
    mdns_client_lib_connection_event:add_handler(chunter_connect_event),
    libsniffle:hypervisor_register(Host, IPStr, 4200),
    lager:info([{fifi_component, chunter}],
               "chunter:init - Host: ~s", [Host]),
    lists:foldl(
      fun (VM, _) ->
              {<<"uuid">>, UUID} = lists:keyfind(<<"uuid">>, 1, VM),
              chunter_vm_fsm:load(UUID)
      end, 0, list_vms()),

    SysInfo = jsx:decode(list_to_binary(os:cmd("sysinfo"))),


    Capabilities = case os:cmd("ls /dev/kvm") of
                       "/dev/kvm\n" ->
                           [<<"zone">>, <<"kvm">>];
                       _ ->
                           [<<"zone">>]
                   end,

    libsniffle:hypervisor_set(Host, [{<<"sysinfo">>, SysInfo},
                                     {<<"version">>, ?VERSION},
                                     {<<"virtualisation">>, Capabilities}]),

    {ok, #state{
       sysinfo = SysInfo,
       name = Host,
       capabilities = Capabilities
      }}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call({call, _Auth, Call}, _From, #state{name = _Name} = State) ->
                                                %    statsderl:increment([Name, ".call.unknown"], 1, 1.0),
    lager:info([{fifi_component, chunter}],
               "unsupported call - ~p", [Call]),
    Reply = {error, {unsupported, Call}},
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknwon}, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_cast(connect, #state{name = Host,
                            capabilities = Caps} = State) ->
                                                %    {ok, Host} = libsnarl:option_get(system, statsd, hostname),
                                                %    application:set_env(statsderl, hostname, Host),
    {TotalMem, _} = string:to_integer(os:cmd("/usr/sbin/prtconf | grep Memor | awk '{print $3}'")),
    Networks = re:split(os:cmd("cat /usbkey/config  | grep '_nic=' | sed 's/_nic.*$//'"), "\n"),
    Networks1 = lists:delete(<<>>, Networks),
    Etherstub = re:split(
                  os:cmd("cat /usbkey/config | grep etherstub | sed -e 's/etherstub=\"\\(.*\\)\"/\\1/'"),
                  ",\\s*|\n"),
    Etherstub1 = lists:delete(<<>>, Etherstub),
    VMS = list_vms(),
    ProvMem = round(lists:foldl(
                      fun (VM, Mem) ->
                              {<<"uuid">>, UUID} = lists:keyfind(<<"uuid">>, 1, VM),
                              chunter_vm_fsm:load(UUID),
                              {<<"max_physical_memory">>, M} = lists:keyfind(<<"max_physical_memory">>, 1, VM),
                              Mem + M
                      end, 0, VMS) / (1024*1024)),

                                                %    statsderl:gauge([Name, ".hypervisor.memory.total"], TotalMem, 1),
                                                %    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], ProvMem, 1),

                                                %    statsderl:increment([Name, ".net.join"], 1, 1.0),
                                                %    libsniffle:join_client_channel(),

    {Host, IPStr} = host_info(),
    libsniffle:hypervisor_register(Host, IPStr, 4200),
    libsniffle:hypervisor_set(Host, [{<<"sysinfo">>, State#state.sysinfo},
                                     {<<"version">>, ?VERSION},
                                     {<<"networks">>, Networks1},
                                     {<<"resources.free-memory">>, TotalMem - ProvMem},
                                     {<<"etherstubs">>, Etherstub1},
                                     {<<"resources.provisioned-memory">>, ProvMem},
                                     {<<"resources.total-memory">>, TotalMem},
                                     {<<"virtualisation">>, Caps}]),
    {noreply, State#state{
                total_memory = TotalMem,
                provisioned_memory = ProvMem,
                connected = true
               }};

handle_cast(disconnect,  State) ->
    {noreply, State#state{connected = false}};

handle_cast({prov_mem, M}, State = #state{name = Name,
                                          provisioned_memory = P,
                                          total_memory = T}) ->
    MinMB = round(M / (1024*1024)),
    Provisioned = round(MinMB + P),
    Free = T - Provisioned,
    libsniffle:hypervisor_set(Name, [{<<"resources.free-memory">>, Free},
                                     {<<"resources.provisioned-memory">>, Provisioned}]),
    libhowl:send(Name, [{<<"event">>, <<"memorychange">>},
                        {<<"data">>, [{<<"free">>, Free},
                                      {<<"provisioned">>, Provisioned}]}]),
                                                %    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], Res, 1),
    lager:info([{fifi_component, chunter}],
               "memory:provision - Privisioned: ~p(~p), Total: ~p, Change: +~p.", [Provisioned, M, T, MinMB]),
    {noreply, State#state{provisioned_memory = Provisioned}};

handle_cast({unprov_mem, M}, State = #state{name = Name,
                                            provisioned_memory = P,
                                            total_memory = T}) ->
    MinMB = round(M / (1024*1024)),
    Provisioned = round(P - MinMB),
    Free = T - Provisioned,
    libsniffle:hypervisor_set(Name, [{<<"resources.free-memory">>, Free},
                                     {<<"resources.provisioned-memory">>, Provisioned}]),

    libhowl:send(Name, [{<<"event">>, <<"memorychange">>},
                        {<<"data">>, [{<<"free">>, Free},
                                      {<<"provisioned">>, Provisioned}]}]),

                                                %    statsderl:gauge([Name, ".hypervisor.memory.provisioned"], Res, 1),
    lager:info([{fifi_component, chunter}],
               "memory:unprovision - Unprivisioned: ~p(~p) , Total: ~p, Change: -~p.", [Provisioned, M, T, MinMB]),
    {noreply, State#state{provisioned_memory = Provisioned}};


handle_cast(_Msg, #state{name = _Name} = State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

list_vms() ->
    [chunter_zoneparser:load([{<<"name">>, Name}, {<<"uuid">>, UUID}]) ||
        [ID,Name,_VMState,_Path,UUID,_Type,_IP,_SomeNumber] <-
            [ re:split(Line, ":")
              || Line <- re:split(os:cmd("/usr/sbin/zoneadm list -ip"), "\n")],
        ID =/= <<"0">>].


host_info() ->
    Host = case application:get_env(hostname) of
               undefined ->
                   [H|_] = re:split(os:cmd("uname -n"), "\n"),
                   H;
               {ok, H} when is_binary(H) ->
                   H;
               {ok, H} when is_list(H) ->
                   list_to_binary(H)
           end,
    {A,B,C,D} = case application:get_env(ip) of
                    undefined ->
                        {ok, R} = inet:getaddr(binary_to_list(Host), inet),
                        R;
                    {ok, R} ->
                        R
                end,
    IPStr = list_to_binary(io_lib:format("~p.~p.~p.~p", [A,B,C,D])),
    {Host, IPStr}.
