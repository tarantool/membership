# Membership library for Tarantool based on a gossip protocol

This library builds a mesh from multiple tarantool instances. The
mesh monitors itself, helps members discover everyone else and get
notified about their status changes with low latency.

It is built upon the ideas from consul, or, more precisely,
the [SWIM](docs/swim-paper.pdf) algorithm.

Membership module works over UDP protocol and can operate
even before tarantool `box.cfg` was initialized.

## API

### init

```lua
membership.init(advertise_host, port)
```

Initialize membership module.
This binds a UDP socket on `0.0.0.0:<port>` and
sets `advertise_uri = <advertise_host>:<port>`,
`incarnation = 1`.

It is possible to call `init()` several times:
the old socket will be closed and the new opened.
If `advertise_uri` is changed during `init()`, the old `advertise_uri` will be considered `DEAD`.
In order to teardown gracefully use function [`quit()`](#quit).

Returns `true` or raises an error.

### members

```lua
membership.members()
```

Obtain the table with all members known to current instance.

Returns table with `{uri=member}` pairs.
Particular member is represented by the table with fields:
* `uri`
* `status` (numeric value)
* `status_name` which can be `alive`, `suspect`, `dead` or `quit`
* `incarnation` which is incremented every time the instance is being suspected or dead or updates its payload
* `payload`
* `timestamp` which is a value of `fiber.time64()`.
`timestamp` corresponds to the last update of status or incarnation.
`timestamp` is always local and does not depent on other members' clock setting.

Example output:

```yaml
---
- localhost:33001:
    payload: []
    uri: localhost:33001
    status: 1
    status_name: alive
    timestamp: 1522427330993752
    incarnation: 1
...
```

### pairs

```lua
membership.pairs()
```

This is a shorthand for

```lua
pairs(membership.members())
```

### add_member

```lua
membership.add_member(uri)
```

Add member to the mesh and propagate this event to other members.
It is enough to add member to a single instance and everybody else in group will receive the update with time.

It does not matter who adds whom, the result will be the same.

### set_payload

```lua
membership.set_payload(payload)
```

Payload will be disseminated along with member status.
The payload is simply a Lua table.
Various modules can use it to share individual configs.

`set_payload()` increments `incarnation`.

Returns `true`
