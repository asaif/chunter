
-module(chunter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    [_Name|_] = re:split(os:cmd("uname -n"), "\n"),
    {ok, {{one_for_one, 5, 10},
          [
           ?CHILD(chunter_vm_sup, supervisor),
           ?CHILD(chunter_server, worker),
           ?CHILD(chunter_kstat_arc, worker),
           ?CHILD(chunter_zpool_monitor, worker),
           ?CHILD(chunter_perf_plugin, worker),
           ?CHILD(chunter_zonemon, worker)
          ]}}.
