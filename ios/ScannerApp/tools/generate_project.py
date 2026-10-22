"""Deterministic native Xcode target, no third-party generator/install required.

The original upstream project is deliberately untouched. This only prepares source/project files;
Xcode on a Mac must compile the app and execute its tests before any installable claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def identity(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()


def generate():
    objects = {}

    def add(key, isa, **values):
        uid = identity(key)
        objects[uid] = dict(isa=isa, **values)
        return uid

    app_sources = sorted(p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*.swift') if 'Tests' not in p.parts)
    tests = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'Tests').rglob('*.swift'))
    source_refs = {}
    for path in app_sources + tests:
        source_refs[path] = add(path, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=path, sourceTree='<group>')
    info = add('plist', 'PBXFileReference', lastKnownFileType='text.plist.xml', path='App/Info.plist', sourceTree='<group>')
    notice = add('notice', 'PBXFileReference', lastKnownFileType='text', path='THIRD-PARTY.md', sourceTree='<group>')
    app_product = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='ScannerApp.app', sourceTree='BUILT_PRODUCTS_DIR')
    test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='ScannerAppTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
    products = add('products', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
    group = add('group', 'PBXGroup', children=list(source_refs.values()) + [info, notice, products], sourceTree='<group>')
    package = add('stream-package', 'XCLocalSwiftPackageReference', relativePath='../StreamingCore')
    library = add('stream-library', 'XCSwiftPackageProductDependency', package=package, productName='ScannerStreamingCore')

    def phases(name, sources, resources=False):
        source_builds = [add(name + '-compile-' + p, 'PBXBuildFile', fileRef=source_refs[p]) for p in sources]
        src = add(name + '-sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
        framework = add(name + '-library', 'PBXBuildFile', productRef=library)
        framework_phase = add(name + '-frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[framework], runOnlyForDeploymentPostprocessing=0)
        resource_builds = [add(name + '-notice', 'PBXBuildFile', fileRef=notice)] if resources else []
        res = add(name + '-resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
        return [src, framework_phase, res]

    common = dict(SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='18.6', SDKROOT='iphoneos',
                  TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
                  CLANG_ENABLE_MODULES='YES', SWIFT_STRICT_CONCURRENCY='targeted', DEVELOPMENT_TEAM='', CODE_SIGN_STYLE='Automatic')

    def configs(name, extra):
        values = []
        for configuration in ('Debug', 'Release'):
            settings = dict(common, **extra)
            settings.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if configuration == 'Debug' else '-O',
                            DEBUG_INFORMATION_FORMAT='dwarf' if configuration == 'Debug' else 'dwarf-with-dsym',
                            ENABLE_TESTABILITY='YES' if configuration == 'Debug' else 'NO')
            if configuration == 'Debug':
                settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
                # Swift package products build only the active simulator arch in Debug; match it.
                settings['ONLY_ACTIVE_ARCH'] = 'YES'
            values.append(add(name + '-' + configuration, 'XCBuildConfiguration', buildSettings=settings, name=configuration))
        return add(name + '-configurations', 'XCConfigurationList', buildConfigurations=values,
                   defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

    app_target = add('app-target', 'PBXNativeTarget', name='ScannerApp', productName='ScannerApp', productReference=app_product,
                     productType='com.apple.product-type.application', buildPhases=phases('app', app_sources, True),
                     buildConfigurationList=configs('app', dict(PRODUCT_BUNDLE_IDENTIFIER='org.scanner3d.capture',
                        PRODUCT_NAME='$(TARGET_NAME)', INFOPLIST_FILE='App/Info.plist', GENERATE_INFOPLIST_FILE='NO')),
                     buildRules=[], dependencies=[], packageProductDependencies=[library])
    proxy = add('test-proxy', 'PBXContainerItemProxy', containerPortal=identity('project'), proxyType=1,
                remoteGlobalIDString=app_target, remoteInfo='ScannerApp')
    dependency = add('test-dependency', 'PBXTargetDependency', target=app_target, targetProxy=proxy)
    test_target = add('test-target', 'PBXNativeTarget', name='ScannerAppTests', productName='ScannerAppTests', productReference=test_product,
                      productType='com.apple.product-type.bundle.unit-test', buildPhases=phases('tests', tests),
                      buildConfigurationList=configs('tests', dict(PRODUCT_BUNDLE_IDENTIFIER='org.scanner3d.capture.tests',
                         PRODUCT_NAME='$(TARGET_NAME)', GENERATE_INFOPLIST_FILE='YES',
                         TEST_HOST='$(BUILT_PRODUCTS_DIR)/ScannerApp.app/ScannerApp', BUNDLE_LOADER='$(TEST_HOST)')),
                      buildRules=[], dependencies=[dependency], packageProductDependencies=[library])
    project = add('project', 'PBXProject', attributes=dict(LastUpgradeCheck='1600', BuildIndependentTargetsInParallel='YES',
                      TargetAttributes={app_target: dict(CreatedOnToolsVersion='16.0'), test_target: dict(CreatedOnToolsVersion='16.0', TestTargetID=app_target)}),
                  buildConfigurationList=configs('project', {}), compatibilityVersion='Xcode 15.0', developmentRegion='en',
                  hasScannedForEncodings=0, knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products,
                  projectDirPath='', projectRoot='', targets=[app_target, test_target], packageReferences=[package])

    def emit(value, level=0):
        if isinstance(value, dict):
            return '{\n' + ''.join('\t' * (level + 1) + json.dumps(k) + ' = ' + emit(v, level + 1) + ';\n' for k, v in value.items()) + '\t' * level + '}'
        if isinstance(value, list): return '(\n' + ''.join('\t' * (level + 1) + emit(v, level + 1) + ',\n' for v in value) + '\t' * level + ')'
        return str(value) if isinstance(value, int) else json.dumps(value, ensure_ascii=False)

    project_text = '// !$*UTF8*$!\n' + emit(dict(archiveVersion=1, classes={}, objectVersion=60, objects=objects, rootObject=project)) + '\n'
    scheme = ET.Element('Scheme', LastUpgradeVersion='1600', version='1.3')
    build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
    entries = ET.SubElement(build, 'BuildActionEntries')
    entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')

    def reference(parent, uid, product, name):
        ET.SubElement(parent, 'BuildableReference', BuildableIdentifier='primary', BlueprintIdentifier=uid,
                      BuildableName=product, BlueprintName=name, ReferencedContainer='container:ScannerApp.xcodeproj')
    reference(entry, app_target, 'ScannerApp.app', 'ScannerApp')
    test_action = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
    testables = ET.SubElement(test_action, 'Testables')
    reference(ET.SubElement(testables, 'TestableReference', skipped='NO'), test_target, 'ScannerAppTests.xctest', 'ScannerAppTests')
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', allowLocationSimulation='NO')
    reference(ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'), app_target, 'ScannerApp.app', 'ScannerApp')
    ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
    ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
    ET.indent(scheme)
    return {'ScannerApp.xcodeproj/project.pbxproj': project_text,
            'ScannerApp.xcodeproj/xcshareddata/xcschemes/ScannerApp.xcscheme': ET.tostring(scheme, encoding='unicode') + '\n'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for relative, text in generate().items():
        path = ROOT / relative
        if args.check:
            if not path.is_file() or path.read_text(encoding='utf-8') != text: raise SystemExit('Stale project: ' + relative)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8', newline='\n')
    print('Project source list current. Preparation only; NOT an Xcode compile.')
