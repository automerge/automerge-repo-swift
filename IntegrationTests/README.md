# Integration Tests

The integration tests included in this Swift package can be run from either the command line or Xcode.
They actively use network communications, and to fully execute all the tests, you need an operational local copy of `automerge-repo-sync-server`.
To use Docker to provide an instance to test against, run the following command from this directory:

```bash
../scripts/interop.sh
``

After it is operational, you can run the tests on the command line, also from this directory:

```bash
swift test
```

The tests are written to accomodate running the tests in parallel, but there is also a script to run them serially, because Xcode (and `swift test`) default to running the tests in parallel.

```bash
./scripts/serial_tests.bash
```