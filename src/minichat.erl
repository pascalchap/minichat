% @doc A simple, one file chat system working on an Erlang cluster
-module (minichat).

% server interfaces
-export ([start_server/0,register_me/2,where_is/1,get_state/0,stop_server/0]).

% user interfaces
-export ([start_user/1,start_user/2]).

% server "private"
-export ([server_init/0]).

% user "private"
-export ([user_init/1,listen_loop/0]).

% doc generation
-export ([gendoc/0]).

%%%%%%%%%%%%%
% Name server
%%%%%%%%%%%%%

-record (user, {name :: string(),pid :: pid(), monitor :: reference()}).

-type user() :: #user{name :: string(), pid :: pid(), monitor :: reference()}.
-type connected_user_list() :: [{string(), pid()}].

% Interfaces

% @doc Start the "name server".
% This function must be executed prior to any other one on the server node.
% It is in charge of keeping a list of all the connected users.
% Each user info is stored in a record containing its name, the pid of the user listen loop
% and a monitor reference used to manage the death or deconnection of the users.
-spec start_server() -> pid().  
start_server() ->
	spawn(?MODULE,server_init,[]).

% @doc Register a user and its listen loop pid.
% This function is an interface provided to the user in order to register its name and the pid of its listen loop.
% Doing so, he allows other users to get its liten loop pid which will be used later for communication.
% The Name must be unique.
%
% <em> Note the this function, as all other server interfaces, uses global:send/2 to send messages to the server rthar than the operator !.
% It is because the server is registered "globally" in order to "find" it easily from any node of the cluster. On the other hand, in
% the rest of the code, we can use the operator ! since we know the pid of the processes we want to reach.</em>
% 
-spec register_me(Name :: string() | atom(), Pid :: pid()) -> ok | {error,already_exist}.
register_me(Name,Pid) when is_atom(Name) ->
	register_me(atom_to_list(Name),Pid);
register_me(Name,Pid) ->
	global:send(minichat_server,{register,string:strip(Name,both),Pid,self()}),
	receive
		R -> R
	end.

% @doc Find the user listen loop pid of a given user name.
% This function is an interface provided to the user in order to retreive the listen loop pid of a given user.
-spec where_is(Name :: string()) -> {ok,pid()} | {error,not_registered}.
where_is(Name) ->
	global:send(minichat_server,{where_is,Name,self()}),
	receive
		R -> R
	end.
% @doc Get the user record list from the server.
% This function is an interface provided to the user to get the list of all connected users.
-spec get_state() -> [user()].
get_state() ->
	global:send(minichat_server,{get_state,self()}),
	receive
		R -> R
	end.

% @doc Stop the server.
% @spec stop_server() -> pid()
stop_server() ->
	global:send(minichat_server,stop).


% server

% @doc Server initialization.
% This fuction is exported to allow the usage of spwan/3 to start the server process.
% It register the server with the name 'minichat_server' using the global module.
% Thus the registration is available for all the nodes of the cluster.
%
% Then it calls the server_loop with an empty list of users as initial state.
-spec server_init() -> ok.
server_init() ->
	global:register_name(minichat_server,self()),
	server_loop([]).

% @doc <em>Private</em> Server loop.
% This function is in charge to manage the incomming messages to the server.
% It maintains a list of user records who are connected to the chat system.
% It add the new users, monitor their processes and remove them from the list when the user process dies.
% It ignores any unexpected (badly formatted) message.
-spec server_loop([user()]) -> ok.
server_loop(Users) ->
	receive
		{register,Name,Pid,From} ->
			server_loop(do_register(Users,Name,Pid,From));
		{where_is,Name,From} ->
			search(Users,Name,From),
			server_loop(Users);
		{'DOWN', MonitorRef, process, _Pid, _Reason} ->
			server_loop(unregister(MonitorRef,Users));
		{get_state,From} ->
			From ! Users,
			server_loop(Users);
		stop ->
			ok;
		_ -> % ignore other messages
			server_loop(Users)
	end.

% helpers

% @doc <em>Private</em> Function to register a new user.
% Check if the Name of the registering user is not already in use,
% <li> if not, start to monitor the user process (send loop) and add the user record to the existing list and send back the message ok.</li>
% <li> if yes send back an error message.</li>
% 
% Note that the pid used for the communication is the is the user send loop, the one which is waiting for an answer,
% while the pid stored in the user record is the listen loop's one which will used by other users to send messages.
-spec do_register(Users :: [user()], Name :: string(), Pid :: pid(), From :: pid()) -> ok | {error,already_exist}.
do_register(Users,Name,Pid,From) ->
	case lists:filter(fun(X) -> X#user.name == Name end, Users) of
		[] -> % OK Name is not registered yet
			From ! ok,
			MonitorRef = erlang:monitor(process,From),
			[#user{name = Name, pid = Pid, monitor = MonitorRef} | Users];
		_ -> % cannot register, Name already exists
			From ! {error,already_exist},
			Users
	end.

% @doc <em>Private</em> Function to un-register a user whose process died.
-spec unregister(MonitorRef :: reference(), Users :: [user()]) -> [user()].
unregister(MonitorRef,Users) ->
	[User] = lists:filter(fun(X) -> X#user.monitor == MonitorRef end, Users),
	lists:delete(User,Users).

% @doc <em>Private</em> Get the user listen loop pid given his name.
-spec search(Users :: [user()], Name :: string(), From :: pid()) -> {ok,pid()} | {error,not_registered} .
search(Users,Name,From) ->
	case lists:filter(fun(X) -> X#user.name == Name end, Users) of
		[] -> % error, can't find Name
			From ! {error,not_registered};
		[User] -> 
			From ! {ok,User#user.pid}
	end.


%%%%%%%%%%%%%%%%
% User processes
%%%%%%%%%%%%%%%%

% Interfaces

% @doc Start the user process with a default server node.
% The node server is defined as 'server@127.0.0.1'. Convenient to make the test without getting annoyed by the firewall configuration.
-spec start_user(Name :: string()) -> pid().
start_user(Name) ->
	start_user(Name,'server@127.0.0.1').

% @doc Start the user process with given server node.
% the function connects the local node to the server node and waits for the node synchronization before spawning the user process.
% It is important since the first job that the user process will perform is to register itself to the server.
-spec start_user(Name :: string(), ServerNode :: atom()) -> pid().
start_user(Name,ServerNode) ->
    net_kernel:connect_node(ServerNode),
    global:sync(),
	spawn(?MODULE,user_init,[Name]).

% User processes

% @doc Initialize the user processes.
% First, it starts the listen loop, an then it registers itself to the server.
% <li> if it works, call the send loop. At this point the user is made of 2 processes linked together : the send and the listen loops. If any
% of them dies, the other will die also. When the user closes its process (normal termination) the code must take care to ends both processes.</li>
% <li> if it fails, stop the listen loop and return an error message.</li>
-spec user_init(Name :: string()) -> ok | {error,already_exist}.
user_init(Name) ->
	% start a new process to receive messages
	Me = spawn_link(?MODULE,listen_loop,[]),
	case register_me(Name,Me) of
		ok -> % call the loop to send messages
			send_loop(Name,Me,[]);
		{error,already_exist} -> 
			Me ! stop, % clean
			io:format("~p already exists~n",[Name])
	end.

% @doc Listen loop.
% A simple receive bloc listening any message.
% <li> If it is a well formed message from another user, it prints to the shell the date an time, the emitter name and then the message text.
% Then it aknowledges the message</li>
% <li> If it is the stop message, it ends the loop.</li>
% <li> It ignores all other messages, simply removing them from the mailbox.</li>
% The listening activity run in a separate process, so it is always available to display incoming messages, independently of the writting activity
% of the user. Nevertheless both processes share the shell panel to display their results, The basic test I made worked correctly, even if an incomming
% message is displayed while the user is writting.
-spec listen_loop() -> ok.
listen_loop() ->
	receive
		{From,Name,Message} ->
			io:format("~p : from ~s -> ~s",[erlang:localtime(),Name,Message]),
			From ! message_received,
			listen_loop();
		stop -> ok;
		_ -> listen_loop()
	end.

% @doc <em>Private</em> Send loop.
% The main user process is in charge to get the input from the user , analyze it and make an action accordingly. 3 messages are supported, the other ones are ignored:
% <li> "bye" : leave the chat</li>
% <li> "who" : get a list of the reachable users</li>
% <li> "Recipient : Text" : to send the message "Text" to the user "Recipient" Recipient is any string that do not contain a : character. So a user who have chosen the name
% "Smart:Joe" is not reachable while "Smart Joe" is correct.</li>
% 
% The sending loop stores 3 information:
% <li> Name : The user name is used to tag the messages so the recipent will know who wrote each of the received messages.</li>
% <li> Me : the pid of the listen loop, in order to stop it whe the user leaves the chat. As far as the listen loop is linked to the send loop, it was also possible to
% exit the prcess using a reason different than normal, but I don't like to use error mechanism for a normal behavior.</li>
% <li> Connected : a list of pair {Name,Pid} to avoid permanent accesses to the server to solve the Recipient address. A consequence is that if one user is disconnected
% for a while, the first message won't be delivered (The system don't propagate the user disparition).</li>
% Sending the message needs some steps, the execution is delegate to the helper function send message who is in charge to send the message if possible and update the pair
% list of [user,pid].
-spec send_loop(Name :: string(), Me :: pid(), Connected :: connected_user_list()) -> ok.
send_loop(Name,Me,Connected) ->
	timer:sleep(500),
	Input = io:get_line("--> "),
	case Input of
		"bye\n" ->
			Me ! stop,
			io:format("Disconnected~n");
		"who\n" ->
			show_people(Connected),
			send_loop(Name,Me,Connected);
		Message ->
			send_loop(Name,Me,send_message(Message,Name,Connected))
	end.

% helpers

% @doc <em>Private</em> First step of the send message operation responsible to extract the Recipent name from the user input.
-spec send_message(Message :: string(), Sender :: string(), Connected :: connected_user_list()) -> connected_user_list().
send_message(Message,Sender,Connected) ->
	{Recipient,Text} = split(Message),
	case Recipient of
		error ->
			io:format("bad formatted message, valid entries are~n\tbye~n\twho~n\tRecipient : Text~n"),
			Connected;
		Recipient ->
			send_message(Recipient,Text,Sender,Connected)
	end.

% @doc <em>Private</em> Second step of the send message operation responsible to retreive the Recipient listen loop.
% If the Recipent is not connected yet to this user, it requests its pid to the server and adds it to the connected list
-spec send_message(Recipient :: string(), Text :: string(), Sender :: string(), Connected :: connected_user_list()) -> connected_user_list().
send_message(Recipient,Text,Sender,Connected) ->
	case lists:filter(fun({Name,_}) -> Name == Recipient end, Connected) of
		[{_,To}] ->
			do_send(To,Text,Sender,Connected);
		[] -> 
			case where_is(Recipient) of
				{ok,To} ->
					do_send(To,Text,Sender,[{Recipient,To}|Connected]);
				{error,not_registered} ->
					io:format("##### not delivered, ~p not registered #####~n",[Recipient]),
					Connected
			end
	end.
					
% @doc <em>Private</em> Last step of the send message operation responsible to send the message.
% If the message is not acknowledged within 2 seconds, it removes the recipein from the connected user list.
-spec do_send(To :: pid(), Text :: string(), Sender :: string(), Connected :: connected_user_list()) -> connected_user_list().
do_send(To,Text,Sender,Connected) ->
	To ! {self(),Sender,Text},
	receive
		message_received -> Connected
	after 2000 ->
		io:format("##### message not acknowledged #####~n"),
		lists:filter(fun({_,Pid}) -> Pid =/= To end, Connected)
	end.

% @doc <em>Private</em> Extract the Recipient name from a string.
% It first splits the string into pieces using the charater : as separator. Then it constructs a tuple made of the first token (without leading and trailing blanks)
% and the rest of the input string (if there were multiple : charaters, the message is rebuilt).
-spec split(Message :: string()) -> {string(), string()} | {error, string()}.
split(Message) ->
	case string:tokens(Message,":") of
		[_] -> {error,Message};
		[H|T] -> {string:strip(H,both), string:join(T,":")}
	end.

% @doc <em>Private</em> Request the list of the registered users.
% When the list is received, the function extract all the names and check if they are in the connected list and print the information accordingly.
-spec show_people(Connected :: connected_user_list()) -> ok.
show_people(Connected) ->
	List = get_state(),
	F = fun(X) ->
			case lists:filter(fun({Y,_}) -> Y == X#user.name end, Connected) of
				[] -> io:format("\t~s~n",[X#user.name]);
				_  -> io:format("\t~s (connected)~n",[X#user.name])
			end
		end,
	lists:foreach(F,List).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% doc generation, just because I am too leazy to remember and type the command :o)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% @doc Generate the documentation
-spec gendoc() -> ok.
gendoc() ->
	edoc:run(["src/minichat.erl"],[{dir,"doc"},{private, true},{sort_functions,false}]).

