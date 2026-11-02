#!/usr/bin/env python3
"""Regenerate a dependency-free Xcode project from checked-in Swift sources."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parents[1]
project = root / "LumaFrame.xcodeproj"
project.mkdir(exist_ok=True)
def key(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def quote(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
objects = []
def obj(name, value): objects.append(f"\t\t{key(name)} = {{ {value} }};")
sources = sorted([*root.glob("App/**/*.swift"), *root.glob("LumaCore/Sources/**/*.swift")])
tests = sorted(root.glob("UITests/*.swift"))
resources = [p for p in [root/"App/Assets.xcassets",root/"App/PrivacyInfo.xcprivacy"] if p.exists()]
for p in sources+tests+resources:
    rel = str(p.relative_to(root))
    kind = "folder.assetcatalog" if p.suffix==".xcassets" else ("text.xml" if p.suffix==".xcprivacy" else "sourcecode.swift")
    obj("ref"+rel, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(rel)}; sourceTree = SOURCE_ROOT;")
    obj("build"+rel, f"isa = PBXBuildFile; fileRef = {key('ref'+rel)};")
obj("appProduct", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = LumaFrame.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("testProduct", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = LumaFrameUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj("productGroup", f"isa = PBXGroup; children = ({key('appProduct')}, {key('testProduct')}); name = Products; sourceTree = \"<group>\";")
refs = ", ".join(key("ref"+str(p.relative_to(root))) for p in sources+tests+resources)
obj("mainGroup", f'isa = PBXGroup; children = ({refs}, {key("productGroup")}); sourceTree = "<group>";')
for name, typ, files in [("appSources","PBXSourcesBuildPhase",sources),("testSources","PBXSourcesBuildPhase",tests),("resources","PBXResourcesBuildPhase",resources),("frameworks","PBXFrameworksBuildPhase",[]),("testFrameworks","PBXFrameworksBuildPhase",[])]:
    builds = ", ".join(key("build"+str(p.relative_to(root))) for p in files)
    obj(name, f"isa = {typ}; buildActionMask = 2147483647; files = ({builds}); runOnlyForDeploymentPostprocessing = 0;")
obj("proxy", f'isa = PBXContainerItemProxy; containerPortal = {key("project")}; proxyType = 1; remoteGlobalIDString = {key("appTarget")}; remoteInfo = LumaFrame;')
obj("dependency", f"isa = PBXTargetDependency; target = {key('appTarget')}; targetProxy = {key('proxy')};")
obj("appTarget", f'isa = PBXNativeTarget; buildConfigurationList = {key("appConfigs")}; buildPhases = ({key("appSources")}, {key("frameworks")}, {key("resources")}); buildRules = (); dependencies = (); name = LumaFrame; productName = LumaFrame; productReference = {key("appProduct")}; productType = "com.apple.product-type.application";')
obj("testTarget", f'isa = PBXNativeTarget; buildConfigurationList = {key("testConfigs")}; buildPhases = ({key("testSources")}, {key("testFrameworks")}); buildRules = (); dependencies = ({key("dependency")}); name = LumaFrameUITests; productName = LumaFrameUITests; productReference = {key("testProduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
for scope in ["project","app","test"]:
    for cfg in ["Debug","Release"]:
        settings = {
            "CLANG_ENABLE_MODULES":"YES", "IPHONEOS_DEPLOYMENT_TARGET":"17.0", "SDKROOT":"iphoneos",
            "SWIFT_VERSION":"5.0", "SWIFT_STRICT_CONCURRENCY":"minimal", "TARGETED_DEVICE_FAMILY":"1",
            "ENABLE_USER_SCRIPT_SANDBOXING":"YES", "SWIFT_OPTIMIZATION_LEVEL":"-Onone" if cfg=="Debug" else "-O",
            "DEBUG_INFORMATION_FORMAT":"dwarf" if cfg=="Debug" else "dwarf-with-dsym",
        }
        if cfg=="Debug": settings.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS":"DEBUG","ENABLE_TESTABILITY":"YES"})
        if scope=="app":
            settings.update({"PRODUCT_BUNDLE_IDENTIFIER":"com.lumaframe.dev","PRODUCT_NAME":"$(TARGET_NAME)","INFOPLIST_FILE":"App/Info.plist",
                             "CODE_SIGN_STYLE":"Automatic","CURRENT_PROJECT_VERSION":"1","MARKETING_VERSION":"0.1.0",
                             "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator","LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks"})
            if (root/"App/Assets.xcassets").exists(): settings["ASSETCATALOG_COMPILER_APPICON_NAME"]="AppIcon"
        if scope=="test":
            settings.update({"PRODUCT_BUNDLE_IDENTIFIER":"com.lumaframe.dev.uitests","PRODUCT_NAME":"$(TARGET_NAME)",
                             "GENERATE_INFOPLIST_FILE":"YES","CODE_SIGN_STYLE":"Automatic","TEST_TARGET_NAME":"LumaFrame"})
        content = " ".join(f"{k} = {quote(v)};" for k,v in settings.items())
        obj(scope+cfg, f"isa = XCBuildConfiguration; buildSettings = {{ {content} }}; name = {cfg};")
    obj(scope+"Configs", f"isa = XCConfigurationList; buildConfigurations = ({key(scope+'Debug')}, {key(scope+'Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {key("appTarget")} = {{ CreatedOnToolsVersion = 26.6; }}; {key("testTarget")} = {{ CreatedOnToolsVersion = 26.6; TestTargetID = {key("appTarget")}; }}; }}; }}; buildConfigurationList = {key("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; knownRegions = ("zh-Hans", en, Base); mainGroup = {key("mainGroup")}; productRefGroup = {key("productGroup")}; projectDirPath = ""; projectRoot = ""; targets = ({key("appTarget")}, {key("testTarget")});')
(project/"project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"+"\n".join(objects)+"\n\t};\n\trootObject = "+key("project")+";\n}\n")
scheme_dir=project/"xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True,exist_ok=True)
def ref(target,product,name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key(target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:LumaFrame.xcodeproj"/>'
app=ref("appTarget","LumaFrame.app","LumaFrame")
test=ref("testTarget","LumaFrameUITests.xctest","LumaFrameUITests")
(scheme_dir/"LumaFrame.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
info={
    "CFBundleDevelopmentRegion":"zh_CN","CFBundleDisplayName":"光格","CFBundleExecutable":"$(EXECUTABLE_NAME)",
    "CFBundleIdentifier":"$(PRODUCT_BUNDLE_IDENTIFIER)","CFBundleInfoDictionaryVersion":"6.0",
    "CFBundleName":"$(PRODUCT_NAME)","CFBundlePackageType":"APPL","CFBundleShortVersionString":"$(MARKETING_VERSION)",
    "CFBundleVersion":"$(CURRENT_PROJECT_VERSION)","LSRequiresIPhoneOS":True,"UILaunchScreen":{},
    "UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait"],
    "UIApplicationSceneManifest":{"UIApplicationSupportsMultipleScenes":False},
    "NSCameraUsageDescription":"光格使用后置相机测量环境曝光并生成本地取景参考图，不会上传画面。",
    "NSPhotoLibraryAddUsageDescription":"将你确认的取景参考图与拍摄参数保存到系统相册。",
    "ITSAppUsesNonExemptEncryption":False
}
(root/"App/Info.plist").write_bytes(plistlib.dumps(info,sort_keys=False))
print(f"Generated {project.name}: {len(sources)} Swift sources, {len(tests)} UI test source(s).")

