Task: translate the README.md of aspia-server-docker into <LANGUAGE> and save it as docs/README.<code>.md. Branch docs/i18n.

Read first: README.md (the canonical version), docs/dev/TRANSLATING.md, docs/dev/GLOSSARY.md. For Russian, also read the Russian half of the old README at the upstream/main revision and keep its terminology wherever it does not contradict the glossary.

Rules
- Translate meaning, not words: the text should read as if a native-speaking administrator wrote it.
- Never translated: code blocks, commands, variable names, paths, file names, Router, Relay, Host, Client, Console, product names.
- Comments inside code blocks are translated.
- Structure, section order and table rows match the canonical file one to one, so later changes are easy to carry over.
- Fix relative links for the fact that the file lives in docs/.
- The first line is an HTML comment with the commit hash of the README.md the translation was made from.
- The language switcher at the top is the same as in the canonical file, with the current language not linked.
- Add nothing and remove nothing. If you spot an error in the canonical file, do not fix it in the translation; report it.

Verification: the number of headings, code blocks and table rows matches the canonical file; every relative link resolves; code blocks are byte-identical to the canonical ones except for comments.

Deliverable: the translation file and a report listing the places where you were unsure of a term and any errors you noticed in the canonical file.
