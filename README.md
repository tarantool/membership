<a href="https://github.com/tarantool/membership/actions?query=workflow%3ATest">
<img src="https://github.com/tarantool/membership/workflows/Test/badge.svg">
</a>

# Membership library for Tarantool based on a gossip protocol

This library builds a mesh from multiple tarantool instances. The
mesh monitors itself, helps members discover everyone else and get
notified about their status changes with low latency.

It is built upon the ideas from consul, or, more precisely,
the [SWIM](doc/swim-paper.pdf) algorithm.

Membership module works over UDP protocol and can operate
even before tarantool `box.cfg` was initialized.

## Member data structure

A member is represented by the table with fields:

* `uri`
* `status` is a string: `alive`, `suspect`, `dead` or `left`
* `incarnation` which is incremented every time the instance is being
  suspected or dead or updates its payload
* `payload` is a table with auxiliary data, which can be used by various
  modules to do whatever they want
* `timestamp` is a value of `fiber.time64()` (in microseconds),
  corresponding to the last update of status or incarnation. `timestamp`
  is always local and does not depent on other members' clock setting.
* `clock_delta` is a time drift between member's clock (remote) and the
  local one (in microseconds).

Example:

```yaml
---
uri: "localhost:33001"
status: "alive"
incarnation: 1
payload:
    uuid: "2d00c500-2570-4019-bfcc-ab25e5096b73"
timestamp: 1522427330993752
clock_delta: 27810
...
```

## Reloadability

Membership module supports hot-reload:

```lua
package.loaded['membership'] = nil
require('membership')
```

## Changing options

You can change membership options directly by using:

```lua
require("membership.options")[opt_name] = opt_value
```

Available options:
* Period of sending direct PINGs.
  `PROTOCOL_PERIOD_SECONDS`, default: 1.0

* Time to wait for ACK message after PING.
  If a member does not reply within this time,
  the indirect ping algorithm is invoked.
  `ACK_TIMEOUT_SECONDS`, default: 0.2

* Period to perform anti-entropy sync.
  `ANTI_ENTROPY_PERIOD_SECONDS`, default: 10

* Toggle producing `suspect` rumors when ping fails. Even if disabled,
  it doesn't affect neither gossip dissemination nor other statuses
  generation (e.g. `dead` and `non-decryptable`).
  `SUSPICIOUSNESS`, default: true

* Timeout to mark `suspect` members as `dead`.
  `SUSPECT_TIMEOUT_SECONDS`, default: 3

* Number of members to try indirectly pinging a `suspect`.
  Denoted as `k` in [SWIM paper](swim-paper.pdf).
  `NUM_FAILURE_DETECTION_SUBGROUPS`, default: 3

* Maximum size of UPD packets to send.
  `MAX_PACKET_SIZE`, default: 1472 (`Default-MTU (1500) - IP-Header (20) - UDP-Header (8)`)

## Payload

You can add payload to any member by calling:

```lua
membership.set_payload(key, value)
```
