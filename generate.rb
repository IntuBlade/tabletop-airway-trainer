require 'xcodeproj'

Dir.chdir(__dir__)
firebase = ENV['TRAINER_FIREBASE'] == '1'
name = firebase ? 'TabletopTrainerFirebase' : 'TabletopTrainer'
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
  if File.exist?('GoogleService-Info.plist')
    app.add_resources([project.main_group.new_file('GoogleService-Info.plist')])
  end
  app.build_configurations.each do |configuration|
    configuration.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/TrainerFirebase.entitlements'
  end
end
checks.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'com.intublade.tabletoptrainer.workflow',
    'TEST_TARGET_NAME' => app.name, 'SWIFT_VERSION' => '5.0', 'TARGETED_DEVICE_FAMILY' => '1'
  )
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(checks)
scheme.save_as(project.path, app.name, true)
