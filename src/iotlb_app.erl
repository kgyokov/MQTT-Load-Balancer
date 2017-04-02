-module(iotlb_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() -> application:ensure_all_started(iotlb).

start(_StartType, _StartArgs) ->
    start_lb(),
    start_gui(),
    iotlb_sup:start_link().


start_lb() ->
    ProtOpts = [{shutdown,5000}],
    ConnOpts = #{},
    TransportOpts =[
        {tcp,[{port,1883}]},
%%        {ssl,[
%%            {port,5556},
%%            {certfile, ""},
%%            {cacertfile, ""},
%%            {verify, verify_peer}
%%        ]},
        {http,[{port, 80}]}
%%        {https,[{port, 443}]}
    ],
    [{ok,_} = mqttl_sup:start_listener(T,Opts,iotlb_conn,ConnOpts,ProtOpts) || {T,Opts} <- TransportOpts].


start_gui() ->
    ProcessOpts  = [],
    Dispatch = cowboy_router:compile([
        %% {HostMatch, list({PathMatch, Handler, Opts})}
        {'_',
            [
             {"/ws/stats", iotlb_gui_ws, ProcessOpts},
             {"/stats", iotlb_gui, ProcessOpts}
            ]
        }
    ]),
    ProtOpts =
        [{env, [{dispatch, Dispatch}]},
         {shutdown,5000}],
    TransOpts =[{port,12000}],
    {ok,_} = cowboy:start_http(gui_http,10,TransOpts,ProtOpts).


stop(_State) ->
    ok.
