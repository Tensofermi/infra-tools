# proxy

A small control CLI for a local [mihomo](https://github.com/MetaCubeX/mihomo)
(Clash Meta) instance: start it, pick a node that actually pushes bytes, and
export `HTTP(S)_PROXY` into the current shell.

`install-fast/install-mihomo.sh` gives you a binary, a config and
`mihomoctl start|stop|status`. This directory is the layer on top, the one you
type while working:

```
proxy on        start mihomo, pick a working node, turn the proxy on
git clone ...   works now
proxy off       stop mihomo, clear the environment
```

Plain Bash, runtime requirements `bash` + `curl` + `python3` (the controller
speaks JSON). No root, no daemon of its own.

## Install

```bash
./install-fast/install-user.sh --only proxy   # from the repo root
./proxy/install.sh                            # or call the installer directly

./proxy/install.sh --prefix /etc/mihomo --no-rc
./proxy/install.sh --sub-file ~/meta/vpn-link --no-proxy '.corp.example'
./proxy/install.sh --remove                   # uninstall (mihomo/config/cache kept)
```

`--sub-file` records the file `proxy update` reads (default
`<prefix>/subscription`); `--no-proxy` appends hosts that must bypass the
proxy. Both land in the managed block, so they are per-machine rather than
baked into the repo.

The CLI is installed **next to the mihomo instance** (`--prefix`, default
`$MIHOMO_DIR` or `~/Mihomo`), because that is the thing it controls. A `proxy`
launcher is linked into `~/.local/bin`, and a managed block is added to
`~/.bashrc` (and `~/.zshrc` when present):

```
# >>> infra-tools proxy >>>
export PROXY_CLI_BIN="/home/you/Mihomo/proxy"
[ -f "/home/you/Mihomo/proxy-shell.sh" ] && . "/home/you/Mihomo/proxy-shell.sh"
# <<< infra-tools proxy <<<
```

`--remove` deletes the two scripts, the launcher and that block. It never
deletes the mihomo directory — `config.yaml`, the binary, `cache.db` and your
subscription stay exactly where they are.

### Why a sourced function and a launcher

`proxy on` has to change the environment of the shell you are typing in, and no
child process can do that. So the executable prints `export` / `unset` lines on
stdout, human-readable status on stderr, and `proxy-shell.sh` evals the stdout
half. Everything that does not need to touch your environment (`status`,
`nodes`, `test`, ...) is passed straight through to the executable.

Consequence worth knowing: the environment is **per shell**. A new terminal, a
new tmux pane, a VS Code terminal or a `sudo -i` starts empty — run `proxy on`
there too. Use `proxy status` to check: it prints the environment of *this*
shell on its own line.

## Commands

| Command | Meaning |
|---------|---------|
| `proxy` / `proxy status` | VPN / node / egress IP / this shell's environment |
| `proxy on [-k]` | start mihomo, pick a node, export the proxy (`-k` keeps the current node) |
| `proxy off` | stop mihomo, unset the proxy variables |
| `proxy toggle` | flip between on and off |
| `proxy pick` | re-pick the fastest *proven* node without restarting |
| `proxy nodes` | list every node in the main group with live latency |
| `proxy node [N\|NAME]` | show or switch the main group (`MATCH` uses it) |
| `proxy test` | node latency + proxy-vs-direct download speed |
| `proxy ip` | egress IP and location |
| `proxy update` | re-pull the subscription (`PROXY_SUB_FILE`) and restart |
| `proxy log [N]` | tail the mihomo log (default 30 lines) |
| `proxy env` | print the export lines (`eval "$(proxy env)"`) |

### Node selection

Latency alone lies: a 120 ms node can be perfectly alive for the URL-test probe
and still drop every TLS handshake. `proxy on` and `proxy pick` therefore sort
candidates by mihomo's own latency, then **really download** a slice of a GitHub
release through each one and keep the fastest that moved bytes. Tuning:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PROXY_PICK_CANDIDATES` | `3` | how many latency-ranked candidates get speed-tested |
| `PROXY_PICK_GOOD_SPEED` | `4194304` | stop early once a node is this fast (B/s) |
| `PROBE_SECS` | `3` | download window per candidate |
| `PROXY_TEST_URL` | this mihomo release | probe/`test` sample URL |

Other knobs: `MIHOMO_DIR` (instance dir), `PROXY_MAIN_GROUP` (default
`节点选择`), `PROXY_AUTO_GROUP` (fallback group; auto-detected as the first
`url-test` / `fallback` group when unset), `PROXY_SUB_FILE` (default
`<prefix>/subscription`), `PROXY_SUB_INSECURE` (see below), `PROXY_NO_PROXY`
(extra bypass hosts), `PROXY_NO_CN_MIRRORS=0` (do not bypass Chinese mirrors),
`PROXY_PING_URL` (default `http://www.gstatic.com/generate_204`).

The default `NO_PROXY` covers loopback and RFC1918 only, plus public Chinese
mirrors. Company-internal domains belong in `PROXY_NO_PROXY` on the machine
that needs them — not in a public repo.

### Subscription updates

`proxy update` re-pulls the subscription and swaps `config.yaml`, keeping the
**instance-level** keys a subscription never carries: `mixed-port`,
`bind-address`, `external-controller` and `secret` (losing `secret` would leave
the controller open on a shared box). It backs up the old file, validates the
new one with `mihomo -t`, and rolls back on failure.

TLS verification is **on** by default: whoever can answer for the subscription
URL can rewrite every route you take. If your provider really uses a self-signed
certificate, opt out explicitly:

```bash
PROXY_SUB_INSECURE=1 proxy update
```

## Gotchas this CLI is built around

- **A silent `proxy on`.** The env is emitted from a heredoc, and a heredoc is
  expanded as a whole — so `export no_proxy="$NO_PROXY"` inside it reads the
  *old* environment, not the line above. Under `set -u` on a fresh shell that is
  a hard error: the whole block vanishes, the "✔ 代理已开启" line still prints
  (stderr), and everything keeps going direct. Fixed by computing the list
  first; `proxy-shell.sh` now also refuses to pretend success when stdout is
  empty or `HTTPS_PROXY` stays unset.
- **Direct GitHub is dead, the proxy is not.** `curl` without a proxy times out;
  through the proxy the same URL answers in ~0.4 s. If a download hangs, check
  `proxy status` before blaming the node.
- **`git` and SSH.** `HTTP(S)_PROXY` only affects tools that honour it. GitHub
  over `git@github.com:` ignores it entirely (your port 22 may well work
  directly); `sudo git clone` drops the environment. To pin git regardless of
  the shell:

  ```bash
  git config --global http.https://github.com/.proxy http://127.0.0.1:17890
  ```

  Remember `proxy off` stops mihomo, so git then fails with "couldn't connect to
  proxy" rather than falling back to direct.
- **Shared hosts.** `port 17890 already in use` is another account running a
  proxy: pick a free port with `install-mihomo.sh --port`, then re-run
  `./proxy/install.sh` (it reads the port from `config.yaml`).
- **Rate limits.** `api.github.com` / `ipinfo.io` are shared by the whole exit
  IP; a `403` / `429` on those is not a broken proxy. `git clone` is unaffected.

## Layout

```
<prefix>/proxy           the CLI (installed copy)
<prefix>/proxy-shell.sh  shell integration (installed copy)
<prefix>/mihomo          binary          (from install-fast/install-mihomo.sh)
<prefix>/mihomoctl       start|stop|status
<prefix>/config.yaml     proxies / groups / rules
<prefix>/mihomo.log      log
<prefix>/mihomo.pid      pid
~/.local/bin/proxy       launcher symlink -> <prefix>/proxy
tests/run.sh             regression tests (stubbed controller, no network)
tests/stub-curl.sh       fake mihomo controller used by the tests
```

`--prefix` installs are recorded in
`${XDG_CONFIG_HOME:-~/.config}/infra-tools/mihomo-dir`, so `proxy` (and
`install-user.sh --only proxy`) still find the instance, and `--remove` works
without repeating `--prefix`.

## Tests

```bash
./proxy/tests/run.sh     # 61 assertions, no network, no mihomo, no root
```

`stub-curl.sh` answers the controller endpoints with fixture JSON, so the
tests cover things that are painful to reproduce by hand: `NO_PROXY` emission
under `set -u`, subscription info entries never being selectable as nodes,
`toggle` returning 0 in both directions, `-k` never being passed unless asked,
`secret` reaching curl through stdin, rc-block idempotency/legacy migration/
mode preservation, atomic writes, and `update` rollback.

## Language

This component's user-facing output is **Chinese-first**, unlike the rest of
the repo. It was written for operators of Chinese-language proxy
subscriptions, where node and group names are Chinese: mixing an English UI
with Chinese data reads worse than either alone. Code comments are English
where they explain a decision, Chinese where they explain a local gotcha.

Run it straight from the repo without installing:

```bash
MIHOMO_DIR=~/Mihomo ./proxy/proxy status
. ./proxy/proxy-shell.sh && proxy on
```
