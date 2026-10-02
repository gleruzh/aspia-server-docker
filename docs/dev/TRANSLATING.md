# Translating the README

`README.md` in the repository root is the canonical version, in English. Every translation is made
from it and follows it. A translation never adds or removes content. If the canonical file is
wrong, fix `README.md` first, then carry the fix into every translation.

Current languages:

| Code | Language | File |
|---|---|---|
| `en` | English (canonical) | `README.md` |
| `ru` | Russian | `docs/README.ru.md` |

Agreed terms are in [GLOSSARY.md](GLOSSARY.md).

## File names

A translation is `docs/README.<code>.md`. The code is the two-letter ISO 639-1 language code in
lower case (`ru`, `de`, `uk`). Use a region suffix only when two variants of a language are both
translated (`pt-BR`).

## The first line: the canonical revision

The first line of a translation records the commit of `README.md` it was made from, as an HTML
comment in exactly this form (the full 40-character hash):

```
<!-- canonical: README.md 0123456789abcdef0123456789abcdef01234567 -->
```

Take the hash of the last commit that changed the text of `README.md`:

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

- A commit that only raises the version (`scripts/versions.sh bump` rewrites `README.md` and every
  `docs/README.*.md` together) needs no change of the hash.
- After a rebase or an amend the commit hashes change. Take the hash again, or it points to a
  commit that no longer exists.

## How to add a language

1. Ask the owner of the repository first. A language is added only if someone will keep it up to
   date. A stale translation is worse than none.
2. Add a column for the language to [GLOSSARY.md](GLOSSARY.md) and fill in every term. Agree on the
   terms before you translate the text.
3. Copy `README.md` to `docs/README.<code>.md` and add the first line described above.
4. Translate (see the rules below).
5. Add the language to the language switcher, in `README.md` and in every translation, in the same
   order everywhere. The current language is bold and not a link:
   - in `README.md`: `**English** | [Русский](docs/README.ru.md)`
   - in `docs/README.ru.md`: `[English](../README.md) | **Русский**`
6. Add the language to the table at the top of this file.
7. Check the translation (see "Checks" below) and run `tests/lint.sh`.

## Rules

- Translate the meaning, not the words. The text should read as if an administrator who speaks the
  language wrote it. Keep the short sentences of the original.
- Keep the structure one to one: the same headings in the same order, the same lists, the same
  table rows, the same code blocks. This makes later changes easy to carry over.
- Never translated:
  - the names of the Aspia components: Router, Relay, Host, Client, Console (capitalised, as in
    the English text);
  - product and project names: Aspia, Docker, Docker Compose, Docker Engine, Podman, Quadlet,
    systemd, GitHub, GitHub Container Registry, Debian, ufw, STUN;
  - the content of code blocks and inline code: commands, variable names, file names, paths, port
    numbers, configuration keys, image names and tags;
  - log messages and error messages quoted from the container or from Aspia
    (`Public key for hosts`, `ACCESS_DENIED`, and so on): the user searches for the exact text;
  - names of people and accounts in the credits.
- Translated: comments inside code blocks (the text after `#`), the link texts, the table headers
  and the table cells that are prose.
- Labels of the Aspia Client and Host user interface ("Unapproved hosts", the tab "Router"): keep
  the English label in quotes, because the user may run the program in English. You may add the
  label of the translated interface in parentheses if you know its exact text.
- In the English text, "server" and "machine" mean a computer, and "Host" (capitalised) means the
  Aspia Host. The section title "Running a Relay on a separate host" uses "host" for a computer:
  translate it as a computer, not as the Aspia Host.
- Anchors: the headings are translated, so the anchors change. Links inside the translation point
  to the translated headings. Links from other files (for example `podman/README.md`) point to the
  canonical `README.md` and are not changed.
- Relative links: the translation lives in `docs/`, so:
  - links to files in the repository root get `../` (`LICENSE` becomes `../LICENSE`,
    `podman/README.md` becomes `../podman/README.md`);
  - links to files in `docs/` lose `docs/` (`docs/ci.md` becomes `ci.md`);
  - the badge links (`../../actions/...`) are relative to the repository page on GitHub, so they
    need one more `../`.
- Example values stay as they are: addresses from `203.0.113.0/24`, the example key and digest,
  the version tag. `scripts/versions.sh check` (run by `tests/lint.sh` and CI) also checks the image
  tags in `docs/README.*.md`, and `scripts/versions.sh bump` updates them.

## Checks

Before you commit a translation:

```shell
# headings (outside code fences, where "#" starts a comment), code fences and table rows:
# the numbers must be the same
for f in README.md docs/README.ru.md; do
  awk -v f="$f" '/^ *```/ { fences++; infence = !infence; next }
       !infence && /^#/ { headings++ }
       /^\|/ { rows++ }
       END { printf "%s: headings %d, fences %d, table rows %d\n", f, headings, fences, rows }' "$f"
done

# the image tags still match versions.env
scripts/versions.sh check
```

Also check by eye that the code blocks are identical to the canonical ones except for the
comments, and that every relative link opens on GitHub.
