pusher-ws
=========

An implementation of the Pusher WebSocket (client) protocol in
Haskell.

Current features:

- ws:// and wss:// protocols.
- Clusters.
- Subscribing to channels.
- Unsubscribing from channels.
- Authorisation for private and presence channels.
- Binding event handlers.
- Unbinding event handlers
- Sending client events.
- Threads which automatically get cleaned up on connection close.

Missing features:

- Reconnection.
- Connection state events.
- Pusher error handling.

The documentation of the latest developmental version is
[available online][docs].

Example
-------

Here's a tiny example to subscribe to a bunch of channels and just
print out the messages received:

```haskell
let key = "your-key"
let channels = ["your", "channels"]

-- Connect to Pusher with your key, SSL, and the us-east-1 region.
pusherWithKey key defaultOptions $ do

  -- Subscribe to all the channels
  mapM_ subscribe channels

  -- Bind an event handler for all events on all channels which prints
  -- the received JSON.
  bindAll Nothing (liftIO . print)

  -- Loop forever, as the connection is closed when this action
  -- terminates.
  forever (liftIO yield)
```

Contributing
------------

Bug reports, pull requests, and comments are very welcome!

Feel free to contact me on GitHub, through IRC (#haskell on freenode),
or email (mike@barrucadu.co.uk).

[docs]: https://docs.barrucadu.co.uk/pusher-ws
