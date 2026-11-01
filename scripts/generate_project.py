"""Generate a standalone macOS Xcode project without external dependencies."""
from pathlib import Path
from hashlib import sha256
import json

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchBeat"
objects = []

def uid(name): return sha256(name.encode()).hexdigest()[:24].upper()
def quote(value): return json.dumps(str(value), ensure_ascii=False)
def obj(label, body):
    objects.append(f"{uid(label)} /* {label} */ = {{ {body} }};")
    return uid(label)

source_paths = sorted([p.relative_to(SOURCE).as_posix() for p in SOURCE.rglob("*.swift")]
                    + [p.relative_to(SOURCE).as_posix() for p in SOURCE.rglob("*.m")])
other_paths = ["Info.plist", "NotchBeat.entitlements", "NotchBeat-Bridging-Header.h", "Media/MediaRemoteBridge.h", "Assets.xcassets"]
for path in source_paths + other_paths:
    ext = Path(path).suffix
    kind = {".swift": "sourcecode.swift", ".m": "sourcecode.c.objc", ".h": "sourcecode.c.h", ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements", ".xcassets": "folder.assetcatalog"}[ext]
    obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = \"<group>\";")
    if path in source_paths or path == "Assets.xcassets":
        obj("build:" + path, f"isa = PBXBuildFile; fileRef = {uid('file:' + path)};")
obj("appProduct", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = NotchBeat.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("sourceGroup", 'isa = PBXGroup; path = NotchBeat; sourceTree = "<group>"; children = (' + ', '.join(uid('file:' + p) for p in source_paths + other_paths) + ', );')
obj("products", f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({uid("appProduct")}, );')
obj("root", f'isa = PBXGroup; sourceTree = "<group>"; children = ({uid("sourceGroup")}, {uid("products")}, );')
obj("sources", 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ', '.join(uid('build:' + p) for p in source_paths) + ', ); runOnlyForDeploymentPostprocessing = 0;')
obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("build:Assets.xcassets")}, ); runOnlyForDeploymentPostprocessing = 0;')
obj("frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfigs")}; buildPhases = ({uid("sources")}, {uid("frameworks")}, {uid("resources")}, ); buildRules = (); dependencies = (); name = NotchBeat; productName = NotchBeat; productReference = {uid("appProduct")}; productType = "com.apple.product-type.application";')
obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; BuildIndependentTargetsInParallel = YES; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {uid("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; knownRegions = (ru, en, Base); mainGroup = {uid("root")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")}, );')

for mode in ("Debug", "Release"):
    project_settings = {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
        "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO",
        "GCC_OPTIMIZATION_LEVEL": "0" if mode == "Debug" else "s",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
        "ENABLE_TESTABILITY": "YES" if mode == "Debug" else "NO"
    }
    target_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.alex.notchbeat", "PRODUCT_NAME": "$(TARGET_NAME)",
        "INFOPLIST_FILE": "NotchBeat/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "NotchBeat/NotchBeat.entitlements", "CODE_SIGN_IDENTITY": "-",
        "CODE_SIGN_STYLE": "Automatic", "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "COMBINE_HIDPI_IMAGES": "YES",
        "SWIFT_OBJC_BRIDGING_HEADER": "NotchBeat/NotchBeat-Bridging-Header.h",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks"
    }
    for group, settings in (("project", project_settings), ("target", target_settings)):
        obj(f"{group}:{mode}", 'isa = XCBuildConfiguration; buildSettings = { ' + ' '.join(f'{key} = {quote(value)};' for key, value in settings.items()) + f' }}; name = {mode};')
for group in ("project", "target"):
    obj(group + "Configs", f'isa = XCConfigurationList; buildConfigurations = ({uid(group + ":Debug")}, {uid(group + ":Release")}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project = ROOT / "NotchBeat.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="NotchBeat.app" BlueprintName="NotchBeat" ReferencedContainer="container:NotchBeat.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="NotchBeat.app" BlueprintName="NotchBeat" ReferencedContainer="container:NotchBeat.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="NotchBeat.app" BlueprintName="NotchBeat" ReferencedContainer="container:NotchBeat.xcodeproj"/></BuildableProductRunnable>
 </ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
scheme_path = project / "xcshareddata" / "xcschemes" / "NotchBeat.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme)
print(f"Generated project with {len(source_paths)} compiled source files")
