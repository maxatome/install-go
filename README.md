# install-go

Install any version of golang anywhere

## Usage

```
usage: install-go.pl VERSION [INSTALLATION_DIR]
```

- `VERSION` can be:
  - any version of go (1.9, 1.10.3);
  - a version without patch version specified, meaning the last one
    (1.11.x, 1.15.x);
  - `tip`, the latest HEAD.

- `INSTALLATION_DIR` the directory in which install the `go/`
  directory. This directory must exist. It default to current
  directory.

Tested on Linux on FreeBSD, for amd64 arch only.


### Install last version of go 1.15 in current directory:

```
./install-go.pl 1.15.x
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

Note that even if `~/my/path/go/bin/go` is the `gotip` executable at
the end of installation, `tip` is compiled and installed in `~/sdk/gotip/`.
