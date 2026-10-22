# Groups and Shortcuts

NimLaunch supports two related configuration concepts for organizing commands:

- **Shortcuts**: Actions triggered by a prefix or by selecting a grouped entry.
- **Groups**: Named collections used to organize shortcuts.

These are declared in
`${XDG_CONFIG_HOME:-~/.config}/nimlaunch/nimlaunch.toml`.

## Shortcut Fields

```toml
[[shortcuts]]
prefix = ":g"
label  = "Search Google: "
base   = "https://www.google.com/search?q={query}"
mode   = "url"
```

| Field | Default | Meaning |
| ----- | ------- | ------- |
| `prefix` | | Trigger typed after `:`. Leading/trailing `:` are optional and case is ignored, so `":g"`, `"g"`, `"g:"` and `"G"` are the same. Ignored when `group` is set |
| `group` | | Attach the shortcut to a group instead of giving it its own prefix |
| `label` | | Text shown in the results list |
| `base` | required | URL, shell command or path, with an optional `{query}` placeholder |
| `mode` | `"url"` | `"url"`, `"shell"` or `"file"`; any other value means `url` |
| `run_mode` | `"terminal"` | Shell mode only: `"terminal"` runs in your terminal, `"spawn"` runs in the background with no terminal |
| `stay_open` | `false` | Keep NimLaunch open after the action succeeds (any mode) |

A shortcut needs `base` and either a `prefix` or a `group`; otherwise it is
skipped. The built-in prefixes `s`, `c`, `t`, `r`, `q` and `quit` always win
over a shortcut with the same name.

## Prefix Shortcuts

```toml
[[shortcuts]]
prefix = ":w"
label  = "Search Wiki: "
base   = "https://en.wikipedia.org/wiki/Special:Search?search={query}"
mode   = "url"
```

Usage: `:w nim language`

### The `{query}` placeholder

Text after the prefix replaces every `{query}` in `base`. If `base` has no
placeholder, the query is appended to the end, so end `base` with any needed
separator. How the query is inserted depends on `mode`:

| Mode | Query inserted as |
| ---- | ----------------- |
| `url` | URL-encoded |
| `shell` | Shell-quoted for you (do not add quotes around `{query}`) |
| `file` | Raw text; `~` is expanded afterwards |

## Shortcut Modes

### URL
Opens the URL with your default handler.

```toml
[[shortcuts]]
prefix = ":y"
label  = "Search YouTube: "
base   = "https://www.youtube.com/results?search_query={query}"
mode   = "url"
```

### Shell
Runs `base` as a shell command. With `run_mode = "terminal"` (default) it opens
in your terminal; with `run_mode = "spawn"` it runs in the background.

```toml
[[shortcuts]]
prefix   = ":term"
label    = "Open btop: "
base     = "btop"
mode     = "shell"
run_mode = "terminal"
```

### File
Opens a file or directory with the default handler. The path must exist after
`~` expansion, otherwise NimLaunch shows "Not found" and stays open.

```toml
[[shortcuts]]
prefix = ":docs"
label  = "Open Docs: "
base   = "~/Documents/{query}"
mode   = "file"
```


## Groups

A group is a named menu of shortcuts reached with one prefix (`:sys`). Give a
shortcut a `group` and it joins that group; its own `prefix` is ignored. Group
names are lowercased.

Groups referenced by shortcuts are created automatically with the default
`filter` behavior. A `[[groups]]` block is only needed to set
`query_mode = "pass"`.

```toml
[[shortcuts]]
group     = "sys"
label     = "Lock"
base      = "loginctl lock-session"
mode      = "shell"
run_mode  = "spawn"
stay_open = false
```

Usage: `:sys lock`. A shortcut prefix with the same name as a group wins over the
group.

## Group Query Modes

| `query_mode` | Typed text after the group name |
| ------------ | -------------------------------- |
| `filter` (default) | Filters the group's entries by label (fuzzy). `{query}` is replaced with empty text when you run an entry |
| `pass` | Is not used for filtering; it is substituted into every entry's `{query}`. Also accepted as `passthrough` or `pass-through` |

### filter

`:sys re` narrows the list to entries matching "re" (such as Reboot). Use this
for a fixed set of actions. An entry without a `label` is matched and shown by
its `base`.

### pass

Every entry is shown with the query applied, and nothing is shown until you
type a query. Use it when the typed text is an argument. Declare the group
explicitly:

```toml
[[groups]]
name = "svc"
query_mode = "pass"

[[shortcuts]]
group = "svc"
label = "systemctl status: "
base  = "systemctl status {query}"
mode  = "shell"

[[shortcuts]]
group = "svc"
label = "systemctl cat: "
base  = "systemctl cat {query}"
mode  = "shell"
```

Usage: `:svc ssh` lists both entries; choosing the first runs
`systemctl status ssh` in your terminal.

## Related Documentation

- [Themes](themes.md)
- [Configuration](configuration.md)
- [Dmenu Mode](dmenu.md)
