%%%-------------------------------------------------------------------
%%% @author Kalin
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 13. Mar 2017 11:01 PM
%%%-------------------------------------------------------------------
-module(iotlb_conn).
-author("Kalin").

-include_lib("mqttl/include/mqttl_packets.hrl").
-behaviour(gen_server).

%% API
-export([start_link/3, new_link/3, unexpected_disconnect/2, bad_packet/2, handle_packet/2]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
  transport_info ::any(),
  connected::boolean(),
  sup_pid :: pid(),
  socket :: port()                 %% The process sending to the actual device
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(ReceiverPid::pid(),SupPid::pid(),TSO::any()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(ReceiverPid,SupPid,TSO) ->
  gen_server:start_link(?MODULE, [ReceiverPid,SupPid,TSO], []).


new_link(Transport,Socket,Opts) ->
  TSO = {Transport,Socket,Opts},
  iotlb_conn_sup_sup:start_connection(self(),TSO).

%%todo: Maybe just have the receiver quit let the mqttl_conn process be killed?
unexpected_disconnect(_Pid,_Details) -> ok. %%gen_server:cast(Pid,{disconnect,Details}).

%%todo: Maybe just have the receive quit and let the mqttl_conn process be killed?
bad_packet(_Pid,_Reason) -> ok. %%gen_server:cast(Pid,{bad_packet,Reason}).

handle_packet(Pid,Packet) ->
  gen_server:call(Pid,{packet,Packet}).

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
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([ReceiverPid,SupPid,TSO = {_,_,Opts}]) ->
  link(ReceiverPid),
  TimeOut = maps:get(conn_timeout,Opts,10000),
  erlang:send_after(TimeOut,self(),conn_timeout),
  {ok, #state{sup_pid = SupPid,
              connected = false,
              transport_info = TSO}
  }.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).

handle_call({packet,Packet = #'CONNECT'{client_id = ClientId}},_From,
              S = #state{connected = false,
                         sup_pid = SupPid,
                         transport_info = TRO}) ->
  %%@todo: Packet validation to avoid bad packets being sent to the wrong server???
  {_,_,Opts} = TRO,
  {Address,Port} = iotlb_broker_selection:select_broker(Packet),
  {ok,BrokerSocket} = connect_to_broker(Address,Port,Opts),
  {ok,BrokerForwarder} = iotlb_conn_sup:start_bsender(SupPid, TRO,BrokerSocket),
  ok = gen_tcp:controlling_process(BrokerSocket,BrokerForwarder),
  S1 = S#state{socket = BrokerSocket,connected = true},
  iotlb_stats_col:connected(self(),ClientId,{Address,Port}),
  forward_to_broker(Packet,S1);

handle_call({packet,_Packet},_From,S = #state{connected = false}) ->
  {stop, premature_packet, S}; %%Maybe specify a different reason

handle_call({packet,Packet},_From,S = #state{connected = true}) ->
  forward_to_broker(Packet,S);

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).

handle_cast(_Request, State) ->
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
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).

handle_info(conn_timeout, S = #state{connected = false}) ->
  {stop, conn_timeout, S};

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
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _S) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

connect_to_broker(Address,Port,Opts)->
  ConnTimeOut = maps:get(server_connect_timeout,Opts,10000),
  gen_tcp:connect(Address,Port,[binary, {active,true}],ConnTimeOut).

forward_to_broker(Packet,S = #state{socket = BrokerSender}) ->
  Binary = mqttl_builder:build_packet(Packet),
  error_logger:info_msg("Sending to broker Packet ~p with Binary ~p~n",[Packet,Binary]),
  case gen_tcp:send(BrokerSender,Binary) of
    ok ->
      {reply,ok,S};
    {error,Reason} ->
      {stop, unable_to_send, {error,Reason}, S}
  end.
