# OnTrack on desktop

OnTrack's desktop app is the existing website installed through a desktop
browser. It opens in its own window, uses the same account and API, and receives
web releases through the existing Angular service worker. Desktop and mobile
share the same web build; no additional server, API endpoint, database migration,
app store account, or native installer is required for desktop installation.

Installation is not an offline submission feature. Previously cached interface
assets may load without a connection, but sign-in, current unit/task data,
submissions, comments, file uploads and downloads, and server notifications need
the network. Save work before reloading or applying an update.

## Install and remove

Use the institution's normal HTTPS OnTrack address in a regular browser window.
Open **Install OnTrack** below sign-in or in the account menu for guidance, or use the browser's
own install control. Browser policies, versions, and existing installations can
change which controls appear. A dismissed suggestion does not require clearing
site data: the account-menu entry remains available.

| Desktop | Browser | Installation |
| --- | --- | --- |
| Windows | Chrome | Select the install icon in the address bar, or **More → Cast, save, and share → Install page as app**; confirm installation. |
| Windows | Edge | Select the app-available icon in the address bar, or **Settings and more → More tools → Apps → Install this site as an app**. |
| macOS | Chrome or Edge | Use the browser's install icon/menu; launch OnTrack from the installed app shortcut and optionally keep it in the Dock. |
| macOS Sonoma 14 or later | Safari | Open the OnTrack home page, choose **File → Add to Dock** (also available from Share), then **Add**. Open the Dock app and sign in if requested. |
| Linux | Chrome | Use the install icon or **More → Cast, save, and share → Install page as app**; launch from the desktop environment's application menu. |

Chrome documents desktop installation, shortcuts and uninstall for Windows,
macOS and Linux in [Use web apps](https://support.google.com/chrome/answer/9658361?co=GENIE.Platform%3DDesktop&hl=en).
Edge documents installation and app management in
[Install, manage, or uninstall apps](https://support.microsoft.com/en-us/edge/install-manage-or-uninstall-apps-in-microsoft-edge).
Safari web apps require macOS Sonoma 14 or later and maintain their own cookies
and website data, so a new app may need another sign-in. See
[Use Safari web apps on Mac](https://support.apple.com/en-us/104996).

Firefox on Windows also offers manual web apps, starting with version 143
(version 150 for Microsoft Store installations). Its web-app behavior differs
from Chromium's manifest-driven install prompt; validate it separately if the
institution includes it in the support matrix. Do not present Firefox as
universally unable to install desktop web apps. See
[Mozilla's Windows web app guide](https://support.mozilla.org/en-US/kb/web-apps-firefox-windows).
Other browser/platform combinations can continue using the website.

Launch the installed OnTrack shortcut to get the app window. Existing browser
tabs remain tabs. Desktop taskbar/Dock integration and shortcut menus vary by
browser and OS; the manifest's Home, Notifications and Unit Hub shortcuts are
optional browser features. An unauthenticated shortcut must send the user through
sign-in before displaying account data.

For removal, use the installed app's browser menu: Chrome offers
**Uninstall OnTrack**, and Edge manages installed apps at `edge://apps`.
Safari creates the app in the user's Applications folder; move that app to Trash
to remove it. Removing a local app does not delete the OnTrack account or server
submissions. Deleting website data may remove local preferences and sessions.

## Deployment contract

Build the production `doubtfire-web` release with its existing Docker build and
Angular service worker enabled. The development server is not the installation
acceptance target. Keep the web app at the root of its canonical HTTPS origin,
with `/api` forwarded to the existing API. Retain production certificate checks;
HTTP is only suitable for localhost development.

The web manifest is `/manifest.webmanifest`, linked from `/index.html` with a
root `<base href="/">`. The explicit app `id` and `start_url` both resolve to
`/index.html`, matching the previous implicit identity; `scope` stays `/` and
`display` is `standalone`. Keep that origin and identity stable across upgrades
to avoid a second installed app. Changing the installation origin is a migration
that requires separate browser acceptance.

Serve these public assets directly, before any identity-provider redirect:

| Resource | Response contract |
| --- | --- |
| `/index.html` and application navigation routes | HTML app shell, with root base and manifest link |
| `/manifest.webmanifest` | JSON with `application/manifest+json` or `application/json` |
| `/ngsw.json` | Angular-generated control manifest with `application/json` |
| `/ngsw-worker.js` | Angular worker JavaScript with a JavaScript content type |
| Manifest icons | Real PNG files with declared dimensions, including general-purpose 192×192 and 512×512 icons |
| Bundled scripts and styles | Correct JavaScript/CSS content types and bytes matching the generated `ngsw.json` hashes |

The index, web manifest and worker control files must prevent stale caching;
query parameters must not bypass the policy. The existing web `nginx.conf`
provides these headers and returns real 404s for missing control files and
`/assets/` paths. The production proxy forwards those responses. Preserve these
rules in any institutional CDN, ingress, or reverse proxy. Fingerprinted bundles
may be cached normally. Do not upload a new `ngsw.json` ahead of its corresponding
assets or substitute the SPA HTML for a missing worker, manifest or icon.

The API uses its existing authentication callbacks and push configuration.
Desktop installation needs no CORS exception, new auth callback scheme, or
additional VAPID key. A browser may return an external identity-provider flow to
a normal tab; acceptance must confirm the installed app can recover the session
or complete sign-in itself, with no login loop or lost destination. Safari's
separate app storage makes this particularly important.

## Verify a candidate release

From the deploy repository root, run the public-asset gate with Python 3.9 or
later (standard library only):

```bash
python3 -B production/verify-pwa.py https://ontrack.example.edu --timeout 30
```

Replace the example with the actual staging or production origin. For a
production build served through local Nginx, loopback HTTP is also allowed:

```bash
python3 -B production/verify-pwa.py http://localhost:8080
```

The command issues bounded GET requests to public static assets only, does not
use a login or call `/api`, verifies TLS, and rejects redirects. It bypasses
ambient proxy environment variables so it checks the named origin directly.
Each request has a 1–300 second timeout and 32 MiB response limit. It verifies
manifest identity, start/scope, icon PNG data, MIME types, fresh control-file
policy including query variants, entry bundles, and app-shell hash consistency.
Third-party font stylesheets are left to browser acceptance. It does not fetch
every lazy chunk, prove authentication, register a worker, install an OS app,
or verify notification delivery. A pass is evidence about the publicly served
assets, not full browser or operating-system certification.

Run verifier regression tests without a running OnTrack stack or Docker:

```bash
python3 -B production/tests/verify_pwa_test.py
```

CI runs these tests with the required deployment checks. They use a disposable
loopback HTTP server and synthetic assets; they do not contact a live account.

## Browser acceptance and release

1. Build the web image from the exact reviewed desktop-PWA web revision and run
   its focused tests and production build. Use the release process in
   [RELEASING.md](RELEASING.md) to publish the tested image and record its immutable
   digest. Keep deploy/web revision references aligned with that release.
2. Deploy the candidate to a staging HTTPS origin using the existing
   [deployment runbook](DEPLOYING.md), then run `production/verify-pwa.py` against
   that public origin in addition to `production/verify.sh`.
3. On the actual operating systems and browsers the institution will support,
   use a normal fresh browser profile and install OnTrack. Record OS and browser
   versions, web image digest, origin, date, and outcome for each check below.
4. Also test an app installed from the previous release, then deliver the
   candidate at the same origin. Confirm the existing app updates without a
   duplicate installation, the update notice waits for the user's action, and
   canceling/deferring the update keeps the current work available.
5. After acceptance, follow the normal production release procedure. Run both
   production verification and the separate PWA public-asset command against
   the final public origin, then repeat the installed-app smoke checks. Record
   a real browser result before describing a platform as supported.

| Smoke check | Expected result |
| --- | --- |
| Install from the browser and account menu | Guidance matches the platform; a supported browser prompts only after user action; canceling permits a later attempt. |
| Launch, close, relaunch; check taskbar/Dock icon | OnTrack opens in its app window with the expected icon and name; it does not install a duplicate at the same origin. |
| Identity-provider login and logout | Full external login round trip succeeds; callback credentials disappear from the URL; logout and a subsequent launch obey the institution's session policy. |
| Remember-me and non-remembered sessions | Relaunch behaves according to the selected option and existing session expiry rules, including Safari's separate app storage. |
| Home, Notifications, Unit Hub and a permitted task link | In-scope navigation and reload work; signed-out routes require sign-in; browser-provided shortcuts work where offered. |
| Resize, maximize and keyboard navigation | Existing desktop layout remains usable; install guidance traps/returns focus correctly; buttons and close controls are accessible. |
| Submit a permitted test file, download feedback, open an external link | Existing workflows still work; external content follows browser policy without losing OnTrack state. |
| Opt in to notifications using a real test account | OS/browser permission is requested on user action; a background notification arrives and its click opens the intended route. Never promise delivery after the browser is fully quit. |
| Go offline after an online visit, then reconnect | Cached shell may load, while API-backed operations cannot be accepted offline; reconnect restores current data without claiming an unsent submission succeeded. |
| Apply a second staged release | Existing update flow completes after work is saved; the running app and cached resources settle on the new version. |
| Uninstall and reinstall | Browser removal works; reinstall opens the same institution app and server data remains available after sign-in. |

Repeat the existing mobile PWA acceptance on a representative Android and iOS
installation because these platforms share the manifest and worker. Browser
installation, SSO and push need interactive checks; a headless unit test cannot
replace this matrix.

## Rollback and recovery

Retain the prior source revision, web image digest, deploy checkout, and browser
acceptance record. Restoring a byte-identical previous image is **insufficient
for service-worker clients that already know that version**. In Angular 22.0.3,
an already-known `ngsw.json` hash produces `NO_NEW_VERSION_DETECTED` without
changing the worker's latest version. Both an existing window and a newly opened
window can therefore continue using the newer cached release after an old image
is restored.

For a desktop-only web change with no backend or schema change:

1. Rebuild the prior source revision as a **new recovery release**. Run the
   production Angular build again so it generates a fresh `ngsw.json` timestamp
   and version hash. Use the release publisher's `--no-cache-web` option to
   prevent reuse of a Docker layer containing the old output. Give the image a
   distinct immutable release tag and record its digest. Changing only a tag or
   image label does not force Angular to rebuild.
2. Check that the recovery manifest differs from the failed and previous
   manifests, and that all asset hashes match the recovery output. Preserve the
   canonical origin, `/index.html` app identity and `/` scope. Publish the complete
   coherent image, not individually edited control files or bundles.
3. Deploy through the existing change-control and Compose procedure. Run the
   verifier belonging to that source revision against the public origin.
4. In an app still running the failed version, check for an update. Confirm the
   recovery release produces the existing **Reload** notice, leaves unsaved work
   intact until the user acts, and loads the intended recovery content after
   saving work and choosing Reload. Verify a new app window as well, then check
   `/ngsw/state` reports `NORMAL` and repeat the offline/reconnect smoke check.

After pinning the intended recovery source in a clean, reviewed deploy checkout,
use the protected evidence directory and release-version setup from
[RELEASING.md](RELEASING.md#2-publish-attested-application-images), adding the flag
to its publication command:

```bash
PUBLISH_RELEASE_CONFIRM=1 production/publish-release.sh --no-cache-web \
  registry.example.edu/ontrack "$DF_RELEASE_VERSION" linux/amd64,linux/arm64 \
  > "$DF_RELEASE_EVIDENCE_DIR/release-application-digests.txt"
```

The publisher still publishes the full five-image release; only the web build
bypasses cache. Review the output under the normal release policy, and deploy
only the intended component digests. The flag does not deploy or clear browser
data. Use a new evidence file and immutable release version for each attempt.

For a combined application release, use the ordered API/web rollback and
migration decision in [DEPLOYING.md](DEPLOYING.md#upgrades-and-rollback), applying
the same fresh-recovery-build requirement to the web image. The forward-only
deploy helper is not a rollback procedure.

An open window can remain on its prior version until the user reloads; publishing
a recovery image is not an instant client rollback. Check control-file caching
at the public edge if the recovery update is not found. Avoid clearing site data
or changing app identity as the default recovery step: that can remove local
work/preferences or create a second installation.

An older mobile-PWA release
may omit the explicit identity or description required by this desktop verifier;
that expected mismatch must not be reported as a passing desktop release.
Repeat the applicable login, navigation, upload/download, notification and
update smoke checks before accepting the rollback.
