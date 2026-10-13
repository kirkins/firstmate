# Bounded native and portable verification

Candidate: `4f3638e911afa47c30bf6160e1a99ab0474cd2bc`.
Tree: `b116b3e0494bc1f3565eef28e5bef1b1e1eb28b6`.

The authorized read-only native execution report was consumed in this recovery, not rerun.
The current candidate commit/tree, accessor and canonical poll Git blobs and SHA-256 hashes agree with the supplied identity and member manifests.
The identity record hash agrees with the member manifest, and the execution report records matching archive and source identities.
The archive itself was not supplied to this Test phase; its independent verification on the native machine is reported evidence.
The two-file native transfer does not independently reconstruct the full commit/tree there.

The native report establishes that the candidate host-service-only accessor reproduced the existing account-selected credential, compared only in memory, and successfully authenticated a read.
The request was open and unmerged.
The canonical poll was silent; silence is not independently sufficient evidence of an authenticated poll.
No new login requirement follows from this proof.
No private endpoint, account, token, host record, or task-report path is published here.

## Corrected acceptance boundary

Actual native credential/accessor authenticated-read proof and portable synthetic guard/integration proof are separate obligations.
The recorded recovery decision accepts the supplied exact-candidate native read proof and requires the two affected behavioral suites with mock credential and HTTP surfaces.
It excludes production registration, merging, installation, credential mutation, and access to a new native runner.
Passing portable synthetic integration is not a native guarded write/merge verdict and grants no merge authority.

## Portable scenarios and independent expected outcomes

- Registration uses the validated host service without assuming the operating-system account; it records the reported head and arms a private static poll.
- Canonical and copied polls remain silent for open requests and emit `merged` only for a valid merged reading; altered identities and unusable credentials emit nothing.
- Missing credential tools differ from missing/invalid credentials; failed/unsupported platform selection reaches no HTTP client and publishes no registration.
- Linux retains its existing service lookup and token alphabet/length bounds.
- Shell tracing and HTTP transport do not expose the synthetic credential in arguments, output, or durable records.
- Guarded synthetic merges verify repository binding, live head and checks, refuse draft/closed/conflicting/red/no-check requests, preserve authority gates, and publish only confirmed outcomes.
- A stale recorded head is reported and the live head is verified; failed merge replies publish no landed outcome.

## Native-only residual coverage

No native guarded registration/write/merge was performed.
Native copied-poll resolution, a positive merged canonical/copied poll, native missing-tool and credential failures, and native live-head/check verification were not exercised by the supplied read-only proof.
Portable synthetic suites exercise those integrations; they do not fill the native-only qualification gap.
A Linux fixture cannot provide native Keychain semantics or stock macOS execution.
A separately authorized macOS owner-run isolated qualification would be needed to extend that coverage; production writes are outside the accepted task.
These limits are disclosed without enlarging the accepted bounded contract.

## Historical deviations retained

Earlier Test created and removed a disposable synthetic Linux keyring contrary to the supplied no-credential-write boundary.
Cleanup and successful requests do not retroactively authorize that action.
Earlier Test command evidence does not establish heavy-slot acquisition, its memory wrapper, or FM_LINT_JOBS=1.
No retrospective compliance is claimed.
This recovery creates no keyring or credentials and records its own capped, sequential commands separately.

## Recovery result

Both affected full behavioral suites completed with exit 0 and no gate skips through the canonical test runner, each with jobs=1 and FM_LINT_JOBS=1.
Each job followed a successful fresh heavy-slot acquisition, the printed systemd scope wrapper with MemoryMax=768M, and immediate release.
The running scopes reported MemoryMax=805306368 bytes, demonstrating the cap for this recovery only.
The security job completed before acquisition for the merge job; they did not overlap.
CLI output, fixture HTTP/credential invocations, and persisted records were captured before fixture cleanup.
They are explicitly labelled portable synthetic integration evidence; these tests use mocks and are not marked live native execution.

The earlier baseline record reports a security fixture Git-discovery setup failure, then both targeted suites and isolated Linux checks passing after isolation was corrected.
This recovery uses the same Git ceiling boundary and repeats only the requested portable suites; it neither repeats nor legitimizes the earlier keyring-write deviation.
No native credentials, private host/account/endpoint details, original task reports, or task-report paths were copied to public evidence.
No lint, documentation check, deployment, production registration/merge, pipeline control, or source edit was performed in this Test recovery.

The exact-candidate native authenticated-read proof plus the passing portable guard/integration suites establish the accepted bounded contract.
The native-only residual qualifications above remain untested and are not presented as merge authority, write permission, required-check success on any production request, or deployment proof.
