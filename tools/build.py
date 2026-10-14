#!/usr/bin/env python3
"""Build and verify the native v0.2.0 app entirely in its portable directory."""
import argparse, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--destination', type=pathlib.Path)
    parser.add_argument('--test',action='store_true'); parser.add_argument('--probe',action='store_true')
    parser.add_argument('--skip-icons',action='store_true')
    args=parser.parse_args()
    destination=(args.destination or ROOT.parent).resolve()
    marker=destination/'QuietGuard.portable.json'
    if not marker.is_file() or destination.is_symlink(): raise RuntimeError('A prepared portable directory is required')
    identity=json.loads(marker.read_text())
    mount=destination
    while mount.parent != mount and not mount.is_mount(): mount=mount.parent
    info=plistlib.loads(subprocess.run(['/usr/sbin/diskutil','info','-plist',str(mount)],check=True,capture_output=True).stdout)
    if info.get('VolumeUUID') != identity['volumeUUID'] or info.get('Internal') is True:
        raise RuntimeError('Refusing to build onto an unexpected or internal volume')
    work=destination/'Work'; work.mkdir(exist_ok=True)
    (work/'tmp').mkdir(exist_ok=True); (work/'ModuleCache').mkdir(exist_ok=True)
    env=os.environ.copy(); env.update({'TMPDIR':str(work/'tmp')+'/', 'CLANG_MODULE_CACHE_PATH':str(work/'ModuleCache')})
    def run(command,timeout=240):
        result=subprocess.run([str(a) for a in command],cwd=ROOT,env=env,text=True,capture_output=True,timeout=timeout)
        if result.stdout: print(result.stdout,end='')
        if result.stderr: print(result.stderr,end='',file=sys.stderr)
        if result.returncode: raise RuntimeError(f'Command failed ({result.returncode}): {command[0]}')
        return result.stdout
    assets=ROOT/'Assets'; assets.mkdir(exist_ok=True)
    if not args.skip_icons or not (assets/'QuietGuard.icns').exists():
        run(['xcrun','swift','-module-cache-path',work/'ModuleCache',ROOT/'tools/make_icon.swift',assets])
        run(['/usr/bin/iconutil','-c','icns',assets/'QuietGuard.iconset','-o',assets/'QuietGuard.icns'])
    app=destination/'长安 QuietGuard.app'; macos=app/'Contents/MacOS'; resources=app/'Contents/Resources'
    macos.mkdir(parents=True,exist_ok=True); resources.mkdir(parents=True,exist_ok=True)
    binary=macos/'QuietGuard'; obj=work/'Bridge.o'
    # Refuse to overwrite an executable which is currently running.
    ps=subprocess.run(['/bin/ps','-ax','-o','comm='],check=True,capture_output=True,text=True).stdout
    if any(line.strip()==str(binary) for line in ps.splitlines()): raise RuntimeError('Quit this portable app before rebuilding')
    run(['xcrun','clang','-O2','-Wall','-Wextra','-mmacosx-version-min=15.0','-c',ROOT/'Sources/Bridge.c','-o',obj])
    files=['Core.swift','PortableStore.swift','Monitor.swift','Interface.swift','Tests.swift','StorageTests.swift','main.swift']
    command=['xcrun','swiftc','-O','-swift-version','5','-module-cache-path',work/'ModuleCache','-target','arm64-apple-macosx15.0',
             '-import-objc-header',ROOT/'Sources/Bridge.h',*[ROOT/'Sources'/name for name in files],obj,'-o',binary]
    for framework in ['AppKit','SwiftUI','Charts','IOKit','UserNotifications']: command+=['-framework',framework]
    run(command)
    bundle={'CFBundleIdentifier':'local.quietguard.app','CFBundleName':'QuietGuard','CFBundleDisplayName':'长安 QuietGuard',
            'CFBundleExecutable':'QuietGuard','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.2.0',
            'CFBundleVersion':'2','LSMinimumSystemVersion':'15.0','LSUIElement':True,'NSHighResolutionCapable':True,
            'CFBundleIconFile':'QuietGuard.icns','NSHumanReadableCopyright':'QuietGuard contributors. Stats MIT attribution retained.'}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(bundle))
    (resources/'PortableConfig.json').write_text(json.dumps(identity,indent=2)+'\n')
    for name in ['QuietGuard.icns','QuietGuardMark.png','QuietGuardMenu.png','QuietGuardMenu@2x.png']:
        shutil.copy2(assets/name,resources/name)
    shutil.copy2(ROOT/'Vendor/Stats/LICENSE',resources/'Stats-MIT-LICENSE.txt')
    for name in ['README.md','SECURITY.md','THIRD_PARTY.md','LICENSE','CHANGELOG.md']:
        if (ROOT/name).exists(): shutil.copy2(ROOT/name,resources/name)
    run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',app])
    run(['/usr/bin/codesign','--verify','--strict','--verbose=2',app])
    report={'version':'0.2.0','app':str(app),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
            'binary_bytes':binary.stat().st_size,'signature':'local ad-hoc; not notarized',
            'portable_check':run([binary,'--portable-check']), 'storage_volume_uuid':identity['volumeUUID'],
            'icon_sha256':hashlib.sha256((resources/'QuietGuard.icns').read_bytes()).hexdigest()}
    if args.test:
        report['rule_tests']=run([binary,'--self-test'])
        report['storage_tests']=run([binary,'--storage-self-test'])
        report['signal_test']=run([binary,'--signal-self-test'])
    if args.probe: report['hardware_probe']=json.loads(run([binary,'--probe']))
    (work/'verification-v0.2.0.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['rule_tests','storage_tests','signal_test']},ensure_ascii=False,indent=2))
if __name__=='__main__': main()
