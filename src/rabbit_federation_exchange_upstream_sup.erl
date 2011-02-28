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

-module(rabbit_federation_exchange_upstream_sup).

-behaviour(supervisor2).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_federation.hrl").

%% Supervises the upstreams for an exchange.

-export([start_link/1]).
-export([init/1]).
-export([call_all/2]).

-define(SUPERVISOR, ?MODULE).

start_link(Args) ->
    supervisor2:start_link(?MODULE, Args).

call_all(Sup, Msg) ->
    [gen_server2:call(Pid, Msg, infinity) ||
        {_, Pid, _, _} <- supervisor2:which_children(Sup)].

%%----------------------------------------------------------------------------

init({URIs, DownstreamX, Durable}) ->
    true = ets:insert(?ETS_NAME, {DownstreamX, self()}),
    Specs = [{URI,
              {rabbit_federation_exchange_upstream, start_link,
               [{URI, DownstreamX, Durable}]},
              temporary, %% TODO making this transient or {transient, N}
                         %% breaks shutdown
              ?MAX_WAIT, worker,
              [rabbit_federation_exchange_upstream]} ||
                URI <- URIs],
    {ok, {{one_for_one, 3, 10}, Specs}}.
