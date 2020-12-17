%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2019-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(credentials_obfuscation_pbe).

-include("credentials_obfuscation.hrl").

-export([supported_ciphers/0, supported_hashes/0, default_cipher/0, default_hash/0, default_iterations/0]).
-export([encrypt_term/5, decrypt_term/5]).
-export([encrypt/5, decrypt/5]).

%% A lot of ugly code in this module can be removed once we support OTP-22+.
-ifdef(OTP_RELEASE).
-if(?OTP_RELEASE >= 22).
-define(HAS_CRYPTO_INFO_FUNCTIONS, 1).
-endif.
-endif.

-ifdef(HAS_CRYPTO_INFO_FUNCTIONS).
-define(DEFAULT_CIPHER, aes_128_cbc).
-else.
-define(DEFAULT_CIPHER, aes_cbc128).
-endif.

%% Supported ciphers and hashes

-ifdef(HAS_CRYPTO_INFO_FUNCTIONS).

%% We only support block ciphers that use an initialization vector.

%% @todo ctr_mode ciphers can be supported starting from OTP-22+
%% without any additional change. stream_cipher ciphers can be
%% supported starting from OTP-22+ by using the new encrypt/decrypt
%% functions.

supported_ciphers() ->
    SupportedByCrypto = crypto:supports(ciphers),
    lists:filter(fun(Cipher) ->
        Mode = maps:get(mode, crypto:cipher_info(Cipher)),
        not lists:member(Mode, [ccm_mode, ctr_mode, ecb_mode, gcm_mode, stream_cipher])
    end,
    SupportedByCrypto).

-else.

supported_ciphers() ->
    NotSupportedByUs = [aes_ccm, aes_128_ccm, aes_192_ccm, aes_256_ccm,
                        aes_gcm, aes_128_gcm, aes_192_gcm, aes_256_gcm,
                        aes_ecb, aes_128_ecb, aes_192_ecb, aes_256_ecb,
                        aes_ctr, aes_128_ctr, aes_192_ctr, aes_256_ctr,
                        chacha20, chacha20_poly1305,
                        blowfish_ecb, des_ecb, rc4],
    SupportedByCrypto = proplists:get_value(ciphers, crypto:supports()),
    lists:filter(fun(Cipher) ->
        not lists:member(Cipher, NotSupportedByUs)
    end,
    SupportedByCrypto).

-endif.

supported_hashes() ->
    proplists:get_value(hashs, crypto:supports()).

%% Default encryption parameters.
default_cipher() ->
    ?DEFAULT_CIPHER.

default_hash() ->
    sha256.

default_iterations() ->
    1.

%% Encryption/decryption of arbitrary Erlang terms.

encrypt_term(_Cipher, _Hash, _Iterations, ?PENDING_SECRET, Term) ->
    {plaintext, Term};
encrypt_term(Cipher, Hash, Iterations, Secret, Term) ->
    encrypt(Cipher, Hash, Iterations, Secret, term_to_binary(Term)).

decrypt_term(_Cipher, _Hash, _Iterations, _Secret, {plaintext, Term}) ->
    Term;
decrypt_term(Cipher, Hash, Iterations, Secret, Base64Binary) ->
    binary_to_term(decrypt(Cipher, Hash, Iterations, Secret, Base64Binary)).

%% The cipher for encryption is from the list of supported ciphers.
%% The hash for generating the key from the secret is from the list
%% of supported hashes. See crypto:supports/0 to obtain both lists.
%% The key is generated by applying the hash N times with N >= 1.
%%
%% The encrypt/5 function returns a base64 binary and the decrypt/5
%% function accepts that same base64 binary.

-spec encrypt(crypto:block_cipher(), crypto:hash_algorithms(),
              pos_integer(), iodata() | '$pending-secret', binary()) -> {plaintext, binary()} | {encrypted, binary()}.
encrypt(_Cipher, _Hash, _Iterations, ?PENDING_SECRET, ClearText) ->
    {plaintext, ClearText};
encrypt(Cipher, Hash, Iterations, Secret, ClearText) when is_list(ClearText) ->
    encrypt(Cipher, Hash, Iterations, Secret, list_to_binary(ClearText));
encrypt(Cipher, Hash, Iterations, Secret, ClearText) when is_binary(ClearText) ->
    Salt = crypto:strong_rand_bytes(16),
    Ivec = crypto:strong_rand_bytes(iv_length(Cipher)),
    Key = make_key(Cipher, Hash, Iterations, Secret, Salt),
    Binary = crypto:block_encrypt(Cipher, Key, Ivec, pad(Cipher, ClearText)),
    Encrypted = base64:encode(<<Salt/binary, Ivec/binary, Binary/binary>>),
    {encrypted, Encrypted}.

-spec decrypt(crypto:block_cipher(), crypto:hash_algorithms(),
              pos_integer(), iodata(), {'encrypted', binary() | [1..255]} | {'plaintext', _}) -> any().
decrypt(_Cipher, _Hash, _Iterations, _Secret, {plaintext, ClearText}) ->
    ClearText;
decrypt(Cipher, Hash, Iterations, Secret, {encrypted, Base64Binary}) ->
    IvLength = iv_length(Cipher),
    << Salt:16/binary, Ivec:IvLength/binary, Binary/bits >> = base64:decode(Base64Binary),
    Key = make_key(Cipher, Hash, Iterations, Secret, Salt),
    unpad(crypto:block_decrypt(Cipher, Key, Ivec, Binary)).

%% Generate a key from a secret.

make_key(Cipher, Hash, Iterations, Secret, Salt) ->
    Key = pbdkdf2(Secret, Salt, Iterations, key_length(Cipher),
        fun crypto:hmac/4, Hash, hash_length(Hash)),
    if
        Cipher =:= des3_cbc; Cipher =:= des3_cbf; Cipher =:= des3_cfb;
                Cipher =:= des_ede3; Cipher =:= des_ede3_cbc;
                Cipher =:= des_ede3_cbf; Cipher =:= des_ede3_cfb ->
            << A:8/binary, B:8/binary, C:8/binary >> = Key,
            [A, B, C];
        true ->
            Key
    end.

%% Functions to pad/unpad input to a multiplier of block size.

pad(Cipher, Data) ->
    BlockSize = block_size(Cipher),
    N = BlockSize - (byte_size(Data) rem BlockSize),
    Pad = list_to_binary(lists:duplicate(N, N)),
    <<Data/binary, Pad/binary>>.

unpad(Data) ->
    N = binary:last(Data),
    binary:part(Data, 0, byte_size(Data) - N).

-ifdef(HAS_CRYPTO_INFO_FUNCTIONS).

hash_length(Type) ->
    maps:get(size, crypto:hash_info(Type)).

iv_length(Type) ->
    maps:get(iv_length, crypto:cipher_info(Type)).

key_length(Type) ->
    maps:get(key_length, crypto:cipher_info(Type)).

block_size(Type) ->
    maps:get(block_size, crypto:cipher_info(Type)).

-else.

hash_length(md4) -> 16;
hash_length(md5) -> 16;
hash_length(ripemd160) -> 20;
hash_length(sha) -> 20;
hash_length(sha224) -> 28;
hash_length(sha3_224) -> 28;
hash_length(sha256) -> 32;
hash_length(sha3_256) -> 32;
hash_length(sha384) -> 48;
hash_length(sha3_384) -> 48;
hash_length(sha512) -> 64;
hash_length(sha3_512) -> 64;
hash_length(blake2b) -> 64;
hash_length(blake2s) -> 32.

iv_length(des_cbc) -> 8;
iv_length(des_cfb) -> 8;
iv_length(des3_cbc) -> 8;
iv_length(des3_cbf) -> 8;
iv_length(des3_cfb) -> 8;
iv_length(des_ede3) -> 8;
iv_length(des_ede3_cbf) -> 8;
iv_length(des_ede3_cfb) -> 8;
iv_length(des_ede3_cbc) -> 8;
iv_length(blowfish_cbc) -> 8;
iv_length(blowfish_cfb64) -> 8;
iv_length(blowfish_ofb64) -> 8;
iv_length(rc2_cbc) -> 8;
iv_length(aes_cbc) -> 16;
iv_length(aes_cbc128) -> 16;
iv_length(aes_cfb8) -> 16;
iv_length(aes_cfb128) -> 16;
iv_length(aes_cbc256) -> 16;
iv_length(aes_128_cbc) -> 16;
iv_length(aes_192_cbc) -> 16;
iv_length(aes_256_cbc) -> 16;
iv_length(aes_128_cfb8) -> 16;
iv_length(aes_192_cfb8) -> 16;
iv_length(aes_256_cfb8) -> 16;
iv_length(aes_128_cfb128) -> 16;
iv_length(aes_192_cfb128) -> 16;
iv_length(aes_256_cfb128) -> 16;
iv_length(aes_ige256) -> 32.

key_length(des_cbc) -> 8;
key_length(des_cfb) -> 8;
key_length(des3_cbc) -> 24;
key_length(des3_cbf) -> 24;
key_length(des3_cfb) -> 24;
key_length(des_ede3) -> 24;
key_length(des_ede3_cbf) -> 24;
key_length(des_ede3_cfb) -> 24;
key_length(des_ede3_cbc) -> 24;
key_length(blowfish_cbc) -> 16;
key_length(blowfish_cfb64) -> 16;
key_length(blowfish_ofb64) -> 16;
key_length(rc2_cbc) -> 16;
key_length(aes_cbc) -> 16;
key_length(aes_cbc128) -> 16;
key_length(aes_cfb8) -> 16;
key_length(aes_cfb128) -> 16;
key_length(aes_cbc256) -> 32;
key_length(aes_128_cbc) -> 16;
key_length(aes_192_cbc) -> 24;
key_length(aes_256_cbc) -> 32;
key_length(aes_128_cfb8) -> 16;
key_length(aes_192_cfb8) -> 24;
key_length(aes_256_cfb8) -> 32;
key_length(aes_128_cfb128) -> 16;
key_length(aes_192_cfb128) -> 24;
key_length(aes_256_cfb128) -> 32;
key_length(aes_ige256) -> 16.

block_size(aes_cbc) -> 16;
block_size(aes_cbc256) -> 16;
block_size(aes_cbc128) -> 16;
block_size(aes_128_cbc) -> 16;
block_size(aes_192_cbc) -> 16;
block_size(aes_256_cbc) -> 16;
block_size(aes_ige256) -> 16;
block_size(_) -> 8.

-endif.

%% The following was taken from OTP's lib/public_key/src/pubkey_pbe.erl
%%
%% This is an undocumented interface to password-based encryption algorithms.
%% These functions have been copied here to stay compatible with R16B03.

%%--------------------------------------------------------------------
-spec pbdkdf2(iodata(), iodata(), integer(), integer(), fun(), atom(), integer())
	     -> binary().
%%
%% Description: Implements password based decryption key derive function 2.
%% Exported mainly for testing purposes.
%%--------------------------------------------------------------------
pbdkdf2(Password, Salt, Count, DerivedKeyLen, Prf, PrfHash, PrfOutputLen)->
    NumBlocks = ceiling(DerivedKeyLen / PrfOutputLen),
    NumLastBlockOctets = DerivedKeyLen - (NumBlocks - 1) * PrfOutputLen ,
    blocks(NumBlocks, NumLastBlockOctets, 1, Password, Salt,
	   Count, Prf, PrfHash, PrfOutputLen, <<>>).

blocks(1, N, Index, Password, Salt, Count, Prf, PrfHash, PrfLen, Acc) ->
    <<XorSum:N/binary, _/binary>> = xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen),
    <<Acc/binary, XorSum/binary>>;
blocks(NumBlocks, N, Index, Password, Salt, Count, Prf, PrfHash, PrfLen, Acc) ->
    XorSum = xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen),
    blocks(NumBlocks -1, N, Index +1, Password, Salt, Count, Prf, PrfHash,
	   PrfLen, <<Acc/binary, XorSum/binary>>).

xor_sum(Password, Salt, Count, Index, Prf, PrfHash, PrfLen) ->
    Result = Prf(PrfHash, Password, [Salt,<<Index:32/unsigned-big-integer>>], PrfLen),
    do_xor_sum(Prf, PrfHash, PrfLen, Result, Password, Count-1, Result).

do_xor_sum(_, _, _, _, _, 0, Acc) ->
    Acc;
do_xor_sum(Prf, PrfHash, PrfLen, Prev, Password, Count, Acc) ->
    Result = Prf(PrfHash, Password, Prev, PrfLen),
    do_xor_sum(Prf, PrfHash, PrfLen, Result, Password, Count-1, crypto:exor(Acc, Result)).

ceiling(Float) ->
    erlang:round(Float + 0.5).
