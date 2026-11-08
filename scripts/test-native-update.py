from pathlib import Path
import subprocess,shutil,plistlib,hashlib,json,tempfile,time,uuid,sys
automatic="--automatic" in sys.argv
repo=Path(__file__).resolve().parent.parent
root=Path(tempfile.mkdtemp(prefix='winmouse-native-update-'))
fixture_id='io.github.anilmetin0.winmouse-update-test.'+uuid.uuid4().hex
print(f'Native update fixture: {root}',flush=True)
shared=(repo/'Sources/Shared/UpdateSupport.swift').read_text().replace('static let bundleID = "io.github.anilmetin0.winmouse"',f'static let bundleID = "{fixture_id}"')
(root/'UpdateSupport.swift').write_text(shared)
app=(repo/'Sources/WinMouse/App.swift').read_text()
app=app.replace('let app = NSApplication.shared','UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["tr"], "launchedBefore": true], forName: UserDefaults.argumentDomain)\n        let app = NSApplication.shared',1)
app=app.replace('Settings.registerDefaults()', '''URLProtocol.registerClass(UpdateFixtureProtocol.self)
        fixtureRecord("launch")
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.2.0" {
            Task {
                self.updater.check()
                while self.updater.phase == .checking { try? await Task.sleep(for: .milliseconds(50)) }
                if case .available(let release) = self.updater.phase {
                    fixtureRecord("available")
                    self.updater.install(release)
                    while self.updater.busy { try? await Task.sleep(for: .milliseconds(50)) }
                    if case .failed(let message) = self.updater.phase { try? message.write(toFile: "__WINMOUSE_FIXTURE_ROOT__/error", atomically: true, encoding: .utf8) }
                }
            }
        }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.3.0" {
            Task { try? await Task.sleep(for: .seconds(3)); NSApp.terminate(nil) }
        }
        Settings.registerDefaults()''',1)
app=app.replace('"launchedBefore": true]', '"launchedBefore": true, "automaticUpdates": '+('true' if automatic else 'false')+']')
if automatic:
 app=app.replace('if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.2.0" {','if false {')
 app=app.replace('Settings.registerDefaults()', '''if Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.2.0" {
            Task {
                while !self.updater.hasPreparedUpdate { try? await Task.sleep(for: .milliseconds(50)) }
                fixtureRecord("deferred")
                self.tap.canRestartForUpdate = true
                self.tap.onInputIdle?()
            }
        }
        Settings.registerDefaults()''',1)
(root/'App.swift').write_text(app)
(root/'Fixture.swift').write_text('''import AppKit
import Foundation
func fixtureRecord(_ event:String) {
 let path=URL(fileURLWithPath:"__WINMOUSE_FIXTURE_ROOT__/events")
 if !FileManager.default.fileExists(atPath:path.path) { FileManager.default.createFile(atPath:path.path,contents:nil) }
 let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "?"
 if let file=try? FileHandle(forWritingTo:path) { _ = try? file.seekToEnd();try? file.write(contentsOf:Data("\\(event) \\(version)\\n".utf8));try? file.close() }
}
@MainActor final class PointerController {
 var mice:[String]=[]; var onMiceChange:(@MainActor ()->Void)?
 func apply(_ settings:Settings) {}
 func restoreAll() { fixtureRecord("restore") }
}
@MainActor final class MouseTap {
 var onPermissionLost:(@MainActor ()->Void)?; var onInputIdle:(@MainActor ()->Void)?
 var canRestartForUpdate = true
 func apply(_ settings:Settings)->Bool { true }
 func stop() { fixtureRecord("stop") }
}
final class UpdateFixtureProtocol: URLProtocol,@unchecked Sendable {
 override class func canInit(with r:URLRequest)->Bool { r.url?.host == "github.com" && (r.url?.path.contains("/anilmetin0/winmouse/releases/") ?? false) }
 override class func canonicalRequest(for r:URLRequest)->URLRequest { r }
 override func startLoading() {
  let data:Data
  if request.url?.lastPathComponent == "update.json" { data=try! Data(contentsOf:URL(fileURLWithPath:"__WINMOUSE_FIXTURE_ROOT__/update.json")) }
  else { data=try! Data(contentsOf:URL(fileURLWithPath:"__WINMOUSE_FIXTURE_ROOT__/WinMouse-0.3.0.dmg")) }
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
''')
if automatic:
 p=root/'Fixture.swift';p.write_text(p.read_text().replace('var canRestartForUpdate = true','var canRestartForUpdate = false'))
for name in ['App.swift','Fixture.swift']:
 p=root/name;p.write_text(p.read_text().replace('__WINMOUSE_FIXTURE_ROOT__',str(root)))
cache=str(repo/'build/ModuleCache')
common=['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-disable-sandbox','-module-cache-path',cache]
subprocess.run(common+[str(repo/'Sources/UpdateHelper/main.swift'),str(root/'UpdateSupport.swift'),'-o',str(root/'WinMouseUpdater')],check=True)
inputs=[p for p in (repo/'Sources/WinMouse').glob('*.swift') if p.name not in ['App.swift','PointerController.swift','MouseTap.swift']]
subprocess.run(common+[str(p) for p in inputs]+[str(root/'App.swift'),str(root/'Fixture.swift'),str(root/'UpdateSupport.swift'),'-o',str(root/'WinMouse')],check=True)
for version in ['0.2.0','0.3.0']:
 app=root/version/'WinMouse.app';(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True);(app/'Contents/Resources').mkdir(exist_ok=True)
 shutil.copy2(root/'WinMouse',app/'Contents/MacOS/WinMouse');shutil.copy2(root/'WinMouseUpdater',app/'Contents/MacOS/WinMouseUpdater')
 shutil.copy2(repo/'Resources/AppIcon.icns',app/'Contents/Resources/AppIcon.icns')
 for language in ['en','tr']:shutil.copytree(repo/f'Resources/{language}.lproj',app/f'Contents/Resources/{language}.lproj',dirs_exist_ok=True)
 info=plistlib.loads((repo/'Resources/Info.plist').read_bytes());info['CFBundleIdentifier']=fixture_id;info['CFBundleName']='WinMouseUpdateE2E';info['CFBundleShortVersionString']=version
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 for target in [app/'Contents/MacOS/WinMouseUpdater',app]:subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(target)],check=True)
(root/'image').mkdir(exist_ok=True)
shutil.copytree(root/'0.3.0/WinMouse.app',root/'image/WinMouse.app',dirs_exist_ok=True)
print('E2E fixture uses production App/Updater/helper code with a separate bundle ID, mock mouse controllers and fixture network responses')

subprocess.run(['/usr/bin/hdiutil','create','-quiet','-volname','WinMouse update fixture','-srcfolder',str(root/'image'),'-fs','HFS+','-format','UDZO','-ov',str(root/'WinMouse-0.3.0.dmg')],check=True)
manifest=subprocess.check_output(['python3',str(repo/'scripts/update-manifest.py'),'0.3.0',str(root/'WinMouse-0.3.0.dmg')])
(root/'update.json').write_bytes(manifest)
subprocess.run(['xcodebuildmcp','macos','launch','--app-path',str(root/'0.2.0/WinMouse.app')],check=True)
deadline=time.monotonic()+60
while time.monotonic()<deadline:
 log=(root/'events').read_text() if (root/'events').exists() else ''
 if 'restore 0.3.0' in log: break
 if (root/'error').exists(): raise RuntimeError((root/'error').read_text())
 time.sleep(0.2)
else: raise RuntimeError(f'Update timed out; inspect {root}')
expected=['launch 0.2.0','available 0.2.0','stop 0.2.0','restore 0.2.0','launch 0.3.0','stop 0.3.0','restore 0.3.0']
if automatic: expected[1]='deferred 0.2.0'
assert log.splitlines()==expected,log
installed=root/'0.2.0/WinMouse.app'
assert plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']=='0.3.0'
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(installed)],check=True)
print(log,flush=True)
print(('Automatic' if automatic else 'Manual')+' native update: verified download -> orderly shutdown -> bundle replacement -> relaunch PASS',flush=True)
