# Native DDI management (experimental)

DDI lifecycle management is separate from touch. Neither input preparation nor
HTTP/MCP touch requests invoke this CLI. The app does not download, redistribute,
or bundle Apple images, run Python, or invoke a third-party mounting tool.

## Available read-only commands

Run the app's executable directly; no running GUI is required:

```sh
iphone-use ddi inspect FULL_USB_UDID
iphone-use ddi preflight /absolute/DDI.bundle /absolute/source-receipt.json iPhone13,2
```

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

## Not yet available

There are no product `mount`, `unmount`, `switch`, or `restore` commands yet, and
no network endpoint accepts a DDI path. Do not substitute an experimental script
for product acceptance. A future mutating command must first stop and confirm
release of active input, bind the exact device and current image, stage and
revalidate candidate/backup bytes, obtain explicit local authorization tied to
their hashes and provenance, and persist recoverable transaction phases before
unmounting. Independent mounted metadata readback and whole restore-entry
acceptance remain required. Source rollback does not restore a phone's DDI.

The current fixed newer experimental image came from a pinned third-party mirror,
not a direct Apple CDN acquisition. License/source-policy review remains deferred;
successful preflight is not distribution clearance or permission to mount it.
