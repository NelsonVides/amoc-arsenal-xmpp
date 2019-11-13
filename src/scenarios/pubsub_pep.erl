-module(pubsub_pep).

-behavior(amoc_scenario).

-include_lib("exml/include/exml.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("kernel/include/logger.hrl").

-required_variable({'IQ_TIMEOUT',         <<"IQ timeout (milliseconds, def: 10000ms)"/utf8>>}).
-required_variable({'COORDINATOR_DELAY',  <<"Delay after N subscriptions (milliseconds, def: 0ms)"/utf8>>}).
-required_variable({'NODE_CREATION_RATE', <<"Rate of node creations (per minute, def:600)">>}).
-required_variable({'PUBLICATION_SIZE',   <<"Size of additional payload (bytes, def:300)">>}).
-required_variable({'PUBLICATION_RATE',   <<"Rate of publications (per minute, def:1500)">>}).
-required_variable({'N_OF_SUBSCRIBERS',   <<"Number of subscriptions for each node (def: 50)"/utf8>>}).
-required_variable({'ACTIVATION_POLICY',  <<"Publish after subscribtion of (def: all_nodes | n_nodes)"/utf8>>}).
-required_variable({'MIM_HOST',           <<"The virtual host served by the server (def: <<\"localhost\">>)"/utf8>>}).

-define(ALL_PARAMETERS,[
    {iq_timeout,                   10000, positive_integer},
    {coordinator_delay,                0, nonnegative_integer},
    {node_creation_rate,             600, positive_integer},
    {publication_size,               300, nonnegative_integer},
    {publication_rate,              1500, positive_integer},
    {n_of_subscribers,                50, nonnegative_integer},
    {activation_policy,        all_nodes, [all_nodes, n_nodes]},
    {mim_host,           <<"localhost">>, bitstring}
]).

-define(PEP_NODE_NS, <<"just_some_random_namespace">>).
-define(CAPS_HASH, <<"erNmVoMSwRBR4brUU/inYQ5NFr0=">>). %% mod_caps:make_disco_hash(feature_elems(), sha1).
-define(NODE, {pep, ?PEP_NODE_NS}).

-define(GROUP_NAME, <<"pubsub_simple_coordinator">>).
-define(NODE_CREATION_THROTTLING, node_creation).
-define(PUBLICATION_THROTTLING, publication).

-define(COORDINATOR_TIMEOUT, 100).

-export([init/0, start/2]).

-spec init() -> {ok, amoc_scenario:state()} | {error, Reason :: term()}.
init() ->
    init_metrics(),
    case amoc_config:parse_scenario_settings(?ALL_PARAMETERS) of
        {ok, Settings} ->

            {ok, PublicationRate} = amoc_config:get_scenario_parameter(publication_rate, Settings),
            {ok, NodeCreationRate} = amoc_config:get_scenario_parameter(node_creation_rate, Settings),

            amoc_throttle:start(?NODE_CREATION_THROTTLING, NodeCreationRate),
            amoc_throttle:start(?PUBLICATION_THROTTLING, PublicationRate),
            start_coordinator(Settings),
            {ok, Settings};
        Error -> Error
    end.

-spec start(amoc_scenario:user_id(), amoc_scenario:state()) -> any().
start(Id, Settings) ->
    Client = connect_amoc_user(Id, Settings),
    start_user(Client, Settings).

init_metrics() ->
    iq_metrics:start([node_creation, publication]),
    Counters = [message],
    Times = [message_ttd],
    [amoc_metrics:init(counters, Metric) || Metric <- Counters],
    [amoc_metrics:init(times, Metric) || Metric <- Times].


%%------------------------------------------------------------------------------------------------
%% Coordinator
%%------------------------------------------------------------------------------------------------
start_coordinator(Settings) ->
    amoc_coordinator:start(?MODULE, get_coordination_plan(Settings), ?COORDINATOR_TIMEOUT).

get_coordination_plan(Settings) ->
    N = get_no_of_node_subscribers(Settings),

    [{N, [fun make_clients_friends/3,
          users_activation(Settings, n_nodes),
          coordination_delay(Settings)]},
     {all, users_activation(Settings, all_nodes)}].

coordination_delay(Settings) ->
    Delay = get_parameter(coordinator_delay, Settings),
    fun({coordinate, _}) -> timer:sleep(Delay);
        (_) -> ok
    end.

make_clients_friends(_, _, undefined) -> ok;
make_clients_friends(_, {_, C1}, {_, C2}) ->
    send_presence(C1, <<"subscribe">>, C2),
    send_presence(C2, <<"subscribe">>, C1).

users_activation(Settings, ActivationPolicy) ->
    case get_parameter(activation_policy, Settings) of
        ActivationPolicy ->
            fun(_, CoordinationData) ->
                [schedule_publishing(Pid) || {Pid, _} <- CoordinationData]
            end;
        _ -> fun(_) -> ok end
    end.
%%------------------------------------------------------------------------------------------------
%% User
%%------------------------------------------------------------------------------------------------
start_user(Client, Settings) ->
    ?LOG_DEBUG("user process ~p", [self()]),
    create_new_node(Client, Settings),
    erlang:monitor(process, Client#client.rcv_pid),
    escalus_tcp:set_active(Client#client.rcv_pid, true),
    send_presence_with_caps(Client),
    user_loop(Settings, Client).

create_new_node(Client, Settings) ->
    amoc_throttle:send_and_wait(?NODE_CREATION_THROTTLING, create_node),
    create_pubsub_node(Client, Settings),
    amoc_coordinator:add(?MODULE, Client).

user_loop(Settings, Client) ->
    receive
        {stanza, _, #xmlel{name = <<"message">>} = Stanza, #{recv_timestamp := TimeStamp}} ->
            process_msg(Stanza, TimeStamp),
            user_loop(Settings, Client);
        {stanza, _, #xmlel{name = <<"iq">>} = Stanza, _} ->
            process_iq(Client, Stanza),
            user_loop(Settings, Client);
        {stanza, _, #xmlel{name = <<"presence">>} = Stanza, _} ->
            process_presence(Client, Stanza),
            user_loop(Settings, Client);
        publish_item ->
            IqTimeout = get_parameter(iq_timeout, Settings),
            Id = publish_pubsub_item(Client, Settings),
            iq_metrics:request(publication, Id, IqTimeout),
            user_loop(Settings, Client);
        {'DOWN', _, process, Pid, Info} when Pid =:= Client#client.rcv_pid ->
            ?LOG_ERROR("TCP connection process ~p down: ~p", [Pid, Info]);
        Msg ->
            ?LOG_ERROR("unexpected message ~p", [Msg])
    end.

schedule_publishing(Pid) ->
    amoc_throttle:send(?PUBLICATION_THROTTLING, Pid, publish_item).

%%------------------------------------------------------------------------------------------------
%% User connection
%%------------------------------------------------------------------------------------------------
connect_amoc_user(Id, Settings) ->
    ExtraProps = amoc_xmpp:pick_server([[{host, "127.0.0.1"}]]) ++
                 [{server, get_parameter(mim_host, Settings)},
                  {socket_opts, socket_opts()}],

    {ok, Client, _} = amoc_xmpp:connect_or_exit(Id, ExtraProps),
    erlang:put(jid, Client#client.jid),
    Client.

socket_opts() ->
    [binary,
     {reuseaddr, false},
     {nodelay, true}].

%%------------------------------------------------------------------------------------------------
%% Node creation
%%------------------------------------------------------------------------------------------------
create_pubsub_node(Client, Settings) ->
    ReqId = iq_id(create, Client),
    iq_metrics:request(node_creation, ReqId),
    Request = publish_pubsub_stanza(Client, ReqId, #xmlel{name = <<"nothing">>}),
    %Request = escalus_pubsub_stanza:create_node(Client, ReqId, ?NODE),
    escalus:send(Client, Request),

    CreateNodeResult = (catch escalus:wait_for_stanza(Client, get_parameter(iq_timeout, Settings))),

    case {escalus_pred:is_iq_result(Request, CreateNodeResult), CreateNodeResult} of
        {true, _} ->
            ?LOG_DEBUG("node creation ~p (~p)", [?NODE, self()]),
            iq_metrics:response(ReqId, result);
        {false, {'EXIT', {timeout_when_waiting_for_stanza, _}}} ->
            iq_metrics:timeout(ReqId, delete),
            ?LOG_ERROR("Timeout creating node: ~p", [CreateNodeResult]),
            exit(node_creation_timeout);
        {false, _} ->
            iq_metrics:response(ReqId, error),
            ?LOG_ERROR("Error creating node: ~p", [CreateNodeResult]),
            exit(node_creation_failed)
    end.

%%------------------------------------------------------------------------------------------------
%% User presence & caps
%%------------------------------------------------------------------------------------------------
send_presence(From, Type, To = #client{}) ->
    ToJid = escalus_client:short_jid(To),
    send_presence(From, Type, ToJid);
send_presence(From, Type, To) ->
    Presence = escalus_stanza:presence_direct(To, Type),
    escalus_client:send(From, Presence).

send_presence_with_caps(Client) ->
    Presence = escalus_stanza:presence(<<"available">>, [caps()]),
    escalus:send(Client, Presence).

caps() ->
    #xmlel{name = <<"c">>,
           attrs = [{<<"xmlns">>, <<"http://jabber.org/protocol/caps">>},
                    {<<"hash">>, <<"sha-1">>},
                    {<<"node">>, <<"http://www.chatopus.com">>},
                    {<<"ver">>, ?CAPS_HASH}]}.

%%------------------------------------------------------------------------------------------------
%% Item publishing
%%------------------------------------------------------------------------------------------------
publish_pubsub_item(Client, Settings) ->
    Id = iq_id(publish, Client),
    PayloadSize = get_parameter(publication_size, Settings),
    Content = item_content(PayloadSize),
    Request = publish_pubsub_stanza(Client, Id, Content),
    escalus:send(Client, Request),
    Id.

publish_pubsub_stanza(Client, Id, Content) ->
    ItemId = <<"current">>,
    escalus_pubsub_stanza:publish(Client, ItemId, Content, Id, ?NODE).

item_content(PayloadSize) ->
    Payload = #xmlcdata{content = <<<<"A">> || _ <- lists:seq(1, PayloadSize)>>},
    #xmlel{
        name = <<"entry">>,
        attrs = [{<<"timestamp">>, integer_to_binary(os:system_time(microsecond))},
                 {<<"jid">>, erlang:get(jid)}],
        children = [Payload]}.

%%------------------------------------------------------------------------------------------------
%% Item processing
%%------------------------------------------------------------------------------------------------
process_msg(#xmlel{name = <<"message">>} = Stanza, TS) ->
    escalus:assert(is_message, Stanza),
    Entry = exml_query:path(Stanza, [{element, <<"event">>}, {element, <<"items">>},
                                     {element, <<"item">>}, {element, <<"entry">>}]),
    case Entry of
        undefined -> ok;
        _ ->
            case {exml_query:attr(Entry, <<"jid">>), erlang:get(jid)} of
                {JID, JID} -> schedule_publishing(self());
                _ -> ok
            end,
            TimeStampBin = exml_query:attr(Entry, <<"timestamp">>),
            TimeStamp = binary_to_integer(TimeStampBin),
            TTD = TS - TimeStamp,
%%            ?LOG_DEBUG("time to delivery ~p", [TTD]),
            amoc_metrics:update_counter(message),
            amoc_metrics:update_time(message_ttd, TTD)
    end.

process_presence(Client, Stanza) ->
    case exml_query:attr(Stanza, <<"type">>) of
        <<"subscribe">> ->
            From = exml_query:attr(Stanza, <<"from">>),
            send_presence(Client, <<"subscribed">>, From);
        _ ->
            ok %%it's ok to just ignore other presence notifications
    end.

process_iq(Client, #xmlel{name = <<"iq">>} = Stanza) ->
    Id = exml_query:attr(Stanza, <<"id">>),
    Type = exml_query:attr(Stanza, <<"type">>),
    NS = exml_query:path(Stanza, [{element, <<"query">>}, {attr, <<"xmlns">>}]),
    case {Type, NS, Id} of
        {<<"get">>, ?NS_DISCO_INFO, _} ->
            handle_disco_query(Client, Stanza);
        {<<"set">>, ?NS_ROSTER, _} ->
            ok; %%it's ok to just ignore roster pushes
        {_, undefined, <<"publish", _/binary>>} ->
            handle_publish_resp(Stanza,  Id);
        _ ->
            ?LOG_WARNING("unexpected iq ~p", [Stanza])
    end.

handle_publish_resp(PublishResult, Id) ->
    case escalus_pred:is_iq_result(PublishResult) of
        true ->
%%            ?LOG_DEBUG("publish time ~p", [PublishTime]),
            iq_metrics:response(Id, result);
        _ ->
            iq_metrics:response(Id, error),
            ?LOG_ERROR("Error publishing failed: ~p", [PublishResult]),
            exit(publication_failed)
    end.

handle_disco_query(Client, DiscoRequest) ->
    ?LOG_DEBUG("handle_disco_query ~p", [self()]),
    QueryEl = escalus_stanza:query_el(<<"http://jabber.org/protocol/disco#info">>,
                                      feature_elems()),
    DiscoResult = escalus_stanza:iq_result(DiscoRequest, [QueryEl]),
    escalus:send(Client, DiscoResult).

feature_elems() ->
    NodeNs = ?PEP_NODE_NS,
    [#xmlel{name = <<"identity">>,
            attrs = [{<<"category">>, <<"client">>},
                     {<<"name">>, <<"Psi">>},
                     {<<"type">>, <<"pc">>}]},
     #xmlel{name = <<"feature">>,
            attrs = [{<<"var">>, <<"http://jabber.org/protocol/disco#info">>}]},
     #xmlel{name = <<"feature">>,
            attrs = [{<<"var">>, NodeNs}]},
     #xmlel{name = <<"feature">>,
            attrs = [{<<"var">>, <<NodeNs/bitstring, "+notify">>}]}].
%%------------------------------------------------------------------------------------------------
%% Stanza helpers
%%------------------------------------------------------------------------------------------------
iq_id(Type, Client) ->
    UserName = escalus_utils:get_username(Client),
    Suffix = random_suffix(),
    list_to_binary(io_lib:format("~s-~s-~p",
                                 [Type, UserName, Suffix])).

random_suffix() ->
    Suffix = base64:encode(crypto:strong_rand_bytes(5)),
    re:replace(Suffix, "/", "_", [global, {return, binary}]).

%%------------------------------------------------------------------------------------------------
%% Config helpers
%%------------------------------------------------------------------------------------------------
get_parameter(Name, Settings) ->
    case amoc_config:get_scenario_parameter(Name, Settings) of
        {error, Err} ->
            ?LOG_ERROR("amoc_config:get_scenario_parameter/2 failed ~p", [Err]),
            exit(Err);
        {ok, Value} -> Value
    end.

get_no_of_node_subscribers(Settings) ->
    %instead of constant No of subscriptions we can use min/max values.
    get_parameter(n_of_subscribers, Settings).