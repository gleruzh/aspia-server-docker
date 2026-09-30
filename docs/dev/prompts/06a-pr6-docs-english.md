Task: rework the aspia-server-docker documentation into one canonical English README that translations will be made from. Branch docs/i18n from main (PRs 1-5 are merged there; if one is not, branch from the latest unmerged one and use it as the PR base).

Read first: the current README.md (bilingual, Russian and English in one file), docs/dev/UPSTREAM-3.x-NOTES.md, docker-compose.yml, .env.example, podman/, docs/ci.md, tests/.

The reader: an administrator who wants to run their own Aspia server and does not have to know Docker deeply. They should get from an empty server to a connected host in 10 minutes.

Structure
- README.md - English, the canonical version. A language switcher at the top: English | Русский | ...
- Translations live in docs/README.<language code>.md.
- Sections: what this is and what it is not (unofficial packaging; Aspia is written by Dmitry Chapyshev; the original image is by paprikkafox); requirements (x86_64); quick start with compose; first login, the public key for hosts, changing the password; ports as a table "port, service, purpose, expose publicly or not"; environment variables; updating; upgrading from 2.x; backup and restore; running a Relay on a separate host; Podman (link to podman/); building locally; troubleshooting as a table "symptom, what to do"; licence and credits.
- Remove the section on installing Docker and link to the official instructions instead: it goes stale faster than anything else.

Rules
- You have run every command in the README and it works. Every port, path and variable name is checked against the repository files, not against memory.
- No claims about Aspia behaviour that are not in the notes or in the documentation on aspia.org; link to aspia.org rather than retell it.
- Every example pins the image to an exact version tag; latest appears nowhere. The updating section describes a manual update (change the tag, pull, recreate) and shows how to pin by digest.
- Example addresses come from the documentation ranges (203.0.113.0/24), never real ones.
- Write for translation: short sentences, no idioms, commands and variable names only inside code blocks.

Deliverable: README.md; docs/dev/TRANSLATING.md (how to add a language, what is never translated, how a translation records the canonical revision it was made from); and a glossary docs/dev/GLOSSARY.md: Router, Relay, Host, Client and Console are never translated; for the other terms, the agreed translation in each target language.
