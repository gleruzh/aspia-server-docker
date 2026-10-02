# Translating the README

`README.md` and `podman/README.md` are the canonical versions, in English. Every translation is
made from them and follows them. A translation never adds or removes content. If a canonical file
is wrong, fix it first, then carry the fix into every translation.

Current languages and files:

| Code | Language | `README.md` becomes | `podman/README.md` becomes |
|---|---|---|---|
| `en` | English (canonical) | `README.md` | `podman/README.md` |
| `ru` | Russian | `docs/README.ru.md` | `podman/README.ru.md` |

`docs/ci.md`, `docs/dockerhub.md` and `docs/dev/*` are English only.

Agreed terms, and the words that are never translated, are in [GLOSSARY.md](GLOSSARY.md).

## File names

- A translation of `README.md` is `docs/README.<code>.md`.
- A translation of `podman/README.md` is `podman/README.<code>.md`, next to the original.

The code is the two-letter ISO 639-1 language code in lower case (`ru`, `de`, `uk`). Use a region
suffix only when two variants of a language are both translated (`pt-BR`).

## The first line: the canonical revision

The first line of a translation records the commit of its canonical file that it was made from, as
an HTML comment in exactly this form (the full 40-character hash). For `docs/README.ru.md`:

```
<!-- canonical: README.md 0123456789abcdef0123456789abcdef01234567 -->
```

For `podman/README.ru.md` the comment names `podman/README.md`:

```
<!-- canonical: podman/README.md 0123456789abcdef0123456789abcdef01234567 -->
```

Take the hash of the last commit that changed the text of the canonical file (use the other path for
the Podman file):

```shell
git log -1 --format=%H -- README.md
```

Commit the canonical change first, then the translation, so the hash already exists. To see what
a translation is missing, compare that revision with the current one:

```shell
git diff 0123456789abcdef0123456789abcdef01234567 HEAD -- README.md
```

To update a translation: carry every change over, in the same places, and set the new hash in the
first line in the same commit. If you cannot update a translation, leave the old hash: readers and
maintainers can then see that it is behind.

Two cases:

- A commit that only raises the version (`scripts/versions.sh bump` rewrites `README.md`,
  `podman/README.md` and every translation together) needs no change of the hash.
- After a rebase or an amend the commit hashes change. Take the hash again, or it points to a
  commit that no longer exists.

## How to add a language

1. Ask the owner of the repository first. A language is added only if someone will keep it up to
   date. A stale translation is worse than none.
2. Add a column for the language to [GLOSSARY.md](GLOSSARY.md) and fill in every term. Agree on the
   terms before you translate the text.
3. Copy `README.md` to `docs/README.<code>.md` and `podman/README.md` to `podman/README.<code>.md`.
   Add the first line described above to each.
4. Translate (see the rules below).
5. Add the language to the language switcher, in both canonical files and in every translation, in
   the same order everywhere. The current language is bold and not a link:
   - in `README.md`: `**English** | [Русский](docs/README.ru.md)`
   - in `docs/README.ru.md`: `[English](../README.md) | **Русский**`
   - in `podman/README.md`: `**English** | [Русский](README.ru.md)`
   - in `podman/README.ru.md`: `[English](README.md) | **Русский**`
6. Add the language to the table at the top of this file.
7. Check the translations (see "Checks" below) and run `tests/lint.sh`.

## Rules

- Translate the meaning, not the words. The text should read as if an administrator who speaks the
  language wrote it. Keep the short sentences of the original.
- Keep the structure one to one: the same headings in the same order, the same lists, the same
  table rows, the same code blocks. This makes later changes easy to carry over.
- Never translated: the list in [GLOSSARY.md](GLOSSARY.md), "Never translated". It covers the Aspia
  component names, product names, the content of code, quoted log messages and the names of people.
- Translated: comments inside code blocks (the text after `#`), the link texts, the table headers
  and the table cells that are prose.
- Labels of the Aspia Client and Host user interface ("Unapproved hosts", the tab "Router"): keep
  the English label in quotes, because the user may run the program in English. You may add the
  label of the translated interface in parentheses if you know its exact text.
- In the English text, "server" and "machine" mean a computer, and "Host" (capitalised) means the
  Aspia Host. The section title "Running a Relay on a separate host" uses "host" for a computer:
  translate it as a computer, not as the Aspia Host.
- Anchors: the headings are translated, so the anchors change. Links inside a translation point
  to the translated headings of the same file or of the other translated file. Links from other
  files (for example `docs/dockerhub.md`) point to the canonical files and are not changed.
- Relative links in `docs/README.<code>.md` (it lives in `docs/`):
  - links to files in the repository root get `../` (`LICENSE` becomes `../LICENSE`,
    `podman/README.md` becomes `../podman/README.<code>.md`);
  - links to files in `docs/` lose `docs/` (`docs/ci.md` becomes `ci.md`);
  - the badge links (`../../actions/...`) are relative to the repository page on GitHub, so they
    need one more `../`.
- Relative links in `podman/README.<code>.md` (it lives in `podman/`, like the original): they
  are the same as in `podman/README.md`, except that links to `README.md` and to its sections
  (`../README.md#ports`) become `../docs/README.<code>.md` and the translated anchor.
- Example values stay as they are: addresses from `203.0.113.0/24`, the example key and digest,
  the version tag. `scripts/versions.sh check` (run by `tests/lint.sh` and CI) also checks the image
  tags in every translation, and `scripts/versions.sh bump` updates them.

## Checks

Before you commit a translation, compare each translation with its canonical file:

```shell
# headings (outside code fences, where "#" starts a comment), code fences and table rows:
# the numbers must be the same
for f in README.md docs/README.ru.md podman/README.md podman/README.ru.md; do
  awk -v f="$f" '/^ *```/ { fences++; infence = !infence; next }
       !infence && /^#/ { headings++ }
       /^\|/ { rows++ }
       END { printf "%s: headings %d, fences %d, table rows %d\n", f, headings, fences, rows }' "$f"
done

# the image tags still match versions.env
scripts/versions.sh check
```

The numbers of `docs/README.ru.md` must equal those of `README.md`, and the numbers of
`podman/README.ru.md` must equal those of `podman/README.md`.

Also check by eye that the code blocks are identical to the canonical ones except for the
comments, and that every relative link opens on GitHub.
