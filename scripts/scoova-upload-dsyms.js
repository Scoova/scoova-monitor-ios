#!/usr/bin/env node
/**
 * scoova-upload-dsyms — package + upload iOS dSYM bundles to Scoova Monitor.
 *
 * After Xcode archives an iOS app, the matching dSYM files live at:
 *   <DerivedData>/.../Build/Products/<config>-iphoneos/<App>.app.dSYM
 * and inside the .xcarchive at:
 *   <Archive>.xcarchive/dSYMs/<App>.app.dSYM
 *
 * This CLI:
 *   1. Walks --dir for `.app.dSYM` directories
 *   2. ZIPs each one (via the system `zip` binary; preserves file structure)
 *   3. POSTs each ZIP to /v1/upload/mapping with mappingType=dsym
 *
 * Usage (manual, from a Terminal):
 *   node scoova-upload-dsyms.js \
 *     --api-key sm_xxx \
 *     --version 1.4.0 \
 *     --build 42 \
 *     --dir ~/Library/Developer/Xcode/Archives/.../MyApp.xcarchive/dSYMs
 *
 * Or in a Run Script Build Phase in Xcode. The script ships inside this
 * Swift Package, so it is already on disk once the SDK is added — point
 * the build phase at the SPM checkout:
 *   if [ "$CONFIGURATION" = "Release" ]; then
 *       SCRIPT="${BUILD_DIR%Build/*}SourcePackages/checkouts/scoova-monitor-ios/scripts/scoova-upload-dsyms.js"
 *       node "$SCRIPT" \
 *           --api-key "$SCOOVA_API_KEY" \
 *           --version "$MARKETING_VERSION" \
 *           --build "$CURRENT_PROJECT_VERSION" \
 *           --dir "$DWARF_DSYM_FOLDER_PATH"
 *   fi
 *
 * No external dependencies — uses Node stdlib + the system `zip` binary.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const child_process = require('child_process');
const https = require('https');
const http = require('http');
const url = require('url');

const args = parseArgs(process.argv.slice(2));

if (!args['api-key'] || !args.version || !args.dir) {
    usage();
    process.exit(1);
}

const endpoint = args.endpoint || 'https://monitor.scoo-va.info';
const buildNumber = String(args.build || '');

main().catch(err => {
    console.error('FAILED:', err.message || err);
    process.exit(2);
});

async function main() {
    const dir = path.resolve(args.dir);
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
        throw new Error(`directory not found: ${dir}`);
    }
    const dsyms = walkForDsyms(dir);
    if (dsyms.length === 0) {
        console.error(`no .app.dSYM folders found under ${dir}`);
        return;
    }
    console.log(`Found ${dsyms.length} dSYM bundle(s) under ${dir}`);
    console.log(`Uploading to ${endpoint} for v${args.version} build ${buildNumber || '(none)'}`);

    let ok = 0, failed = 0;
    for (const dsym of dsyms) {
        const name = path.basename(dsym);
        const tmpZip = path.join(os.tmpdir(), `scoova-${Date.now()}-${name}.zip`);
        try {
            // Zip the dSYM directory tree, preserving structure
            child_process.execFileSync('zip', ['-r', '-q', tmpZip, name], {
                cwd: path.dirname(dsym),
                stdio: ['ignore', 'ignore', 'inherit'],
            });
            const sizeMB = (fs.statSync(tmpZip).size / 1024 / 1024).toFixed(1);
            await uploadOne(tmpZip, name);
            console.log(`  ✓ ${name} (${sizeMB} MB)`);
            ok++;
        } catch (e) {
            console.error(`  ✗ ${name}: ${e.message}`);
            failed++;
        } finally {
            try { fs.unlinkSync(tmpZip); } catch (_) {}
        }
    }
    console.log(`\nDone: ${ok} uploaded, ${failed} failed.`);
    if (failed > 0) process.exit(3);
}

function uploadOne(zipPath, name) {
    return new Promise((resolve, reject) => {
        const data = fs.readFileSync(zipPath);
        const target = url.parse(endpoint + '/v1/upload/mapping');
        const isHttps = target.protocol === 'https:';
        const lib = isHttps ? https : http;

        const boundary = '----scoova' + Math.random().toString(36).slice(2);
        const parts = [];
        const field = (k, v) => parts.push(Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`,
        ));
        field('appVersion', args.version);
        field('buildNumber', buildNumber);
        field('platform', 'ios');
        field('mappingType', 'dsym');
        parts.push(Buffer.from(
            `--${boundary}\r\nContent-Disposition: form-data; name="mapping"; filename="${name}.zip"\r\n` +
            `Content-Type: application/zip\r\n\r\n`,
        ));
        parts.push(data);
        parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));
        const body = Buffer.concat(parts);

        const req = lib.request({
            hostname: target.hostname,
            port: target.port,
            path: target.path,
            method: 'POST',
            headers: {
                'X-API-Key': args['api-key'],
                'Content-Type': `multipart/form-data; boundary=${boundary}`,
                'Content-Length': body.length,
            },
            timeout: 180_000,
        }, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => {
                const status = res.statusCode || 0;
                const text = Buffer.concat(chunks).toString('utf8');
                if (status >= 200 && status < 300) return resolve();
                reject(new Error(`HTTP ${status}: ${text.slice(0, 200)}`));
            });
        });
        req.on('error', reject);
        req.on('timeout', () => req.destroy(new Error('upload timed out')));
        req.write(body);
        req.end();
    });
}

function walkForDsyms(dir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            if (entry.name.endsWith('.dSYM')) {
                out.push(p);
            } else {
                out.push(...walkForDsyms(p));
            }
        }
    }
    return out;
}

function parseArgs(argv) {
    const out = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith('--')) {
            const k = a.slice(2);
            const v = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : 'true';
            out[k] = v;
        }
    }
    return out;
}

function usage() {
    console.error(`scoova-upload-dsyms — upload iOS dSYM bundles to Scoova Monitor

Usage:
  node scoova-upload-dsyms.js --api-key <KEY> --version <V> [--build <BUILD>] --dir <DIR> [--endpoint <URL>]

Required:
  --api-key   Scoova Monitor API key for the iOS platform
  --version   App version, e.g. "1.4.0"
  --dir       Directory to scan for *.app.dSYM bundles (recursive)

Optional:
  --build     Build number (recommended: $CURRENT_PROJECT_VERSION in Xcode)
  --endpoint  Override the Scoova endpoint (default: https://monitor.scoo-va.info)

Xcode Run Script integration (Build Phases → New Run Script Phase, after Embed).
The script ships inside this Swift Package, so it is already on disk:
  if [ "$CONFIGURATION" = "Release" ]; then
      SCRIPT="\${BUILD_DIR%Build/*}SourcePackages/checkouts/scoova-monitor-ios/scripts/scoova-upload-dsyms.js"
      node "$SCRIPT" \\
          --api-key "$SCOOVA_API_KEY" \\
          --version "$MARKETING_VERSION" \\
          --build   "$CURRENT_PROJECT_VERSION" \\
          --dir     "$DWARF_DSYM_FOLDER_PATH"
  fi

Set SCOOVA_API_KEY in the scheme's Build → Pre-actions or as a User-Defined Setting.
`);
}
