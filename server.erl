-module(server).

-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.

start_server() ->
    catch(unregister(server)),
    register(server, self()),
    case whereis(testsuite) of
	undefined -> ok;
	TestSuitePID -> TestSuitePID!{server_up, self()}
    end,
    loop(
      #serv_st{
	 nicks = maps:new(), %% nickname map. client_pid => "nickname"
	 registrations = maps:new(), %% registration map. "chat_name" => [client_pids]
	 chatrooms = maps:new() %% chatroom map. "chat_name" => chat_pid
	}
     ).

loop(State) ->
    receive 
	%% initial connection
	{ClientPID, connect, ClientNick} ->
	    NewState =
		#serv_st{
		   nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
		   registrations = State#serv_st.registrations,
		   chatrooms = State#serv_st.chatrooms
		  },
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, join, ChatName} ->
	    NewState = do_join(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to join a chat
	{ClientPID, Ref, leave, ChatName} ->
	    NewState = do_leave(ChatName, ClientPID, Ref, State),
	    loop(NewState);
	%% client requests to register a new nickname
	{ClientPID, Ref, nick, NewNick} ->
	    NewState = do_new_nick(State, Ref, ClientPID, NewNick),
	    loop(NewState);
	%% client requests to quit
	{ClientPID, Ref, quit} ->
	    NewState = do_client_quit(State, Ref, ClientPID),
	    loop(NewState);
	{TEST_PID, get_state} ->
	    TEST_PID!{get_state, State},
	    loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
	case maps:is_key(ChatName, State#serv_st.chatrooms) of
		true ->
			New_state =  State;
		false ->
			New_Room = spawn(chatroom, start_chatroom, [ChatName]),
			New_state = State#serv_st{chatrooms = maps:put(ChatName, New_Room, State#serv_st.chatrooms), registrations = maps:put(ChatName, [], State#serv_st.registrations)}
	end,
	maps:get(ChatName, New_state#serv_st.chatrooms) ! {self(), Ref, register, ClientPID, maps:get(ClientPID, New_state#serv_st.nicks)},
	New_state#serv_st{registrations = maps:put(ChatName, maps:get(ChatName, New_state#serv_st.registrations) ++ [ClientPID], New_state#serv_st.registrations)}.

%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
	New_state = State#serv_st{registrations = maps:put(ChatName, maps:without([ClientPID], State#serv_st.registrations), State#serv_st.registrations)},
	%New_state = State#serv_st{registrations = maps:put(ChatName, lists:delete(ClientPID, maps:get(ChatName, State#serv_st.registrations)), State#serv_st.registrations)},
	maps:get(ChatName, New_state#serv_st.chatrooms) ! {self(), Ref, unregister, ClientPID},
	ClientPID ! {self(), Ref, ack_leave},
	New_state.

%% executes new nickname protocol from server perspective
do_new_nick(State, Ref, ClientPID, NewNick) ->
	case lists:member(NewNick, maps:values(State#serv_st.nicks)) of
		true ->
			ClientPID ! {self(), Ref, err_nick_used},
			State;
		false ->
			New_state = State#serv_st{nicks = maps:put(ClientPID, NewNick, State#serv_st.nicks)},
			Regs = maps:keys(maps:filter(fun (_ChatName, Clients) -> lists:member(ClientPID, Clients) end, New_state#serv_st.registrations)),
			lists:foreach(fun(ChatName) ->
				maps:get(ChatName, New_state#serv_st.chatrooms) ! {self(), Ref, update_nick, ClientPID, NewNick} end , Regs),
			ClientPID ! {self(), Ref, ok_nick},
			New_state
	end.

%% executes client quit protocol from server perspective
do_client_quit(State, Ref, ClientPID) ->
	New_state = State#serv_st{nicks = maps:remove(ClientPID, State#serv_st.nicks)},
	Regs = maps:keys(maps:filter(fun (_ChatName, Clients) -> lists:member(ClientPID, Clients) end, New_state#serv_st.registrations)),
	lists:foreach(fun(ChatName) ->
		maps:get(ChatName, New_state#serv_st.chatrooms) ! {self(), Ref, unregister, ClientPID},
		New_state#serv_st{registrations = maps:put(ChatName, maps:without([ClientPID], New_state#serv_st.registrations), New_state#serv_st.registrations)}
%%		New_state#serv_st{registrations = maps:put(ChatName, lists:delete(ClientPID, maps:get(ChatName, New_state#serv_st.registrations)), New_state#serv_st.registrations)}
		end , Regs),
	ClientPID ! {self(), Ref, ack_quit},
	New_state.