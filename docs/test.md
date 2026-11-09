# Testsuite

How to run, select and write the tests of glaipnir. The testsuite is in
[`test/`](../test) and uses the [bats](https://github.com/bats-core/bats-core)
project.

---

## Table of Contents

- [Testsuite](#testsuite)
  - [Table of Contents](#table-of-contents)
  - [Prerequisites](#prerequisites)
  - [Running the tests](#running-the-tests)
    - [Select the test files](#select-the-test-files)
    - [Test the sources](#test-the-sources)
    - [Run bats directly](#run-bats-directly)
  - [Test files](#test-files)
  - [Environment variables](#environment-variables)
  - [Real build of the image](#real-build-of-the-image)
  - [Safety of your host](#safety-of-your-host)
  - [Skipped tests](#skipped-tests)
  - [Writing a test](#writing-a-test)

---

## Prerequisites

* The bats libraries are git submodules. Get them with
  `git clone --recurse-submodules`, or in an existing clone:

  ```bash
  git submodule update --init --recursive
  ```

* `shellcheck`, to check the sources (`sh build.sh check`) and the hook tests
  of `build.bats`.
* `parallel` (GNU), optional, to run the tests in parallel.
* `podman`, only for `isolation.bats` and `build-real.bats`. The other tests
  use a fake podman.
* `krun`, `/dev/kvm` and the `kvm` group, only for the microVM tests.

---

## Running the tests

```bash
sh build.sh test
```

It builds glaipnir, then runs every `test/*.bats` file on the **built**
script. The tests run in parallel when GNU `parallel` is installed, with
`BUILD_TEST_JOBS` jobs (2 by default). The exit status is `0` only if every
test passes.

### Select the test files

Give the names of the files to run after `test`, with or without the `.bats`
extension:

```bash
sh build.sh test build-real          # only test/build-real.bats
sh build.sh test cli conf            # test/cli.bats and test/conf.bats
sh build.sh test build.bats          # the extension is accepted
```

An unknown name fails before anything is built or run:

```
Unknown test file: nope
Action test Failed.
```

### Test the sources

Give the script to test with `BIN_TEST`: the project is then not built, which
is the quick way to iterate on `src/glaipnir.sh`:

```bash
BIN_TEST=src/glaipnir.sh sh build.sh test build
```

### Run bats directly

```bash
BIN_TEST=src/glaipnir.sh test/bats/bin/bats test/build.bats
BIN_TEST=src/glaipnir.sh test/bats/bin/bats --filter "hook" test/build.bats
```

`BIN_TEST` is required: the files of `test/` do not build the script.

---

## Test files

| File                  | Covers                                              | podman |
|-----------------------|-----------------------------------------------------|--------|
| `cli.bats`            | command line: help, version, options, actions       | stub   |
| `conf.bats`           | configuration file: keys, blocks, `--no-gcloud`     | stub   |
| `agent-selection.bats`| agents: validity, aliases, order, disclaimer        | stub   |
| `mount-policy.bats`   | workspace, cache and data dir policy                | stub   |
| `ro-mounts.bats`      | `--ro-mount` and `RO_MOUNTS`                        | stub   |
| `run-security.bats`   | security options of the `podman run` command        | stub   |
| `build.bats`          | `podman build` arguments, context, hooks, images    | stub   |
| `build-script.bats`   | the `test` action of `build.sh`                     | no     |
| `isolation.bats`      | isolation of the podman store of the tests          | real   |
| `build-real.bats`     | real build of the image (opt-in)                    | real   |

*stub*: a fake `podman` first in the `PATH`, see
[`test/test_helper/stubs/`](../test/test_helper/stubs). It records the calls
(`podman run` and `podman build` arguments, one per line, and the files of the
build context) and never starts or builds anything.

---

## Environment variables

| Variable                         | Effect                                      |
|----------------------------------|---------------------------------------------|
| `BIN_TEST`                       | Script to test. Without it, `build.sh test` builds and tests the built one |
| `BUILD_TEST_JOBS`                | Parallel jobs, default `2`                  |
| `GLAIPNIR_TEST_TMPDIR`           | Parent of the temporary dirs of real podman tests, default `${TMPDIR:-/tmp}`. Change it if `/tmp` is a small tmpfs |
| `GLAIPNIR_TEST_SHARE_IMAGES=1`   | Reuse your own images read-only (`additionalimagestores`) instead of pulling them again |
| `GLAIPNIR_TEST_REAL_BUILD=1`     | Run the real build of `build-real.bats`     |
| `GLAIPNIR_TEST_REAL_BUILD_FULL=1`| Also build the `from-scratch` stage, implies `GLAIPNIR_TEST_REAL_BUILD` |

---

## Real build of the image

`build-real.bats` builds the image from `image/Containerfile` with a real
podman. It needs the network and takes minutes, so it is skipped unless asked:

```bash
GLAIPNIR_TEST_REAL_BUILD=1 sh build.sh test build-real
```

It builds the `claude` image once, with a build hook, then checks the tags,
the `version` label, the unprivileged user, the installed agent, the hook and
`glaipnir status`. This build starts from the published base image.

To also build the whole system from scratch (very long, installs every
package of the `Containerfile`):

```bash
GLAIPNIR_TEST_REAL_BUILD_FULL=1 sh build.sh test build-real
```

---

## Safety of your host

The tests must never change your own podman images, containers, volumes or
files:

* Tests that need a real podman call `isolate_podman` (see
  [`podman-isolation.bash`](../test/test_helper/podman-isolation.bash)). It
  redirects the podman storage, the runtime dir, `HOME` and the `XDG_*`
  directories into a temporary directory, and fails immediately if podman still
  points to your real store.
* At the end, the temporary directory is removed with `podman unshare` (the
  storage files belong to sub-uids). If the isolation failed, podman is not
  run to clean up, so nothing can reach your containers.
* `isolation.bats` and `build-real.bats` check that your images (and, for the
  second one, containers and volumes) are the same as before the tests.
* Tests with the fake podman use a fake `HOME` and `XDG_*` directories in
  `$BATS_TEST_TMPDIR`; the real podman is never reached.

---

## Skipped tests

A test is skipped only when the host lacks a prerequisite or the test is
opt-in:

| Reason                                        | Tests                   |
|-----------------------------------------------|-------------------------|
| `podman` is not installed                     | `isolation.bats`, `build-real.bats` |
| `krun`, `/dev/kvm` or the `kvm` group missing | microVM tests           |
| `shellcheck` is not installed                 | hook tests of `build.bats` |
| run as root                                   | the tests of `mount-policy.bats` that create directories |
| `GLAIPNIR_TEST_REAL_BUILD` is not set         | `build-real.bats`       |

A test that fails because of a bug is never skipped: the code is fixed.

---

## Writing a test

* Create a test for every new feature, and adapt the tests when a behaviour
  changes.
* Load the helpers in `setup()`, not in `setup_file()`:

  ```bash
  setup() {
      load 'test_helper/common-setup'
      _common_setup
      load 'test_helper/podman-stub'
      stub_env "$BATS_TEST_TMPDIR"
  }
  ```

  `_common_setup` loads `bats-assert` and `bats-support` and sets `BIN_TEST`.
* Run glaipnir through `"$BIN_TEST"`, never by a hard-coded path.
* Helpers of [`podman-stub.bash`](../test/test_helper/podman-stub.bash):
  `glaipnir_run_no_microvm`, `glaipnir_run_microvm`, `glaipnir_build`,
  `assert_run_opt`, `assert_run_opt_match`, `refute_run_opt_match`,
  `assert_build_opt`, `assert_build_opt_match`, `refute_build_called`...
* Messages of glaipnir are written on stderr, so `run` puts them in `$output`.
* For a real podman, isolate it first (`isolate_podman` in `setup_file()`,
  `cleanup_podman` in `teardown_file()`) and use a tiny `FROM scratch` image,
  see `isolation.bats`.
* Keep the lines under 80 characters, and check the helpers with
  `shellcheck -x test/test_helper/*.bash`.
