#!/usr/bin/env ruby
# Optional regeneration only. The generated project is committed for Xcode users.
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Examples/Apple/SBV2Demo.xcodeproj'))
source = project.main_group.new_file('SBV2Demo.swift')
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = '../..'
project.root_object.package_references << package
[['SBV2Demo-iOS', :ios, '18.0'], ['SBV2Demo-macOS', :osx, '15.0']].each do |name, platform, version|
  target = project.new_target(:application, name, platform, version)
  target.source_build_phase.add_file_reference(source)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = 'SBV2CoreML'
  target.package_product_dependencies << dependency
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => platform == :ios ? 'org.example.sbv2coreml.demo' : 'org.example.sbv2coreml.demo.mac',
      'PRODUCT_NAME' => 'SBV2Demo', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'SWIFT_VERSION' => '5.0', 'MARKETING_VERSION' => '0.1.0', 'CURRENT_PROJECT_VERSION' => '1',
      'CODE_SIGN_STYLE' => 'Automatic', 'INFOPLIST_KEY_CFBundleDisplayName' => 'SBV2 Core ML',
      'INFOPLIST_KEY_UIFileSharingEnabled' => 'YES', 'INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace' => 'YES',
      'INFOPLIST_KEY_UILaunchScreen_Generation' => 'YES', 'ENABLE_APP_SANDBOX' => 'NO',
      'ENABLE_HARDENED_RUNTIME' => 'YES'
    })
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2' if platform == :ios
    config.build_settings['ARCHS'] = 'arm64' if platform == :osx
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(project.path, name, true)
end
project.save
puts project.path
