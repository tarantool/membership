# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.2.0] - 2019-10-22

### Added

- New field `member.clock_delta`, which indicates difference between
  remote and local clocks.

## [2.1.4] - 2019-08-25

### Fixed

- In some cases membership did disseminate invalid (nil) payload.
  The bug relates versions 2.1.2, 2.1.3.

## [2.1.3] - 2019-08-01

### Fixed

- Leaving membership with encryption enabled.
  Due to the bug, other members reported 'dead' status instead of 'left'.

## [2.1.2] - 2019-06-02

### Added

- Ldoc api documentation

### Fixed

- Fairly calculate size of UDP packets
- Speed up events dissemination by fully utilizing
  PING and ACK packets
- Restrict packet size for anti-entropy sync.
  Due to the lack of restriction it used to fail
  which plagued members detection

### Minor

- Make tests lighter by using `console` connection instead of `net.box`

## [2.1.1] - 2019-01-09

### Fixed

- Obtain UDP broadcast address from `getifaddrs` C call

### Updated

- Module `checks` dependency updated to v3.0.0

## [2.1.0] - 2018-09-04

### Added

- API method `probe_uri()`
- API method `get_member()`
- Low-level encryption support
- API methods `set_encryption_key()`, `get_encryption_key()`
- API method `broadcast()`
- API methods `subscribe()`, `unsubscribe()`

### Changed

- API method `set_payload()` now sets only the given key within payload table
- Hide internal numeric `status` from public API

## [2.0.0] - 2018-04-03

### Changed

- Rename API method: `quit()` -> `leave()`

## [1.0.0] - 2018-04-02

### Added

- Basic functionality
- Integration tests
- Luarock-based packaging
- Gitlab CI integration
