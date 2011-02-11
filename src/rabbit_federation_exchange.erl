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
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

-module(rabbit_federation_exchange).

-rabbit_boot_step({?MODULE,
                   [{description, "federation exchange type"},
                    {mfa, {rabbit_registry, register,
                           [exchange, <<"x-federation">>,
                            rabbit_federation_exchange]}},
                    {requires, rabbit_registry},
                    {enables, exchange_recovery}]}).

-include_lib("rabbit_common/include/rabbit_exchange_type_spec.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-behaviour(rabbit_exchange_type).
-behaviour(gen_server).

-export([start/0]).

-export([description/0, route/2]).
-export([validate/1, create/2, recover/2, delete/3,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%----------------------------------------------------------------------------

-define(ETS_NAME, ?MODULE).
-define(TX, false).
-record(state, { downstream_connection, downstream_channel,
                 upstream_connection, upstream_channel,
                 downstream_exchange, upstream_queue, upstream_properties }).

%%----------------------------------------------------------------------------

start() ->
    %% TODO get rid of this ets table when bug 23825 lands.
    ?ETS_NAME = ets:new(?ETS_NAME, [public, set, named_table]).

description() ->
    [{name, <<"x-federation">>},
     {description, <<"Federation exchange">>}].

route(X, Delivery) ->
    with_module(X, fun (M) -> M:route(X, Delivery) end).

validate(_X) ->
    %% TODO validate args
    ok.
    %%with_module(X, fun (M) -> M:validate(X) end).

create(?TX, X = #exchange{ name = Downstream, arguments = Args }) ->
    {longstr, Upstream} = rabbit_misc:table_lookup(Args, <<"upstream">>),
    {longstr, Type} = rabbit_misc:table_lookup(Args, <<"type">>),
    {ok, Module} = rabbit_registry:lookup_module(
                     exchange, rabbit_exchange:check_type(Type)),
    rabbit_federation_sup:start_child(Downstream, binary_to_list(Upstream), Module),
    with_module(X, fun (M) -> M:create(?TX, X) end);
create(_Tx, _X) ->
    ok.
    %%with_module(X, fun (M) -> M:create(Tx, X) end).

recover(X, Bs) ->
    with_module(X, fun (M) -> M:recover(X, Bs) end).

delete(Tx, X, Bs) ->
    %% TODO shut down process
    with_module(X, fun (M) -> M:delete(Tx, X, Bs) end).

add_binding(?TX, X, B) ->
    %% TODO add bindings only if needed.
    call(X, {add_binding, B}),
    with_module(X, fun (M) -> M:add_binding(?TX, X, B) end);
add_binding(Tx, X, B) ->
    with_module(X, fun (M) -> M:add_binding(Tx, X, B) end).

remove_bindings(?TX, X, Bs) ->
    %% TODO remove bindings only if needed.
    call(X, {remove_bindings, Bs}),
    with_module(X, fun (M) -> M:remove_bindings(?TX, X, Bs) end);
remove_bindings(Tx, X, Bs) ->
    with_module(X, fun (M) -> M:remove_bindings(Tx, X, Bs) end).

assert_args_equivalence(X = #exchange{name = Name, arguments = Args},
                        NewArgs) ->
    rabbit_misc:assert_args_equivalence(Args, NewArgs, Name,
                                        [<<"upstream">>, <<"type">>]),
    with_module(X, fun (M) -> M:assert_args_equivalence(X, Args) end).

%%----------------------------------------------------------------------------

call(#exchange{ name = Downstream }, Msg) ->
    [{_, Pid, _}] = ets:lookup(?ETS_NAME, Downstream),
    gen_server:call(Pid, Msg, infinity).

with_module(#exchange{ name = Downstream }, Fun) ->
    [{_, _, Module}] = ets:lookup(?ETS_NAME, Downstream),
    Fun(Module).

%%----------------------------------------------------------------------------

start_link(Downstream, Upstream, Module) ->
    gen_server:start_link(?MODULE, {Downstream, Upstream, Module},
                          [{timeout, infinity}]).

%%----------------------------------------------------------------------------

init({DownstreamX, UpstreamURI, Module}) ->
    UpstreamProps0 = uri_parser:parse(
                       UpstreamURI, [{host, undefined}, {path, "/"},
                                     {port, undefined}, {'query', []}]),
    [VHostEnc, XEnc] = string:tokens(
                         proplists:get_value(path, UpstreamProps0), "/"),
    VHost = httpd_util:decode_hex(VHostEnc),
    X = httpd_util:decode_hex(XEnc),
    UpstreamProps = [{vhost, VHost}, {exchange, X}] ++ UpstreamProps0,
    Params = #amqp_params{host = proplists:get_value(host, UpstreamProps),
                          virtual_host = list_to_binary(VHost)},
    {ok, UConn} = amqp_connection:start(network, Params),
    {ok, UCh} = amqp_connection:open_channel(UConn),
    #'queue.declare_ok' {queue = Q} =
        amqp_channel:call(UCh, #'queue.declare'{ exclusive = true}),
    amqp_channel:subscribe(UCh, #'basic.consume'{ queue = Q,
                                                  no_ack = true }, %% FIXME
                           self()),
    {ok, DConn} = amqp_connection:start(direct),
    {ok, DCh} = amqp_connection:open_channel(DConn),
    true = ets:insert(?ETS_NAME, {DownstreamX, self(), Module}),
    {ok, #state{downstream_connection = DConn, downstream_channel = DCh,
                upstream_connection = UConn, upstream_channel = UCh,
                downstream_exchange = DownstreamX,
                upstream_properties = UpstreamProps, upstream_queue = Q} }.

handle_call({add_binding, #binding{key = Key, args = Args} }, _From,
            State = #state{ upstream_channel = UCh,
                            upstream_properties = UpstreamProps,
                            upstream_queue = Q}) ->
    X = list_to_binary(proplists:get_value(exchange, UpstreamProps)),
    amqp_channel:call(UCh, #'queue.bind'{queue       = Q,
                                         exchange    = X,
                                         routing_key = Key,
                                         arguments   = Args}),
    {reply, ok, State};

handle_call({remove_bindings, Bs }, _From,
            State = #state{ upstream_channel = UCh,
                            upstream_properties = UpstreamProps,
                            upstream_queue = Q}) ->
    X = list_to_binary(proplists:get_value(exchange, UpstreamProps)),
    [amqp_channel:call(UCh, #'queue.unbind'{queue       = Q,
                                            exchange    = X,
                                            routing_key = Key,
                                            arguments   = Args}) ||
        #binding{key = Key, args = Args} <- Bs],
    {reply, ok, State};

handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = _DTag,
                              %%redelivered = Redelivered,
                              %%exchange = Exchange,
                              routing_key = Key},
             Msg}, State = #state{downstream_exchange = #resource {name = X},
                                  downstream_channel = DCh}) ->
    amqp_channel:cast(DCh, #'basic.publish'{exchange = X,
                                            routing_key = Key}, Msg),
    {noreply, State};

handle_info(Msg, State) ->
    {stop, {unexpected_info, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, State = #state { downstream_connection = DConn,
                                    upstream_connection = UConn,
                                    downstream_exchange = DownstreamX }) ->
    amqp_connection:close(DConn),
    amqp_connection:close(UConn),
    true = ets:delete(?ETS_NAME, DownstreamX),
    State.