%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ Federation.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_federation_exchange_test).

-include("rabbit_federation.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-import(rabbit_misc, [pget/2]).
-import(rabbit_federation_util, [name/1]).

-import(rabbit_federation_test_util,
        [expect/3, expect_empty/2, set_param/3, clear_param/2,
         set_pol/3, clear_pol/1, plugin_dir/0, policy/1,
         start_other_node/1, start_other_node/2, start_other_node/3]).

-define(UPSTREAM_DOWNSTREAM, [x(<<"upstream">>),
                              x(<<"fed.downstream">>)]).

%% Used everywhere
-define(RABBIT,     {"rabbit-test",       5672}).

%% Used in restart_upstream_test
-define(HARE,       {"hare",       5673}).

%% Used in max_hops_test
-define(FLOPSY,     {"flopsy",     5674}).
-define(MOPSY,      {"mopsy",      5675}).
-define(COTTONTAIL, {"cottontail", 5676}).

%% Used in binding_propagation_test
-define(DYLAN,   {"dylan",   5674}).
-define(BUGS,    {"bugs",    5675}).
-define(JESSICA, {"jessica", 5676}).

%% Used in cycle_detection_test
-define(CYCLE1,   {"cycle1", 5674}).
-define(CYCLE2,   {"cycle2", 5675}).

simple_test() ->
    with_ch(
      fun (Ch) ->
              Q = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              await_binding(<<"upstream">>, <<"key">>),
              publish_expect(Ch, <<"upstream">>, <<"key">>, Q, <<"HELLO">>)
      end, ?UPSTREAM_DOWNSTREAM).

multiple_upstreams_test() ->
    with_ch(
      fun (Ch) ->
              Q = bind_queue(Ch, <<"fed12.downstream">>, <<"key">>),
              await_binding(<<"upstream">>, <<"key">>),
              await_binding(<<"upstream2">>, <<"key">>),
              publish_expect(Ch, <<"upstream">>, <<"key">>, Q, <<"HELLO1">>),
              publish_expect(Ch, <<"upstream2">>, <<"key">>, Q, <<"HELLO2">>)
      end, [x(<<"upstream">>),
            x(<<"upstream2">>),
            x(<<"fed12.downstream">>)]).

multiple_uris_test() ->
    %% We can't use a direct connection for Kill() to work.
    set_param("federation-upstream", "localhost",
              "{\"uri\": [\"amqp://localhost\", \"amqp://localhost:5672\"]}"),
    WithCh = fun(F) ->
                     {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
                     {ok, Ch} = amqp_connection:open_channel(Conn),
                     F(Ch),
                     amqp_connection:close(Conn)
             end,
    WithCh(fun (Ch) -> declare_all(Ch, ?UPSTREAM_DOWNSTREAM) end),
    expect_uris([<<"amqp://localhost">>, <<"amqp://localhost:5672">>]),
    WithCh(fun (Ch) -> delete_all(Ch, ?UPSTREAM_DOWNSTREAM) end),
    %% Put back how it was
    set_param("federation-upstream", "localhost", "{\"uri\": \"amqp://\"}").

expect_uris([])   -> ok;
expect_uris(URIs) -> [Link] = rabbit_federation_status:status(),
                     URI = pget(uri, Link),
                     kill_only_connection(n("rabbit-test")),
                     expect_uris(URIs -- [URI]).

kill_only_connection(Node) ->
    case connection_pids(Node) of
        [Pid] -> catch rabbit_networking:close_connection(Pid, "boom"), %% [1]
                 wait_for_pid_to_die(Node, Pid);
        _     -> timer:sleep(100),
                 kill_only_connection(Node)
    end.

%% [1] the catch is because we could still see a connection from a
%% previous time round. If so that's fine (we'll just loop around
%% again) but we don't want the test to fail because a connection
%% closed as we were trying to close it.

wait_for_pid_to_die(Node, Pid) ->
    case connection_pids(Node) of
        [Pid] -> timer:sleep(100),
                 wait_for_pid_to_die(Node, Pid);
        _     -> ok
    end.


multiple_downstreams_test() ->
    with_ch(
      fun (Ch) ->
              Q1 = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              Q12 = bind_queue(Ch, <<"fed12.downstream2">>, <<"key">>),
              await_binding(<<"upstream">>, <<"key">>, 2),
              await_binding(<<"upstream2">>, <<"key">>),
              publish(Ch, <<"upstream">>, <<"key">>, <<"HELLO1">>),
              publish(Ch, <<"upstream2">>, <<"key">>, <<"HELLO2">>),
              expect(Ch, Q1, [<<"HELLO1">>]),
              expect(Ch, Q12, [<<"HELLO1">>, <<"HELLO2">>])
      end, ?UPSTREAM_DOWNSTREAM ++
          [x(<<"upstream2">>),
           x(<<"fed12.downstream2">>)]).

e2e_test() ->
    with_ch(
      fun (Ch) ->
              bind_exchange(Ch, <<"downstream2">>, <<"fed.downstream">>,
                            <<"key">>),
              await_binding(<<"upstream">>, <<"key">>),
              Q = bind_queue(Ch, <<"downstream2">>, <<"key">>),
              publish_expect(Ch, <<"upstream">>, <<"key">>, Q, <<"HELLO1">>)
      end, ?UPSTREAM_DOWNSTREAM ++ [x(<<"downstream2">>)]).

unbind_on_delete_test() ->
    with_ch(
      fun (Ch) ->
              Q1 = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              Q2 = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              await_binding(<<"upstream">>, <<"key">>),
              delete_queue(Ch, Q2),
              publish_expect(Ch, <<"upstream">>, <<"key">>, Q1, <<"HELLO">>)
      end, ?UPSTREAM_DOWNSTREAM).

unbind_on_unbind_test() ->
    with_ch(
      fun (Ch) ->
              Q1 = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              Q2 = bind_queue(Ch, <<"fed.downstream">>, <<"key">>),
              await_binding(<<"upstream">>, <<"key">>),
              unbind_queue(Ch, Q2, <<"fed.downstream">>, <<"key">>),
              publish_expect(Ch, <<"upstream">>, <<"key">>, Q1, <<"HELLO">>),
              delete_queue(Ch, Q2)
      end, ?UPSTREAM_DOWNSTREAM).

user_id_test() ->
    with_ch(
      fun (Ch) ->
              stop_other_node(?HARE),
              start_other_node(?HARE),
              {ok, Conn2} = amqp_connection:start(
                              #amqp_params_network{username = <<"hare-user">>,
                                                   password = <<"hare-user">>,
                                                   port     = 5673}),
              {ok, Ch2} = amqp_connection:open_channel(Conn2),
              declare_exchange(Ch2, x(<<"upstream">>)),
              declare_exchange(Ch, x(<<"hare.downstream">>)),
              Q = bind_queue(Ch, <<"hare.downstream">>, <<"key">>),
              await_binding(?HARE, <<"upstream">>, <<"key">>),

              Msg = #amqp_msg{props   = #'P_basic'{user_id = <<"hare-user">>},
                              payload = <<"HELLO">>},

              SafeUri = fun (H) ->
                                {array, [{table, Recv}]} =
                                    rabbit_misc:table_lookup(
                                      H, <<"x-received-from">>),
                                ?assertEqual(
                                   {longstr, <<"amqp://localhost:5673">>},
                                   rabbit_misc:table_lookup(Recv, <<"uri">>))
                        end,
              ExpectUser =
                  fun (ExpUser) ->
                          fun () ->
                                  receive
                                      {#'basic.deliver'{},
                                       #amqp_msg{props   = Props,
                                                 payload = Payload}} ->
                                          #'P_basic'{user_id = ActUser,
                                                     headers = Headers} = Props,
                                          SafeUri(Headers),
                                          ?assertEqual(<<"HELLO">>, Payload),
                                          ?assertEqual(ExpUser, ActUser)
                                  end
                          end
                  end,

              publish(Ch2, <<"upstream">>, <<"key">>, Msg),
              expect(Ch, Q, ExpectUser(undefined)),

              set_param("federation-upstream", "local5673",
                        "{\"uri\": \"amqp://localhost:5673\","
                        " \"trust-user-id\": true}"),

              publish(Ch2, <<"upstream">>, <<"key">>, Msg),
              expect(Ch, Q, ExpectUser(<<"hare-user">>)),

              delete_exchange(Ch, <<"hare.downstream">>),
              delete_exchange(Ch2, <<"upstream">>)
      end, []).

%% In order to test that unbinds get sent we deliberately set up a
%% broken config - with topic upstream and fanout downstream. You
%% shouldn't really do this, but it lets us see "extra" messages that
%% get sent.
unbind_gets_transmitted_test() ->
    with_ch(
      fun (Ch) ->
              Q11 = bind_queue(Ch, <<"fed.downstream">>, <<"key1">>),
              Q12 = bind_queue(Ch, <<"fed.downstream">>, <<"key1">>),
              Q21 = bind_queue(Ch, <<"fed.downstream">>, <<"key2">>),
              Q22 = bind_queue(Ch, <<"fed.downstream">>, <<"key2">>),
              await_binding(<<"upstream">>, <<"key1">>),
              await_binding(<<"upstream">>, <<"key2">>),
              [delete_queue(Ch, Q) || Q <- [Q12, Q21, Q22]],
              publish(Ch, <<"upstream">>, <<"key1">>, <<"YES">>),
              publish(Ch, <<"upstream">>, <<"key2">>, <<"NO">>),
              expect(Ch, Q11, [<<"YES">>]),
              expect_empty(Ch, Q11)
      end, [x(<<"upstream">>),
            x(<<"fed.downstream">>)]).

no_loop_test() ->
    with_ch(
      fun (Ch) ->
              Q1 = bind_queue(Ch, <<"one">>, <<"key">>),
              Q2 = bind_queue(Ch, <<"two">>, <<"key">>),
              await_binding(<<"one">>, <<"key">>, 2),
              await_binding(<<"two">>, <<"key">>, 2),
              publish(Ch, <<"one">>, <<"key">>, <<"Hello from one">>),
              publish(Ch, <<"two">>, <<"key">>, <<"Hello from two">>),
              expect(Ch, Q1, [<<"Hello from one">>, <<"Hello from two">>]),
              expect(Ch, Q2, [<<"Hello from one">>, <<"Hello from two">>]),
              expect_empty(Ch, Q1),
              expect_empty(Ch, Q2)
      end, [x(<<"one">>),
            x(<<"two">>)]).

binding_recovery_test() ->
    Q = <<"durable-Q">>,

    stop_other_node(?HARE),
    Ch = start_other_node(?HARE, "hare-two-upstreams"),

    declare_all(Ch, [x(<<"upstream2">>) | ?UPSTREAM_DOWNSTREAM]),
    #'queue.declare_ok'{} =
        amqp_channel:call(Ch, #'queue.declare'{queue   = Q,
                                               durable = true}),
    bind_queue(Ch, Q, <<"fed.downstream">>, <<"key">>),
    timer:sleep(100), %% To get the suffix written

    %% i.e. don't clean up
    rabbit_federation_test_util:stop_other_node(?HARE),
    start_other_node(?HARE, "hare-two-upstreams"),

    ?assert(none =/= suffix(?HARE, "upstream")),
    ?assert(none =/= suffix(?HARE, "upstream2")),

    %% again don't clean up
    rabbit_federation_test_util:stop_other_node(?HARE),

    Ch2 = start_other_node(?HARE),

    publish_expect(Ch2, <<"upstream">>, <<"key">>, Q, <<"HELLO">>),
    ?assert(none =/= suffix(?HARE, "upstream")),
    ?assertEqual(none, suffix(?HARE, "upstream2")),
    delete_all(Ch2, [x(<<"upstream2">>) | ?UPSTREAM_DOWNSTREAM]),
    delete_queue(Ch2, Q),
    ok.

suffix({Nodename, _}, XName) ->
    rpc:call(n(Nodename), rabbit_federation_db, get_active_suffix,
             [r(<<"fed.downstream">>),
              #upstream{name          = list_to_binary(Nodename),
                        exchange_name = list_to_binary(XName)}, none]).

n(Nodename) ->
    {_, NodeHost} = rabbit_nodes:parts(node()),
    rabbit_nodes:make({Nodename, NodeHost}).

%% Downstream: rabbit-test, port 5672
%% Upstream:   hare,        port 5673

restart_upstream_test() ->
    with_ch(
      fun (Downstream) ->
              stop_other_node(?HARE),
              Upstream = start_other_node(?HARE),

              declare_exchange(Upstream, x(<<"upstream">>)),
              declare_exchange(Downstream, x(<<"hare.downstream">>)),

              Qstays = bind_queue(
                         Downstream, <<"hare.downstream">>, <<"stays">>),
              Qgoes = bind_queue(
                        Downstream, <<"hare.downstream">>, <<"goes">>),
              stop_other_node(?HARE),
              Qcomes = bind_queue(
                         Downstream, <<"hare.downstream">>, <<"comes">>),
              unbind_queue(
                Downstream, Qgoes, <<"hare.downstream">>, <<"goes">>),
              Upstream1 = start_other_node(?HARE),

              %% Wait for the link to come up and for these bindings
              %% to be transferred
              await_binding(?HARE, <<"upstream">>, <<"comes">>, 1),
              await_binding_absent(?HARE, <<"upstream">>, <<"goes">>),
              await_binding(?HARE, <<"upstream">>, <<"stays">>, 1),

              publish(Upstream1, <<"upstream">>, <<"goes">>, <<"GOES">>),
              publish(Upstream1, <<"upstream">>, <<"stays">>, <<"STAYS">>),
              publish(Upstream1, <<"upstream">>, <<"comes">>, <<"COMES">>),

              expect(Downstream, Qstays, [<<"STAYS">>]),
              expect(Downstream, Qcomes, [<<"COMES">>]),
              expect_empty(Downstream, Qgoes),

              delete_exchange(Downstream, <<"hare.downstream">>),
              delete_exchange(Upstream1, <<"upstream">>)
      end, []).

%% flopsy, mopsy and cottontail, connected in a ring with max_hops = 2
%% for each connection. We should not see any duplicates.

max_hops_test() ->
    Flopsy     = start_other_node(?FLOPSY),
    Mopsy      = start_other_node(?MOPSY),
    Cottontail = start_other_node(?COTTONTAIL),

    declare_exchange(Flopsy,     x(<<"ring">>)),
    declare_exchange(Mopsy,      x(<<"ring">>)),
    declare_exchange(Cottontail, x(<<"ring">>)),

    Q1 = bind_queue(Flopsy,     <<"ring">>, <<"key">>),
    Q2 = bind_queue(Mopsy,      <<"ring">>, <<"key">>),
    Q3 = bind_queue(Cottontail, <<"ring">>, <<"key">>),

    await_binding(?FLOPSY,     <<"ring">>, <<"key">>, 3),
    await_binding(?MOPSY,      <<"ring">>, <<"key">>, 3),
    await_binding(?COTTONTAIL, <<"ring">>, <<"key">>, 3),

    publish(Flopsy,     <<"ring">>, <<"key">>, <<"HELLO flopsy">>),
    publish(Mopsy,      <<"ring">>, <<"key">>, <<"HELLO mopsy">>),
    publish(Cottontail, <<"ring">>, <<"key">>, <<"HELLO cottontail">>),

    Msgs = [<<"HELLO flopsy">>, <<"HELLO mopsy">>, <<"HELLO cottontail">>],
    expect(Flopsy,     Q1, Msgs),
    expect(Mopsy,      Q2, Msgs),
    expect(Cottontail, Q3, Msgs),
    expect_empty(Flopsy,     Q1),
    expect_empty(Mopsy,      Q2),
    expect_empty(Cottontail, Q3),

    stop_other_node(?FLOPSY),
    stop_other_node(?MOPSY),
    stop_other_node(?COTTONTAIL),
    ok.

%% Two nodes, both federated with each other, and max_hops set to a
%% high value. Things should not get out of hand.
cycle_detection_test() ->
    Cycle1 = start_other_node(?CYCLE1),
    Cycle2 = start_other_node(?CYCLE2),

    declare_exchange(Cycle1, x(<<"cycle">>)),
    declare_exchange(Cycle2, x(<<"cycle">>)),

    Q1 = bind_queue(Cycle1, <<"cycle">>, <<"key">>),
    Q2 = bind_queue(Cycle2, <<"cycle">>, <<"key">>),

    %% "key" present twice because once for the local queue and once
    %% for federation in each case
    await_binding(?CYCLE1, <<"cycle">>, <<"key">>, 2),
    await_binding(?CYCLE2, <<"cycle">>, <<"key">>, 2),

    publish(Cycle1, <<"cycle">>, <<"key">>, <<"HELLO1">>),
    publish(Cycle2, <<"cycle">>, <<"key">>, <<"HELLO2">>),

    Msgs = [<<"HELLO1">>, <<"HELLO2">>],
    expect(Cycle1, Q1, Msgs),
    expect(Cycle2, Q2, Msgs),
    expect_empty(Cycle1, Q1),
    expect_empty(Cycle2, Q2),

    stop_other_node(?CYCLE1),
    stop_other_node(?CYCLE2),
    ok.

%% Arrows indicate message flow. Numbers indicate max_hops.
%%
%% Dylan ---1--> Bugs ---2--> Jessica
%% |^                              |^
%% |\--------------1---------------/|
%% \---------------1----------------/
%%
%%
%% We want to demonstrate that if we bind a queue locally at each
%% broker, (exactly) the following bindings propagate:
%%
%% Bugs binds to Dylan
%% Jessica binds to Bugs, which then propagates on to Dylan
%% Jessica binds to Dylan directly
%% Dylan binds to Jessica.
%%
%% i.e. Dylan has two bindings from Jessica and one from Bugs
%%      Bugs has one binding from Jessica
%%      Jessica has one binding from Dylan
%%
%% So we tag each binding with its original broker and see how far it gets
%%
%% Also we check that when we tear down the original bindings
%% that we get rid of everything again.

binding_propagation_test() ->
    Dylan   = start_other_node(?DYLAN),
    Bugs    = start_other_node(?BUGS),
    Jessica = start_other_node(?JESSICA),

    declare_exchange(Dylan,   x(<<"x">>)),
    declare_exchange(Bugs,    x(<<"x">>)),
    declare_exchange(Jessica, x(<<"x">>)),

    Q1 = bind_queue(Dylan,   <<"x">>, <<"dylan">>),
    Q2 = bind_queue(Bugs,    <<"x">>, <<"bugs">>),
    Q3 = bind_queue(Jessica, <<"x">>, <<"jessica">>),

    await_binding( ?DYLAN,   <<"x">>, <<"jessica">>, 2),
    await_bindings(?DYLAN,   <<"x">>, [<<"bugs">>, <<"dylan">>]),
    await_bindings(?BUGS,    <<"x">>, [<<"jessica">>, <<"bugs">>]),
    await_bindings(?JESSICA, <<"x">>, [<<"dylan">>, <<"jessica">>]),

    delete_queue(Dylan,   Q1),
    delete_queue(Bugs,    Q2),
    delete_queue(Jessica, Q3),

    await_bindings(?DYLAN,   <<"x">>, []),
    await_bindings(?BUGS,    <<"x">>, []),
    await_bindings(?JESSICA, <<"x">>, []),

    stop_other_node(?DYLAN),
    stop_other_node(?BUGS),
    stop_other_node(?JESSICA),
    ok.

upstream_has_no_federation_test() ->
    with_ch(
      fun (Downstream) ->
              stop_other_node(?HARE),
              Upstream = start_other_node(
                           ?HARE, "hare-no-federation", "no_plugins"),
              declare_exchange(Upstream, x(<<"upstream">>)),
              declare_exchange(Downstream, x(<<"hare.downstream">>)),
              Q = bind_queue(Downstream, <<"hare.downstream">>, <<"routing">>),
              await_binding(?HARE, <<"upstream">>, <<"routing">>),
              publish(Upstream, <<"upstream">>, <<"routing">>, <<"HELLO">>),
              expect(Downstream, Q, [<<"HELLO">>]),
              delete_exchange(Downstream, <<"hare.downstream">>),
              delete_exchange(Upstream, <<"upstream">>),
              stop_other_node(?HARE)
      end, []).

dynamic_reconfiguration_test() ->
    with_ch(
      fun (_Ch) ->
              Xs = [<<"all.fed1">>, <<"all.fed2">>],
              %% Left from the conf we set up for previous tests
              assert_connections(Xs, [<<"localhost">>, <<"local5673">>]),

              %% Test that clearing connections works
              clear_param("federation-upstream", "localhost"),
              clear_param("federation-upstream", "local5673"),
              assert_connections(Xs, []),

              %% Test that readding them and changing them works
              set_param("federation-upstream", "localhost",
                        "{\"uri\": \"amqp://localhost\"}"),
              %% Do it twice so we at least hit the no-restart optimisation
              set_param("federation-upstream", "localhost",
                        "{\"uri\": \"amqp://\"}"),
              set_param("federation-upstream", "localhost",
                        "{\"uri\": \"amqp://\"}"),
              assert_connections(Xs, [<<"localhost">>]),

              %% And re-add the last - for next test
              set_param("federation-upstream", "local5673",
                        "{\"uri\": \"amqp://localhost:5673\"}")
      end, [x(<<"all.fed1">>), x(<<"all.fed2">>)]).

dynamic_reconfiguration_integrity_test() ->
    with_ch(
      fun (_Ch) ->
              Xs = [<<"new.fed1">>, <<"new.fed2">>],

              %% Declared exchanges with nonexistent set - no links
              assert_connections(Xs, []),

              %% Create the set - links appear
              set_param("federation-upstream-set", "new-set",
                        "[{\"upstream\": \"localhost\"}]"),
              assert_connections(Xs, [<<"localhost">>]),

              %% Add nonexistent connections to set - nothing breaks
              set_param("federation-upstream-set", "new-set",
                        "[{\"upstream\": \"localhost\"},"
                        " {\"upstream\": \"does-not-exist\"}]"),
              assert_connections(Xs, [<<"localhost">>]),

              %% Change connection in set - links change
              set_param("federation-upstream-set", "new-set",
                        "[{\"upstream\": \"local5673\"}]"),
              assert_connections(Xs, [<<"local5673">>])
      end, [x(<<"new.fed1">>), x(<<"new.fed2">>)]).

federate_unfederate_test() ->
    with_ch(
      fun (_Ch) ->
              Xs = [<<"dyn.exch1">>, <<"dyn.exch2">>],

              %% Declared non-federated exchanges - no links
              assert_connections(Xs, []),

              %% Federate them - links appear
              set_pol("dyn", "^dyn\\.", policy("all")),
              assert_connections(Xs, [<<"localhost">>, <<"local5673">>]),

              %% Change policy - links change
              set_pol("dyn", "^dyn\\.", policy("localhost")),
              assert_connections(Xs, [<<"localhost">>]),

              %% Unfederate them - links disappear
              clear_pol("dyn"),
              assert_connections(Xs, [])
      end, [x(<<"dyn.exch1">>), x(<<"dyn.exch2">>)]).

%%----------------------------------------------------------------------------

with_ch(Fun, Xs) ->
    {ok, Conn} = amqp_connection:start(#amqp_params_network{}),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    declare_all(Ch, Xs),
    rabbit_federation_test_util:assert_status(
      Xs, {exchange, upstream_exchange}),
    Fun(Ch),
    delete_all(Ch, Xs),
    amqp_connection:close(Conn),
    cleanup(?RABBIT),
    ok.

cleanup({Nodename, _}) ->
    [rpc:call(n(Nodename), rabbit_amqqueue, delete, [Q, false, false]) ||
        Q <- queues(Nodename)].

queues(Nodename) ->
    case rpc:call(n(Nodename), rabbit_amqqueue, list, [<<"/">>]) of
        {badrpc, _} -> [];
        Qs          -> Qs
    end.

stop_other_node(Node) ->
    cleanup(Node),
    rabbit_federation_test_util:stop_other_node(Node).

declare_all(Ch, Xs) -> [declare_exchange(Ch, X) || X <- Xs].
delete_all(Ch, Xs) ->
    [delete_exchange(Ch, X) || #'exchange.declare'{exchange = X} <- Xs].

declare_exchange(Ch, X) ->
    amqp_channel:call(Ch, X).

x(Name) -> x(Name, <<"topic">>).

x(Name, Type) ->
    #'exchange.declare'{exchange = Name,
                        type     = Type,
                        durable  = true}.

r(Name) -> rabbit_misc:r(<<"/">>, exchange, Name).

declare_queue(Ch) ->
    #'queue.declare_ok'{queue = Q} =
        amqp_channel:call(Ch, #'queue.declare'{exclusive = true}),
    Q.

bind_queue(Ch, Q, X, Key) ->
    amqp_channel:call(Ch, #'queue.bind'{queue       = Q,
                                        exchange    = X,
                                        routing_key = Key}).

unbind_queue(Ch, Q, X, Key) ->
    amqp_channel:call(Ch, #'queue.unbind'{queue       = Q,
                                          exchange    = X,
                                          routing_key = Key}).

bind_exchange(Ch, D, S, Key) ->
    amqp_channel:call(Ch, #'exchange.bind'{destination = D,
                                           source      = S,
                                           routing_key = Key}).

bind_queue(Ch, X, Key) ->
    Q = declare_queue(Ch),
    bind_queue(Ch, Q, X, Key),
    Q.

delete_exchange(Ch, X) ->
    amqp_channel:call(Ch, #'exchange.delete'{exchange = X}).

delete_queue(Ch, Q) ->
    amqp_channel:call(Ch, #'queue.delete'{queue = Q}).

await_binding(X, Key)             -> await_binding(?RABBIT, X, Key, 1).
await_binding(B = {_, _}, X, Key) -> await_binding(B,       X, Key, 1);
await_binding(X, Key, Count)      -> await_binding(?RABBIT, X, Key, Count).

await_binding(Broker = {Nodename, _Port}, X, Key, Count) ->
    case bound_keys_from(Nodename, X, Key) of
        L when length(L) <   Count -> timer:sleep(100),
                                      await_binding(Broker, X, Key, Count);
        L when length(L) =:= Count -> ok;
        L                          -> exit({too_many_bindings,
                                            X, Key, Count, L})
    end.

await_bindings(Broker, X, Keys) ->
    [await_binding(Broker, X, Key) || Key <- Keys].

await_binding_absent(Broker = {Nodename, _Port}, X, Key) ->
    case bound_keys_from(Nodename, X, Key) of
        [] -> ok;
        _  -> timer:sleep(100),
              await_binding_absent(Broker, X, Key)
    end.

bound_keys_from(Nodename, X, Key) ->
    [K || #binding{key = K} <-
              rpc:call(n(Nodename), rabbit_binding, list_for_source, [r(X)]),
          K =:= Key].

publish(Ch, X, Key, Payload) when is_binary(Payload) ->
    publish(Ch, X, Key, #amqp_msg{payload = Payload});

publish(Ch, X, Key, Msg = #amqp_msg{}) ->
    amqp_channel:call(Ch, #'basic.publish'{exchange    = X,
                                           routing_key = Key}, Msg).

publish_expect(Ch, X, Key, Q, Payload) ->
    publish(Ch, X, Key, Payload),
    expect(Ch, Q, [Payload]).

%%----------------------------------------------------------------------------

assert_connections(Xs, Conns) ->
    Links = [{X, C, X} ||
                X <- Xs,
                C <- Conns],
    Remaining = lists:foldl(
                  fun (Link, Status) ->
                          rabbit_federation_test_util:assert_link_status(
                            Link, Status, {exchange, upstream_exchange})
                  end, rabbit_federation_status:status(), Links),
    ?assertEqual([], Remaining),
    ok.

connection_pids(Node) ->
    [P || [{pid, P}] <-
              rpc:call(Node, rabbit_networking, connection_info_all, [[pid]])].
