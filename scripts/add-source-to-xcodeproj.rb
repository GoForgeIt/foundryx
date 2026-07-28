#!/usr/bin/env ruby
# add-source-to-xcodeproj.rb — register a new Swift source with FoundryX.xcodeproj.
#
# The project uses explicit PBXFileReference entries (not Xcode 16 synchronized folder
# groups), so a file added to Sources/FoundryXKit or App/ builds fine under SwiftPM
# (`swift test`) while the iOS app target silently cannot see it — the failure surfaces
# only as "cannot find X in scope" at xcodebuild time, which is exactly the
# swift-test-is-not-a-build-gate trap. This wires the file into the same group and the
# same targets as an existing sibling in its directory, so a new file inherits whatever
# membership its neighbours already have.
#
#   ruby scripts/add-source-to-xcodeproj.rb Sources/FoundryXKit/PassageProgress.swift ...
#
# Idempotent: a path already present is reported and skipped.

require 'xcodeproj'

PROJECT = File.expand_path('../FoundryX.xcodeproj', __dir__)
paths = ARGV
abort("usage: add-source-to-xcodeproj.rb <path> [<path>...]") if paths.empty?

project = Xcodeproj::Project.open(PROJECT)
changed = false

paths.each do |rel|
  rel = rel.sub(%r{\A\./}, '')
  abort("no such file: #{rel}") unless File.exist?(File.expand_path("../#{rel}", __dir__))

  if project.files.any? { |f| f.real_path.to_s.end_with?("/#{rel}") }
    puts "= already registered: #{rel}"
    next
  end

  dir = File.dirname(rel)
  # A sibling already in the project tells us both the group to join and the targets
  # to join — guessing either independently is how a file ends up compiling for the
  # app but not the widget extension.
  sibling = project.files.find do |f|
    p = f.real_path.to_s
    File.dirname(p).end_with?("/#{dir}") && p.end_with?('.swift') && !p.end_with?("/#{rel}")
  end
  abort("no sibling .swift already in the project under #{dir}/ — add this one by hand") unless sibling

  group = sibling.parent
  ref = group.new_reference(File.basename(rel))

  targets = project.targets.select do |t|
    t.source_build_phase.files.any? { |bf| bf.file_ref == sibling }
  end
  abort("sibling #{sibling.path} belongs to no target's Sources phase") if targets.empty?

  targets.each { |t| t.source_build_phase.add_file_reference(ref) }
  puts "+ #{rel} → group #{group.display_name}, targets: #{targets.map(&:name).join(', ')}"
  changed = true
end

if changed
  project.save
  puts "saved #{PROJECT}"
else
  puts "nothing to do"
end
