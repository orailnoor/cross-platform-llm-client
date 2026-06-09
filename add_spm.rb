require 'xcodeproj'

project_path = 'ios/Runner.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Add the SPM package reference
package_url = 'https://github.com/apple/ml-stable-diffusion.git'
package_req = {
  kind: 'upToNextMinorVersion',
  minimumVersion: '1.1.0' # Using 1.1.0 which is stable for CoreML
}

# Check if already added
already_added = project.root_object.package_references.find { |p| p.repositoryURL == package_url }

unless already_added
  puts "Adding ml-stable-diffusion SPM package..."
  pkg_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg_ref.repositoryURL = package_url
  pkg_ref.requirement = package_req
  project.root_object.package_references << pkg_ref

  # Find the Runner target
  target = project.targets.find { |t| t.name == 'Runner' }

  if target
    # Create the package product dependency
    prod_ref = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    prod_ref.package = pkg_ref
    prod_ref.product_name = 'StableDiffusion'

    # Add it to the target's dependencies
    target_dep = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
    target_dep.product_ref = prod_ref
    target.dependencies << target_dep

    # We also need to add it to the build phase (Frameworks)
    frameworks_phase = target.frameworks_build_phase
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = prod_ref
    frameworks_phase.files << build_file
    
    puts "Successfully linked StableDiffusion to Runner target."
  else
    puts "Could not find Runner target!"
  end

  project.save
  puts "Saved project."
else
  puts "Package already exists in project."
end
