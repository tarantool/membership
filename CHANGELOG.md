# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- API method `probe_uri()`
- API method `get_member()`
- Low-level encryption support
- API methods `set_encryption_key()`, `get_encryption_key()`

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
