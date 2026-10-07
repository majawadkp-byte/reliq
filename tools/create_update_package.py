#!/usr/bin/env python3
import argparse, hashlib, json, pathlib, zipfile


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description='Create a RELIQ offline update package (.reliq).')
    ap.add_argument('--version', required=True)
    ap.add_argument('--build', required=True, type=int)
    ap.add_argument('--db-min', required=True, type=int)
    ap.add_argument('--db-target', required=True, type=int)
    ap.add_argument('--channel', default='stable')
    ap.add_argument('--notes', default='')
    ap.add_argument('--windows', type=pathlib.Path)
    ap.add_argument('--macos', type=pathlib.Path)
    ap.add_argument('--output', required=True, type=pathlib.Path)
    args = ap.parse_args()

    platforms = {}
    files = []
    if args.windows:
        if not args.windows.exists(): raise SystemExit(f'Windows payload not found: {args.windows}')
        name = 'payload/windows/RELIQ_Solutions_Windows.zip'
        platforms['windows'] = {'file': name, 'kind': 'windows_zip', 'sha256': sha256(args.windows)}
        files.append((args.windows, name))
    if args.macos:
        if not args.macos.exists(): raise SystemExit(f'macOS payload not found: {args.macos}')
        name = 'payload/macos/RELIQ_Solutions_macOS_App.tgz'
        platforms['macos'] = {'file': name, 'kind': 'macos_app_tgz', 'sha256': sha256(args.macos)}
        files.append((args.macos, name))
    if not platforms: raise SystemExit('At least one platform payload is required.')

    manifest = {
        'format': 'reliq-update-v1',
        'product': 'RELIQ Solutions',
        'version': args.version,
        'build': args.build,
        'minimum_database_version': args.db_min,
        'target_database_version': args.db_target,
        'release_notes': args.notes,
        'channel': args.channel,
        'platforms': platforms,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.writestr('manifest.json', json.dumps(manifest, indent=2))
        for src, arcname in files:
            z.write(src, arcname)
    print(args.output)
    print('SHA256:', sha256(args.output))

if __name__ == '__main__':
    main()
