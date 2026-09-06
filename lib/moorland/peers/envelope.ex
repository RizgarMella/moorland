defmodule Moorland.Peers.Envelope do
  @moduledoc """
  The encrypted peer wire, as pure functions.

  Every installation keeps a key-exchange pair ("kx", X25519) next to its
  permanent Ed25519 identity. A peer learns the kx key from the
  unauthenticated `hello` endpoint, whose reply is signed by the identity key
  and timestamped, so the kx key is bound to the identity in the peer code.

  A request is one sealed envelope (Noise-N style, plus a signature): the
  sender makes a fresh ephemeral X25519 key, agrees a secret with the
  recipient's kx key, derives a request key and a reply key with HKDF-SHA256,
  encrypts the request with ChaCha20-Poly1305, and signs the whole transcript
  with its Ed25519 identity. The recipient answers under the reply key, which
  only the holder of the kx private key can derive. Because every ephemeral
  key is used exactly once, nonces are fixed. A relay in the middle (phase 3)
  sees nothing but ciphertext - not even which script is being synced.
  """

  alias Moorland.Peers.Crypto

  @protocol "moorland-envelope-v1"
  @hello_protocol "moorland-kx-v1"
  @nonce <<0::96>>
  @tag_bytes 16

  @type kx :: %{public: binary, private: binary}
  @type identity :: %{public_key: binary, private_key: binary}
  @type session :: %{reply_key: binary, aad: binary, eph: binary}

  @doc "A fresh X25519 key-exchange pair."
  def generate_kx do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{public: public, private: private}
  end

  ## Hello: publishing a kx key under the identity's signature

  @doc "Builds the signed hello that binds `kx_public` to the identity at time `ts`."
  def sign_hello(kx_public, identity_public, identity_private, ts) when is_integer(ts) do
    signature = Crypto.sign(hello_message(ts, kx_public), identity_private)

    %{
      moorland: 1,
      key: Crypto.encode_key(identity_public),
      kx: Crypto.encode_key(kx_public),
      ts: ts,
      sig: Crypto.encode_key(signature)
    }
  end

  @doc """
  Checks a decoded hello (string keys) against the identity we expect, and
  that it was signed within `max_skew` seconds of `now`. Returns the kx key.
  """
  def verify_hello(hello, expected_identity, now, max_skew) when is_map(hello) do
    with {:ok, ^expected_identity} <- decode32(hello["key"]),
         {:ok, kx} <- decode32(hello["kx"]),
         {:ok, signature} <- decode(hello["sig"]),
         ts when is_integer(ts) and abs(now - ts) <= max_skew <- hello["ts"],
         true <- Crypto.verify(hello_message(ts, kx), signature, expected_identity) do
      {:ok, kx}
    else
      _ -> {:error, :bad_hello}
    end
  end

  def verify_hello(_hello, _expected_identity, _now, _max_skew), do: {:error, :bad_hello}

  defp hello_message(ts, kx_public), do: @hello_protocol <> <<ts::signed-64>> <> kx_public

  ## Requests

  @doc """
  Seals `plaintext` for whoever holds the private half of `recipient_kx`,
  signed by `identity`. Returns the envelope (JSON-ready) and the session
  needed to open the reply.
  """
  @spec seal(binary, identity, binary) :: {map, session}
  def seal(plaintext, identity, recipient_kx)
      when is_binary(plaintext) and byte_size(recipient_kx) == 32 do
    eph = generate_kx()
    transcript = identity.public_key <> eph.public <> recipient_kx
    {:ok, secret} = shared_secret(recipient_kx, eph.private)
    {request_key, reply_key} = derive(secret, transcript)
    aad = @protocol <> transcript
    box = aead_seal(request_key, plaintext, aad)
    signature = Crypto.sign(@protocol <> transcript <> box, identity.private_key)

    envelope = %{
      v: 1,
      from: Crypto.encode_key(identity.public_key),
      eph: Crypto.encode_key(eph.public),
      to: Crypto.encode_key(recipient_kx),
      box: Crypto.encode_key(box),
      sig: Crypto.encode_key(signature)
    }

    {envelope, %{reply_key: reply_key, aad: aad, eph: eph.public}}
  end

  @doc """
  Opens an envelope (string keys) addressed to `my_kx`. `lookup` maps a
  sender's identity key to a known peer, or nil: strangers are refused before
  any cryptography runs. Returns the plaintext, the peer, and the session
  for sealing the reply.
  """
  @spec open(map, kx, (binary -> term)) ::
          {:ok, binary, term, session} | {:error, atom}
  def open(envelope, my_kx, lookup) when is_map(envelope) and is_function(lookup, 1) do
    with {:ok, from} <- decode32(envelope["from"]),
         {:ok, eph} <- decode32(envelope["eph"]),
         {:ok, to} <- decode32(envelope["to"]),
         {:ok, box} <- decode(envelope["box"]),
         {:ok, signature} <- decode(envelope["sig"]),
         {:ok, peer} <- known_peer(lookup, from),
         transcript = from <> eph <> to,
         :ok <- check_signature(@protocol <> transcript <> box, signature, from),
         :ok <- check_recipient(to, my_kx.public),
         {:ok, secret} <- shared_secret(eph, my_kx.private),
         {request_key, reply_key} = derive(secret, transcript),
         aad = @protocol <> transcript,
         {:ok, plaintext} <- aead_open(request_key, box, aad) do
      {:ok, plaintext, peer, %{reply_key: reply_key, aad: aad, eph: eph}}
    end
  end

  def open(_envelope, _my_kx, _lookup), do: {:error, :malformed}

  @doc "Encrypts a reply under the session's reply key; returns it base64-encoded."
  def seal_reply(%{reply_key: key, aad: aad}, plaintext) when is_binary(plaintext) do
    Crypto.encode_key(aead_seal(key, plaintext, aad))
  end

  @doc "Decrypts a reply sealed by the peer that opened our envelope."
  def open_reply(%{reply_key: key, aad: aad}, box64) do
    with {:ok, box} <- decode(box64),
         {:ok, plaintext} <- aead_open(key, box, aad) do
      {:ok, plaintext}
    else
      _ -> {:error, :bad_reply}
    end
  end

  ## Checks

  defp known_peer(lookup, from) do
    case lookup.(from) do
      nil -> {:error, :unknown_peer}
      peer -> {:ok, peer}
    end
  end

  defp check_signature(message, signature, public_key) do
    if Crypto.verify(message, signature, public_key), do: :ok, else: {:error, :bad_signature}
  end

  defp check_recipient(to, mine) when to == mine, do: :ok
  defp check_recipient(_to, _mine), do: {:error, :stale_kx}

  ## Primitives

  defp shared_secret(their_public, my_private) do
    case :crypto.compute_key(:ecdh, their_public, my_private, :x25519) do
      # A low-order point yields an all-zero secret; refuse it.
      <<0::256>> -> {:error, :bad_key}
      secret -> {:ok, secret}
    end
  rescue
    _ -> {:error, :bad_key}
  end

  # HKDF-SHA256 (RFC 5869) with the protocol name as salt and the transcript
  # as info: block 1 is the request key, block 2 the reply key.
  defp derive(secret, transcript) do
    prk = :crypto.mac(:hmac, :sha256, @protocol, secret)
    request_key = :crypto.mac(:hmac, :sha256, prk, transcript <> <<1>>)
    reply_key = :crypto.mac(:hmac, :sha256, prk, request_key <> transcript <> <<2>>)
    {request_key, reply_key}
  end

  defp aead_seal(key, plaintext, aad) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, key, @nonce, plaintext, aad, true)

    ciphertext <> tag
  end

  defp aead_open(key, box, aad) when byte_size(box) >= @tag_bytes do
    size = byte_size(box) - @tag_bytes
    <<ciphertext::binary-size(^size), tag::binary-size(@tag_bytes)>> = box

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           @nonce,
           ciphertext,
           aad,
           tag,
           false
         ) do
      :error -> {:error, :bad_box}
      plaintext -> {:ok, plaintext}
    end
  end

  defp aead_open(_key, _box, _aad), do: {:error, :bad_box}

  defp decode32(value) do
    case decode(value) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _ -> {:error, :malformed}
    end
  end

  defp decode(value) when is_binary(value) do
    case Crypto.decode_key(value) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :malformed}
    end
  end

  defp decode(_value), do: {:error, :malformed}
end
