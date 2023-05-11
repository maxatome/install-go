# install-go

Install any version of golang anywhere, even in a github action.

No need to wait for the last version of go to be integrated in
`actions/setup-go` no need of any github action at all, even `tip` is
available out of the box.


## Usage

```
usage: install-go.pl [OPTIONS] VERSION [INSTALLATION_DIR]
```

- `VERSION` can be:
  - any version of go (1.9, 1.10.3);
  - a version without patch version specified, meaning the last one
    (1.11.x, 1.16.x);
  - `tip`, the latest HEAD.

- `INSTALLATION_DIR` the directory in which install the `go/`
  directory. This directory must exist. It default to current
  directory.

- `OPTIONS` can be:
  - `-e`, `--dont-alter-github-env`: ignore GITHUB_ENV environment variable;
  - `-p`, `--dont-alter-github-path`: ignore GITHUB_PATH environment variable.

By default, if `GITHUB_ENV` environment variable exists **AND** references
a writable file, `GOROOT` and `GOPATH` affectations are written to
respectively reference `INSTALL_DIR/go` and `INSTALL_DIR/go/gopath`.</br>
`-e` or `--dont-alter-github-env` option disables this behavior.

By default, if `GITHUB_PATH` environment variable exists **AND**
references a writable file, `INSTALL_DIR/go/bin` and
`INSTALL_DIR/go/gopath/bin` (aka `$GOPATH/bin` except if `-e` or no
`GITHUB_ENV`) are automatically appended to this file.</br>
`-p` (or `--dont-alter-github-path`) option disables this behavior.

See [Github Actions / Environment variables](https://docs.github.com/en/actions/learn-github-actions/environment-variables)
for details.

Tested on Linux (and Github unbuntu-latest), FreeBSD, Github
macos-latest and windows-latest, for amd64 arch only.


### In a github action

```yaml
jobs:
  test:
    strategy:
      matrix:
        go-version: [1.9.x, 1.10.x, 1.11.x, 1.12.x, 1.13.x, 1.14.x, 1.15.x, 1.16.x, 1.17.x, tip]
        os: [ubuntu-latest, windows-latest, macos-latest]

    runs-on: ${{ matrix.os }}

    steps:
      - name: Setup go
        run: |
          curl -sL https://raw.githubusercontent.com/maxatome/install-go/v3.4/install-go.pl |
              perl - ${{ matrix.go-version }} $HOME/go

      - name: Checkout code
        uses: actions/checkout@v2

      - name: Testing
        continue-on-error: ${{ matrix.go-version == 'tip' }}
        run: |
          go version
          go test ./... # or whatever you want with go executable
```


### Install last version of go 1.16 in current directory:

```
./install-go.pl 1.16.x
```

then

```
./go/bin/go version
```


### Install go 1.9.2 in `$HOME/go192` directory:

```
./install-go.pl 1.9.2 ~/go192
```

then

```
~/go192/go/bin/go version
```

### Install tip in `$HOME/my/path` directory:

```
./install-go.pl tip ~/my/path
```

then

```
~/my/path/go/bin/go version
```

When `tip` has to be compiled (because an already built instance could
not be retrieved), `~/my/path/go/bin/go` is the `gotip` executable at
the end of installation, but `tip` is also compiled and installed in
`~/sdk/gotip/`.


## How does it work?

`install-go.pl` first checks if the requested version already exists
in its environment.

If yes, it symlinks this version in the `INSTALLATION_DIR` directory.

If no, it downloads the binary version from
[golang.org](https://golang.org/dl/), which is pretty fast.

For the `tip` case, `install-go.pl` tries to find the already built
instance on Google storage servers. If it fails to find it, it
downloads then compiles it. So be prepared to have a longer build due
to this compilation stage in such cases (it typically occurs during
the few minutes that follow a golang/go master commit).


## Real full example of use

See [go-testdeep action](https://github.com/maxatome/go-testdeep/blob/master/.github/workflows/ci.yml),
only on linux but with linter and coverage steps.
