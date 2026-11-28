require 'xcodeproj'

Dir.chdir(__dir__)
firebase = ENV['TRAINER_FIREBASE'] == '1'
name = firebase ? 'TabletopTrainerFirebase' : 'TabletopTrainer'
name += 'Blade' if ENV['TRAINER_BLADE_SDK']
project = Xcodeproj::Project.new("#{name}.xcodeproj")
app = project.new_target(:application, 'TabletopTrainer', :ios, '26.0')
checks = project.new_target(:ui_test_bundle, 'TrainerWorkflowTests', :ios, '26.0')
checks.add_dependency(app)

['App', 'Core'].each do |folder|
  group = project.main_group.new_group(folder, folder)
  Dir["#{folder}/*.swift"].sort.each { |file| app.add_file_references([group.new_file(File.basename(file))]) }
  app.add_resources([group.new_file('Assets.xcassets')]) if folder == 'App'
end

art = project.main_group.new_group('Artwork', 'Artwork')
app.add_resources([art.new_file('TrainerHead.usdz')])

group = project.main_group.new_group('UITests', 'UITests')
Dir['UITests/*.swift'].sort.each { |file| checks.add_file_references([group.new_file(File.basename(file))]) }

app.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'ASSETCATALOG_COMPILER_APPICON_NAME' => '', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => '',
    'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.intublade.tabletoptrainer',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Airway Practice',
    'INFOPLIST_KEY_NSCameraUsageDescription' => 'Place the virtual training head on the table.',
    'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES',
    'INFOPLIST_KEY_FirebaseAppCheckTokenAutoRefreshEnabled' => 'NO',
    'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1', 'IPHONEOS_DEPLOYMENT_TARGET' => '26.0'
  )
end
if firebase
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = 'https://github.com/firebase/firebase-ios-sdk.git'
  package.requirement = { 'kind' => 'exactVersion', 'version' => '12.19.3' }
  project.root_object.package_references << package
  %w[FirebaseAILogic FirebaseAppCheck FirebaseCore].each do |product|
    dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dependency.package = package
    dependency.product_name = product
    app.package_product_dependencies << dependency
    link = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    link.product_ref = dependency
    app.frameworks_build_phase.files << link
  end
  # Each bundle identifier has its own Firebase registration. The research
  # blade build names its own configuration file here.
  config = ENV.fetch('TRAINER_FIREBASE_CONFIG', 'GoogleService-Info.plist')
  if File.exist?(config)
    raise 'Expected GoogleService-Info.plist' unless File.basename(config) == 'GoogleService-Info.plist'
    app.add_resources([project.main_group.new_file(config)])
  end
  # App Attest needs the capability on the App ID. Builds that verify with an
  # App Check debug token leave it off.
  if ENV['TRAINER_APP_ATTEST']
    app.build_configurations.each do |configuration|
      configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/TrainerFirebase.entitlements'
    end
  end
end
checks.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.intublade.tabletoptrainer.workflow',
    'TEST_TARGET_NAME' => app.name, 'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1'
  )
end
if ENV['TRAINER_BLADE_SDK']
  if ENV['TRAINER_RESEARCH_SCENE']
    scene = File.realpath(ENV.fetch('TRAINER_RESEARCH_SCENE'))
    raise 'Expected PrivateAirway.usdz' unless File.basename(scene) == 'PrivateAirway.usdz'
    app.add_resources([project.main_group.new_file(scene)])
  end
  sdk = File.realpath(ENV.fetch('TRAINER_BLADE_SDK'))
  app.build_configurations.each do |cfg|
    cfg.build_settings.merge!(
      'FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]' => ['$(inherited)', sdk],
      'OTHER_LDFLAGS[sdk=iphoneos*]' => '$(inherited) -framework BaseCamera -framework WDLogger -framework ZMFICamera',
      'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
      'INFOPLIST_FILE' => 'App/BladeInfo.plist',
      'MARKETING_VERSION' => '0.2', 'CURRENT_PROJECT_VERSION' => '2',
      'TRAINER_SDK_PATH' => sdk, 'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO')
  end
  phase = app.new_shell_script_build_phase('Embed licensed blade frameworks')
  phase.shell_script = <<~'SH'
    set -eu
    [ "$PLATFORM_NAME" = iphoneos ] || exit 0
    destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
    mkdir -p "$destination"
    for name in BaseCamera WDLogger ZMFICamera; do
      rsync -a --exclude Headers --exclude PrivateHeaders --exclude Modules "$TRAINER_SDK_PATH/$name.framework" "$destination/"
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$destination/$name.framework"
    done
  SH
end

if ENV['TRAINER_BLADE_SDK'] && ENV['TRAINER_OPENCV_DIR']
  fixture = project.main_group.new_group('Fixture', 'Fixture')
  app.add_file_references([fixture.new_file('FixtureReader.mm')])
  app.add_resources([fixture.new_file('FixtureMarks.json')])
  if ENV['TRAINER_FIXTURE_REPLAY']
    ref = project.main_group.new_file('.fixture-local/FixtureReplay')
    ref.last_known_file_type = 'folder'
    app.add_resources([ref])
  end
  app.build_configurations.each do |cfg|
    cv = File.realpath(ENV.fetch('TRAINER_OPENCV_DIR'))
    cfg.build_settings['FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]'] << cv
    cfg.build_settings['OTHER_LDFLAGS[sdk=iphoneos*]'] += ' -framework opencv2 -lc++ -lz -framework Accelerate -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework CoreGraphics -framework AssetsLibrary'
    cfg.build_settings['SWIFT_OBJC_BRIDGING_HEADER[sdk=iphoneos*]'] = 'Fixture/FixtureReader.h'
    cfg.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]'] = '$(inherited) FIXTURE_TRACKING'
    cfg.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
    cfg.build_settings['EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*]'] = 'FixtureReader.mm'
  end
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(checks)
scheme.save_as(project.path, app.name, true)
