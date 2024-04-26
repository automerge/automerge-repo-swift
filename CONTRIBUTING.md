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

The integration tests work the network adapters provided in the repository with real networking.
They check for a local instance of the javascript automerge-repo sync server, and if available, run.
If the local instance is not available, the tests report as skipped.

To run a local instance, invoke the following command in another terminal window prior to running the tests:

```bash
./scripts/interop.sh
```

To run the integration test, you can either run them serially:

```bash
./IntegrationTests/scripts/serial_tests.bash
```

Or switch into the IntegrationTests directory and run them in parallel with swift test:

```bash
cd IntegrationTests
swift test
```

## Pull Requests

### New Features/Extended Features

New features should start with [a new issue](https://github.com/automerge/automerge-repo-swift/issues/new), not just a pull request.

New features should include:

- at least some coverage by tests
- documentation for all public and internal methods and types
- If the feature is purely internal, and changing how something operates, update the [FutureMe.md](notes/FutureMe.md) notes.
Share what's been updated and how the new system both functions and is intended to function.

### Merging Pull Requests

All of the projects tests must pass before we merge a pull request, with the exception of a pull request that ONLY contains a test update that illustrates an existing bug.
Code should be formatted with `swiftformat` prior to submitting a pull request.

Integration Tests are not required to pass, but a pull request may be reverted after the fact if the Integration Tests start failing due to the change.
As a general pattern, if the change is related to a networking provider or that interface, verify the change by running the Integration Tests manually and verifying they pass before submitting a pull request.

## Building the docs

The script `./scripts/preview-docs.sh` will run a web server previewing the docs.
This does not pick up all source code changes, so if you are working on documentation, you may need to restart it occasionally.

## Releasing Updates

The full process of releasing updates for the library is detailed in [Release Process](./notes/release-process.md)
