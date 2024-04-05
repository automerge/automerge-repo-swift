# Contributing

Issues for this library are tracked on GitHub: [https://github.com/automerge/automerge-repo-swift/issues](https://github.com/automerge/automerge-repo-swift/issues)

Feel free to [join the Automerge Discord Server](https://discord.gg/HrpnPAU5zx), which includes a channel for `#automerge-swift`, for conversation about this library, the [automerge-swift](https://github.com/automerge/automerge-swift) library, or Automerge in general.

## Building and Developing

This is a standard Swift library package.
Use Xcode to open Package.swift, or use swift on the command line:

```bash
swift build
swift test
```

The code is written to be fully Swift 6 concurrency compliant, and supports compilation back to Swift 5.9.

## Formatting

This project uses [swiftformat](https://github.com/nicklockwood/SwiftFormat) to maintain consistency of the formatting.
Before submitting any pull requests, please format the code:

```bash
swiftformat .
```

## Integration Tests

Some of the tests are integration tests.
They check for a local instance of the javascript automerge-repo sync server, and if available, run.
If the local instance is not available, the tests report as skipped.

To run a local instance, invoke the following command in another terminal window prior to running the tests:

```bash
./scripts/interop.sh
```

## Building the docs

The script `./scripts/preview-docs.sh` will run a web server previewing the docs.
This does not pick up all source code changes so you may need to restart it occasionally.

## Releasing Updates

The full process of releasing updates for the library is detailed in [Release Process](./notes/release-process.md)
