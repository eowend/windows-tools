# windows-tools - instructions for Claude sessions

## Policy: no infrastructure for automated tests (owner decision, 2026-10-27, permanent)

Do not create, configure, enable or run compute infrastructure whose purpose is automated tests, unless the owner has approved it
beforehand and explicitly. That covers GitHub-hosted runners (Linux, Windows, macOS) for CI, workflows that run test suites after a
commit, push or pull request, test matrices, temporary VMs in Azure or elsewhere that stand in for CI, ACR Tasks used to run test
suites, and any other mechanism that moves the same test load to another platform. Restoring a CI workflow that was removed is
covered too. This is not a cost-saving rule: do not propose caches, fewer runs, concurrency limits, other runners or other
providers as substitutes. "It is standard practice" or "it is technically possible" is not an authorization.

Still authorized, with no new conversation needed:
- developing, fixing, branching, committing, opening pull requests, reviewing and merging under the project's existing rules;
- running tests, linters, type checks and static analysis from the existing development environment, with local services where
  possible;
- building and publishing artifacts and container images, and deploying through the existing mechanisms (GitHub Actions deploy
  workflows included; their billable minutes are accepted);
- post-deployment health checks and functional checks against deployed applications in authorized environments.

A deployment workflow must not become a CI pipeline: it builds, publishes, deploys and verifies; it does not run test suites on a
provisioned runner. If a check needs infrastructure that is not allowed: (1) run it in the existing development environment;
(2) otherwise validate it functionally in an already-authorized environment, safely; (3) otherwise record the pending check, why
it could not run and the residual risk; (4) keep doing every independent piece of work. Never report a test as passed if it did
not run. Never create test infrastructure as a shortcut. The absence of CI is not by itself a reason to block a merge or a
deployment: follow each project's acceptance criteria and standing authorizations.
