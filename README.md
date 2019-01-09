[![pipeline status](https://gitlab.com/tarantool/ib-core/membership/badges/master/pipeline.svg)](https://gitlab.com/tarantool/ib-core/membership/commits/master)

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
* `incarnation` which is incremented every time the instance is being suspected or dead or updates its payload
* `payload` is a table with auxiliary data, which can be used by various modules to do whatever they want
* `timestamp` is a value of `fiber.time64()`
`timestamp` corresponds to the last update of status or incarnation.
`timestamp` is always local and does not depent on other members' clock setting.

Example:

```yaml
---
uri: "localhost:33001"
status: "alive"
incarnation: 1
payload:
    uuid: "2d00c500-2570-4019-bfcc-ab25e5096b73"
timestamp: 1522427330993752
...
```
