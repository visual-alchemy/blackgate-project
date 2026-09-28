# Customer-facing release notes

`priv/release-notes.json` holds only the current release's version, release date,
and short customer-facing changes. Update it together with
`iso-builder/release-version` before building a release. Production builds reject
missing, malformed, or mismatched notes; signed-update packaging also checks its
requested version matches the release version.

Describe observable changes in plain language. Mention behavior that affects
streams or requires customer action. Do not include credentials, internal commit
details, or previous releases' notes.

The notes travel inside the application archive covered by the signed manifest's
release checksum. Settings > System > Software Updates reads notes from the
running application's private directory, alongside its release version. Uploading
or selecting another package does not change this view. Deploying a release changes
the notes after it starts. There is no history browser. Older releases without this
feature cannot display notes.

Expiry reminders appear throughout the authenticated dashboard at 7 days,
3 days, and 24 hours remaining, using the gateway's evaluated remaining seconds.
The browser formats the exact deadline in its local timezone and UTC. Reminders
do not change route operation or license deadlines.

Validation:

```sh
rtk node --test web_app/src/utils/licenseWarning.test.js
```

Run backend tests with isolated `DATABASE_DATA_DIR` and `BLACKGATE_UNIX_SOCKET`
paths to avoid interfering with a running appliance.
