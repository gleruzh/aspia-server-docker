Task: let the aspia-server image run only the Router or only the Relay, so that a Relay can run on a different host from the Router and several Relays can serve one Router. Branch feat/relay-standalone from main (PRs 1, 3 and 4 are merged there; if one is not, branch from the latest unmerged one and use it as the PR base).

Read first: docs/dev/UPSTREAM-3.x-NOTES.md (how the Relay authenticates to the Router, which Router port it connects to, the Router's relay allow-list, what address the Relay advertises to clients), aspia_start, the healthcheck script, docker-compose.yml, .env.example, podman/, tests/.

Who the user is: an administrator who already runs the combined container and wants to add a Relay closer to a group of users, or to move traffic relaying off the Router host. They start a second container on another machine, give it the Router's address and public key, and sessions start flowing through it.

DESIGN
- One image, one variable: ASPIA_ROLE with the values all (default), router, relay. With all, behaviour is exactly what it was before this PR; existing users change nothing. Do not build separate images.
- Role relay: start only the Relay. Required settings: the Router's address and port, the Router's public key (as a value or as a path to a mounted file), and this Relay's own external address. If a required setting is missing, exit with one clear message that names it. Do not generate Router configs or a Router database in this role.
- Role router: start only the Router. Print at startup what a remote Relay needs: the public key and the port Relays connect to. Provide a variable for the relay allow-list if the Router has that key; if the Router's default would accept relays from anywhere, or from nowhere but localhost, say so in the README and in the startup log, because this is the step people get wrong.
- The healthcheck depends on the role: router - the Router is listening; relay - the Relay process is up and connected to the remote Router; all - both, as before.
- Signal handling and exit-on-child-death work the same for one process as for two.
- Reuse the variable names from .env.example; add only what the new roles need.

FILES
- aspia_start and the healthcheck: role handling.
- compose.router.yml and compose.relay.yml next to the existing docker-compose.yml, each publishing only the ports its role needs, with a comment on which ports must be reachable from where (clients, hosts, the other server).
- podman/: a relay-only Quadlet unit and env example, mirroring the existing one.
- .env.example: the new variables, in their own group.
- README: a short section "Running a Relay on a separate host" - the steps on the Router side, the steps on the Relay side, firewall rules for both, and how to confirm in the Router (console or log) that the Relay registered. Keep it in the existing README structure; the documentation rewrite is a separate PR.

TESTS
Add to tests/run.sh:
1. Two containers on one Docker network, one with role router and one with role relay configured with the Router's key: both become healthy and the Router log shows the Relay connected.
2. Relay with a wrong public key: it does not become healthy, and the log says why.
3. Relay with a required setting missing: clear message, non-zero exit.
4. Relay whose Router is unreachable: state what the intended behaviour is (retry and stay unhealthy, or exit), implement it, and test it.
5. Role all: every earlier scenario still passes unchanged.
6. Two relays against one Router: both register.
The tests run on one machine, so they cannot prove that traffic flows through a Relay across real NAT. Say that in the report and describe the manual check I should do with two hosts and a real client.

OUT OF SCOPE
Separate images per component, orchestration across hosts (Swarm, Kubernetes), automatic distribution of the Router key to Relays, load-balancing policy between Relays (that is the Router's business), translations.

DELIVERABLE
The branch, the PR description (including a small diagram or table of which port must be open from where in the split setup), the output of tests/run.sh and shellcheck, and the manual two-host check procedure.
