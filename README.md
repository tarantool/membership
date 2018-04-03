[![pipeline status](https://gitlab.com/tarantool/ib-core/membership/badges/master/pipeline.svg)](https://gitlab.com/tarantool/ib-core/membership/commits/master)

# Membership library for Tarantool based on a gossip protocol

This library builds a mesh from multiple tarantool instances. The
mesh monitors itself, helps members discover everyone else and get
notified about their status changes with low latency.

It is built upon the ideas from consul, or, more precisely,
the [SWIM](docs/swim-paper.pdf) algorithm.

Membership module works over UDP protocol and can operate
even before tarantool `box.cfg` was initialized.

## API

- [`init(advertise_host, port)`](#membershipinitadvertise_host-port)
- [`members()`](#membershipmembers)
- [`pairs()`](#membershippairs)
- [`myself()`](#membershipmyself)
- [`add_member(uri)`](#membershipadd_memberuri)
- [`set_payload(payload)`](#membershipset_payloadpayload)
- [`leave()`](#membershipleave)

### `membership.init(advertise_host, port)`

Initialize membership module.
This binds a UDP socket on `0.0.0.0:<port>` and
sets `advertise_uri = <advertise_host>:<port>`,
`incarnation = 1`.

It is possible to call `init()` several times:
the old socket will be closed and the new opened.
If `advertise_uri` is changed during `init()`, the old `advertise_uri` will be considered as `DEAD`.
In order to leave the group gracefully use function [`leave()`](#membershipleave).

Returns `true` or raises an error.

### `membership.members()`

Obtain the table with all members known to current instance.

Returns table with `{uri=member}` pairs.
Particular member is represented by the table with fields:
* `uri`
* `status` (numeric value)
* `status_name` which can be `alive`, `suspect`, `dead` or `quit`
* `incarnation` which is incremented every time the instance is being suspected or dead or updates its payload
* `payload`
* `timestamp` which is a value of `fiber.time64()`
`timestamp` corresponds to the last update of status or incarnation.
`timestamp` is always local and does not depent on other members' clock setting.

Editing this table has no effect.

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

### `membership.pairs()`

This is a shorthand for

```lua
pairs(membership.members())
```

### `membership.myself()`

Returns the same table as `membership.members()[advertise_uri]`.

### `membership.add_member(uri)`

Add member to the group and propagate this event to other members.
It is enough to add member to a single instance and everybody else in group will receive the update with time.

It does not matter who adds whom, the result will be the same.

### `membership.set_payload(payload)`

Payload will be disseminated along with member status.
The payload is simply a Lua table.
Various modules can use it to share individual configs.

`set_payload()` increments `incarnation`.

Returns `true`


### `membership.leave()`

Gracefully leave the membership group.
The node will be marked with status `left` and no other members will ever try to connect it.

