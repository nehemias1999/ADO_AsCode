<!--
The Definition of done from CONTRIBUTING.md §4 and AGENTS.md §5, as a checklist. It
lived in two documents and was carried in people's heads on the way to the PR form,
which is the point at which a row gets skipped.
-->

## What changed, and why

<!-- What a reviewer needs to know that the diff does not say. The reason, not the list
of files. If it fixes something, describe the failure it prevents. -->

## Definition of done

- [ ] Static analysis and the unit suite pass — `.\scripts\Invoke-Tests.ps1`
- [ ] The module guide under `docs/guides/` reflects the new behaviour
- [ ] Every new document is linked from `docs/README.md` — CI fails on an unindexed one
- [ ] `CHANGELOG.md` names the module and the observable result
- [ ] A test covers the new rule, with fixtures containing no real data
- [ ] `plan` produces the same output for unchanged input, or the changelog entry explains the difference
- [ ] If this adds a way to write, the guide says how to reverse it

## Evidence

<!-- Paste the gate's last lines, or the output that shows the behaviour changed. A
claim a reviewer cannot check is a claim they have to take on trust. -->

## Nothing here is a credential

- [ ] No token, password, private key, real host name, real organization name or real
      user; no execution report or plan output
