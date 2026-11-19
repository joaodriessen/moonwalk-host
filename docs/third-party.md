# Third-party code and source

Moonwalk Host includes code from [Sunshine](https://github.com/LizardByte/Sunshine) and [Lumen](https://github.com/lumaaaaaa/Lumen). The [source provenance](origin.md) identifies the import. See also the project [license](../LICENSE) and [notices](../NOTICE).

## Native dependencies

The app contains static libraries and vendored code. The release recipe pins the source archives for OpenSSL, Opus, miniupnpc, Boost, nlohmann/json and FFmpeg. It verifies those inputs before building. The [VideoToolbox notes](../patches/README.md) describe the patches applied to FFmpeg.

The macOS FFmpeg build links three static libraries from the checksummed Darwin arm64 companion archive. These are the corresponding submodule revisions recorded by the build-deps recipe for that archive.

| Library | Source |
| --- | --- |
| x264 | [`b35605a`](https://github.com/LizardByte-infrastructure/x264/tree/b35605ace3ddf7c1a5d67a2eb553f034aef41d55) |
| x265 | [`1d117be`](https://github.com/LizardByte-infrastructure/x265_git/tree/1d117bed4747758b51bd2c124d738527e30392cb) |
| SVT-AV1 | [`c04f951`](https://github.com/LizardByte-infrastructure/SVT-AV1/tree/c04f951541ad600e0d9c10836f2ab7b9bc69816d) |

[Companion build recipe and patches](https://github.com/LizardByte/build-deps/tree/9d09f3123532beeddcbe42f96a476d2cb261f471) · [Companion archive](https://github.com/LizardByte/build-deps/releases/tag/v2026.621.21936)

The source of TPCircularBuffer retains its license notice in `third-party/TPCircularBuffer`. The other vendored trees retain their notices and license files.

## Web settings

The optional web settings page is built from this repository and the exact npm packages in `package-lock.json`. It includes [LizardByte Shared Web](https://github.com/LizardByte/shared-web/tree/2402f88a8cfcfab0bbf1cdcc9a3da0d9a155f468) under AGPL-3.0-only. The page links to the host's source revision when the build records one.

Vue devtools API 6.6.4 omits the license file from its npm package. The release copies the [MIT license at that package’s source revision](https://github.com/vuejs/vue-devtools/blob/df6ab6bb7791a7a525a97990de73b3ea5e9a1941/LICENSE). The other web notices come from the installed packages.

## For a release

The app includes these license texts under `Contents/Resources/ThirdPartyLicenses/`. Keep the exact source commit, pinned dependency sources, applied patches and build instructions available alongside a downloadable DMG. Before distributing, verify that recipients can get the corresponding source for the complete artifact and that the browser’s source link works for them. [Release checklist](releasing.md)
