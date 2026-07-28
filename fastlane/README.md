fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios gates

```sh
[bundle exec] fastlane ios gates
```

Run the permanent CI gates (package tests, CQRS invariants, iOS compiles, Release leak, flake, lint).

### ios perf

```sh
[bundle exec] fastlane ios perf
```

Large-library perf budgets on a simulated iPhone (nav + churn-interleaved CQRS phase).

### ios register

```sh
[bundle exec] fastlane ios register
```

First run only: register the bundle id + create the App Store Connect app record.

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build FoundryX (Release, app-store) and upload to TestFlight.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
