Task: let users of the aspia-server image configure Router and Relay through environment variables and a .env file for compose. Branch feat/env-config from main (PR 1 is already merged there).

Read first: docs/dev/UPSTREAM-3.x-NOTES.md (the section listing router.conf and relay.conf keys and their defaults), aspia_start, docker-compose.yml, tests/.

Why: today the only setting is EXTERNAL_IP; everything else is edited by hand in files on the volume. That is awkward for people on Portainer, a NAS, or a dynamic IP. At the same time some users already hand-edit the configs, and their edits must not be wiped.

PRINCIPLES
- Every variable maps to a real 3.0.21 config key or to entrypoint behaviour. Build a table "variable - config key - default - example" and put it in your report first; only what is in the table goes into code.
- Precedence: if a variable is set, its value is written to the config on every start; if it is unset, the value in the file is left alone. Hand edits survive and behaviour stays predictable. State this in one sentence in the README.
- One prefix scheme: ASPIA_ROUTER_*, ASPIA_RELAY_*. EXTERNAL_IP keeps working as an alias of the new variable, with no deprecation warning.
- Validate at startup: a port is a number in range, an address is an IP or a hostname, a list is well-formed. On error, print one clear message naming the variable and exit non-zero before starting any process.

CANDIDATES (keep only those confirmed by the notes)
- The Relay's external address; the value auto means detect the public IP at startup. For auto: several sources with a timeout, the result validated as an IP, and a log line saying which source answered. If detection fails, exit with an error rather than start with an empty address.
- Router and Relay ports. The Relay tells clients its own port, so the port inside and outside the container must match; compose must take both sides from the same variable.
- Address allow-lists (administrators, relays, clients), if such keys exist in 3.x.
- STUN parameters, timeouts, Relay limits, log level, if they exist.
- TZ.
- PUID and PGID to run the processes as non-root, only if the binaries allow it. Check; otherwise write it to FOLLOWUPS.
- Secrets from files (VAR_FILE), only if any setting is actually secret.
Do not add an initial admin password variable until you have checked whether the Router has a supported way to set it. If it does not, do not invent one; write it to FOLLOWUPS.

FILES
- aspia_start: move applying variables to configs into separate functions; write configs atomically (temp file, then rename).
- docker-compose.yml: values as ${VAR:-default}; ports from the same variables.
- .env.example: every variable, grouped, with comments, required ones marked.
- README: the variable table.
- tests/: scenarios - a set variable lands in the config; a variable removed, the hand edit in the file survives; an invalid value gives an error and a non-zero exit; auto address with no network gives an error; docker compose config succeeds with .env.example.

OUT OF SCOPE
CI, Podman, translations, splitting into two containers.

DELIVERABLE
The branch, the PR description with the variable table, the output of tests/run.sh and shellcheck, and the list of candidates you rejected, each with the reason.
