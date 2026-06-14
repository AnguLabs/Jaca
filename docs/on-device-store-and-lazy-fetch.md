# On-device store and lazy detail fetch (proposal, not yet built)

Status: deferred. We're keeping decryption on the desktop for now. This is written
down so the gRPC contract we build today leaves room for it and we don't have to
rewrite the wire format later.

## Why

Right now the phone is a dumb pipe. It tunnels raw TLS to the desktop and the
desktop decrypts everything live. That's fine on the same LAN, where bandwidth is
free. It stops being fine the moment the phone is remote.

The plan is to reach the desktop from anywhere over Tailscale. On a 4G connection,
streaming every byte of every request and response back to the desktop as it
happens is slow and burns data. Most of those bytes are never looked at. You glance
at the list, open three or four requests, and ignore the rest.

So the goal is simple: send the cheap part (metadata) live, keep the expensive part
(bodies) on the phone, and pull a full transaction only when someone actually opens
it.

## The idea

- The phone records every captured transaction into a local SQLite database. Use
  SQLDelight so iOS can reuse the same store later.
- It streams only metadata as traffic happens: app, package, host, port, method,
  URL, timestamp, status, byte sizes.
- The desktop shows that metadata in the list it already has. Nothing changes on
  that screen.
- When you click a row, the desktop asks the phone for that one transaction by id.
  The phone reads it from SQLite and returns the full headers and body.
- A switch in the mobile app picks the mode: send everything (today's behavior,
  good on LAN) or metadata only with fetch on demand (good on 4G).

This is a clean fit for gRPC: a server stream for the metadata feed, a unary call
for the detail fetch.

## The catch

For the phone to hand back a full transaction on demand, that transaction has to
live on the phone in a form something can read. Today only the desktop ever sees
plaintext, because only the desktop decrypts.

You can't lazily fetch from the desktop what the desktop already has. And if the
desktop is the one decrypting, every byte has to reach it during capture, which is
the exact cost we're trying to avoid. Saving bandwidth and decrypting on the
desktop are mutually exclusive. You pick one.

To make lazy fetch real, the phone has to do the MITM and hold the data.

## Proposed architecture (for later)

Move the MITM onto the phone:

1. Mint the leaf certs on the device, signing with a CA private key kept in the
   Android hardware keystore. The key is non-exportable, so even a malicious app
   can't read it out. This is the same keystore the companion link's TLS cert
   already uses, so the mechanism is proven on the device.
2. The phone terminates TLS, reads the plaintext, and writes the transaction to
   SQLite.
3. Before it persists the body, it encrypts it to the desktop's public key. The
   phone holds ciphertext at rest, not plaintext. A lost or seized phone gives up
   nothing without the desktop's private key.
4. Metadata streams to the desktop live. When you open a request, the desktop
   fetches the encrypted blob and decrypts it locally.

The phone does see plaintext for the moment it takes to capture and re-encrypt.
That part is unavoidable: it's the thing doing the capture, and the traffic belongs
to the phone's own apps anyway. The threat we actually cared about was someone
lifting the CA key and impersonating us, and the hardware keystore covers that.

## Why we're not doing it yet

Desktop decryption works, it's simpler, and the remote story isn't urgent. Keeping
it for now is the right call. The only thing we owe the future is a contract that
won't fight us: a detail-fetch call and a capture-mode field cost nothing to design
in today and save a rewrite later.

So the proto we build now should reserve space for:

- `GetTransactionDetail(id) -> TransactionDetail` (unary)
- a `CaptureMode` field the desktop can read and the mobile switch can set

We won't implement them yet. We just won't paint ourselves into a corner.

## What it would take to finish

- Reimplement the MITM in Kotlin on the phone: terminate TLS, mint leaf certs,
  parse HTTP. NetBare already does most of this and we ported its forwarding
  engine, so this is the next layer on top.
- Add SQLDelight and a transactions table.
- Add the CA key to the keystore and a leaf-cert minting path.
- Encrypt stored bodies to the desktop's public key; the desktop holds the private
  key.
- Extend the proto with the detail call and the capture-mode field above.
- Add the switch to the mobile UI.

## Security notes

- CA private key: hardware keystore, non-exportable, never leaves the phone.
- Stored bodies: encrypted to the desktop's public key, useless on a lost phone.
- The desktop stays the only place plaintext is persisted and read.
