-module(host_cpu_perf).

-export([mpstat/1]).

mpstat({KStat, Acc}) ->
    Data = ekstat:read(KStat, "misc", "cpu"),
    Data1 = lists:sort([{ID, Keys} ||
                           {_,_,ID, _Name, Keys} <- Data, _Name =:= "sys"]),
    Data2 = [jsxd:from_list([{list_to_binary(K), V} ||
                                {"cpu_nsec_" ++ K, V} <- Ks]) || {_, Ks} <- Data1],
    [Node |_] = re:split(os:cmd("uname -n"), "\n"),
    {KStat, [{Node, [{<<"data">>, Data2},
                     {<<"event">>, <<"mpstat">>}]}|Acc]}.
