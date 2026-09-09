//
//  auth-schema-closure.mjs
//  WXYC DJ
//
//  Prints, one per line, the transitive `$ref` closure of every schema
//  reachable from wxyc-shared api.yaml's non-device `/auth/*` operations.
//
//  This is the input to regenerate-api-types.sh's AUTH_MODELS_DROP tripwire.
//  Those schemas are owned by the WXYCAuth package (WXYC/wxyc-swift-auth),
//  which vendors its own generated copy of exactly this closure; vendoring
//  them here too would put a second public declaration of each name into any
//  build graph holding both packages. So this repo drops precisely the set
//  that repo keeps.
//
//  The file is a deliberate near-duplicate of wxyc-swift-auth's script of the
//  same name, and the duplication is the point rather than a wart: both repos
//  derive the partition from the SAME api.yaml, so while the two pins name the
//  same commit the two sets are equal by construction and cannot drift into
//  either a collision (a schema kept by both) or a gap (a schema dropped here
//  and never vended there). A shared helper would need a shared distribution
//  channel for one build-time parse, and this repo deliberately depends on
//  wxyc-shared only through the pin.
//
//  A hardcoded list cannot be its own guard -- it silently keeps vendoring a
//  17th auth schema that arrives upstream, and the collision only surfaces as
//  a redeclaration error in whatever target links both packages, far from the
//  list that caused it. This closure can be the guard, because it is derived
//  from api.yaml rather than from the list it checks: a schema newly reachable
//  from an auth operation appears here and fails the comparison, and a list
//  entry that stops being reachable fails it too.
//
//  Usage: node auth-schema-closure.mjs <wxyc-shared-clone-dir>
//
//  Resolves its YAML parser out of the clone's own node_modules (populated by
//  the `npm ci` regenerate-api-types.sh already runs), so this repo carries no
//  package.json of its own for one build-time parse.
//

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const cloneDir = process.argv[2];
if (!cloneDir) {
    console.error('usage: auth-schema-closure.mjs <wxyc-shared-clone-dir>');
    process.exit(2);
}

const require = createRequire(join(resolve(cloneDir), 'package.json'));
const YAML = require('yaml');

const doc = YAML.parse(readFileSync(join(cloneDir, 'api.yaml'), 'utf8'));

// The device-authorization (QR) surface is excluded, so this repo KEEPS the
// DeviceAuth* models. WXYCAuth does not vend them -- wxyc-dj-ios#64's
// approve/deny/verify surface is this app's own -- so they are not part of the
// collision this exclusion exists to prevent, and dropping them would delete
// types the app is expected to consume.
// Segment-matched, NOT a substring prefix. `startsWith('/auth/device')` would
// also swallow a future `/auth/devices` or `/auth/device-code`, and the
// consequence is the silent drop this closure exists to make loud: a schema
// reachable only from such a path never enters the closure, so the two-way
// AUTH_MODELS_DROP comparison passes while the type stays vendored here AND in
// WXYCAuth -- the collision, undetected.
const isDevicePath = (path) => path === '/auth/device' || path.startsWith('/auth/device/');
const isAuthOperationPath = (path) => path.startsWith('/auth/') && !isDevicePath(path);

const schemaRefsIn = (node, found) => {
    if (node === null || typeof node !== 'object') return found;
    if (Array.isArray(node)) {
        for (const child of node) schemaRefsIn(child, found);
        return found;
    }
    for (const [key, value] of Object.entries(node)) {
        if (key === '$ref' && typeof value === 'string') {
            const match = /^#\/components\/schemas\/(.+)$/.exec(value);
            if (!match) {
                // Every `$ref` in this document's auth section is a local
                // component-schema reference. A `$ref` shaped any other way
                // (an external file, a `#/components/responses/...`
                // indirection) would silently contribute nothing to the
                // closure, so the comparison downstream would pass while the
                // staged tree still carries a colliding type. Refuse rather
                // than under-report.
                console.error(`ERROR: unsupported $ref form in the auth surface: ${value}`);
                process.exit(1);
            }
            found.add(match[1]);
        } else {
            schemaRefsIn(value, found);
        }
    }
    return found;
};

const seeds = new Set();
for (const [path, operations] of Object.entries(doc.paths ?? {})) {
    if (isAuthOperationPath(path)) schemaRefsIn(operations, seeds);
}
if (seeds.size === 0) {
    console.error('ERROR: no schemas are reachable from any non-device /auth/* operation -- did the auth section move or get renamed?');
    process.exit(1);
}

const schemas = doc.components?.schemas ?? {};
const closure = new Set();
const pending = [...seeds];
while (pending.length > 0) {
    const name = pending.pop();
    if (closure.has(name)) continue;
    closure.add(name);
    const schema = schemas[name];
    if (schema === undefined) {
        console.error(`ERROR: auth operation references '#/components/schemas/${name}', which the document does not define`);
        process.exit(1);
    }
    for (const ref of schemaRefsIn(schema, new Set())) {
        if (!closure.has(ref)) pending.push(ref);
    }
}

for (const name of [...closure].sort()) console.log(name);
