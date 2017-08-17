# Membership library for Tarantool based on a gossip protocol

This library builds a mesh from multiple tarantool instances. The
mesh monitors itself, helps members discover everyone else and get
notified about their status changes with low latency.

It is built upon the ideas from consul, or, more precisely,
the [SWIM](http://www.cs.cornell.edu/~asdas/research/dsn02-SWIM.pdf)
algorithm.

*NB*: This is a work-in-progress.

## Example

Make sure to also check the `dev` directory of this repo. You can find
the working example of a 3-node cluster there.

```lua
#!/usr/bin/env tarantool

local membership = require 'membership'
local fiber = require 'fiber'
local log = require 'log'

box.cfg{listen=3302}

local advertise_uri = "localhost:3302"
local bootstrap_uri = "localhost:3301"

membership.init(advertise_uri, bootstrap_uri)

local function print_members()
    while true do
        for _, member in membership.pairs() do
            log.info("[%s] %s", member.status, member.uri)
        end
        fiber.sleep(2)
    end
end


fiber.create(print_members)
```

Here, the only thing you need to do to bootstrap a cluster is to call
`membership.init()`. It will instruct the membership protocol to
launch worker fibers and start trying to reach other nodes. The node
specified in `bootstrap_uri` will be used to do an initial sync. As
nodes in the mesh find out about the new node, they will include it in
gossip spreading.

## API

### `membership.init(advertise_uri, bootstrap_uri)`

Initializes and starts the mesh protocol workers.

- `advertise_uri` - URI, by which other nodes can connect to this one
- `bootstrap_uri` - Any URI, or list of URIs that will be used for initial sync. One is usually enough.

### `membership.pairs()`

Returns an iterator to the cluster state. Every value is as follows:

```lua
{uri = "localhost:3301",
 status = "alive",
 incarnation = 0}
```

- `uri` - the URI this node advertises
- `status` - either `"alive"`, `"dead"` or `"suspect"`
- `incarnation` - a counter of how many times the node has been suspected as non-responsive by the mesh

## Known limitations

As this is a work-in-progress, there are limitations:
- State is not persisted, so the cluster will re-bootstrap itself on restart
- Authentication is not (yet) supported
