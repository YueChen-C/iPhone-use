# Native DDI management (experimental)

DDI lifecycle management is separate from touch. Neither input preparation nor
HTTP/MCP touch requests invoke this CLI. The app does not download, redistribute,
or bundle Apple images, run Python, or invoke a third-party mounting tool.

## Desktop plan and review

The local **iPhone Use → DDI Plan & Review (Experimental)** menu opens a native
window for an exact full USB UDID, read-only inspection, candidate/baseline bundle
and receipt pickers, a new transaction directory, opening an existing journal,
and **Find pending recovery** discovery.
Creating a plan invokes the same application's `ddi plan` entry in an isolated
child. Hashing and staging stay off the AppKit/video thread. It shows the complete
JSON review including current/candidate/baseline versions, sources, digests,
device/OS identity, plan hash and phase. Local output is private and bounded.

The window has **no mount/restore action** and its request type can construct only
`inspect`, `plan`, `status` or `recovery`. Copyable status/apply/restore commands quote local
paths and are text only, not shell execution or a mount authorization. Both
mutation templates are commented out so pasting the copied text cannot apply and
restore as an accidental batch; explicitly select/uncomment only the intended
operation after reviewing the plan. Close all
input owners cleanly, review the exact plan and source-risk warning, then use the
offline CLI below. The running GUI's lifetime lease is never bypassed. Existing
transactions can be opened even without input preparation; failed/pending phases
are not automatically retried. If an interrupted transaction's global pending
barrier blocks a fresh GUI start, run local `ddi recovery` to find the recorded
transaction before reviewing `ddi status` and explicitly choosing `ddi restore`;
the review window never bypasses that startup barrier. Recovery discovery offers
only a status command and a commented restore template, never an apply template.
This is a plan/review integration, not accepted
whole hardware recovery or authenticated source policy. Interactive window
validation still requires an unlocked desktop.

## Available read-only commands

Run the app's executable directly; no running GUI is required:

```sh
iphone-use ddi inspect FULL_USB_UDID
iphone-use ddi preflight /absolute/DDI.bundle /absolute/source-receipt.json iPhone13,2
iphone-use ddi recovery
```

`recovery` only discovers the fixed per-user pending record. It works without an
input or management lease, including while a management owner is live or a pending
barrier prevents GUI/MCP startup. It does not create the control directory, clear
the barrier, inspect a phone, validate transaction snapshots, authorize a restore,
or execute returned arguments. A private, user-owned regular record is read
without symlink components and with a 16 KiB limit; an unsafe or malformed record
is an error, not a report that recovery is unnecessary. No pending record returns
`recoveryPending: false`. A valid record returns its literal transaction path,
plan hash, and `statusArguments` / `restoreArguments` arrays. Both
`transactionValidated` and `restoreAuthorized` remain `false`. Review the journal
and sources, close owners cleanly, and explicitly authorize restoration separately.
Never delete the pending file to make input start.

`inspect` uses the Apple-installed MobileDevice framework, limited to the verified
arm64 ABI at version `1827.100.17.100.1`. It selects exactly one already-trusted USB
device by its full physical UDID, reads product/build information and mounted-image
metadata, and exits. It does not pair a device, acquire a touch usage assertion,
prepare input, or change the mounted image. Names, prefixes, CoreDevice UUIDs and
first-device fallback are not accepted. Failure to parse a reply is an error, not
an empty mount list. This isolated CLI has a 30-second process deadline.

`preflight` is offline and has a 120-second process deadline. It requires a local
source receipt pinned independently of the bundle. All SHA256 values are lowercase
hexadecimal. A receipt has this schema (replace the example hashes with values
from the independently acquired/pinned source):

```json
{
  "schemaVersion": 1,
  "kind": "third-party-mirror",
  "location": "https://example.invalid/DDI-mirror",
  "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "sha256": {
    "version.plist": "SHA256",
    "Restore/BuildManifest.plist": "SHA256",
    "Restore/Image.dmg": "SHA256",
    "Restore/Image.dmg.trustcache": "SHA256"
  }
}
```

Use the manifest's actual relative payload paths, not necessarily the example
filenames. The receipt must cover exactly the two metadata files and every
referenced image/trustcache file. Supported source kinds are `third-party-mirror`
(HTTPS URL and full 40-character commit) and `apple-installed` (local file URL
and installed source version). These are user-supplied provenance descriptions,
not authenticated assertions. A mirror is never labeled as a direct Apple CDN
download.

The preflight checks:

- Bounded, regular files opened without symlink components; relative component
  paths cannot contain traversal, absolute paths, backslashes or empty segments.
- Exact external SHA256 pins for both plists and every referenced payload.
- Bounded BuildManifest/version plists with matching build, iOS platform, a
  CoreDevice version, and an identity matching the supplied product type.
- Only the target product's verified `PersonalizedDMG` and `LoadableTrustCache`
  component dialect; its referenced payloads are streamed through SHA384 and
  compared against each matching identity's manifest digest. Conflicting matching
  identity digests are rejected. Unrelated products' legacy SHA1 identities and
  the alternative Cryptex variant are explicitly out of scope, not validated.
  `validationScope`, `compatibleIdentities` and `ignoredIdentities` expose this
  boundary; this is not whole-bundle or alternative-variant acceptance.
- File size/change checks during reads. Images are hashed in bounded chunks,
  never loaded whole into the GUI or processed on the video hot path.

Success reports `integrityVerified: true`, but always reports
`provenanceVerified: false`, `mountAuthorized: false`,
`deviceCompatibilityVerified: false` and `deviceMutation: false`. It is a
point-in-time integrity report for a manually supplied product type, **not** an
Apple signature check, device-bound mount authorization, or proof that HID works.
Editing a bundle after preflight invalidates that report. Do not generate a
receipt from an untrusted bundle and treat the matching hashes as authentication.

Output is one JSON object on stdout. Usage/identity/path syntax errors exit 64;
inspection/integrity/runtime failures exit 70 with JSON on stderr. Reaching the
process deadline terminates the CLI rather than retrying a device operation.

## Offline transaction commands (experimental; hardware recovery not accepted yet)

No network endpoint accepts a DDI path. The local transaction interface is:

```sh
iphone-use ddi plan FULL_USB_UDID /absolute/candidate /absolute/candidate-receipt.json /absolute/baseline /absolute/baseline-receipt.json /absolute/NEW_TRANSACTION
iphone-use ddi status /absolute/NEW_TRANSACTION
iphone-use ddi apply /absolute/NEW_TRANSACTION --confirm PLAN_SHA256 --acknowledge-source-risk
iphone-use ddi restore /absolute/NEW_TRANSACTION --confirm PLAN_SHA256 --acknowledge-source-risk
```

`plan` is non-mutating on the phone. It independently inspects the exact trusted
USB device and requires the supplied baseline to match the mounted personalized
image's build, CoreDevice version and 48-byte image signature. It validates both
receipts and copies just their pinned metadata/payloads into new private local
snapshots, streams and revalidates the copies, and fsyncs files/directories before
writing a plan and journal. The existing directory must not be reused. Treat the
output as sensitive: it contains physical device identity and local paths.

`apply` and `restore` require all app/input owners to be **cleanly stopped first**.
Finish/cancel the active gesture and confirm release before quitting the GUI.
Stop other MCP/AX sessions through their owning tasks; the CLI never kills them.
Every non-`ddi` entry takes a shared process lease before dispatch: GUI, USB touch
worker, MCP forwarding, AX listener/worker and capture-identity screenshot helper.
The lease is retained for that process's lifetime. This closes the admission race
where a new helper could start after the legacy-process scan. The fixed private
per-user control directory is not configurable through MCP/environment state paths.
Mutation requires an exclusive lease and also refuses
any other running `iphone-use` process, covering older binaries that do not take
the lease. This is intentionally conservative: idle legacy MCP/AX processes block
mutation as well. It is not a claim that arbitrary old binaries participate in
the new lock or that process exit proves a prior touch release. If an input owner
crashed with an unconfirmed release, stop and resolve it before managing images.

The exact plan SHA256 plus `--acknowledge-source-risk` is a local, explicit
research authorization for the plan's source descriptions, candidate, baseline,
device/OS and current signature. It is **not authenticated Apple provenance**, a
signature/license approval or a general production source-policy clearance. The
CLI accepts no standalone unmount/mount commands and does not retry `apply` after
it has started; an uncertain result requires inspection and explicit recovery.

Before mutation it verifies the snapshots and current identity/mounted state,
then fsyncs a persistent pending-input barrier and each journal intent/result:

```text
preflight -> authorized -> unmounting -> unmounted -> mounting -> mounted
          -> independentlyVerified
restoreAuthorized -> restoreUnmounting -> restoreUnmounted -> restoring
                  -> restoreMounted -> restored
```

Native calls use only the version-pinned Apple framework. Unmount and mount are
independently checked through fresh mounted metadata; a zero return alone cannot
clear the pending barrier. Error/timeout/crash leaves its actual last attempted
phase available through `status`; no automatic restore, contact replay or input
restart occurs. The fixed `~/Library/Application Support/iPhoneUse/DDIControl/`
barrier survives the mutating process and blocks every new non-`ddi` start until the
recorded transaction verifies successfully. Do not delete pending/lock files to
bypass it. For a corrupted candidate, recovery still permits the validated
baseline; corrupted baseline bytes stop recovery before device mutation. A crash
after verified restoration but before barrier removal can be finalized by the
same explicit restore command without remounting.

`plan` has a 240-second process deadline and mutation has a 300-second deadline.
All phases and errors remain local, not in the public PR. A single per-user
offline barrier intentionally blocks all new app input, not just one device.
No DDI payloads or host frameworks are installed into the host system.

### Evidence boundary / remaining work

Focused injected-device tests execute the whole apply/restore engine, ambiguous
mount, wrong identity/signature, corrupt snapshots, durable-write failure,
independent readback, no-replay and persistent input-barrier behavior. A real
device-bound plan was staged with the phone's existing 27B52 image as baseline;
a real `apply` was correctly refused while other app/MCP/AX processes were live,
leaving its journal in preflight and mounted image unchanged. These results do
**not** prove successful native hardware switch/recovery or crash-time touch
release. Whole hardware restore, interrupted native-call acceptance, source
policy and interactive UI acceptance remain unaccepted. The plan/review-only
window does not replace offline management or hardware acceptance. Do not substitute the
historical experiment's constituent calls for this product-entry acceptance.
Source rollback does not restore a phone's DDI or clear a recovery barrier.

The current fixed newer experimental image came from a pinned third-party mirror,
not a direct Apple CDN acquisition. License/source-policy review remains deferred;
successful preflight is not distribution clearance or permission to mount it.
