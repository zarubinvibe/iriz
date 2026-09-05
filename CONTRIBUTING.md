# Contributing

[Русский](CONTRIBUTING.ru.md) · [中文](CONTRIBUTING.zh.md)

<p align="center"><img src="docs/assets/pantheon/doc-contributing.png" alt="Two identical marble tablets on a low table, the left one holding the gold ribbon of voice, the right one empty and waiting, the herald staff standing beside them" width="100%"></p>

The second tablet in that frame is empty on purpose. There is room here for somebody else's work, and it is the same size as mine.

## What you need

A Mac on macOS 14 or newer and Xcode with Swift 6. Nothing else: the project has one dependency and it fetches itself.

```bash
git clone https://github.com/zarubinvibe/iriz.git ~/iriz
cd ~/iriz
bash install.sh
```

With no flags the installer installs nothing. It looks at what your machine is missing, runs the tree selfcheck and names the next step. Building and placing the app in `/Applications` comes later, with `bash install.sh --build`.

## Before you send a change

```bash
swift test
bash scripts/selfcheck.sh --selftest
```

Every test has to be green. If your change alters behaviour, bring a test that failed before it: otherwise, a month from now nobody can tell a fix from a coincidence.

## How code is written here

The simplest thing that works. The standard library or a native platform feature before your own abstraction, one line before a class. Abstractions arrive with the second need, not the first.

A comment explains WHY, not what. `// increment the counter` helps nobody; a line saying which failure was caught live and on which date saves the next person a day.

## The path of a change

Fork, branch, commit, push, Pull Request. Nobody pushes to `main` directly. A commit message says what changed and why, not "fixes".

Found something broken and would rather not fix it yourself? Open an Issue and write what you pressed and what appeared instead of what you expected. That report is worth more than a patch: it shows how the product breaks for a living person.

## What is needed most right now

The app interface is Russian only, while the documentation is already in three languages. Localizing the interface is the largest open piece of work. After that come icons of our own instead of the system set, and a real run on an Intel Mac: the binary carries the slice, the author has no machine to prove it on.
