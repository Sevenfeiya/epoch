%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%%     Handle interaction with the aeternity chain
%%%     through calls to AEternity primitive operations at address 0.
%%% @end
%%% Created : 22 May 2018
%%%-------------------------------------------------------------------

-module(aevm_ae_primops).
-export([call/3]).

-include_lib("aebytecode/include/aeb_opcodes.hrl").

-define(BASE_ADDRESS, 32). %% Byte offset for data
-spec call( non_neg_integer(), binary(), aevm_eeevm_state:state()) ->
                  {ok, binary(), non_neg_integer(), aevm_eeevm_state:state()}
                      | {error, any()}.
call(Value, Data, State) ->
    try
        DecodeAs = fun(T) -> {ok, V} = aeso_data:from_binary(?BASE_ADDRESS, T, Data), V end,
        case DecodeAs({tuple, [word]}) of
            {?PRIM_CALL_SPEND} ->
                {?PRIM_CALL_SPEND, Recipient} = DecodeAs({tuple, [word, word]}),
                spend(Recipient, Value, State);
            {PrimOp} when ?PRIM_CALL_IN_ORACLE_RANGE(PrimOp) ->
                oracle_call(PrimOp, Value, Data, State)
        end
    catch _:_Err ->
	%% TODO: Better error for illegal call.
        {error, out_of_gas}
    end.

%% ------------------------------------------------------------------
%% Basic account operations.
%% ------------------------------------------------------------------


spend(Recipient, Value, State) ->
    ChainAPI   = aevm_eeevm_state:chain_api(State),
    ChainState = aevm_eeevm_state:chain_state(State),

    case ChainAPI:spend(<<Recipient:256>>, Value, ChainState) of
        {ok, ChainState1} ->
            UnitReturn = {ok, <<0:256>>}, %% spend returns unit
            GasSpent   = 0,         %% Already costs lots of gas
            {ok, UnitReturn, GasSpent,
             aevm_eeevm_state:set_chain_state(ChainState1, State)};
        {error, _} = Err -> Err
    end.

%% ------------------------------------------------------------------
%% Oracle operations.
%% ------------------------------------------------------------------

oracle_call(?PRIM_CALL_ORACLE_REGISTER, Value, Data, State) ->
    oracle_call_register(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_QUERY, Value, Data, State) ->
    oracle_call_query(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_RESPOND, Value, Data, State) ->
    oracle_call_respond(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_EXTEND, Value, Data, State) ->
    oracle_call_extend(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_GET_ANSWER, Value, Data, State) ->
    oracle_call_get_answer(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_GET_QUESTION, Value, Data, State) ->
    oracle_call_get_question(Value, Data, State);
oracle_call(?PRIM_CALL_ORACLE_QUERY_FEE, Value, Data, State) ->
    oracle_call_query_fee(Value, Data, State);
oracle_call(_, _, _, _) ->
    {error, out_of_gas}.

call_chain1(Callback, State) ->
    ChainAPI   = aevm_eeevm_state:chain_api(State),
    ChainState = aevm_eeevm_state:chain_state(State),
    Callback(ChainAPI, ChainState).

query_chain(Callback, State) ->
    case call_chain1(Callback, State) of
        {ok, Res} ->
            Return = {ok, aeso_data:to_binary(Res, 0)},
            {ok, Return, 0, State};
        {error, _} = Err -> Err
    end.

call_chain(Callback, State) ->
    case call_chain1(Callback, State) of
        {ok, ChainState1} ->
            UnitReturn = {ok, <<0:256>>},
            GasSpent   = 0,         %% Already costs lots of gas
            {ok, UnitReturn, GasSpent,
             aevm_eeevm_state:set_chain_state(ChainState1, State)};
        {ok, Retval, ChainState1} ->
            GasSpent   = 0,         %% Already costs lots of gas
            Return     = {ok, aeso_data:to_binary(Retval, 0)},
            {ok, Return, GasSpent,
             aevm_eeevm_state:set_chain_state(ChainState1, State)};
        {error, _} = Err -> Err
    end.

oracle_call_register(_Value, Data, State) ->
    ArgumentTypes = [word, word, word, word, typerep, typerep],
    [Acct, Sign, QFee, TTL, QType, RType] = get_args(ArgumentTypes, Data),
    Callback =
        fun(API, ChainState) ->
            case API:oracle_register(<<Acct:256>>, <<Sign:256>>, QFee, TTL, QType, RType, ChainState) of
                {ok, <<OKey:256>>, ChainState1} -> {ok, OKey, ChainState1};
                {error, _} = Err                -> Err
            end end,
    call_chain(Callback, State).

oracle_call_query(Value, Data, State) ->
    Value,
    [Oracle]  = get_args([word], Data),  %% We need the oracle address before we can decode the query
    OracleKey = <<Oracle:256>>,
    case call_chain1(fun(API, ChainState) -> API:oracle_query_spec(OracleKey, ChainState) end, State) of
        {ok, QueryType} ->
            ArgumentTypes = [word, QueryType, word, word],
            [_Oracle, Q, QTTL, RTTL] = get_args(ArgumentTypes, Data),
            Callback = fun(API, ChainState) ->
                case API:oracle_query(OracleKey, Q, Value, QTTL, RTTL, ChainState) of
                    {ok, <<QKey:256>>, ChainState1} -> {ok, QKey, ChainState1};
                    {error, _} = Err                -> Err
                end end,
            call_chain(Callback, State);
        {error, _} = Err -> Err
    end.


oracle_call_respond(_Value, Data, State) ->
    [Oracle, Query] = get_args([word, word], Data),
    OracleKey = <<Oracle:256>>,
    case call_chain1(fun(API, ChainState) -> API:oracle_response_spec(OracleKey, ChainState) end, State) of
        {ok, RType} ->
            ArgumentTypes = [word, word, word, RType],
            [_, _, Sign, R] = get_args(ArgumentTypes, Data),
            QueryKey = <<Query:256>>,
            Callback = fun(API, ChainState) -> API:oracle_respond(OracleKey, QueryKey, Sign, R, ChainState) end,
            call_chain(Callback, State);
        {error, _} = Err -> Err
    end.


oracle_call_extend(_Value, Data, State) ->
    ArgumentTypes = [word, word, word, word],
    [Oracle, Sign, Fee, TTL] = get_args(ArgumentTypes, Data),
    Callback = fun(API, ChainState) -> API:oracle_extend(<<Oracle:256>>, Sign, Fee, TTL, ChainState) end,
    call_chain(Callback, State).


oracle_call_get_answer(_Value, Data, State) ->
    ArgumentTypes = [word, word],
    [O, Q] = get_args(ArgumentTypes, Data),
    Callback = fun(API, ChainState) -> API:oracle_get_answer(<<O:256>>, <<Q:256>>, ChainState) end,
    query_chain(Callback, State).


oracle_call_get_question(_Value, Data, State) ->
    ArgumentTypes = [word, word],
    [O, Q] = get_args(ArgumentTypes, Data),
    Callback = fun(API, ChainState) -> API:oracle_get_question(<<O:256>>, <<Q:256>>, ChainState) end,
    query_chain(Callback, State).


oracle_call_query_fee(_Value, Data, State) ->
    ArgumentTypes = [word],
    [Oracle] = get_args(ArgumentTypes, Data),
    Callback = fun(API, ChainState) -> API:oracle_query_fee(<<Oracle:256>>, ChainState) end,
    query_chain(Callback, State).

get_args(Types, Data) ->
    {ok, Val} = aeso_data:from_binary(?BASE_ADDRESS, {tuple, [word | Types]}, Data),
    [_ | Args] = tuple_to_list(Val),
    Args.

