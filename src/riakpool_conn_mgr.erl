-module(riakpool_conn_mgr).

-compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

-export([pools/0, waiting/0, add_pool/1, remove_pool/1,
		pool_id/2, close_connection/1,
		add_connections/2, remove_connections/2, open_connections/1, open_n_connections/2,
		lock_connection/0, wait_for_connection/0,
		pass_connection/1, 
		replace_connection_as_available/2, replace_connection_as_locked/2,
		find_pool/3]).

-include("riakpool.hrl").

-record(state, {pools, waiting=queue:new(), counter}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
	Res = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
	Res.

pools() ->
	gen_server:call(?MODULE, pools, infinity).

waiting() ->
	gen_server:call(?MODULE, waiting, infinity).

add_pool(Pool) ->
	do_gen_call({add_pool, Pool}).

remove_pool(PoolId) ->
	do_gen_call({remove_pool, PoolId}).

add_connections(PoolId, Conns) when is_list(Conns) ->
	do_gen_call({add_connections, PoolId, Conns}).

remove_connections(PoolId, Num) when is_integer(Num) ->
	do_gen_call({remove_connections, PoolId, Num}).

lock_connection()->
	do_gen_call(lock_connection).

wait_for_connection()->
	%% try to lock a connection. if no connections are available then
	%% wait to be notified of the next available connection
    %-% io:format("~p waits for connection to pool ~p~n", [self(), PoolId]),
	case lock_connection() of
		unavailable ->
            %-% io:format("~p is queued~n", [self()]),
			gen_server:call(?MODULE, start_wait, infinity),
			receive
				{connection, Connection} -> 
                    %-% io:format("~p gets a connection after waiting in queue~n", [self()]),
    				Connection
			after lock_timeout() ->
                %-% io:format("~p gets no connection and times out -> EXIT~n~n", [self()]),
				{error, connection_lock_timeout}
				%exit(connection_lock_timeout)
			end;
		Connection ->
            %-% io:format("~p gets connection~n", [self()]),
			Connection
	end.

pass_connection(Connection) ->
	do_gen_call({pass_connection, Connection}).

replace_connection_as_available(OldConn, NewConn) ->
	do_gen_call({replace_connection_as_available, OldConn, NewConn}).

replace_connection_as_locked(OldConn, NewConn) ->
	do_gen_call({replace_connection_as_locked, OldConn, NewConn}).

%% the stateful loop functions of the gen_server never
%% want to call exit/1 because it would crash the gen_server.
%% instead we want to return error tuples and then throw
%% the error once outside of the gen_server process
do_gen_call(Msg) ->
	case gen_server:call(?MODULE, Msg, infinity) of
		{error, Reason} ->
			exit(Reason);
		Result ->
			Result
	end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
	Pools = initialize_pools(),
	Pools1 = [open_connections(Pool) || Pool <- Pools],
	{ok, #state{pools=Pools1,counter=0}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(pools, _From, State) ->
	{reply, State#state.pools, State};

handle_call(waiting, _From, State) ->
	{reply, State#state.waiting, State};

handle_call({add_pool, Pool}, _From, State) ->
	case find_pool(Pool#pool.pool_id, State#state.pools, []) of
		{_, _} ->
			{reply, {error, pool_already_exists}, State};
		undefined ->
			{reply, ok, State#state{pools = [Pool|State#state.pools]}}
	end;

handle_call({remove_pool, PoolId}, _From, State) ->
	case find_pool(PoolId, State#state.pools, []) of
		{Pool, OtherPools} ->
			{reply, Pool, State#state{pools=OtherPools}};
		undefined ->
			{reply, {error, pool_not_found}, State}
	end;

handle_call({add_connections, PoolId, Conns}, _From, State) ->
	case find_pool(PoolId, State#state.pools, []) of
		{Pool, OtherPools} ->
			OtherConns = Pool#pool.available,
			State1 = State#state{
				pools = [Pool#pool{available = queue:join(queue:from_list(Conns), OtherConns)}|OtherPools]
			},
			{reply, ok, State1};
		undefined ->
			{reply, {error, pool_not_found}, State}
	end;

handle_call({remove_connections, PoolId, Num}, _From, State) ->
	case find_pool(PoolId, State#state.pools, []) of
		{Pool, OtherPools} ->
			case Num > queue:len(Pool#pool.available) of
				true ->
					State1 = State#state{pools = [Pool#pool{available = queue:new()}]},
					{reply, queue:to_list(Pool#pool.available), State1};
				false ->
					{Conns, OtherConns} = queue:split(Num, Pool#pool.available),
					State1 = State#state{pools = [Pool#pool{available = OtherConns}|OtherPools]},
					{reply, queue:to_list(Conns), State1}
			end;
		undefined ->
			{reply, {error, pool_not_found}, State}
	end;

handle_call(start_wait, {From, _Mref}, State) ->
	%% place to calling pid at the end of the waiting queue
	State1 = State#state{
		waiting = queue:in(From, State#state.waiting)
	},
	{reply, ok, State1};

handle_call(lock_connection, _From, State) ->
	%% find the next available connection in the pool identified by PoolId
    %-% io:format("gen srv: lock connection for pool ~p~n", [PoolId]),

	%% TODO: because we are doing round robin, we need to put the lock timeout in here, so we can
	%% increment to the next pool if the current pool doesn't have a connection available
	
	%% we also should check if we can free up some connections that aren't used. We should update the state of
	%% each connection to see when they are last used
	Pool = lists:nth((State#state.counter rem length(State#state.pools) + 1), State#state.pools),

	case find_next_connection_in_pool(State#state.pools, Pool#pool.pool_id) of
		[Pool, OtherPools, Conn, OtherConns] ->
            %-% io:format("gen srv: lock connection ... found a good next connection~n", []),
			NewConn = Conn#connection{locked_at=lists:nth(2, tuple_to_list(now()))},
			Locked = gb_trees:enter(NewConn#connection.id, NewConn, Pool#pool.locked),
			State1 = State#state{pools = [Pool#pool{available=OtherConns, locked=Locked}|OtherPools], counter=State#state.counter + 1},
			{reply, NewConn, State1};
		Other ->
            %-% io:format("gen srv: lock connection ... some other result: ~p~n", [Other]),
			{reply, Other, State}
	end;
handle_call({pass_connection, Connection}, _From, State) ->
	{Result, State1} = pass_on_or_queue_as_available(State, Connection, State#state.waiting),
	{reply, Result, State1};

handle_call({replace_connection_as_available, OldConn, NewConn}, _From, State) ->
	%% if an error occurs while doing work over a connection then
	%% the connection must be closed and a new one created in its
	%% place. The calling process is responsible for creating the
	%% new connection, closing the old one and replacing it in state.
	%% This function expects a new, available connection to be
	%% passed in to serve as the replacement for the old one.
	%% But i.e. if the sql server is down, it can be fed a dead
	%% old connection as new connection, to preserve the pool size.
	case find_pool(OldConn#connection.pool_id, State#state.pools, []) of
		{Pool, OtherPools} ->
			Pool1 = Pool#pool{
				available = queue:in(NewConn, Pool#pool.available),
				locked = gb_trees:delete_any(OldConn#connection.id, Pool#pool.locked)
			},
			{reply, ok, State#state{pools=[Pool1|OtherPools]}};
		undefined ->
			{reply, {error, pool_not_found}, State}
	end;

handle_call({replace_connection_as_locked, OldConn, NewConn}, _From, State) ->
	%% replace an existing, locked condition with the newly supplied one
	%% and keep it in the locked list so that the caller can continue to use it
	%% without having to lock another connection.
	case find_pool(OldConn#connection.pool_id, State#state.pools, []) of
		{Pool, OtherPools} ->
            LockedStripped = gb_trees:delete_any(OldConn#connection.id, Pool#pool.locked),
            LockedAdded = gb_trees:enter(NewConn#connection.id, NewConn, LockedStripped),
		    Pool1 = Pool#pool{locked = LockedAdded},
			{reply, ok, State#state{pools=[Pool1|OtherPools]}};
		undefined ->
			{reply, {error, pool_not_found}, State}
	end;
handle_call(_, _From, State) -> {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
open_connections(Pool) ->
	case (queue:len(Pool#pool.available) + gb_trees:size(Pool#pool.locked)) < Pool#pool.size of
		true ->
			Conn = open_connection(Pool),
			open_connections(Pool#pool{available = queue:in(Conn, Pool#pool.available)});
		false ->
			Pool
	end.
	
open_connection(Pool) ->
	case riakc_pb_socket:start_link(Pool#pool.host, Pool#pool.port, Pool#pool.opts) of
		{ok, Pid} ->
			{M, S, _} = now(),
			Conn = #connection {
				id = erlang:pid_to_list(Pid),
				pool_id = Pool#pool.pool_id,
				pid = Pid,
				spawn_time = (M * 1000000) + S
			},
			Conn;
		{error, E} ->
			exit({failed_to_connect, E})
	end.
	
open_n_connections(PoolId, N) ->
	%-% io:format("open ~p connections for pool ~p~n", [N, PoolId]),
	case find_pool(PoolId, pools(), []) of
		{Pool, _} ->
			[open_connection(Pool) || _ <- lists:seq(1, N)];
		_ ->
			exit(pool_not_found)
	end.
	
close_connection(Conn) ->
	riakc_pb_socket:stop(Conn#connection.pid),
	ok.
	 
initialize_pools() ->
	[
		#pool{
			pool_id = pool_id(Host, Port),
			size = Size,
			host = Host,
			port = Port,
			opts = Opts
		} || {Host, Port, Size, Opts} <- riakpool_app:get_env(conns, [{"127.0.0.1", 8087, 1, []}])
	].

to_binary(V) when is_binary(V) ->
	V;
to_binary(V) when is_list(V) ->
	list_to_binary(V);
to_binary(V) when is_integer(V) ->
	to_binary(integer_to_list(V));
to_binary(V) when is_atom(V) ->
	atom_to_binary(V, utf8);
to_binary(V) when is_tuple(V) ->
	to_binary(tuple_to_list(V)).

pool_id(Host, Port) ->
	H = to_binary(Host),
	P = to_binary(Port),
	pool_id(<<H/binary, P/binary>>).
pool_id(Key) ->
	<<Id:128/big-unsigned-integer>> = crypto:md5(Key),
	list_to_atom(lists:flatten(io_lib:format("~32.16.0b", [Id]))).

find_pool(_, [], _) -> undefined;

find_pool(PoolId, [#pool{pool_id = PoolId} = Pool|Tail], OtherPools) ->
	{Pool, lists:append(OtherPools, Tail)};

find_pool(PoolId, [Pool|Tail], OtherPools) ->
	find_pool(PoolId, Tail, [Pool|OtherPools]).

find_next_connection_in_pool(Pools, PoolId) ->
	case find_pool(PoolId, Pools, []) of
		{Pool, OtherPools} ->
		    % check no of connection in Pool
		    %-% io:format("~p Pool ~p Connections available: ~p~n", [self(), PoolId, queue:len(Pool#pool.available)]),
		    %-% io:format("~p Pool ~p Connections locked: ~p~n", [self(), PoolId, gb_trees:size(Pool#pool.locked)]),
			case queue:out(Pool#pool.available) of
				{{value, Conn}, OtherConns} ->
					[Pool, OtherPools, Conn, OtherConns];
				{empty, _} ->
					unavailable
			end;
		undefined ->
			{error, pool_not_found}
	end.

%% This function does not wait, but may loop over the queue.
pass_on_or_queue_as_available(State, Connection, Waiting) ->
	%% check if any processes are waiting for a connection
	case queue:is_empty(Waiting) of
		true ->
			%% if no processes are waiting then unlock the connection
			case find_pool(Connection#connection.pool_id, State#state.pools, []) of
				{Pool, OtherPools} ->
					%% find connection in locked tree
					case gb_trees:lookup(Connection#connection.id, Pool#pool.locked) of
						{value, Conn} ->
					    %%%
							%% add it to the available queue and remove from locked tree
							Pool1 = Pool#pool{
								available = queue:in(Conn#connection{locked_at=undefined}, Pool#pool.available),
								locked = gb_trees:delete_any(Connection#connection.id, Pool#pool.locked)
							},
							{ok, State#state{pools = [Pool1|OtherPools]}};
						%%%
						none ->
							{{error, connection_not_found}, State}
					end;
				undefined ->
					{{error, pool_not_found}, State}
			end;
		false ->
			%% if the waiting queue is not empty then remove the head of
			%% the queue and check if that process is still waiting
			%% for a connection. If so, send the connection. Regardless,
			%% update the queue in state once the head has been removed.
			{{value, Pid}, Waiting1} = queue:out(Waiting),
			case erlang:process_info(Pid, current_function) of
				{current_function,{riakpool_conn_mgr,wait_for_connection,1}} ->
					erlang:send(Pid, {connection, Connection}),
					{ok, State#state{waiting = Waiting1}};
				_ ->
				    % loop, to traverse queue to find a sane candidate, until empty.
					pass_on_or_queue_as_available(State, Connection, Waiting1)
			end
	end.

lock_timeout() ->
	riakpool_app:get_env(lock_timeout, ?LOCK_TIMEOUT).
