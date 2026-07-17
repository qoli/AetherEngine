# Third-party notices and native artifact audit

This file inventories the exact dependency graph used by the AetherEngine tvOS release candidate. It
is an engineering audit, not legal advice. A shipping application must include the applicable license
texts from [`ThirdPartyLicenses`](ThirdPartyLicenses) in its notices surface and must complete the
release/relink actions below.

## Exact Swift package graph

| Package | Pin kind | Exact revision | Declared license | Source |
| --- | --- | --- | --- | --- |
| FFmpegBuild | immutable revision | `d24262133163dab1a8997e22493176a0db4adea8` | LGPL-3.0 build package; bundled libraries retain independent licenses | <https://github.com/qoli/FFmpegBuild> |
| LibDovi | exact version 1.0.2 | `bebab0af0e3633b0002fcc7106ea6fc7ceea8277` | MIT packaging; bundled libdovi 3.3.2 is MIT | <https://github.com/superuser404notfound/LibDovi> |
| SMBClient | exact version 0.3.1 | `e636c2b2458930770932a36d311ec9d478575b90` | MIT | <https://github.com/kishikawakatsumi/SMBClient> |
| swift-libass | immutable revision | `01c5ebb8ee8b36cefcbcabea819a47208d1e1216` | MIT wrapper; bundled native libraries below | <https://github.com/qoli/swift-libass> |

`Package.swift` uses immutable `revision:` pins for the two qoli Gate 1A build forks and `exact:`
versions for the remaining rows. `Package.resolved` is evidence of the same graph, but is not used to
compensate for a moving manifest range or branch.

LibDovi 1.0.2's build manifest names upstream tag `libdovi-3.3.2`; the canonical tag resolves to
`4fd2b2235c9f93582dd4a00e65ee34a07800afd7`. That exact source declares MIT. The wrapper README's
broader MIT/Apache description is not used as a substitute for the exact tag's license file.

## Published Gate 1A provenance bundles

Both dependency forks publish a prerelease named `syncnext-gate1a-2026-07-17`. Prerelease is
intentional: the technical source/rebuild delivery is complete, but App Store static LGPL legal review
has not approved the final combined work.

| Package | Public release | Bundle SHA-256 | Contents |
| --- | --- | --- | --- |
| FFmpegBuild | <https://github.com/qoli/FFmpegBuild/releases/tag/syncnext-gate1a-2026-07-17> | `226f95734bdbae58760cd754713491d34e599ffe51eb31372520191f97a7fe12` | 4 exact source archives, locked zimg/GoogleTest submodule, 9 rebuilt XCFrameworks, build recipe/environment, notices and relink responsibility |
| swift-libass | <https://github.com/qoli/swift-libass/releases/tag/syncnext-gate1a-2026-07-17> | `8657344dc4264120baee24160d357e3f8553e85c64413ddf394acaacb787692a` | exact ffmpeg-kit plus 9 exact sources, source-lock patch, 6 rebuilt XCFrameworks, build recipe/environment, notices and relink responsibility |

Each tarball contains an internal `SHA256SUMS` manifest. The release also publishes the outer tarball
checksum as a separate asset. A mismatched origin, revision, submodule, dirty source cache or missing
recorded license file is a hard build failure; no tag or branch fallback is permitted.

## swift-libass Gate 1A native tvOS artifacts

The exact wrapper release bundles prebuilt static XCFrameworks. The following SHA-256 values identify
the arm64 tvOS archives actually linked by the 2026-07-17 acceptance build.

| Library | Upstream version | Upstream tag commit | License | tvOS arm64 SHA-256 |
| --- | --- | --- | --- | --- |
| fontconfig | 2.15.0 | `72b9a48f57de6204d99ce1c217b5609ee92ece9b` | permissive fontconfig terms plus file-specific notices | `7477f18903d5621c97c4fb198b091b57310357dcfb1e4305cd061058c10bb1db` |
| FreeType | 2.13.2 | `920c5502cc3ddda88f6c7d85ee834ac611bb11cc` | FreeType License selected for this distribution | `d15b4df4a3a51dbc5e68a4c410fbaad212eef86b92e03dd73bdc617a7de55bbc` |
| FriBidi | 1.0.14 | `bca04dc3cd3af85a9d9220c430737333634d622a` | LGPL-2.1-or-later | `518a19809ba60adf71916e446e186b5aa714aebe75f3a78c9f1ed7b5064e8fed` |
| HarfBuzz | 8.5.0 | `30485ee8c3d43c553afb9d78b9924cb71c8d2f19` | Old MIT | `f5118732671dca888156fd04d3f58576158710940649a8eb5568b1573772f403` |
| libass | 0.17.3 | `e46aedea0a0d17da4c4ef49d84b94a7994664ab5` | ISC | `c2090b60fe250cb74d1cec6d9d953c417793e42bf66ae5583f406718d2539ebc` |
| libpng | 1.6.43 | `ed217e3e601d8e462f7fd1e04bed43ac42212429` | PNG Reference Library License 2.0 | `c48a229e3318ecade5801094a53a3230b8fcfd4ed0e855d70841be3d360f9bbd` |

The versions are declared by the exact swift-libass release and agree with the bundled headers. The
upstream tag commits were independently resolved from the canonical repositories. The included license
files are copied from those exact tags, not from a later default branch.

FreeType binary distribution must include an acknowledgment that the software is based in part on the
work of the FreeType Team. FriBidi is an independent LGPL component. AetherEngine's Apple Store / DRM
exception is permission from AetherEngine's copyright holder for AetherEngine; it does not amend the
license of an independent third-party library.

## Remaining open release blockers

The unpinned-source and unpublished-rebuild blockers are closed by the two public qoli bundles above.
That is a technical provenance result, not an App Store LGPL legal approval. Before a TestFlight/App
Store release that includes these static libraries, all of the following must still close:

1. Produce release-specific Syncnext Corresponding Application Code, object/relink material or another
   legally approved relink mechanism, exact link instructions and installation-information position.
   Static linking must not be treated as if it were a system shared-library mechanism.
2. Obtain project-owner/legal approval for the complete combined work, including FFmpegBuild, FriBidi,
   and libzvbi's file-level license inventory. The qoli forks deliberately do not claim that public
   source alone makes the static App Store distribution compliant.
3. Include AetherEngine's LICENSE, this notice, every applicable file in `ThirdPartyLicenses`, both
   public Gate 1A bundles, exact revisions, modifications and relink instructions in the app release
   compliance archive and notices surface.
4. Audit the final app archive and link map against the locked binaries and record the final hashes. A
   passing source build alone does not prove which native archives were shipped.

Until those rows pass, Aether is an engine/device-tested release candidate but Gate 1A is not legally
release-approved. Do not hide the gap by omitting notices, changing route at runtime, or silently
substituting another renderer or native runtime.
