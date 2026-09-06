defmodule Moorland.Peers.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Moorland.Peers.{Crypto, Envelope}

  @skew 300

  defp identity do
    %{public: public, private: private} = Crypto.generate_keypair()
    %{public_key: public, private_key: private}
  end

  # A JSON round trip yields the string-keyed map the receiving side sees.
  defp over_the_wire(map), do: map |> Jason.encode!() |> Jason.decode!()

  defp now, do: System.system_time(:second)

  setup do
    alice = identity()
    bob = identity()
    bob_kx = Envelope.generate_kx()

    lookup = fn key ->
      if key == alice.public_key, do: %{name: "Alice", public_key: key}
    end

    %{alice: alice, bob: bob, bob_kx: bob_kx, lookup: lookup}
  end

  describe "requests" do
    test "seal, open, reply: round trip with nothing in the clear", ctx do
      {envelope, session} = Envelope.seal("hello bob", ctx.alice, ctx.bob_kx.public)
      wire = over_the_wire(envelope)
      refute Jason.encode!(wire) =~ "hello"

      assert {:ok, "hello bob", %{name: "Alice"}, bob_session} =
               Envelope.open(wire, ctx.bob_kx, ctx.lookup)

      box = Envelope.seal_reply(bob_session, "hi alice")
      refute box =~ "alice"
      assert {:ok, "hi alice"} = Envelope.open_reply(session, box)
    end

    test "a reply opens only with the session that sealed the request", ctx do
      {envelope, _session} = Envelope.seal("one", ctx.alice, ctx.bob_kx.public)
      {:ok, _, _, bob_session} = Envelope.open(over_the_wire(envelope), ctx.bob_kx, ctx.lookup)
      box = Envelope.seal_reply(bob_session, "for the first request only")

      {_other, other_session} = Envelope.seal("two", ctx.alice, ctx.bob_kx.public)
      assert {:error, :bad_reply} = Envelope.open_reply(other_session, box)
      assert {:error, :bad_reply} = Envelope.open_reply(other_session, "not base64!")
    end

    test "strangers are refused before any cryptography runs", ctx do
      mallory = identity()
      {envelope, _} = Envelope.seal("let me in", mallory, ctx.bob_kx.public)

      assert {:error, :unknown_peer} =
               Envelope.open(over_the_wire(envelope), ctx.bob_kx, ctx.lookup)
    end

    test "a forged signature is refused", ctx do
      {envelope, _} = Envelope.seal("x", ctx.alice, ctx.bob_kx.public)
      forged = %{envelope | sig: Crypto.encode_key(Crypto.sign("other", ctx.alice.private_key))}

      assert {:error, :bad_signature} =
               Envelope.open(over_the_wire(forged), ctx.bob_kx, ctx.lookup)
    end

    test "an envelope sealed to a previous run's kx key reports stale_kx", ctx do
      old_kx = Envelope.generate_kx()
      {envelope, _} = Envelope.seal("x", ctx.alice, old_kx.public)
      assert {:error, :stale_kx} = Envelope.open(over_the_wire(envelope), ctx.bob_kx, ctx.lookup)
    end

    test "tampered ciphertext fails to open even when re-signed", ctx do
      {envelope, _} = Envelope.seal("original", ctx.alice, ctx.bob_kx.public)
      {:ok, box} = Crypto.decode_key(envelope.box)
      <<first, rest::binary>> = box
      tampered_box = <<Bitwise.bxor(first, 1), rest::binary>>

      {:ok, from} = Crypto.decode_key(envelope.from)
      {:ok, eph} = Crypto.decode_key(envelope.eph)
      {:ok, to} = Crypto.decode_key(envelope.to)
      transcript = from <> eph <> to

      resigned =
        Crypto.sign("moorland-envelope-v1" <> transcript <> tampered_box, ctx.alice.private_key)

      tampered = %{
        envelope
        | box: Crypto.encode_key(tampered_box),
          sig: Crypto.encode_key(resigned)
      }

      assert {:error, :bad_box} = Envelope.open(over_the_wire(tampered), ctx.bob_kx, ctx.lookup)
    end

    test "malformed envelopes are rejected", ctx do
      assert {:error, :malformed} = Envelope.open(%{}, ctx.bob_kx, ctx.lookup)
      assert {:error, :malformed} = Envelope.open("nope", ctx.bob_kx, ctx.lookup)

      {envelope, _} = Envelope.seal("x", ctx.alice, ctx.bob_kx.public)
      short_key = %{over_the_wire(envelope) | "from" => Crypto.encode_key("short")}
      assert {:error, :malformed} = Envelope.open(short_key, ctx.bob_kx, ctx.lookup)

      bad_base64 = %{over_the_wire(envelope) | "box" => "***"}
      assert {:error, :malformed} = Envelope.open(bad_base64, ctx.bob_kx, ctx.lookup)
    end
  end

  describe "hello" do
    test "binds the kx key to the identity within the clock window", ctx do
      ts = now()

      hello =
        Envelope.sign_hello(ctx.bob_kx.public, ctx.bob.public_key, ctx.bob.private_key, ts)
        |> over_the_wire()

      assert {:ok, kx} = Envelope.verify_hello(hello, ctx.bob.public_key, ts, @skew)
      assert kx == ctx.bob_kx.public

      # Signed by someone other than the peer we expect.
      assert {:error, :bad_hello} = Envelope.verify_hello(hello, ctx.alice.public_key, ts, @skew)

      # Too old to trust: a replayed hello from a previous run.
      assert {:error, :bad_hello} =
               Envelope.verify_hello(hello, ctx.bob.public_key, ts + 3_600, @skew)

      # A swapped kx key breaks the signature.
      swapped = %{hello | "kx" => Crypto.encode_key(Envelope.generate_kx().public)}
      assert {:error, :bad_hello} = Envelope.verify_hello(swapped, ctx.bob.public_key, ts, @skew)

      assert {:error, :bad_hello} = Envelope.verify_hello(%{}, ctx.bob.public_key, ts, @skew)
      assert {:error, :bad_hello} = Envelope.verify_hello(nil, ctx.bob.public_key, ts, @skew)
    end
  end
end
